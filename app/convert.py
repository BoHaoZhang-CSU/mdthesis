"""调用现成的转换管线。

刻意**不复制** tools/convert.sh 的逻辑，而是直接调它 —— CLI 和 API 共用同一条管线，
不会漂移；而且 tests/regression.sh 的断言同时覆盖两条路径。

进程管理上有三个必须做对的地方（都实测验证过）：
  1. `start_new_session=True` + `killpg` —— subprocess.run(timeout=) 只杀直接子进程
     （bash），convert.sh 里那个 ~140MB 的 pandoc 会变成孤儿继续占内存。
     在一台空闲内存只剩几百 MB 的机器上，几次超时就能把机器拖死。
  2. stdout/stderr **重定向到文件**，不用 PIPE —— pandoc 遇到诡异输入能刷爆 64KB
     管道缓冲，然后子进程阻塞、请求挂到超时，看起来像"pandoc 卡死"。
  3. TMPDIR 指向请求目录（磁盘）—— 本机 /tmp 是 3.6GB tmpfs，在里面建临时文件等于吃内存。
"""
import io
import json
import os
import shutil
import signal
import subprocess
import tempfile
import zipfile
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

import re

from . import archive, config, validate


class ConvertError(Exception):
    def __init__(self, message: str, status: int = 500, detail: str = ""):
        super().__init__(message)
        self.message = message
        self.status = status
        self.detail = detail


@dataclass
class ConvertResult:
    docx: bytes
    # 下载时建议的文件名（zip 单个 md 时要用内层 md 的名字，不是包名）
    output_name: str = "output.docx"
    is_zip: bool = False
    warnings: list[str] = field(default_factory=list)
    # 转换前自动修的格式问题。用户不该被要求"自己改好再回来"，
    # 所以修复在服务内部完成，这里只回报做了什么、猜了什么。
    changes: list[str] = field(default_factory=list)
    guesses: list[str] = field(default_factory=list)
    # 「识别结果」：从他这篇里读到了什么（大标题 / 章节 / 公式 / 表格 / 图片 / 目录）。
    # 每项 {"label": ..., "message": ...}，网页上按「标签 → 值」两栏显示，
    # 识别错了（比如大标题挑错）用户当场就能看出来。
    stats: list[dict] = field(default_factory=list)


# ---------- 工作目录 ----------

@contextmanager
def _workdir():
    """每请求一个独立目录，建在磁盘上。异常路径也保证清理。"""
    root = config.WORK_ROOT
    root.mkdir(parents=True, exist_ok=True)
    d = Path(tempfile.mkdtemp(prefix="req-", dir=str(root)))
    try:
        yield d
    finally:
        shutil.rmtree(d, ignore_errors=True)


def _prepare_env(workdir: Path, warnings_file: Path) -> dict:
    env = dict(os.environ)
    env["THESIS_WARNINGS_FILE"] = str(warnings_file)
    # 子进程的内部临时文件也落到请求目录（磁盘），别用 /tmp（tmpfs）
    env["TMPDIR"] = str(workdir)
    if config.BLOCK_NETWORK:
        for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy"):
            env[k] = config.DEAD_PROXY
        env["no_proxy"] = ""
        env["NO_PROXY"] = ""
    return env


# ---------- 子进程 ----------

def _kill_group(proc: subprocess.Popen) -> None:
    """整组杀掉。start_new_session 之后 proc.pid 就是新的 pgid。"""
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()


def _run(cmd, cwd: Path, timeout: int, env: dict, log_path: Path) -> tuple[int, str]:
    """跑子进程，返回 (退出码, 合并后的日志)。超时则整组杀掉。"""
    with open(log_path, "wb") as log:
        proc = subprocess.Popen(
            [str(c) for c in cmd],
            cwd=str(cwd),
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            start_new_session=True,  # 关键：自成进程组，超时时能整组带走
        )
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            raise ConvertError(f"转换超时（超过 {timeout} 秒），已终止", status=504)
    text = log_path.read_text(encoding="utf-8", errors="replace")
    return rc, text


# pandoc 自己的资源警告（图片找不到之类）只在 stderr，不写进 filter 的报告文件。
# 不捞出来的话，用户只会看到图片凭空变成一行文字，不知道为什么。
_PANDOC_RES = re.compile(r"^\[WARNING\]\s*Could not fetch resource (\S+?):", re.M)


def _resource_warnings(log: str) -> list[str]:
    """把 pandoc 的「资源取不到」警告转成用户看得懂的话。"""
    names = list(dict.fromkeys(_PANDOC_RES.findall(log)))
    if not names:
        return []
    shown = "、".join(names[:3]) + ("…" if len(names) > 3 else "")
    return [f"{len(names)} 处图片没能读到，已替换成文字（{shown}）。"
            f"请确认图片已随文档上传（zip 里，或与 md 一起选择），"
            f"且文件名与 md 里的引用一致 —— 文件夹名不同没关系，会按文件名找。"]


