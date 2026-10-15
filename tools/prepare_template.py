#!/usr/bin/env python3
"""把 Word 原始模板加工成 pandoc 专用模板。

做两件事：

1. 给「heading 2」样式加上 pageBreakBefore —— 让每一章自动另起一页。
   （这是 Word 的原生机制，模板自己的 heading 1 就是这么做的；比在正文里
     插空段落干净，也不会多出多余段落。）

2. 删掉模板 media/ 里的所有图片及其关系条目 —— pandoc 转换时一律用不到，
   但会把它们全部打包进输出。凝视与回应模板带 4 张图 ≈3.8MB，
   不删的话每次转换的输出都会从 29KB 变成 4MB。

用法:
    python3 prepare_template.py <原始模板.docx> <输出模板.docx>
"""
import json
import re
import sys
import zipfile
from pathlib import Path

# 脚本用 `python3 -I` 跑（隔离模式）—— 它会去掉 sys.path[0]，
# 同目录的模块就 import 不到了。这里显式加回来（加的是自己所在目录，安全）。
sys.path.insert(0, str(Path(__file__).resolve().parent))

from detect_styles import (  # noqa: E402
    canonicalize_heading_names, detect_heading_styles, detect_named_roles, style_usage,
)

src, dst = sys.argv[1], sys.argv[2]
zin = zipfile.ZipFile(src)


# 用户模板里缺这些样式时，从我们的基准模板搬过来补齐。
#
# 不补的话，filter / pandoc 引用的样式名在用户模板里找不到 → 「悬空引用」，
# Word 会**回落到默认格式**，而不是我们这套调好的版式。
#
# 只列管线真正会用到的。用户模板里已有的同名样式优先，不会被覆盖 ——
# 也就是「用户模板决定版式，缺的部分用我们的兜底」。
REQUIRED_STYLES = [
    # 我们自己用的（filter 按 custom-style 指定）
    "摘要上标题", "摘要", "目录两个字",
    # pandoc 的段落样式（按 w:name 匹配）
    "heading 1", "heading 2", "heading 3", "heading 4", "heading 5",
    "heading 6", "heading 7", "heading 8", "heading 9",
    "Body Text", "First Paragraph", "Compact", "Block Text",
    "Caption", "Table Caption", "Image Caption", "Figure", "Captioned Figure",
    "Source Code", "footnote text", "TOC Heading",
    "toc 1", "toc 2", "toc 3", "toc 4", "toc 5",
    "Title", "Subtitle", "Author", "Date", "Abstract", "Abstract Title",
    "Bibliography", "Definition Term", "Definition",
    # 表格（三线表样式就在这）
    "Table", "Normal",
]

# filter 把论文大标题放在这个样式里（见 filters/thesis_template.lua）
TITLE_STYLE_NAME = "摘要上标题"


def _parse_styles(styles_xml):
    """把 styles.xml 拆成 [(styleId, name, 完整XML), ...]。"""
    out = []
    for m in re.finditer(r"<w:style\b.*?</w:style>", styles_xml, re.S):
        x = m.group(0)
        sid = re.search(r'w:styleId="([^"]+)"', x)
        nm = re.search(r'<w:name w:val="([^"]*)"', x)
        if sid and nm:
            out.append((sid.group(1), nm.group(1), x))
    return out


