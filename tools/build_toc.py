#!/usr/bin/env python3
r"""给 pandoc 生成的目录域填上「缓存结果」。

背景：
  pandoc 的 `--toc` 会生成一个真正的 Word 目录域：
      <w:fldChar type="begin"/> <w:instrText>TOC \o "1-3" \h \z \u</w:instrText>
      <w:fldChar type="separate"/> <w:fldChar type="end"/>
  但 **separate 和 end 之间是空的** —— 没有缓存结果。
  真实 Word 文档那里存着上次更新的目录条目；Word/WPS 打开时会刷新，
  但**不是所有程序都会刷新域**（实测 LibreOffice 直接渲染就是空的）。

  所以这里把章节条目标题填进去。**编号也填**（第1章 / 1.1）：模板的编号是样式的
  自动编号，不在标题文字里，光填标题就成了「引言」而不是原论文里的「第1章 绪论」——
  原论文（assets/sources/）的目录缓存里，编号就是当文字存着的。
  页码留空，等用户打开文档时由 Word/WPS 更新域补上 —— 即使不更新，至少能看到
  目录结构（含章号），而不是一片空白或没头没尾的标题。

用法: python3 build_toc.py <模板.docx> <输入.docx> <输出.docx>
"""
import json
import os
import re
import sys
import zipfile
from pathlib import Path

# 目录里要收录哪些标题级别（样式名），以及各用哪个目录样式
LEVELS = [("heading 2", "toc 1"), ("heading 3", "toc 2")]


def _style_ids(styles_xml):
    """样式名 -> styleId。"""
    out = {}
    for m in re.finditer(
        r'<w:style [^>]*w:styleId="([^"]+)"[^>]*>\s*<w:name w:val="([^"]*)"\s*/>',
        styles_xml,
    ):
        out.setdefault(m.group(2), m.group(1))
    return out


def _esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _para_text(p):
    return "".join(re.findall(r"<w:t[^>]*>([^<]*)</w:t>", p)).strip()


def page_text_width(templates_zip):
    """从模板的页面设置算出正文宽度（twips），用来放右对齐的页码制表位。"""
    try:
        d = templates_zip.read("word/document.xml").decode("utf-8")
    except KeyError:
        return 8306
    m = re.search(r"<w:pgSz[^>]*w:w=\"(\d+)\"", d)
    w = int(m.group(1)) if m else 11906
    left = re.search(r'<w:pgMar[^>]*w:left="(\d+)"', d)
    right = re.search(r'<w:pgMar[^>]*w:right="(\d+)"', d)
    return w - int(left.group(1) if left else 1701) - int(right.group(1) if right else 1134)


def heading_numbering(tpl_zip, ids):
    """从模板读出各级标题的**自动编号**定义（形如 `第%1章` / `%1.%2`）。

    返回 {样式名: (numId, ilvl, lvlText, start)}。

    只认十进制（numFmt="decimal"）：中文数字（一、二、）、带圈编号那类算不准，
    遇到就整条跳过 —— 目录里写出一个错的章号，比不写章号糟得多。
    模板压根没给标题配自动编号（比如用户自带模板）时也返回空，行为与以前一致。
    """
    try:
        styles = tpl_zip.read("word/styles.xml").decode("utf-8")
        numbering = tpl_zip.read("word/numbering.xml").decode("utf-8")
    except KeyError:
        return {}

    out = {}
    for name in (n for n, _ in LEVELS):
        sid = ids.get(name)
        if not sid:
            continue
        st = re.search(
            r'<w:style [^>]*w:styleId="%s"[^>]*>(.*?)</w:style>' % re.escape(sid),
            styles, re.S,
        )
        if not st:
            continue
        npr = re.search(r"<w:numPr>(.*?)</w:numPr>", st.group(1), re.S)
        if not npr:
            continue
        num_id = re.search(r'<w:numId w:val="(\d+)"', npr.group(1))
        ilvl = re.search(r'<w:ilvl w:val="(\d+)"', npr.group(1))
        if not num_id or not ilvl:
            continue
        # numId → abstractNumId → 该 ilvl 的 <w:lvl>
        a = re.search(
            r'<w:num w:numId="%s"[^>]*>\s*<w:abstractNumId w:val="(\d+)"' % num_id.group(1),
            numbering,
        )
        if not a:
            continue
        ab = re.search(
            r'<w:abstractNum w:abstractNumId="%s"[^>]*>(.*?)</w:abstractNum>' % a.group(1),
            numbering, re.S,
        )
        if not ab:
            continue
        lv = re.search(
            r'<w:lvl w:ilvl="%s"[^>]*>(.*?)</w:lvl>' % ilvl.group(1), ab.group(1), re.S
        )
        if not lv:
            continue
        body = lv.group(1)
        fmt = re.search(r'<w:numFmt w:val="([^"]+)"', body)
        txt = re.search(r'<w:lvlText w:val="([^"]*)"', body)
        start = re.search(r'<w:start w:val="(\d+)"', body)
        if not txt or (fmt and fmt.group(1) != "decimal"):
            continue
        out[name] = (num_id.group(1), int(ilvl.group(1)), txt.group(1),
                     int(start.group(1)) if start else 1)
    return out


