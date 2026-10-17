"""上传校验。

用户上传的 docx 本质是个 zip，而且在后续流程里会被**逐个条目读进内存**
（tools/ 下的脚本就是这么读的），所以必须先把炸弹挡在外面。

注意：tools/ 里的脚本用**正则**处理 styles.xml，不做 XML 解析 —— 这样绕开了
XXE 和 billion laughs。千万不要为了"更规范"改成 minidom/ElementTree。
"""
import zipfile
from pathlib import Path

from . import config


class UploadError(Exception):
    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.message = message
        self.status = status


def check_md_size(data: bytes) -> None:
    if len(data) > config.MAX_MD_BYTES:
        raise UploadError(
            f"markdown 文件过大：{len(data) / 1048576:.1f} MB，"
            f"上限 {config.MAX_MD_BYTES / 1048576:.0f} MB",
            status=413,
        )
    if not data.strip():
        raise UploadError("markdown 文件是空的")


def check_docx_safety(path: Path) -> None:
    """把一个不可信的 docx 挡在 zip 层面。通过则返回，否则抛 UploadError。"""
    try:
        zf = zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        raise UploadError("模板不是有效的 docx（不是合法的 zip 包）")
    except OSError as e:
        raise UploadError(f"模板文件无法读取：{e}")

    with zf:
        infos = zf.infolist()

        if len(infos) > config.MAX_ZIP_ENTRIES:
            raise UploadError(
                f"模板 zip 条目过多：{len(infos)}，上限 {config.MAX_ZIP_ENTRIES}"
            )

        total = 0
        for info in infos:
            name = info.filename

            # 路径穿越：绝不接受绝对路径或带 .. 的条目
            if name.startswith("/") or ".." in Path(name).parts:
                raise UploadError(f"模板 zip 含非法路径条目：{name}")

            total += info.file_size
            if total > config.MAX_UNCOMPRESSED_BYTES:
                raise UploadError(
                    f"模板解压后过大，超过 {config.MAX_UNCOMPRESSED_BYTES / 1048576:.0f} MB"
                )

            # zip bomb：单个条目压缩比异常
            if info.compress_size > 0:
                ratio = info.file_size / info.compress_size
                if ratio > config.MAX_COMPRESSION_RATIO and info.file_size > 1048576:
                    raise UploadError(
                        f"模板条目压缩比异常（{ratio:.0f}:1），疑似 zip bomb：{name}"
                    )

        names = set(zf.namelist())
        for required in ("[Content_Types].xml", "word/styles.xml"):
            if required not in names:
                raise UploadError(f"模板缺少必需部件：{required}（不是有效的 Word 文档）")

        # 样式表能不能读出来
        try:
            zf.read("word/styles.xml")
        except Exception as e:
            raise UploadError(f"模板的 word/styles.xml 无法读取：{e}")

    # 到这一步 zip 层面是干净的。样式层面的校验交给 prepare_template.py ——
    # 它找不到 heading 2 会以非零码退出并给出明确信息。


# ---------- 图片上传 ----------

# 只收 docx 塞得进去、pandoc/WPS 都能渲染的格式。svg 不行（需要 rsvg，
# 而且 Word 不同版本支持不一），让用户导出 PNG。
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tif", ".tiff"}
_EXT_BY_KIND = {"png": ".png", "jpg": ".jpg", "gif": ".gif", "bmp": ".bmp",
                "webp": ".webp", "tiff": ".tif"}


def _image_kind(data: bytes) -> str | None:
    """按文件头认图片类型 —— 只看扩展名等于把任意文件当图片收。"""
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if data.startswith((b"GIF87a", b"GIF89a")):
        return "gif"
    if data.startswith(b"BM"):
        return "bmp"
    if len(data) >= 12 and data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return "webp"
    if data.startswith((b"II*\x00", b"MM\x00*")):
        return "tiff"
    return None


def sanitize_upload_name(name: str) -> str:
    """把上传文件名变成安全的纯文件名（不带任何路径）。"""
    base = (name or "").replace("\\", "/").split("/")[-1]
    base = "".join(c for c in base if c.isprintable() and c not in "\x00")
    base = base.strip().strip(".")
    if not base:
        raise UploadError("上传的文件名无效")
    if len(base) > 200:
        stem, dot, ext = base.rpartition(".")
        base = (stem[:190] + dot + ext) if dot else base[:200]
    return base


def check_image(name: str, data: bytes) -> str:
    """校验一张图片，返回安全的文件名（扩展名按真实类型校正）。"""
    safe = sanitize_upload_name(name)
    if len(data) > config.MAX_IMAGE_BYTES:
        raise UploadError(
            f"图片过大：{safe}（{len(data) / 1048576:.1f} MB），"
            f"单张上限 {config.MAX_IMAGE_BYTES / 1048576:.0f} MB",
            status=413,
        )
    kind = _image_kind(data)
    if kind is None:
        raise UploadError(f"不是支持的图片格式：{safe}（支持 png/jpg/gif/bmp/webp/tif）")
    ext = Path(safe).suffix.lower()
    if ext not in IMAGE_EXTS:
        raise UploadError(f"图片扩展名不支持：{safe}")
    if ext not in (".jpg", ".jpeg") or kind != "jpg":
        # 扩展名和真实类型对不上时以文件头为准 —— 否则 Word 里会渲染失败
        safe = str(Path(safe).with_suffix(_EXT_BY_KIND[kind]))
    return safe


# ---------- zip 包（图片 + markdown） ----------

def check_package(path: Path) -> list[zipfile.ZipInfo]:
    """在解压前挡掉非法路径、zip bomb、超大包。"""
    try:
        zf = zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        raise UploadError("压缩包不是有效的 zip")
    except OSError as e:
        raise UploadError(f"压缩包无法读取：{e}")

    with zf:
        infos = [i for i in zf.infolist() if not i.is_dir()]
        if len(infos) > config.MAX_ZIP_ENTRIES:
            raise UploadError(
                f"压缩包条目过多：{len(infos)}，上限 {config.MAX_ZIP_ENTRIES}")
        total = 0
        for info in infos:
            name = info.filename
            parts = Path(name.replace("\\", "/")).parts
            if name.startswith(("/", "\\")) or ".." in parts or (
                    len(name) > 1 and name[1] == ":"):
                raise UploadError(f"压缩包含非法路径条目：{name}")
            total += info.file_size
            if total > config.MAX_UNCOMPRESSED_BYTES:
                raise UploadError(
                    f"压缩包解压后过大，超过 {config.MAX_UNCOMPRESSED_BYTES / 1048576:.0f} MB")
            if info.compress_size > 0 and info.file_size > 1048576:
                ratio = info.file_size / info.compress_size
                if ratio > config.MAX_COMPRESSION_RATIO:
                    raise UploadError(
                        f"条目压缩比异常（{ratio:.0f}:1），疑似 zip bomb：{name}")
    return infos


def extract_package(infos: list[zipfile.ZipInfo], src: Path, dest: Path) -> None:
    """按原目录结构解压（路径已在 check_package 里校验过）。"""
    with zipfile.ZipFile(src) as zf:
        for info in infos:
            name = info.filename.replace("\\", "/")
            if name.startswith("__MACOSX/") or name.endswith("/.DS_Store") or name == ".DS_Store":
                continue
            target = dest / name
            try:
                target.resolve().relative_to(dest.resolve())
            except ValueError:
                raise UploadError(f"压缩包含非法路径条目：{info.filename}")
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as fh, open(target, "wb") as out:
                while chunk := fh.read(1 << 20):
                    out.write(chunk)