def adapt_to_template(styles_xml, doc_xml, donor_path):
    """让我们的转换适配用户模板的样式命名。

    用户模板可能有四种情况：
      ① 标准名 `heading 2` 且在用        → 什么都不用做
      ② 自定义中文名（「一级标题」）      → 靠大纲级别认出来，**改名为 heading N**
      ③ 内建名没在用、另有在用的样式      → 同上（用量告诉我们作者实际用哪个）
      ④ 名字和级别都不规范               → 认不出来，交给基准模板补齐

    返回 (新的 styles.xml, 角色映射 dict)。
    """
    usage = style_usage(doc_xml)
    detected = detect_heading_styles(styles_xml, usage)

    # 只在**两种信号同时成立**时才改名，避免把本来就能用的模板改坏：
    #   ① 名字不是 pandoc 认识的 `heading N`
    #   ② 这个样式在模板正文里**确实被用过** —— 证明作者真的拿它当标题
    # 只看大纲级别就改名太激进：模板里没被使用的占位样式会被错改，
    # 连带把后面的层级整体挪位（我们自己那份模板就踩了这个）。
    to_rename = {
        lv: s for lv, s in detected.items()
        if s["name"] != f"heading {lv}" and usage.get(s["id"], 0) > 0
    }
    if to_rename:
        styles_xml, renames = canonicalize_heading_names(styles_xml, to_rename)
        for old, new in renames:
            print(f'  按大纲级别识别到章节样式：「{old}」→ 改名为 {new}'
                  f'（pandoc 只认这个名字，改名后标题语义不丢）')

    roles = detect_named_roles(styles_xml, {s["id"] for s in detected.values()}, usage)
    return styles_xml, roles


def merge_missing_styles(styles_xml, donor_path):
    """把基准模板（默认模板）里、用户模板缺的样式补进来。

    要处理两件事：
      1. **styleId 冲突** —— 用户模板可能占用了同名 ID，补进来的样式得换个不冲突的 ID
      2. **样式间引用** —— basedOn / next / link 里写的是基准模板的 ID，
         要按「ID → 名字 → 目标模板里的 ID」重新映射，否则会指向别人的样式
    """
    donor = zipfile.ZipFile(donor_path).read("word/styles.xml").decode("utf-8")
    donor_styles = _parse_styles(donor)
    donor_by_name = {name: (sid, xml) for sid, name, xml in donor_styles}
    donor_name_of = {sid: name for sid, name, _ in donor_styles}

    have_names = {name for _, name, _ in _parse_styles(styles_xml)}
    used_ids = {sid for sid, _, _ in _parse_styles(styles_xml)}

    missing = [n for n in REQUIRED_STYLES if n not in have_names and n in donor_by_name]
    if not missing:
        return styles_xml, []

    # 先给要补的样式分配不冲突的新 ID
    new_id = {}
    for n in missing:
        base = re.sub(r"[^A-Za-z0-9]", "", donor_by_name[n][0]) or "S"
        cand, k = base, 1
        while cand in used_ids:
            k += 1
            cand = f"{base}_b{k}"
        used_ids.add(cand)
        new_id[n] = cand

    def remap_refs(xml, self_name):
        """把 basedOn/next/link 的 ID 换成目标模板里对应样式的 ID。"""
        def sub(m):
            tag, ref_id = m.group(1), m.group(2)
            ref_name = donor_name_of.get(ref_id)
            if not ref_name:
                return m.group(0)
            if ref_name in new_id:            # 也是这次要补的
                return f'<w:{tag} w:val="{new_id[ref_name]}"/>'
            m2 = re.search(
                r'<w:style [^>]*w:styleId="([^"]+)"[^>]*>\s*<w:name w:val="%s"'
                % re.escape(ref_name),
                styles_xml,
            )
            if m2:                            # 用户模板里有同名的，指过去
                return f'<w:{tag} w:val="{m2.group(1)}"/>'
            return m.group(0)                 # 都没有就原样留着

        return re.sub(r'<w:(basedOn|next|link) w:val="([^"]+)"\s*/>', sub, xml)

    added = []
    for n in missing:
        sid, xml = donor_by_name[n]
        xml = re.sub(r'w:styleId="%s"' % re.escape(sid), 'w:styleId="%s"' % new_id[n], xml, count=1)
        xml = remap_refs(xml, n)
        styles_xml = styles_xml.replace("</w:styles>", xml + "</w:styles>", 1)
        added.append(n)

    return styles_xml, added