def collect_entries(doc_xml, ids, numbering=None):
    """按文档顺序收集需要进目录的标题，返回 [(目录样式, 编号, 标题文字), ...]。

    编号按模板的自动编号定义递增（第1章 → 第2章；换章后 1.1 重新从 1 数）。
    """
    numbering = numbering or {}
    counters = {}

    def number_of(name):
        spec = numbering.get(name)
        if not spec:
            return ""
        _num_id, ilvl, lvl_text, start = spec
        counters[ilvl] = counters.get(ilvl, start - 1) + 1
        for deeper in [k for k in counters if k > ilvl]:   # 换章后小节重新数
            del counters[deeper]
        return re.sub(r"%(\d)",
                      lambda m: str(counters.get(int(m.group(1)) - 1, start)),
                      lvl_text)

    entries = []
    for m in re.finditer(r"<w:p\b.*?</w:p>", doc_xml, re.S):
        p = m.group(0)
        st = re.search(r'<w:pStyle w:val="([^"]+)"', p)
        if not st:
            continue
        for heading_name, toc_name in LEVELS:
            if ids.get(heading_name) == st.group(1):
                txt = _para_text(p)
                if txt:
                    entries.append((toc_name, number_of(heading_name), txt))
                break
    return entries


def build_toc_xml(entries, ids, tab_pos, page_placeholder=""):
    """生成目录条目段落：编号 + 标题 …… 页码。

    三处细节是照着原论文（assets/sources/）里的真实目录抄的：
      1. 段落要有**右对齐点线制表位** —— 这才是「......」引导线的来源
         <w:tabs><w:tab w:val="right" w:leader="dot" w:pos="..."/></w:tabs>
      2. 条目格式：标题 <Tab> 页码。页码留空，等 Word/WPS 更新域时补上。
      3. 章号与标题是**两个 run**，原论文里就是这样（`第1章 ` + `绪论`）。
    """
    out = []
    for toc_name, num, text in entries:
        sid = ids.get(toc_name)
        style = f'<w:pStyle w:val="{sid}"/>' if sid else ""
        tabs = (f'<w:tabs><w:tab w:val="right" w:leader="dot" w:pos="{tab_pos}"/>'
                "</w:tabs>")
        runs = ('<w:r><w:t xml:space="preserve">' + _esc(num + " ") + "</w:t></w:r>"
                if num else "")
        out.append(
            "<w:p><w:pPr>" + style + tabs + "</w:pPr>"
            + runs
            + '<w:r><w:t xml:space="preserve">' + _esc(text) + "</w:t></w:r>"
            '<w:r><w:tab/><w:t xml:space="preserve">' + page_placeholder + "</w:t></w:r>"
            "</w:p>"
        )
    return "".join(out)


def _role_map(tpl_path):
    """读 prepare_template 写的角色映射（没有就返回空）。"""
    import json
    p = Path(str(tpl_path) + ".map.json")
    if p.is_file():
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def fix_title_style(doc_xml, ids, stats, tpl_path):
    """把「目录」两个字的段落换成模板自己的目录标题样式。

    pandoc 用的是它认得的 `TOC Heading` 样式；但这份模板另有专门给目录标题用的
    `目录两个字` 样式（原论文的「目录」就是它）。用户要求用模板里那个。
    """
    # 目录标题样式名：优先用 prepare_template 识别出来的（用户模板可能叫别的名字）
    role = _role_map(tpl_path).get("toc", "目录两个字")
    want = ids.get(role) or ids.get("目录两个字")
    have = ids.get("TOC Heading")
    if not want or not have or want == have:
        return doc_xml
    # 只改样式是这个的那一段，且该段文字必须是「目录」二字，避免误伤
    pat = re.compile(
        r'<w:p><w:pPr><w:pStyle w:val="%s"\s*/></w:pPr>(.*?目录.*?)</w:p>'
        % re.escape(have),
        re.S,
    )
    new_doc, n = pat.subn(
        lambda m: '<w:p><w:pPr><w:pStyle w:val="%s"/></w:pPr>%s</w:p>'
        % (want, m.group(1)),
        doc_xml,
        count=1,
    )
    if n:
        stats["title_style"] = True
    return new_doc