def _read_report(path: Path) -> tuple[list[str], list[str], list[str], list[dict]]:
    """读 filter 写的结果文件（JSONL），返回 (warnings, changes, guesses, stats)。

    格式：每行一个 {"kind": "...", "message": "..."}，
    kind ∈ warning/change/guess/stat（stat 行额外带 "label"）。
    容忍解析失败的行走（当作 warning），免得格式小改动就把整次转换搞挂。
    """
    if not path.exists():
        return [], [], [], []
    warnings: list[str] = []
    changes: list[str] = []
    guesses: list[str] = []
    stats: list[dict] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
            kind, msg = rec.get("kind", "warning"), rec.get("message", "")
        except (ValueError, AttributeError):
            kind, msg = "warning", line
        if not msg:
            continue
        if kind == "stat":
            stats.append({"label": rec.get("label", ""), "message": msg})
        else:
            {"change": changes, "guess": guesses}.get(kind, warnings).append(msg)
    return warnings, changes, guesses, stats


# ---------- 对外接口 ----------

def run_check(md_bytes: bytes, timeout: int | None = None):
    """只跑 filter 收集报告，不生成 docx（用 -t native，比完整转换快得多）。

    返回 (warnings, changes, guesses) —— 与 run_convert 同源（都来自 filter），
    所以「检查」和「转换」的结论一定一致。
    """
    timeout = timeout or config.CONVERT_TIMEOUT
    with _workdir() as workdir:
        (workdir / "input.md").write_bytes(md_bytes)
        warnings_file = workdir / "report.jsonl"
        env = _prepare_env(workdir, warnings_file)

        rc, log = _run(
            ["pandoc", "input.md", "-f", "markdown", "-t", "native",
             "--lua-filter", config.ROOT / "filters" / "thesis_template.lua",
             "-o", "out.txt"],
            cwd=workdir, timeout=timeout, env=env,
            log_path=workdir / "check.log",
        )
        if rc != 0:
            raise ConvertError("markdown 解析失败", status=422, detail=log.strip()[-2000:])
        return _read_report(warnings_file)[:3]   # /check 只回三份清单，统计归 /convert


def _prepare_template(workdir: Path, uploaded_template: bytes | None,
                      env: dict) -> Path | None:
    """用户模板 → 加工好的模板；没有上传就返回 None（convert.sh 用默认模板）。"""
    if uploaded_template is None:
        return None
    (workdir / "uploaded.docx").write_bytes(uploaded_template)
    # 第三个参数是**基准模板**：用户模板里缺的样式从它补齐。
    # 不补的话那些样式会悬空引用，Word 回落到默认格式，
    # 而不是我们这套调好的版式。
    base = _base_template()
    cmd = ["python3", "-I", config.PREPARE_TEMPLATE,
           "uploaded.docx", "template.docx"]
    if base is not None:
        cmd.append(str(base))
    rc, log = _run(cmd, cwd=workdir, timeout=60, env=env,
                   log_path=workdir / "prepare.log")
    if rc != 0:
        last = (log.strip().splitlines() or ["加工失败"])[-1]
        raise ConvertError("模板不可用：" + last, status=422,
                           detail=log.strip()[-2000:])
    return workdir / "template.docx"


def _write_images(workdir: Path, images: list[tuple[str, bytes]] | None) -> None:
    """把上传的图片放进工作目录；解析器会按文件名从里面找。

    保持扁平结构：多文件上传本来就没有目录信息，md 里写 figures/x.png
    也会按 basename 找到这里的 x.png。
    """
    if not images:
        return
    if len(images) > config.MAX_IMAGE_COUNT:
        raise ConvertError(
            f"图片过多：{len(images)} 张，上限 {config.MAX_IMAGE_COUNT} 张", status=413)
    uploads = workdir / "_uploads"
    uploads.mkdir(parents=True, exist_ok=True)
    total = 0
    for name, data in images:
        try:
            safe = validate.check_image(name, data)
        except validate.UploadError as e:
            raise ConvertError(e.message, status=e.status)
        total += len(data)
        if total > config.MAX_IMAGES_TOTAL_BYTES:
            raise ConvertError(
                f"图片总量过大，上限 {config.MAX_IMAGES_TOTAL_BYTES / 1048576:.0f} MB",
                status=413)
        target = uploads / safe
        if target.exists():
            k = 2
            while (uploads / f"{target.stem}-{k}{target.suffix}").exists():
                k += 1
            target = uploads / f"{target.stem}-{k}{target.suffix}"
        target.write_bytes(data)