# 目录收录哪些层级：样式名 -> 大纲级别（0 = 一级标题）
# ⚠️ 必须**连续**：我们的约定是 `##`→大纲 0、`###`→大纲 1、`####`→大纲 2……
# 中间留缺口的话，按大纲级别识别模板样式时会把后面的层级整体挪位（踩过）。
OUTLINE_LEVELS = {
    "heading 2": 0, "heading 3": 1, "heading 4": 2, "heading 5": 3,
    "heading 6": 4, "heading 7": 5, "heading 8": 6, "heading 9": 7,
}


def fix_outline_levels(styles_xml):
    """让自动生成的目录层级合理。

    原模板的大纲级别是「围绕 hand 1 是最大标题」设计的，但本项目的约定是
    论文大标题用自定义样式（摘要上标题）、章节用 heading 2/3。所以：
      - 大标题样式去掉大纲级别 —— 否则它会作为条目出现在目录里（不该出现）
      - heading 2 -> 0（章，目录一级）
      - heading 3 -> 1（节，目录二级）

    这样 `TOC \\o "1-3"` 生成出来的目录就是「第1章 / 1.1」两级，与原论文一致。
    """
    changed = []

    def set_level(name, level, remove=False):
        m = re.search(
            r'<w:style [^>]*w:styleId="([^"]+)"[^>]*>\s*<w:name w:val="%s"\s*/>.*?</w:style>'
            % re.escape(name),
            styles_xml,
            re.S,
        )
        if not m:
            return styles_xml
        style = m.group(0)
        if "<w:outlineLvl" in style:
            # 9 = body text，等于「不进大纲」
            new = re.sub(r"<w:outlineLvl w:val=\"\d+\"\s*/>",
                         "" if remove else '<w:outlineLvl w:val="%d"/>' % level, style, count=1)
        elif remove:
            return styles_xml
        elif "<w:pPr>" in style:
            new = style.replace("<w:pPr>", '<w:pPr><w:outlineLvl w:val="%d"/>' % level, 1)
        else:
            return styles_xml
        changed.append(name if not remove else name + "(移出大纲)")
        return styles_xml.replace(style, new, 1)

    styles_xml = set_level(TITLE_STYLE_NAME, 0, remove=True)
    for name, lvl in OUTLINE_LEVELS.items():
        styles_xml = set_level(name, lvl)

    print("  大纲级别已调整:", ", ".join(changed) if changed else "无需调整")
    return styles_xml


EQUATION_STYLE_NAME = "公式"


def add_equation_style(styles_xml, doc_xml):
    """加一个 `公式` 样式，用来排带编号的公式。

    中文论文的公式排版是「公式居中、编号右对齐」，靠**段落上的两个制表位**实现
    （不是表格）：段首一个 Tab 跳到居中位置，公式后面一个 Tab 跳到右对齐位置。

    制表位不能写死 —— 不同模板的页边距不同。这里从模板自己的 sectPr 算出正文宽度，
    居中位取一半、右对齐位取整宽。样式已存在就不动（使用者可能自己调过）。
    """
    if re.search(r'<w:name w:val="%s"\s*/>' % re.escape(EQUATION_STYLE_NAME), styles_xml):
        print("  公式样式已存在，跳过")
        return styles_xml

    m = re.search(r'<w:pgSz[^>]*w:w="(\d+)"', doc_xml)
    width = int(m.group(1)) if m else 11906
    left = re.search(r'<w:pgMar[^>]*w:left="(\d+)"', doc_xml)
    right = re.search(r'<w:pgMar[^>]*w:right="(\d+)"', doc_xml)
    text_w = width - int(left.group(1) if left else 1701) - int(right.group(1) if right else 1134)
    center, rightpos = text_w // 2, text_w

    style = (
        f'<w:style w:type="paragraph" w:customStyle="1" w:styleId="{EQUATION_STYLE_NAME}">'
        f'<w:name w:val="{EQUATION_STYLE_NAME}"/><w:basedOn w:val="Normal"/><w:qFormat/>'
        f'<w:pPr>'
        f'<w:tabs>'
        f'<w:tab w:val="center" w:pos="{center}"/>'
        f'<w:tab w:val="right" w:pos="{rightpos}"/>'
        f'</w:tabs>'
        f'<w:spacing w:before="120" w:after="120"/>'
        f'<w:jc w:val="left"/>'
        f'</w:pPr></w:style>'
    )
    print(f"  加上「{EQUATION_STYLE_NAME}」样式（制表位 居中@{center} 右@{rightpos}，"
          f"按模板正文宽度 {text_w} 算出）")
    return styles_xml.replace("</w:styles>", style + "</w:styles>", 1)


