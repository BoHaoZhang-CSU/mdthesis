"""压缩包解包（zip / tar 系 / 7z / rar）。

为什么不能只靠扩展名
--------------------
用户会把 zip 改名成 `数据包.数据`，也会把 rar 当 zip 传上来。一律按**文件头**
识别；识别不出来的再退回 markdown。

各格式怎么解
------------
- zip           Python zipfile（已有加固逻辑在 validate.py）
- tar 系        Python tarfile（tar / tar.gz / tar.bz2 / tar.xz；zst 视 Python 版本）
- 7z / rar      外部工具：优先 7z/7zz（官方 7-Zip），其次 bsdtar（libarchive）
                官方 7-Zip 的解压质量最好；Debian 主仓库的 7zip 包**不含 RAR**
                （unRAR 代码在 non-free），所以 rar 实际会走 bsdtar。
                Dockerfile 里因此装了 libarchive-tools（+ 7zip）。

安全底线
--------
- 解压前先列清单：条目数、解压后总量、加密标记；超限直接拒绝（防 zip bomb）
- 路径不许绝对、不许 `..`、不许盘符；解压后再走一遍树，拒绝符号链接
- 加密压缩包不支持（对外服务没法要密码）——给明确提示，不静默失败
"""
from __future__ import annotations

import io
import os
import re
import shutil
import signal
import subprocess
import tarfile
import zipfile
from pathlib import Path

from . import config, validate
from .validate import UploadError

# 外部工具的单个命令超时（秒）。7z/bsdtar 解几十 MB 的包绰绰有余。
EXTERNAL_TIMEOUT = 120


# ---------- 识别 ----------