def _run_convert_one(cwd: Path, md_name: str, out_path: Path,
                     template_path: Path | None, env: dict, timeout: int,
                     log_path: Path) -> str:
    cmd = [config.CONVERT_SH, md_name, out_path]
    if template_path is not None:
        cmd.append(str(template_path))
    rc, log = _run(cmd, cwd=cwd, timeout=timeout, env=env, log_path=log_path)
    if rc != 0:
        raise ConvertError("转换失败", status=422, detail=log.strip()[-2000:])
    if not out_path.exists():
        raise ConvertError("转换没有产出文件", status=500, detail=log.strip()[-2000:])
    return log


def run_convert(
    md_bytes: bytes,
    template_path: Path | None = None,
    uploaded_template: bytes | None = None,
    timeout: int | None = None,
    images: list[tuple[str, bytes]] | None = None,
    name_hint: str | None = None,
) -> ConvertResult:
    """完整转换。返回 docx 字节 + 报告（告警 / 自动改动 / 判断）。

    自动修复**在 filter 里完成**（它本来就要做这些转换），并回报做了什么 ——
    filter 是唯一的真相来源，Python 侧不再重复实现一遍规则，避免两边不一致。
    用户上传即得结果，不需要"拿回去改完再传一遍"。
    """
    timeout = timeout or config.CONVERT_TIMEOUT

    with _workdir() as workdir:
        (workdir / "input.md").write_bytes(md_bytes)
        _write_images(workdir, images)
        warnings_file = workdir / "warnings.txt"
        env = _prepare_env(workdir, warnings_file)
        # 图片搜索范围限定在本请求目录：上传的图在 _uploads/ 下，
        # 无论如何都读不到别的请求或服务器上的文件。
        env["THESIS_RESOURCE_ROOTS"] = str(workdir)
        template_path = _prepare_template(workdir, uploaded_template, env) or template_path

        out_path = workdir / "output.docx"
        log = _run_convert_one(workdir, "input.md", out_path, template_path,
                               env, timeout, workdir / "convert.log")

        warnings, changes, guesses, stats = _read_report(warnings_file)
        warnings += _resource_warnings(log)      # pandoc 那部分警告单独捞
        stem = Path(name_hint).stem if name_hint else "output"
        return ConvertResult(
            docx=out_path.read_bytes(),
            output_name=stem + ".docx",
            warnings=warnings,
            changes=changes,
            guesses=guesses,
            stats=stats,
        )


# ---------- 压缩包（md + 图片，可能多个 md） ----------

def _natural_key(s: str):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]


def _doc_title(stem: str) -> str:
    """文件名当大标题：去掉开头的「1. / 2、」这类序号。"""
    return re.sub(r"^\s*\d+\s*[.、)]\s*", "", stem).strip() or stem


_H1_LINE = re.compile(r"^\s{0,3}#\s+\S")
_FENCE_LINE = re.compile(r"^\s*(```|~~~)")


def _has_single_h1(text: str) -> bool:
    """md 里恰好有一个一级标题 → 用它当大标题，不要用文件名覆盖。

    多文件包里「文件名当标题」只是**兜底**：
      · 0 个 H1（分章笔记）        → 用文件名
      · 2 个以上 H1（层级有歧义）  → 用文件名，H1 全部降为章节
      · 恰好 1 个 H1（完整论文）   → 保留它（否则真正的标题会被降成第一章）
    """
    count = 0
    in_fence = False
    for line in text.splitlines():
        if _FENCE_LINE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if _H1_LINE.match(line):
            count += 1
            if count > 1:
                return False
    return count == 1


def _unique_name(name: str, used: set[str]) -> str:
    if name not in used:
        used.add(name)
        return name
    stem, ext = os.path.splitext(name)
    k = 2
    while f"{stem} ({k}){ext}" in used:
        k += 1
    out = f"{stem} ({k}){ext}"
    used.add(out)
    return out