def fix_table_style_id(styles_xml):
    """把表格样式的 styleId 改成 "Table"。

    pandoc 对**段落样式**会把名字解析成 styleId（所以 `heading 2` 能找到模板里的 `5`），
    但**表格样式不做这个解析** —— 它直接写 <w:tblStyle w:val="Table"/> 这个名字。
    如果模板里表格样式的 styleId 不是字面量 "Table"（Word 手工建的模板通常是 `33`
    这种数字），引用就悬空，**三线表的三条线一条都不会出现**（实测：渲染出来是无线表格）。

    这里把 name="Table" 的表格样式的 styleId 统一改成 "Table"，让 pandoc 的引用能对上。
    """
    m = re.search(
        r'<w:style [^>]*w:type="table"[^>]*w:styleId="([^"]+)"[^>]*>\s*'
        r'<w:name w:val="Table"\s*/>',
        styles_xml,
    )
    if not m:
        print("  模板里没有 name=Table 的表格样式，跳过（表格会用 Word 默认样式）")
        return styles_xml

    old_id = m.group(1)
    if old_id == "Table":
        print('  表格样式 styleId 已经是 "Table"，无需改')
        return styles_xml

    # 确认没有别的地方引用这个旧 ID，避免改完留下悬空引用
    refs = re.findall(
        r'<w:(?:basedOn|next|link) w:val="%s"' % re.escape(old_id), styles_xml
    )
    if refs:
        sys.exit(f"错误：样式 {old_id} 被其他样式引用（{len(refs)} 处），改名不安全，请人工处理")

    # 只替换这个 <w:style> 开标签里的属性，避免误伤别的样式
    start, end = m.span()
    head = styles_xml[start:end]
    new_head = head.replace('w:styleId="%s"' % old_id, 'w:styleId="Table"', 1)
    styles_xml = styles_xml[:start] + new_head + styles_xml[end:]
    print(f'  表格样式 styleId: "{old_id}" -> "Table"（否则 pandoc 的引用悬空，三线表没线）')
    return styles_xml


def set_page_break(styles_xml):
    """给 w:name = 'heading 2' 的样式插入 <w:pageBreakBefore/>。"""
    m = re.search(
        r'<w:style [^>]*w:styleId="([^"]+)"[^>]*>\s*<w:name w:val="heading 2"\s*/>.*?</w:style>',
        styles_xml,
        re.S,
    )
    if not m:
        sys.exit("错误：模板里找不到 heading 2 样式")
    style = m.group(0)
    if "<w:pageBreakBefore" in style:
        print("  heading 2 已有 pageBreakBefore，跳过")
        return styles_xml

    new_style = style
    # 按 OOXML 的 CT_PPr 顺序，pageBreakBefore 必须排在 keepLines 之后、numPr 之前
    if "<w:keepLines/>" in new_style:
        new_style = new_style.replace("<w:keepLines/>", "<w:keepLines/><w:pageBreakBefore/>", 1)
    elif "<w:numPr>" in new_style:
        new_style = new_style.replace("<w:numPr>", "<w:pageBreakBefore/><w:numPr>", 1)
    elif "<w:pPr>" in new_style:
        new_style = new_style.replace("<w:pPr>", "<w:pPr><w:pageBreakBefore/>", 1)
    else:
        sys.exit("错误：heading 2 没有 pPr，无法插入分页属性")

    print(f"  已给 heading 2 (styleId={m.group(1)}) 加上 pageBreakBefore")
    return styles_xml.replace(style, new_style, 1)


