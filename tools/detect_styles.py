"""从用户的 Word 模板里，推断出「哪个样式是章 / 节 / 大标题 / 摘要 / 目录标题」。

**为什么需要**：pandoc 只认标准样式名（`heading 2` 等），但用户模板可能用
「一级标题」「初标2」这类自定义名字 —— 名字猜不出来，只能靠**结构信息**：

  1. **大纲级别**（`w:outlineLvl`）—— 这是语义的。0/1/2 分别对应我们的章/节/小节。
     用户自己起什么名字都不影响。
  2. **模板正文里的样式使用次数** —— 模板本身就是一份真实文档，
     作者实际拿哪个样式当章节用，看用量最准。
     这条很重要：有的模板里 `heading 2` 和内建的「标题 2」都定义了，
     但作者实际用的是第三个样式。

处理顺序（逐级降级，保证任何模板都有结果）：
 ① 名字就是 `heading N`            → 直接用（pandoc 原生认得，什么都不用做）
 ② 同名但没被用过、另有在用的大纲级别对得上的样式 → 把后者改名为 `heading N`
 ③ 都找不到                        → 交给 prepare_template 从基准模板补齐
"""
import re
from collections import Counter

# markdown 标题级别 -> 大纲级别（我们的约定：## 是章，对应大纲 0）
OUTLINE_OF_LEVEL = {2: 0, 3: 1, 4: 2, 5: 3, 6: 4}

# 名字像「正文/默认」的，别当标题
BODY_LIKE = ("normal", "正文", "default", "bodytext", "body text", "普通")
# 名字像「摘要/目录/题注」的，别当章节标题
NON_HEADING = ("摘要", "abstract", "目录", "contents", "toc", "题注",
               "caption", "图题", "表题", "页眉", "页脚", "header", "footer")


def parse_styles(styles_xml):
    """拆成 [{id, name, outline, xml}, ...]（只取段落样式）。"""
    out = []
    for m in re.finditer(r"<w:style\b.*?</w:style>", styles_xml, re.S):
        x = m.group(0)
        if 'w:type="paragraph"' not in x:
            continue
        sid = re.search(r'w:styleId="([^"]+)"', x)
        nm = re.search(r"<w:name w:val=\"([^\"]*)\"", x)
        if not (sid and nm):
            continue
        lvl = re.search(r'<w:outlineLvl w:val="(\d+)"', x)
        out.append({
            "id": sid.group(1),
            "name": nm.group(1),
            "outline": int(lvl.group(1)) if lvl else None,
            "xml": x,
        })
    return out


def style_usage(doc_xml):
    """模板正文里每个样式用了多少次。"""
    return Counter(re.findall(r'<w:pStyle w:val="([^"]+)"', doc_xml))


def _heading_like(name):
    low = name.lower()
    return ("标题" in name or "heading" in low or "title" in low or "标" in name)


def _body_like(name):
    low = name.lower().replace(" ", "")
    return any(b.replace(" ", "") in low for b in BODY_LIKE)


def _non_heading(name):
    low = name.lower()
    return any(t in low for t in NON_HEADING)


def detect_heading_styles(styles_xml, usage):
    """返回 {markdown 级别: 样式 dict}。找不到的级别不出现在结果里。"""
    styles = parse_styles(styles_xml)
    out = {}
    for level, olvl in OUTLINE_OF_LEVEL.items():
        cands = [s for s in styles if s["outline"] == olvl]
        if not cands:
            continue

        def score(s):
            n, low = s["name"], s["name"].lower()
            v = 0
            # ① 名字正好是 pandoc 要的
            if n == f"heading {level}":
                v += 100000
            # ② 名字像标题（而不是正文/摘要/目录）
            if _heading_like(n):
                v += 3000
            if _non_heading(n):
                v -= 20000
            if _body_like(n):
                v -= 20000
            # ③ 模板正文里实际用了多少次 —— 作者的实际选择
            v += min(usage.get(s["id"], 0), 300) * 50
            return v

        best = max(cands, key=score)
        # 全是被排除的（负分）就别用
        if score(best) > 0:
            out[level] = best
    return out