def relocate_toc(doc_xml, ids, stats):
    """把目录从文档最前面搬到「摘要之后、第一章之前」，并让它独立成页。

    pandoc 把目录放在正文开头（连大标题都在它后面）。但论文的惯例是
        大标题 → 摘要 → 关键词 → 〔换页〕目录〔换页〕→ 第1章 →
    所以要整块挪位置，并给目录标题加上「段前分页」。
    """
    title_id, h2_id = ids.get("目录两个字"), ids.get("heading 2")
    if not title_id or not h2_id:
        return doc_xml

    # 目录块 = 「目录」标题段 → 目录域结束段
    m = re.search(
        r'<w:p><w:pPr><w:pStyle w:val="%s"\s*/></w:pPr>(?:(?!</w:p>).)*?目录.*?</w:p>'
        r'.*?<w:p><w:r><w:fldChar w:fldCharType="end"\s*/></w:r></w:p>'
        % re.escape(title_id),
        doc_xml,
        re.S,
    )
    if not m:
        return doc_xml
    block = m.group(0)
    rest = doc_xml[:m.start()] + doc_xml[m.end():]

    # 目录标题独立成页
    block = block.replace(
        '<w:pPr><w:pStyle w:val="%s"' % title_id,
        '<w:pPr><w:pStyle w:val="%s"/><w:pageBreakBefore/>' % title_id,
        1,
    )
    # 上面替换会留下原本的 "/>"，清掉重复的闭合
    block = block.replace(
        '<w:pStyle w:val="%s"/><w:pageBreakBefore/>/>' % title_id,
        '<w:pStyle w:val="%s"/><w:pageBreakBefore/>' % title_id,
        1,
    )

    # 插到第一个二级标题（第一章）之前
    m2 = re.search(
        r'<w:p><w:pPr><w:pStyle w:val="%s"\s*/></w:pPr>' % re.escape(h2_id), rest
    )
    if not m2:
        return doc_xml  # 找不到章节，保持原位

    stats["relocated"] = True
    return rest[:m2.start()] + block + rest[m2.start():]


def enable_update_fields(settings_xml):
    """在 settings.xml 里打开 `updateFields`。

    这是让 Word/WPS **打开文档时自动更新所有域**的标准开关 —— 目录域的页码就是
    更新时才写进缓存的。不开的话用户得手动右键「更新域」。
    """
    if "updateFields" in settings_xml:
        return settings_xml
    if "<w:compat" in settings_xml:
        return settings_xml.replace(
            "<w:compat", '<w:updateFields w:val="true"/><w:compat', 1
        )
    return settings_xml.replace(
        "</w:settings>", '<w:updateFields w:val="true"/></w:settings>', 1
    )


def note_stat(label, msg):
    """往 filter 那份结果文件里追加一条统计（网页上的「识别结果」）。

    和 filter 共用一条通道 —— 用户看到的是一份完整清单，不用拼两处。
    """
    path = os.environ.get("THESIS_WARNINGS_FILE")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as fh:
            # 紧凑格式，和 filter（Lua 那边）写的行保持一致 —— 同一个文件两种格式
            # 会让人以为解析错了（实际就踩过：断言里 grep 不到）
            fh.write(json.dumps({"kind": "stat", "label": label, "message": msg},
                                ensure_ascii=False, separators=(",", ":")) + "\n")
    except OSError:
        pass


# 目录域缓存里放的**提示**（不是条目）：用户按 F9 后，Word/WPS 会把这段整体换成
# 真正的目录。为什么不用"条目占位"（写完条目、只留页码空着）：
#   条目占位在没人按 F9 时是一份"看起来像目录、但页码全空"的东西 —— 不留神就交上去了 ✗；
#   提示占位在没人按 F9 时是**一行醒目的提示**，不会有人看不见 ✓。
#   代价：没人按 F9 时正文里没有目录（条目占位至少有目录结构）。
# （先前还试过在「目录」上挂页边批注，已撤 —— 正文里写就够了，批注是否显示还取决于设置。）
TOC_PLACEHOLDER = "（在这段文字上点一下，按 F9 → 目录和页码就生成好了）"


def build_toc_placeholder():
    """占位提示段：居中 + 灰字（一眼能看出是"还没生成"的东西）。"""
    grey = '<w:rPr><w:color w:val="808080"/></w:rPr>'
    return ('<w:p><w:pPr><w:jc w:val="center"/>' + grey + "</w:pPr>"
            '<w:r>' + grey + '<w:t xml:space="preserve">' + TOC_PLACEHOLDER
            + "</w:t></w:r></w:p>")