# --- 处理 styles.xml ---
styles = zin.read("word/styles.xml").decode("utf-8")
doc_body = zin.read("word/document.xml").decode("utf-8")

donor = sys.argv[3] if len(sys.argv) > 3 else None
has_donor = bool(donor and Path(donor).is_file()
                 and Path(donor).resolve() != Path(src).resolve())

# 0. 先适配用户的样式命名（按大纲级别 + 用量认出章节样式并改名）。
#    必须在补齐之前做 —— 补齐会把 heading N 补进来，那就认不出作者自己的了。
roles = {}
if has_donor:
    styles, roles = adapt_to_template(styles, doc_body, donor)
    print("  识别到的角色样式：" + (", ".join(f"{k}={v}" for k, v in roles.items()) or "无"))

# 1. 再补齐缺失样式。用户模板已有的同名样式优先，不会被覆盖。
if has_donor:
    styles, _added = merge_missing_styles(styles, donor)
    if _added:
        head = ", ".join(_added[:6]) + ("…" if len(_added) > 6 else "")
        print(f"  从基准模板补齐 {len(_added)} 个缺失样式：{head}")

styles = set_page_break(styles)
styles = fix_table_style_id(styles)
styles = fix_outline_levels(styles)
styles = add_equation_style(styles, doc_body)

# --- 找出要删的 media 及其关系 ---
rels_name = "word/_rels/document.xml.rels"
drop_files, drop_ids = set(), set()
if rels_name in zin.namelist():
    rels = zin.read(rels_name).decode("utf-8")
    for r in re.finditer(r'<Relationship\b[^>]*/>', rels):
        seg = r.group(0)
        typ = re.search(r'Type="([^"]+)"', seg)
        tgt = re.search(r'Target="([^"]+)"', seg)
        rid = re.search(r'Id="([^"]+)"', seg)
        if typ and tgt and rid and typ.group(1).endswith("/image"):
            drop_ids.add(rid.group(1))
            if not tgt.group(1).startswith(("http", "/")):
                drop_files.add("word/" + tgt.group(1).lstrip("/"))
    new_rels = re.sub(
        r'<Relationship\b[^>]*/>',
        lambda mm: "" if re.search(r'Id="([^"]+)"', mm.group(0)).group(1) in drop_ids else mm.group(0),
        rels,
    )
else:
    new_rels = None

# media 目录下的所有文件也一并删掉（含未被 rels 登记的）
drop_files |= {n for n in zin.namelist() if n.startswith("word/media/") and not n.endswith("/")}

# --- 重新打包 ---
saved = 0
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        if item.filename in drop_files:
            saved += item.file_size
            continue
        data = zin.read(item.filename)
        if item.filename == "word/styles.xml":
            data = styles.encode("utf-8")
        elif item.filename == rels_name and new_rels is not None:
            data = new_rels.encode("utf-8")
        zout.writestr(item, data)

print(f"  删除图片 {len(drop_files)} 个，省 {saved/1024/1024:.2f} MB")
# --- 把角色映射写出来，供 filter / build_toc 使用 ---
# 用户模板可能把大标题/摘要/目录标题叫成别的名字，filter 得知道该用哪个。
DEFAULT_ROLES = {"title": TITLE_STYLE_NAME, "abstract": "摘要", "toc": "目录两个字"}
role_map = dict(DEFAULT_ROLES)
role_map.update({k: v for k, v in roles.items() if v})
map_path = Path(dst).with_suffix(Path(dst).suffix + ".map.json")
map_path.write_text(json.dumps(role_map, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"  角色映射写入 {map_path.name}：{role_map}")

print(f"已生成: {dst}")