def detect(data: bytes) -> str | None:
    """按文件头判断压缩格式；不是压缩包返回 None。"""
    if data[:4] in (b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08"):
        return "zip"
    if data[:8] == b"Rar!\x1a\x07\x01\x00" or data[:7] == b"Rar!\x1a\x07\x00":
        return "rar"
    if data[:6] == b"7z\xbc\xaf\x27\x1c":
        return "7z"
    if data[:2] == b"\x1f\x8b":
        return "tar.gz"
    if data[:3] == b"BZh":
        return "tar.bz2"
    if data[:6] == b"\xfd7zXZ\x00":
        return "tar.xz"
    if data[:4] == b"\x28\xb5\x2f\xfd":
        return "tar.zst"
    if len(data) > 262 and data[257:262] == b"ustar":
        return "tar"
    return None


def is_archive(data: bytes) -> bool:
    return detect(data) is not None


# ---------- 外部命令 ----------

def _seven_zip() -> str | None:
    for name in ("7z", "7zz"):
        path = shutil.which(name)
        if path:
            return path
    return None


def _bsdtar() -> str | None:
    return shutil.which("bsdtar")


def _run(cmd: list[str], timeout: int = EXTERNAL_TIMEOUT,
         env_extra: dict | None = None) -> tuple[int, str]:
    """跑外部解压命令；超时整组杀掉（7z 也会 fork 子进程）。"""
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    proc = subprocess.Popen(
        [str(c) for c in cmd],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        env=env,
    )
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        raise UploadError(f"解压超时（超过 {timeout} 秒）", status=413)
    return proc.returncode, out.decode("utf-8", errors="replace")


# ---------- 路径与清单 ----------

def _safe_name(name: str) -> str:
    """校验压缩包内路径；返回规范化后的相对路径。"""
    name = (name or "").replace("\\", "/")
    # 只去掉开头的 "./"，绝不能 lstrip("./") —— 那会把 "../evil" 变成 "evil"，
    # 路径穿越就被"洗白"了（实测踩到）。
    while name.startswith("./"):
        name = name[2:]
    if name in ("", "."):
        return ""          # 根目录条目（tar 从 `.` 打包时常见），跳过即可
    if name == "..":
        raise UploadError("压缩包含非法路径条目")
    parts = Path(name).parts
    if name.startswith("/") or ".." in parts or (len(name) > 1 and name[1] == ":"):
        raise UploadError(f"压缩包含非法路径条目：{name}")
    return name


def _check_limits(count: int, total: int) -> None:
    if count > config.MAX_ZIP_ENTRIES:
        raise UploadError(
            f"压缩包条目过多：{count}，上限 {config.MAX_ZIP_ENTRIES}", status=413)
    if total > config.MAX_UNCOMPRESSED_BYTES:
        raise UploadError(
            f"压缩包解压后过大，超过 "
            f"{config.MAX_UNCOMPRESSED_BYTES / 1048576:.0f} MB", status=413)


def _post_check(dest: Path) -> None:
    """解压后兜底：拒绝符号链接、越界路径，再核一遍总量。"""
    root = dest.resolve()
    count = 0
    total = 0
    for dirpath, dirnames, filenames in os.walk(dest):
        for name in list(dirnames):
            p = Path(dirpath) / name
            if p.is_symlink():
                raise UploadError("压缩包含符号链接，不支持")
        for name in filenames:
            p = Path(dirpath) / name
            if p.is_symlink():
                raise UploadError("压缩包含符号链接，不支持")
            try:
                p.resolve().relative_to(root)
            except ValueError:
                raise UploadError(f"压缩包含非法路径条目：{p}")
            count += 1
            total += p.stat().st_size
    _check_limits(count, total)


# ---------- tar ----------

def _extract_tar(data: bytes, dest: Path) -> None:
    try:
        tf = tarfile.open(fileobj=io.BytesIO(data), mode="r:*")
    except (tarfile.TarError, OSError):
        raise UploadError(
            "压缩包不是有效的 tar（如果是单文件 gz/bz2/xz，请把 md 和图片打包成 zip/tar）")
    with tf:
        members = tf.getmembers()
        total = 0
        checked = []
        for m in members:
            name = _safe_name(m.name)
            if not name:
                continue          # 根目录条目
            if m.isdir():
                checked.append((m, name))
                continue
            if not m.isfile():
                raise UploadError(f"压缩包含链接或设备文件，不支持：{m.name}")
            total += m.size
            _check_limits(len(members), total)
            checked.append((m, name))
        _check_limits(len(members), total)
        for m, name in checked:
            target = dest / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if m.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            src = tf.extractfile(m)
            if src is None:
                continue
            with open(target, "wb") as out:
                while chunk := src.read(1 << 20):
                    out.write(chunk)
    _post_check(dest)


# ---------- 7z / rar ----------

def _list_7z(tool: str, path: Path) -> list[tuple[str, int]]:
    rc, out = _run([tool, "l", "-slt", "-bd", "-y", str(path)])
    if rc != 0:
        raise UploadError(
            "无法读取压缩包（可能已加密、损坏，或需要密码）", status=422)
    entries: list[tuple[str, int]] = []
    started = False
    cur: dict[str, str] = {}

    def flush():
        if not cur:
            return
        name = cur.get("Path", "")
        if name and name != str(path):
            if cur.get("Encrypted") == "+":
                raise UploadError("不支持加密压缩包，请先解压后重新打包", status=422)
            attrs = cur.get("Attributes", "")
            mode = attrs.split()[-1] if attrs else ""
            if mode.startswith("l"):
                raise UploadError(f"压缩包含符号链接，不支持：{name}")
            size = int(cur.get("Size") or 0)
            safe = _safe_name(name)
            if safe:
                entries.append((safe, size))
        cur.clear()

    for line in out.splitlines():
        if line.startswith("----------"):
            started = True
            continue
        if not started:
            continue
        if not line.strip():
            flush()
        elif " = " in line:
            k, v = line.split(" = ", 1)
            cur[k.strip()] = v.strip()
    flush()
    return entries


_BSD_LINE = re.compile(
    r"^(\S+)\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\S+\s+\S+\s+(.*)$")


def _list_bsdtar(tool: str, path: Path) -> list[tuple[str, int]]:
    # C.UTF-8：RAR 里的 UTF-16BE 文件名需要可转换的目标编码；
    # 用 C 会导致 "Pathname cannot be converted from UTF-16BE" 并整体失败（踩过）。
    rc, out = _run([tool, "-tvf", str(path)], env_extra={"LC_ALL": "C.UTF-8"})
    if rc != 0:
        raise UploadError(
            "无法读取压缩包（可能已加密、损坏，或需要密码）", status=422)
    entries: list[tuple[str, int]] = []
    for line in out.splitlines():
        if not line.strip():
            continue
        m = _BSD_LINE.match(line)
        if not m:
            raise UploadError(f"无法校验压缩包内容：{line[:60]}", status=422)
        mode, size, name = m.group(1), int(m.group(2)), m.group(3)
        if mode.startswith("l"):
            raise UploadError(f"压缩包含符号链接，不支持：{name}")
        safe = _safe_name(name)
        if safe:
            entries.append((safe, size))
    return entries


def _extract_external(data: bytes, dest: Path, fmt: str) -> None:
    tool7 = _seven_zip()
    bsd = _bsdtar()
    # 7z 官方工具解 7z 最稳；rar 只能靠 bsdtar（Debian 的 7zip 不含 unRAR 代码）
    order: list[tuple[str, str]] = []
    if tool7:
        order.append(("7z", tool7))
    if bsd:
        order.append(("bsdtar", bsd))
    if not order:
        raise UploadError(
            "服务器没有可用的解压工具（需要 7z 或 bsdtar），"
            "请把文件打包成 zip 后重试", status=503)

    archive_path = dest.parent / f"archive-{fmt}"
    archive_path.write_bytes(data)
    errors: list[str] = []
    for kind, tool in order:
        try:
            entries = (_list_7z(tool, archive_path) if kind == "7z"
                       else _list_bsdtar(tool, archive_path))
            _check_limits(len(entries), sum(s for _, s in entries))
            if kind == "7z":
                rc, out = _run([tool, "x", "-y", "-bd", f"-o{dest}", str(archive_path)])
            else:
                rc, out = _run([tool, "-xf", str(archive_path), "-C", str(dest),
                                "--no-same-owner"],
                               env_extra={"LC_ALL": "C.UTF-8"})
            if rc != 0:
                errors.append(f"{kind}: {out.strip()[-300:]}")
                continue
            _post_check(dest)
            archive_path.unlink(missing_ok=True)
            return
        except UploadError as e:
            # 工具不支持这种格式时换下一个；真正的安全/限额错误直接抛
            if e.status in (413, 422) and "无法读取" in e.message:
                errors.append(f"{kind}: {e.message}")
                continue
            raise
    detail = "；".join(errors[-2:]).replace("\n", " ").strip()
    if len(detail) > 160:
        detail = detail[:160] + "…"
    raise UploadError(
        "解压失败：压缩包可能已损坏、使用了不支持的压缩算法，或需要更高版本的工具。"
        "请改用 zip 重新打包。"
        + (f"（{detail}）" if detail else ""), status=422)


# ---------- 对外 ----------

def extract(data: bytes, dest: Path) -> str:
    """把压缩包解到 dest，返回识别到的格式。"""
    fmt = detect(data) or "zip"   # 兼容旧调用：识别不出来时按 zip 试一次
    dest.mkdir(parents=True, exist_ok=True)

    if fmt == "zip":
        archive = dest.parent / "package.zip"
        archive.write_bytes(data)
        try:
            infos = validate.check_package(archive)
        except validate.UploadError:
            raise
        validate.extract_package(infos, archive, dest)
        archive.unlink(missing_ok=True)
        _post_check(dest)
    elif fmt in ("tar", "tar.gz", "tar.bz2", "tar.xz"):
        _extract_tar(data, dest)
    else:
        _extract_external(data, dest, fmt)
    return fmt
