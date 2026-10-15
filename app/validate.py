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
