#!/usr/bin/env python3
"""把 markdown 里的图片引用解析成 pandoc 能直接读到的安全相对路径。

为什么需要这一步
----------------
真实用户给的东西不是「干净的 markdown + 同目录图片」：

  · Obsidian 导出包用 `![[figures/2-1.png]]` 这种 wiki 嵌入语法 —— pandoc
    **根本不认**，会原样当文字输出（实测：31 张图一张都进不了 docx）。
  · 图片目录名五花八门（figures / images / pics / 图片 / assets …），
    甚至同一份文档里 `figures/x.png` 和裸 `x.png` 混着写。
  · 引用里还可能有 `./`、反斜杠、URL 编码、大小写不一致。

做法
----
按「**精确路径 → 全包按文件名**」解析，找到后把引用改写成相对当前工作目录的
安全路径（不含绝对路径、不含 `..`）。**用户的原 md 一个字不改** —— 改写只写进
一个临时副本，pandoc 读那个副本。

安全
----
只允许从给定的搜索根目录里找文件（默认 = 当前工作目录，递归）。绝对路径和
`..` 一律不直接读，而是退回按文件名在根目录内查找 —— 服务端因此拿不到
根目录以外的任何文件，和 filter 里的 check_resources 是同一套底线。

用法
----
    python3 -I tools/resolve_resources.py <输入.md> <输出.md> [搜索根 ...]

结果（改了什么 / 缺了什么 / 哪些是猜的）写进 THESIS_WARNINGS_FILE（JSONL），
与 filter 的汇报通道同格式。
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote

# 能嵌进 docx 的图片类型。svg 不算 —— pandoc 转 docx 不可靠（需要 rsvg），
# 让用户导出 PNG 比悄悄失败好。
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tif", ".tiff"}

# 目录遍历上限：防止用户在根目录放一个巨型目录树把转换拖死
MAX_SCANNED_FILES = 20000

# Obsidian 别名写成纯数字/宽x高/百分比 时是宽度，其余一律当题注文字
_WIDTH_ALIAS = re.compile(r"^\d+(x\d+)?(px)?$|^\d+(\.\d+)?%$")

_EMBED = re.compile(r"!\[\[([^\]]+)\]\]")
_MD_IMAGE = re.compile(r'!\[([^\]]*)\]\(\s*([^)\s]+)(\s+"[^"]*")?\s*\)')
_FENCE = re.compile(r"^\s*(```|~~~)")


class Resolver:
    def __init__(self, md_path: Path, roots: list[Path]):
        self.md_path = md_path
        self.md_dir = md_path.parent
        self.cwd = Path.cwd()
        # 去重：convert.sh 会传「当前目录」和「md 所在目录」，两者常常是同一个。
        # 不去重的话索引里每个文件会有两份，按文件名查找时永远「重名，无法确定」。
        seen: list[Path] = []
        for r in roots:
            rp = r.resolve()
            if rp not in seen:
                seen.append(rp)
        self.roots = seen
        self.index: dict[str, list[Path]] | None = None
        self.changes: list[str] = []
        self.guesses: list[str] = []
        self.warnings: list[str] = []
        self.embeds = 0
        self.rewritten = 0
        self._copied: dict[str, Path] = {}

    # ---------- 文件索引 ----------

    def _build_index(self) -> dict[str, list[Path]]:
        if self.index is not None:
            return self.index
        idx: dict[str, list[Path]] = {}
        n = 0
        for root in self.roots:
            if not root.is_dir():
                continue
            for dirpath, dirnames, filenames in os.walk(root):
                # 跳过隐藏目录（.git / __MACOSX …），它们不可能是用户的图片目录
                dirnames[:] = [d for d in dirnames if not d.startswith(".")]
                for fn in filenames:
                    n += 1
                    if n > MAX_SCANNED_FILES:
                        self.warnings.append(
                            f"图片搜索超过 {MAX_SCANNED_FILES} 个文件，后面的不再查找"
                        )
                        self.index = idx
                        return idx
                    if Path(fn).suffix.lower() in IMAGE_EXTS:
                        idx.setdefault(fn.lower(), []).append(Path(dirpath) / fn)
        self.index = idx
        return idx

    # ---------- 解析 ----------

    @staticmethod
    def _clean_ref(ref: str) -> str:
        ref = unquote(ref.strip())
        ref = ref.replace("\\", "/")
        while ref.startswith("./"):
            ref = ref[2:]
        return ref

    def _inside_roots(self, p: Path) -> bool:
        try:
            rp = p.resolve()
        except OSError:
            return False
        for root in self.roots:
            try:
                rp.relative_to(root)
                return True
            except ValueError:
                continue
        return False

    def _basename_hits(self, ref: str) -> list[Path]:
        name = os.path.basename(ref).lower()
        return list(self._build_index().get(name, []))

    def _prefer(self, ref: str, hits: list[Path]) -> tuple[Path | None, str]:
        """多个同名文件时挑一个。返回 (文件, 判断说明)。"""
        if len(hits) == 1:
            return hits[0], ""
        parent = os.path.basename(os.path.dirname(ref)) if "/" in ref else ""
        if parent:
            same = [p for p in hits if p.parent.name.lower() == parent.lower()]
            if len(same) == 1:
                return same[0], "按目录名匹配"
            if same:
                hits = same
        # 离 md 最近的优先（路径层数少、共同前缀长）
        def closeness(p: Path) -> tuple[int, int]:
            try:
                rel = Path(os.path.relpath(p, self.md_dir))
                return (len(rel.parts), len(str(rel)))
            except ValueError:
                return (99, len(str(p)))
        hits = sorted(hits, key=closeness)
        if len(hits) >= 2 and closeness(hits[0]) == closeness(hits[1]):
            return None, "重名，无法确定"
        return hits[0], "多个同名文件，取了最近的一个"

    def resolve(self, raw_ref: str) -> Path | None:
        """按 精确路径 → 按文件名 解析；只允许根目录内的文件。"""
        ref = self._clean_ref(raw_ref)
        if not ref:
            return None

        # 1) 相对 md 的路径。允许 ../ —— 只要**解析后仍在搜索根内**：
        #    `reports/x.md` 引用 `../figures/a.png` 是常见布局（真实样本）。
        #    绝对路径同理：根外的（/etc/...）一律不读，退回按文件名找。
        cand = (self.md_dir / ref)
        if cand.is_file() and self._inside_roots(cand):
            return cand

        # 2) 按文件名在整个包里找
        hits = self._basename_hits(ref)
        if not hits:
            return None
        pick, why = self._prefer(ref, hits)
        if pick is None:
            self.warnings.append(f"图片 {raw_ref} —— {why}")
            return None
        if pick.name != os.path.basename(raw_ref) and pick.name.lower() == os.path.basename(raw_ref).lower():
            self.guesses.append(f"图片 {raw_ref} 按大小写不敏感匹配到 {pick.name}")
        elif why:
            self.guesses.append(f"图片 {raw_ref} —— {why}：{pick}")
        return pick

    def safe_target(self, target: Path) -> str:
        """把实际文件变成一个相对 cwd、不含 .. 的安全引用。"""
        rel = os.path.relpath(target, self.cwd)
        if not rel.startswith(".."):
            return rel.replace(os.sep, "/")
        # 在 cwd 之外（例如 CLI 从别的目录调用）：复制进工作目录下的隐藏目录
        name = target.name
        dest = self.cwd / ".resolved_media" / name
        if name in self._copied:
            return self._copied[name].relative_to(self.cwd).as_posix()
        dest.parent.mkdir(parents=True, exist_ok=True)
        k = 1
        while dest.exists() and dest.read_bytes() != target.read_bytes():
            dest = dest.with_name(f"{Path(name).stem}-{k}{Path(name).suffix}")
            k += 1
        if not dest.exists():
            dest.write_bytes(target.read_bytes())
        self._copied[name] = dest
        return dest.relative_to(self.cwd).as_posix()

    # ---------- 改写 ----------

    @staticmethod
    def _stem(ref: str) -> str:
        return Path(os.path.basename(ref)).stem

    def _rewrite_embed(self, m: re.Match) -> str:
        spec = m.group(1)
        path, _, alias = spec.partition("|")
        path = path.split("#", 1)[0].strip()
        if Path(path).suffix.lower() not in IMAGE_EXTS:
            self.warnings.append(f"嵌入 ![[{spec}]] 不是图片，未处理")
            return m.group(0)
        target = self.resolve(path)
        if target is None:
            self.warnings.append(f"找不到嵌入的图片：{path}")
            return m.group(0)
        self.embeds += 1
        rel = self.safe_target(target)
        alias = alias.strip()
        width = ""
        caption = alias
        if alias and _WIDTH_ALIAS.fullmatch(alias):
            caption = ""
            if alias.endswith("%"):
                width = f"{{width={alias}}}"
            else:
                # Obsidian 的 300 / 300px / 300x200 都是宽度（高度不单独指定，
                # 保持比例交给 pandoc；Word 里只认宽度）
                num = alias[:-2] if alias.endswith("px") else alias
                width = f"{{width={num.split('x')[0]}px}}"
        return f"![{caption}]({rel}){width}"

    def _rewrite_image(self, m: re.Match) -> str:
        alt, ref, title = m.group(1), m.group(2), m.group(3) or ""
        if ref.startswith(("data:", "http://", "https://")):
            return m.group(0)   # 外部引用交给 filter 拦截并告警
        if Path(self._clean_ref(ref)).suffix.lower() not in IMAGE_EXTS:
            return m.group(0)
        # 已经是安全且存在的相对路径 → 原样保留
        clean = self._clean_ref(ref)
        unsafe = clean.startswith("/") or ".." in clean.split("/")
        if not unsafe and (self.md_dir / clean).is_file() and self._inside_roots(self.md_dir / clean):
            return m.group(0)
        target = self.resolve(ref)
        if target is None:
            # 交给 pandoc/filter 报「读不到资源」——这里只补一条更具体的
            self.warnings.append(f"找不到图片：{ref}")
            return m.group(0)
        rel = self.safe_target(target)
        if rel != ref:
            self.rewritten += 1
        return f"![{alt}]({rel}{title})"

    def run(self, text: str) -> str:
        out, in_fence = [], False
        for line in text.splitlines(keepends=True):
            if _FENCE.match(line):
                in_fence = not in_fence
                out.append(line)
                continue
            if not in_fence:
                line = _EMBED.sub(self._rewrite_embed, line)
                line = _MD_IMAGE.sub(self._rewrite_image, line)
            out.append(line)
        return "".join(out)

    # ---------- 汇报 ----------

    def report(self) -> None:
        msgs: list[tuple[str, str]] = []
        if self.embeds:
            msgs.append(("change", f"把 {self.embeds} 处 Obsidian 嵌入 ![[…]] 转成了标准图片"))
        if self.rewritten:
            msgs.append(("change", f"按文件名补全了 {self.rewritten} 处图片路径（文件夹名不一致）"))
        msgs += [("guess", g) for g in self.guesses]
        msgs += [("warning", w) for w in self.warnings]
        path = os.getenv("THESIS_WARNINGS_FILE")
        if not path:
            return
        with open(path, "a", encoding="utf-8") as fh:
            for kind, msg in msgs:
                fh.write(json.dumps({"kind": kind, "message": msg}, ensure_ascii=False) + "\n")


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.split("用法")[1].strip(), file=sys.stderr)
        return 2
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    roots = [Path(a) for a in sys.argv[3:]] or [Path.cwd()]
    if not src.is_file():
        print(f"找不到输入文件：{src}", file=sys.stderr)
        return 1
    try:
        text = src.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError:
        text = src.read_text(encoding="utf-8", errors="replace")
    r = Resolver(src.resolve(), roots)
    out = r.run(text)
    dst.write_text(out, encoding="utf-8")
    r.report()
    # 缺图不算失败：pandoc 会把它们变成文字，filter 也会再报一次
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
