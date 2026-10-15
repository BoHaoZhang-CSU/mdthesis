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
import json
import os
import shutil
import signal
import subprocess
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

import re

from . import config


class ConvertError(Exception):
    def __init__(self, message: str, status: int = 500, detail: str = ""):
        super().__init__(message)
        self.message = message
        self.status = status
        self.detail = detail


@dataclass
class ConvertResult:
    docx: bytes
    warnings: list[str] = field(default_factory=list)
    # 转换前自动修的格式问题。用户不该被要求"自己改好再回来"，
    # 所以修复在服务内部完成，这里只回报做了什么、猜了什么。
    changes: list[str] = field(default_factory=list)
    guesses: list[str] = field(default_factory=list)


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
            f"接口只收单个 .md 文件，图片传不上来 —— 含图片的文档请用命令行版转换"
            f"（tools/convert.sh，它会把图片一起读到）。"]


def _read_report(path: Path) -> tuple[list[str], list[str], list[str]]:
    """读 filter 写的结果文件（JSONL），返回 (warnings, changes, guesses)。

    格式：每行一个 {"kind": "...", "message": "..."}，kind ∈ warning/change/guess。
    容忍解析失败的行走（当作 warning），免得格式小改动就把整次转换搞挂。
    """
    if not path.exists():
        return [], [], []
    warnings: list[str] = []
    changes: list[str] = []
    guesses: list[str] = []
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
        {"change": changes, "guess": guesses}.get(kind, warnings).append(msg)
    return warnings, changes, guesses


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
        return _read_report(warnings_file)


def run_convert(
    md_bytes: bytes,
    template_path: Path | None = None,
    uploaded_template: bytes | None = None,
    timeout: int | None = None,
) -> ConvertResult:
    """完整转换。返回 docx 字节 + 报告（告警 / 自动改动 / 判断）。

    自动修复**在 filter 里完成**（它本来就要做这些转换），并回报做了什么 ——
    filter 是唯一的真相来源，Python 侧不再重复实现一遍规则，避免两边不一致。
    用户上传即得结果，不需要"拿回去改完再传一遍"。
    """
    timeout = timeout or config.CONVERT_TIMEOUT

    with _workdir() as workdir:
        (workdir / "input.md").write_bytes(md_bytes)
        warnings_file = workdir / "warnings.txt"
        env = _prepare_env(workdir, warnings_file)

        if uploaded_template is not None:
            (workdir / "uploaded.docx").write_bytes(uploaded_template)
            # 第三个参数是**基准模板**：用户模板里缺的样式从它补齐。
            # 不补的话那些样式会悬空引用，Word 回落到默认格式，
            # 而不是我们这套调好的版式。
            base = _base_template()
            cmd = ["python3", "-I", config.PREPARE_TEMPLATE,
                   "uploaded.docx", "template.docx"]
            if base is not None:
                cmd.append(str(base))
            rc, log = _run(
                cmd, cwd=workdir, timeout=60, env=env, log_path=workdir / "prepare.log",
            )
            if rc != 0:
                last = (log.strip().splitlines() or ["加工失败"])[-1]
                raise ConvertError("模板不可用：" + last, status=422,
                                   detail=log.strip()[-2000:])
            template_path = workdir / "template.docx"

        out_path = workdir / "output.docx"
        cmd = [config.CONVERT_SH, "input.md", out_path]
        if template_path is not None:
            cmd.append(template_path)

        rc, log = _run(cmd, cwd=workdir, timeout=timeout, env=env,
                       log_path=workdir / "convert.log")
        if rc != 0:
            raise ConvertError("转换失败", status=422, detail=log.strip()[-2000:])
        if not out_path.exists():
            raise ConvertError("转换没有产出文件", status=500, detail=log.strip()[-2000:])

        warnings, changes, guesses = _read_report(warnings_file)
        warnings += _resource_warnings(log)      # pandoc 那部分警告单独捞
        return ConvertResult(
            docx=out_path.read_bytes(),
            warnings=warnings,
            changes=changes,
            guesses=guesses,
        )


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