def main():
    tpl_path, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]

    tpl_styles = zipfile.ZipFile(tpl_path).read("word/styles.xml").decode("utf-8")
    ids = _style_ids(tpl_styles)

    zin = zipfile.ZipFile(src)
    doc = zin.read("word/document.xml").decode("utf-8")

    # 没开 --toc 就别动
    if "<w:instrText" not in doc or "TOC " not in doc:
        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                zout.writestr(item, zin.read(item.filename))
        return

    tpl_zip = zipfile.ZipFile(tpl_path)
    entries = collect_entries(doc, ids, heading_numbering(tpl_zip, ids))
    if not entries:
        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                zout.writestr(item, zin.read(item.filename))
        print("  没有可收录的章节标题，目录留空待 Word 生成")
        return

    tab_pos = page_text_width(tpl_zip)      # 只有改回"条目占位"时才用得到
    # 域缓存里放**提示**（不是条目）—— 按 F9 后会被整体换成真正的目录。
    # 想改回"缓存里放条目"：把这行换成 build_toc_xml(entries, ids, tab_pos) 即可
    # （那是今天早些时候的做法，函数和章号逻辑都还留着）。
    toc_xml = build_toc_placeholder()

    # 把 pandoc 的目录域**重建成 Word 的标准结构**。
    #
    # pandoc 生成的是一段一行、fldChar 全挤在同一个 run 里：
    #   <w:p><w:r><w:fldChar begin/><w:instrText>TOC…</w:instrText>
    #        <w:fldChar separate/><w:fldChar end/></w:r></w:p>
    #
    # 而 Word / 原论文里是这样（**每个 fldChar 各自一个 run**，条目是独立段落）：
    #   <w:p><w:r><w:fldChar begin/></w:r><w:r><w:instrText>TOC…</w:instrText></w:r>
    #        <w:r><w:fldChar separate/></w:r></w:p>
    #   <w:p>…条目…</w:p>
    #   <w:p><w:r><w:fldChar end/></w:r></w:p>
    #
    # 另外 pandoc 会套一层 <w:sdt>，而原论文的目录没有 —— 一并去掉。
    # 这两处结构差异都会让部分渲染器（实测 LibreOffice）整块忽略目录内容。
    m = re.search(r"<w:p\b(?:(?!</w:p>).)*?<w:instrText[^>]*>\s*TOC\b.*?</w:p>", doc, re.S)
    if not m:
        print("  警告：没找到目录域，目录保持原样（打开时由 Word 生成）")
        new_doc = doc
    else:
        para = m.group(0)
        ppr = re.search(r"<w:pPr>.*?</w:pPr>", para, re.S)
        instr = re.search(r"<w:instrText[^>]*>(.*?)</w:instrText>", para, re.S)
        rebuilt = (
            "<w:p>" + (ppr.group(0) if ppr else "")
            + '<w:r><w:fldChar w:fldCharType="begin" w:dirty="true"/></w:r>'
            + "<w:r><w:instrText xml:space=\"preserve\">"
            + (instr.group(1) if instr else 'TOC \\o "1-3" \\h \\z \\u')
            + "</w:instrText></w:r>"
            + '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
            + "</w:p>"
            + toc_xml
            + '<w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'
        )
        new_doc = doc[:m.start()] + rebuilt + doc[m.end():]

        def unwrap(mm):
            inner = re.search(r"<w:sdtContent>(.*)</w:sdtContent>", mm.group(0), re.S)
            return inner.group(1) if inner else mm.group(0)

        new_doc = re.sub(r"<w:sdt>.*?</w:sdt>", unwrap, new_doc, count=1, flags=re.S)

    stats = {}
    new_doc = fix_title_style(new_doc, ids, stats, tpl_path)
    new_doc = relocate_toc(new_doc, ids, stats)

    new_settings = None
    if "word/settings.xml" in zin.namelist():
        new_settings = enable_update_fields(
            zin.read("word/settings.xml").decode("utf-8")
        )

    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename == "word/document.xml":
                data = new_doc.encode("utf-8")
            elif item.filename == "word/settings.xml" and new_settings is not None:
                data = new_settings.encode("utf-8")
            zout.writestr(item, data)

    bits = [f"{len(entries)} 条条目"]
    if any(num for _, num, _ in entries):
        bits.append("已写入章号（第N章 / N.M）")
    if stats.get("title_style"):
        bits.append("标题用模板的「目录两个字」样式")
    bits.append("已打开「打开时更新域」——页码由 Word/WPS 打开时写入")
    print("  目录：" + "，".join(bits))
    # 页码只有用户的 Word/WPS 算得出来（我们没有排版引擎）——
    # 但「按 F9 更新域」这句提示由**网页**放在成功行上（WPS 不会打开就更新），
    # 报告里只报条数，避免同一句提示出现两遍
    note_stat("目录", "%d 条（按 F9 生成）" % len(entries))


if __name__ == "__main__":
    main()