def _rename_by_id(styles_xml, sid, new_name):
    """按 styleId 找到样式并改它的 <w:name>。

    **必须按 ID 找、每次重新定位** —— 不能缓存 XML 文本做 replace：
    前面的改名会让后来者的文本失效，导致替换落空、还会产生重名（踩过）。
    """
    for m in re.finditer(r"<w:style\b.*?</w:style>", styles_xml, re.S):
        blk = m.group(0)
        if re.search(r'w:styleId="%s"' % re.escape(sid), blk):
            new = re.sub(r'(<w:name w:val=")[^"]*(")',
                         lambda mm: mm.group(1) + new_name + mm.group(2), blk, count=1)
            return styles_xml[:m.start()] + new + styles_xml[m.end():], True
    return styles_xml, False


def canonicalize_heading_names(styles_xml, detected):
    """把检测到的章节样式的 `w:name` 改成 pandoc 认识的 `heading N`。

    **为什么改名而不是让 filter 去指定**：markdown 的 `##` 要落到作者的样式上，
    同时必须保留**标题语义**（大纲级别、自动编号、目录收录）。
    改名之后 pandoc 原生映射就能命中，这些语义一个都不丢。

    注意这里会做一次「按大纲级别对齐」的平移：
    我们的约定是 `##` = 章 = 大纲级别 0，所以模板里大纲级别 0 的样式
    （哪怕它叫 `heading 1`）会被改成 `heading 2`。名字变了，但行为是对的
    —— 章节拿到的正是模板作者给「第一层标题」用的那套格式。
    """
    live = {s["id"]: s["name"] for s in parse_styles(styles_xml)}
    renames = []

    for level in sorted(detected):
        s = detected[level]
        sid = s["id"]
        if live.get(sid) == f"heading {level}":
            continue
        want = f"heading {level}"

        # 目标名字被别人占着（通常是个没在用的内建样式）→ 先让它让开，
        # 否则会出现两个同名样式，pandoc 按名字找会指错。
        holder = [i for i, n in live.items() if n == want and i != sid]
        for hid in holder:
            alt = want + "_unused"
            while alt in live.values():
                alt += "_"
            styles_xml, ok = _rename_by_id(styles_xml, hid, alt)
            if ok:
                live[hid] = alt

        old_name = live.get(sid, s["name"])
        styles_xml, ok = _rename_by_id(styles_xml, sid, want)
        if ok:
            live[sid] = want
            renames.append((old_name, want))

    return styles_xml, renames


# ---- 大标题 / 摘要 / 目录标题：这几个没有语义标记，只能靠名字 ----

_NAMED_ROLES = [
    # (角色, 强匹配 —— 名字够特别，直接认, 弱匹配 —— 还要被用过才认)
    #
    # 分两档是为了别把 pandoc 自带的通用样式（Title / Abstract / TOC Heading）
    # 误当成「作者的模板样式」：那会让我们放着调好的中文样式不用，去用通用样式。
    # 注意别匹配到 `toc 1`/`toc 2` —— 那是目录**条目**样式，不是目录**标题**样式
    ("toc", [r"^目录两个字$", r"^目录$", r"^目\s*录$", r"^toc 标题$", r"^toc heading$"],
     [r"目录", r"contents"]),
    ("title", [r"^摘要上标题$", r"^论文题目$", r"^论文标题$", r"^封面标题$"],
     [r"论文", r"封面", r"题目"]),
    ("abstract", [r"^摘要$", r"^abstract$"], [r"^摘\s*要"]),
]


def detect_named_roles(styles_xml, taken_ids, usage=None):
    """返回 {角色: 样式名}。taken_ids 是已分配给章节的样式 id，别重复用。

    找不到的角色**不出现在结果里** —— 调用方回落到我们的默认名，
    那些名字由 prepare_template 从基准模板补齐，一定存在。
    """
    usage = usage or {}
    styles = [s for s in parse_styles(styles_xml) if s["id"] not in taken_ids]
    out, used = {}, set()

    for role, strong, weak in _NAMED_ROLES:
        for pats, need_used in ((strong, False), (weak, True)):
            hit = None
            # **按模式的优先级找**，不是按样式在文件里的顺序 ——
            # 否则英文的 `Abstract` 会因为排在前面而被选中，中文的「摘要」被跳过。
            for pat in pats:
                for s in styles:
                    if s["id"] in used or s["name"] in used:
                        continue
                    if need_used and usage.get(s["id"], 0) <= 0:
                        continue
                    if re.search(pat, s["name"].lower()):
                        hit = s
                        break
                if hit:
                    break
            if hit:
                out[role] = hit["name"]
                used.add(hit["id"])
                used.add(hit["name"])
                break
    return out
