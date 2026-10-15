#!/usr/bin/env python3
"""把表格边框写成**直接格式**，不再依赖条件表格样式。

背景（实测）：
  三线表的表头下线，标准做法是在表格样式里写
      <w:tblStylePr w:type="firstRow"><w:tcPr><w:tcBorders>...
  但 **WPS 对条件表格样式支持不完整** —— 同一份 docx：
      LibreOffice 渲染 → 三条线齐全
      WPS 渲染        → 只剩上下两条，表头那条线丢了

  直接格式（写在 <w:tblPr> / <w:tcPr> 里）优先于样式，且所有渲染器都认。

做法：
  1. 从参考模板的 Table 样式里读出边框定义（上/下/表头下线的粗细）
  2. 把「上下线」写进输出里每个表格的 <w:tblPr>
  3. 把「表头下线」写进表头行（带 <w:tblHeader/> 的那行）每个单元格的 <w:tcPr>
  4. 显式声明左右线、内部横竖线为 none

  这样模板声明什么、输出就是什么，换模板也成立；模板没定义表格边框就什么都不做。

用法: python3 set_table_borders.py <参考模板.docx> <输入.docx> <输出.docx>
"""
import re
import sys
import zipfile

TABLE_STYLE_RE = re.compile(
    r'<w:style [^>]*w:type="table"[^>]*>.*?<w:name w:val="Table"\s*/>.*?</w:style>',
    re.S,
)


def _border(styles_xml, side):
    """从 Table 样式的 tblBorders 里取某条边的定义。"""
    m = TABLE_STYLE_RE.search(styles_xml)
    if not m:
        return None
    b = re.search(r"<w:tblBorders>(.*?)</w:tblBorders>", m.group(0), re.S)
    if not b:
        return None
    e = re.search(r"<w:%s\b[^>]*/>" % side, b.group(1))
    return e.group(0) if e else None


def _header_border(styles_xml):
    """取 firstRow 条件里那条 tcBorders 的下边框。"""
    m = TABLE_STYLE_RE.search(styles_xml)
    if not m:
        return None
    fr = re.search(r'<w:tblStylePr w:type="firstRow">(.*?)</w:tblStylePr>', m.group(0), re.S)
    if not fr:
        return None
    e = re.search(r"<w:bottom\b[^>]*/>", fr.group(1))
    return e.group(0) if e else None


def _none(side):
    return f'<w:{side} w:val="none" w:sz="0" w:space="0" w:color="auto"/>'


def _tbl_borders(top, bottom):
    return ("<w:tblBorders>" + top + bottom
            + _none("left") + _none("right") + _none("insideH") + _none("insideV")
            + "</w:tblBorders>")


def _add_tbl_borders(tbl_xml, borders):
    """往 <w:tblPr> 里插 tblBorders。

    位置有讲究：OOXML 的 CT_TblPrBase 是序列化的，
    tblBorders 必须排在 tblStyle/tblW/jc 之后、tblLook/tblCellMar 之前。
    pandoc 生成的是 <w:tblStyle/><w:tblW/><w:tblLook/>，所以插在 tblLook 前。
    """
    m = re.search(r"<w:tblPr>(.*?)</w:tblPr>", tbl_xml, re.S)
    if not m:
        return tbl_xml
    inner = m.group(1)
    if "<w:tblBorders>" in inner:  # 已有就不重复插
        inner = re.sub(r"<w:tblBorders>.*?</w:tblBorders>", "", inner, flags=re.S)
    pos = inner.find("<w:tblLook")
    if pos < 0:
        pos = inner.find("<w:tblCellMar")
    if pos < 0:
        inner = inner + borders
    else:
        inner = inner[:pos] + borders + inner[pos:]
    return tbl_xml[:m.start()] + "<w:tblPr>" + inner + "</w:tblPr>" + tbl_xml[m.end():]


def _set_cell_bottom(cell_xml, header_border):
    """给单元格加下边框（直接格式）。tcBorders 要排在 tcW/gridSpan 之后、tcMar/vAlign 之前。"""
    m = re.search(r"<w:tcPr>(.*?)</w:tcPr>", cell_xml, re.S)
    body = "<w:tcBorders>" + header_border + "</w:tcBorders>"
    if not m:
        return cell_xml.replace("<w:tc>", "<w:tc><w:tcPr>" + body + "</w:tcPr>", 1)
    inner = m.group(1)
    pos = inner.find("<w:tcMar")
    if pos < 0:
        pos = inner.find("<w:vAlign")
    if pos < 0:
        pos = inner.find("<w:shd")
    if pos < 0:
        inner = inner + body
    else:
        inner = inner[:pos] + body + inner[pos:]
    return cell_xml[:m.start()] + "<w:tcPr>" + inner + "</w:tcPr>" + cell_xml[m.end():]


def _all_none():
    return ("<w:tblBorders>"
            + "".join('<w:%s w:val="none" w:sz="0" w:space="0" w:color="auto"/>' % s
                      for s in ("top", "left", "bottom", "right", "insideH", "insideV"))
            + "</w:tblBorders>")


