"""自动修复不合规的 markdown（文本层实现）。

⚠️ **规则必须和 filters/thesis_template.lua 保持一致** —— 否则 `/normalize` 返回的
"修好的 markdown" 和 `/convert` 实际做的事会对不上。
两边都在改时，记得同步，并跑 `tests/regression.sh`（T12/T13 就是专门盯这件事的）。

注意：`/convert` **不依赖这个模块** —— 转换时的自动修复是 filter 在做，
那里才是唯一的执行路径。本模块只服务于 `/normalize`（把修好的 markdown 还给人看）。
"""
import re

CN = "一二三四五六七八九十百"
MAX_BARE_NUM = 99  # 裸数字上限：挡住「2024 年度总结」这类误伤

# 手写编号的常见写法。**顺序有讲究**：先长后短，
# 否则「第3部分」会被「第[..]+[章节篇]」拦不到、而「1.1」会被「1.」吃掉。
_PREFIX_RES = [
    re.compile(r"^\d+(?:\.\d+)+[\.\d]*\s*"),              # 1.1 / 1.1.1 / 1.1.
    re.compile(r"^第[" + CN + r"0-9]+[章节篇]\s*"),          # 第3章 / 第一章 / 第 3 节
    re.compile(r"^第[" + CN + r"0-9]+部分\s*"),              # 第3部分
    re.compile(r"^[（(][" + CN + r"0-9]+[）)]\s*"),          # （一） / (2)
    re.compile(r"^[" + CN + r"]+、\s*"),                     # 一、引言
    re.compile(r"^\d+[\.、．:：）)]\s*"),                     # 1. / 1、/ 1：
]
_BARE_RE = re.compile(r"^(\d+)\s+(\S.*)$")                   # 3 递推最小二乘法辨识方法

HEADING_RE = re.compile(r"^(#{1,6})(\s+)(.*)$")
HR_RE = re.compile(r"^-{3,}\s*$")


def _strip_prefix(text: str):
    """剥掉开头的手写编号，返回剩余部分（**允许为空** —— 编号可能单独成段）。
    不匹配返回 None。"""
    for rx in _PREFIX_RES:
        m = rx.match(text)
        if m:
            return text[m.end():]
    m = _BARE_RE.match(text)
    if m and int(m.group(1)) <= MAX_BARE_NUM:
        return m.group(2)
    return None


def has_number_prefix(text: str) -> bool:
    """整条标题是否以手写编号开头（且编号后还有内容）。"""
    rest = _strip_prefix(text)
    return rest is not None and bool(rest.strip())


def _scan_levels(lines):
    """按层级统计带编号的标题占比。某层超过 60% 才认为这层在用手写编号。

    直接按模式删会误伤「3 个要点」这类正常标题；统计占比能区分
    「整篇都在写编号」和「碰巧标题里有数字」。
    """
    stat = {}
    for line in lines:
        m = HEADING_RE.match(line)
        if not m or len(m.group(1)) < 2:  # 一级标题是论文题目，不动
            continue
        lvl = len(m.group(1))
        s = stat.setdefault(lvl, [0, 0])
        s[0] += 1
        if has_number_prefix(m.group(3)):
            s[1] += 1
    return {lvl: (hit / total) >= 0.6 for lvl, (total, hit) in stat.items()}


def normalize(md: str):
    """返回 (修好的 md, changes, guesses)。

    changes —— 无需判断的修复，做了什么
    guesses —— 需要判断的地方，猜了什么
    """
    lines = md.split("\n")

    # 哪些 --- 是「紧挨标题的章节分隔线」（中间允许夹空行，与 filter 的 Blocks 判据一致）
    drop_hr = set()
    for i, line in enumerate(lines):
        if not HR_RE.match(line):
            continue
        j = i + 1
        while j < len(lines) and not lines[j].strip():
            j += 1
        if j < len(lines) and HEADING_RE.match(lines[j]):
            drop_hr.add(i)

    strip_level = _scan_levels(lines)

    out = []
    n_h1 = 0
    n_h1_demoted = 0
    n_numbered = 0
    n_hr = 0
    h1_titles = []

    for i, line in enumerate(lines):
        if i in drop_hr:
            n_hr += 1
            continue

        m = HEADING_RE.match(line)
        if not m:
            out.append(line)
            continue

        hashes, gap, text = m.group(1), m.group(2), m.group(3)
        level = len(hashes)

        if level == 1:
            h1_titles.append(text.strip())
            n_h1 += 1
            if n_h1 > 1:
                out.append("##" + gap + text)  # 与 filter 一致：多余的降级为章节
                n_h1_demoted += 1
                continue
            out.append(line)
            continue

        if strip_level.get(level):
            rest = _strip_prefix(text)
            if rest is not None and rest.strip():
                out.append(hashes + gap + rest)
                n_numbered += 1
                continue

        out.append(line)

    changes = []
    if n_numbered:
        changes.append(f"去掉 {n_numbered} 处标题里手写的编号")
    if n_hr:
        changes.append(f"删除 {n_hr} 条紧挨章节标题的水平线 ---")
    if n_h1_demoted:
        changes.append(f"把 {n_h1_demoted} 个多余的一级标题降级为二级标题 ##")

    guesses = []
    if n_h1 > 1:
        listed = "、".join(f"「{t}」" for t in h1_titles[:3])
        more = "…" if len(h1_titles) > 3 else ""
        guesses.append(
            f"文档有 {n_h1} 个一级标题（{listed}{more}），已把**第一个**当作论文大标题，"
            f"其余 {n_h1_demoted} 个当作章节。如果猜错了，请手工调整后重新转换。"
        )

    return "\n".join(out), changes, guesses