def run_convert_package(
    package_bytes: bytes,
    template_path: Path | None = None,
    uploaded_template: bytes | None = None,
    timeout: int | None = None,
    name_hint: str | None = None,
) -> ConvertResult:
    """转换一个压缩包（zip / tar 系 / 7z / rar）：可能有多个 md。

    · 一个 md  → 返回一个 docx
    · 多个 md  → 每个 md 一个 docx，打包成 zip 返回（空 md 也出一个空 docx）
    · 大标题取自文件名（多 md 时），md 里的 H1 降为章节
    """
    timeout = timeout or config.CONVERT_TIMEOUT

    with _workdir() as workdir:
        root = workdir / "pkg"
        try:
            archive.extract(package_bytes, root)
        except validate.UploadError as e:
            raise ConvertError(e.message, status=e.status)

        mds = sorted(
            [p for p in root.rglob("*")
             if p.is_file() and p.suffix.lower() in (".md", ".markdown")
             and not any(part.startswith(".") for part in p.relative_to(root).parts)],
            key=lambda p: _natural_key(str(p.relative_to(root))))
        if not mds:
            raise ConvertError("压缩包里没有 markdown 文件（.md）", status=422)
        if len(mds) > config.MAX_PACKAGE_MD_FILES:
            raise ConvertError(
                f"压缩包里的 markdown 过多：{len(mds)} 个，上限 "
                f"{config.MAX_PACKAGE_MD_FILES} 个", status=413)

        env = _prepare_env(workdir, workdir / "warnings.txt")
        template_path = _prepare_template(workdir, uploaded_template, env) or template_path
        multi = len(mds) > 1

        docs = []
        all_warnings: list[str] = []
        all_changes: list[str] = []
        all_guesses: list[str] = []
        all_stats: list[dict] = []
        for i, md in enumerate(mds):
            rel = md.relative_to(root).as_posix()
            prefix = f"{rel}：" if multi else ""
            wf = workdir / f"warnings-{i}.jsonl"
            doc_env = _prepare_env(workdir, wf)
            # 搜索根 = 解压出来的整个包：md 在 reports/ 里引用 ../figures/a.png
            # 也能找到，但读不到包外的任何文件。
            doc_env["THESIS_RESOURCE_ROOTS"] = str(root)
            if multi:
                # 有且只有一个 H1 的 md 自己就有大标题，别用文件名覆盖它
                try:
                    text = md.read_text(encoding="utf-8-sig", errors="replace")
                except OSError:
                    text = ""
                if not _has_single_h1(text):
                    doc_env["THESIS_DOC_TITLE"] = _doc_title(md.stem)
            out = workdir / f"out-{i}.docx"
            log = _run_convert_one(md.parent, md.name, out, template_path,
                                   doc_env, timeout, workdir / f"convert-{i}.log")
            w, c, g, s = _read_report(wf)
            all_warnings += [prefix + x for x in w] + _resource_warnings(log)
            all_changes += [prefix + x for x in c]
            all_guesses += [prefix + x for x in g]
            if multi:
                all_stats += [{"label": f"{md.stem} · {x['label']}", "message": x["message"]}
                              for x in s]
            else:
                all_stats += s
            docs.append((md, out))

        if not multi:
            md, out = docs[0]
            return ConvertResult(docx=out.read_bytes(),
                                 output_name=md.stem + ".docx",
                                 warnings=all_warnings, changes=all_changes,
                                 guesses=all_guesses, stats=all_stats)

        buf = io.BytesIO()
        used: set[str] = set()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            for md, out in docs:
                zf.write(out, _unique_name(md.stem + ".docx", used))
        stem = Path(name_hint).stem if name_hint else "converted"
        return ConvertResult(docx=buf.getvalue(),
                             output_name=f"{stem}-docx.zip",
                             is_zip=True,
                             warnings=all_warnings, changes=all_changes,
                             guesses=all_guesses, stats=all_stats)


# ---------- 模板 ----------

def _base_template() -> Path | None:
    """基准模板 —— 用户模板里缺的样式从它补齐。

    取模板目录里第一个 .docx，而不是写死文件名：本仓库不带模板，
    使用者放哪个名字就该用哪个。
    """
    if not config.TEMPLATES_DIR.is_dir():
        return None
    for p in sorted(config.TEMPLATES_DIR.glob("*.docx")):
        return p
    return None


def available_templates() -> list[str]:
    if not config.TEMPLATES_DIR.is_dir():
        return []
    return sorted(p.name for p in config.TEMPLATES_DIR.glob("*.docx"))


def resolve_template(name: str | None) -> Path | None:
    """把模板名解析成项目内的路径。None 表示用 convert.sh 的默认模板。

    只接受内置模板名（不接受任何路径分隔符），防止路径穿越。
    """
    if not name:
        return None
    if "/" in name or "\\" in name or ".." in name:
        raise ConvertError(f"模板名非法：{name}", status=400)
    path = config.TEMPLATES_DIR / name
    if not path.is_file():
        raise ConvertError(f"没有这个模板：{name}。可用模板见 GET /templates", status=404)
    return path


def pandoc_version() -> str:
    try:
        out = subprocess.run(["pandoc", "--version"], capture_output=True,
                             text=True, timeout=15).stdout
        return out.splitlines()[0] if out else "unknown"
    except Exception:
        return "unknown"