def _fix_formula_table(tbl_xml, text_width):
    """公式表格（filter 生成的，放「公式 + 编号」）：固定列宽 + 彻底无边框。

    两处都必须用**直接格式**压过样式，否则会出问题：

    1. **边框**：模板的 Table 样式本身就是三线表（上下 sz=12 的粗线）。
       只「不添加」直接边框是不够的 —— 样式照样生效，公式上下就出现两条黑线。
       必须显式把六条边都设成 none。

    2. **列宽**：pandoc 生成的是 tblW="auto"，列宽跟着内容自适应 ——
       不同公式宽度不同 → 编号列宽度不同 → **编号对不齐**；
       而且中间列的中心不等于页面中心、编号右边缘不等于右边距。
       固定成「编号列 / 公式列 / 编号列」且**首尾等宽**：
       这样中间列的中心正好落在页面中心、编号列右边缘正好落在右边距。
    """
    # 编号列宽度要装得下「（12-34）」这种最长的编号，还要留出单元格左右边距。
    # 首列必须和编号列**等宽** —— 这样中间列的中心才正好落在页面中心。
    w_num = 1400
    w1 = w3 = w_num
    w2 = text_width - w1 - w3

    # 固定表格总宽
    tbl_xml = re.sub(r'<w:tblW[^>]*/>',
                     f'<w:tblW w:type="dxa" w:w="{text_width}"/>', tbl_xml, count=1)
    # 固定各列宽
    widths = [w1, w2, w3]
    idx = [0]
    def _col(m):
        v = widths[idx[0]]; idx[0] += 1
        return f'<w:gridCol w:w="{v}"/>'
    tbl_xml = re.sub(r'<w:gridCol[^>]*/>', _col, tbl_xml)
    # 关掉全部边框（压过样式的三线表）
    if "<w:tblBorders>" in tbl_xml:
        tbl_xml = re.sub(r"<w:tblBorders>.*?</w:tblBorders>", "", tbl_xml, flags=re.S)
    tbl_xml = tbl_xml.replace("<w:tblPr>", "<w:tblPr>" + _all_none(), 1)
    # 固定布局，否则 Word 仍会按内容重算列宽
    if "<w:tblLayout" not in tbl_xml:
        tbl_xml = tbl_xml.replace("<w:tblPr>", '<w:tblPr><w:tblLayout w:type="fixed"/>', 1)
    return tbl_xml


def process_table(tbl_xml, top, bottom, header_border, stats, text_width):
    # 公式表格（filter 生成的，用来放「公式 + 编号」）单独处理 ——
    # 靠零宽空格标记和显示式公式（m:oMathPara）两个特征认出来。
    if "\u200b" in tbl_xml or "m:oMathPara" in tbl_xml:
        stats["formula_tables"] = stats.get("formula_tables", 0) + 1
        return _fix_formula_table(tbl_xml, text_width)
    tbl_xml = _add_tbl_borders(tbl_xml, _tbl_borders(top, bottom))

    # 表头行：pandoc 会给它打 <w:tblHeader/>
    rows = list(re.finditer(r"<w:tr\b.*?</w:tr>", tbl_xml, re.S))
    for row in rows:
        if "<w:tblHeader" not in row.group(0):
            continue
        new_row = re.sub(
            r"<w:tc>.*?</w:tc>",
            lambda mm: _set_cell_bottom(mm.group(0), header_border),
            row.group(0),
            flags=re.S,
        )
        tbl_xml = tbl_xml[:row.start()] + new_row + tbl_xml[row.end():]
        stats["header_rows"] += 1
        break  # 只处理第一个表头行
    stats["tables"] += 1
    return tbl_xml


def main():
    tpl_path, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]

    styles = zipfile.ZipFile(tpl_path).read("word/styles.xml").decode("utf-8")
    top = _border(styles, "top")
    bottom = _border(styles, "bottom")
    header_border = _header_border(styles)

    if not (top and bottom):
        print("  模板的 Table 样式没定义上下边框，表格原样输出")
        top = bottom = None

    zin = zipfile.ZipFile(src)
    doc = zin.read("word/document.xml").decode("utf-8")
    # 正文宽度 —— 公式表格按它定列宽，好让编号落在右边距上
    try:
        _tpl_doc = zipfile.ZipFile(tpl_path).read("word/document.xml").decode("utf-8")
    except KeyError:
        _tpl_doc = ""
    _m = re.search(r'<w:pgSz[^>]*w:w="(\d+)"', _tpl_doc)
    _pw = int(_m.group(1)) if _m else 11906
    _l = re.search(r'<w:pgMar[^>]*w:left="(\d+)"', _tpl_doc)
    _r = re.search(r'<w:pgMar[^>]*w:right="(\d+)"', _tpl_doc)
    text_width = _pw - int(_l.group(1) if _l else 1701) - int(_r.group(1) if _r else 1134)

    stats = {"tables": 0, "header_rows": 0}

    doc = re.sub(
        r"<w:tbl>.*?</w:tbl>",
        lambda m: process_table(m.group(0), top, bottom,
                                header_border or _none("bottom"), stats, text_width),
        doc,
        flags=re.S,
    )

    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename == "word/document.xml":
                data = doc.encode("utf-8")
            zout.writestr(item, data)

    if stats.get("formula_tables"):
        print(f"  跳过 {stats['formula_tables']} 个公式表格的边框（公式+编号用的无框表格）")
    if stats["tables"]:
        print(f"  表格边框已写成直接格式：{stats['tables']} 个表格，"
              f"{stats['header_rows']} 个表头行（WPS 下也能出三线表）")


if __name__ == "__main__":
    main()
