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


def process_table(tbl_xml, top, bottom, header_border, stats):
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
    stats = {"tables": 0, "header_rows": 0}

    if top and bottom:
        doc = re.sub(
            r"<w:tbl>.*?</w:tbl>",
            lambda m: process_table(m.group(0), top, bottom,
                                    header_border or _none("bottom"), stats),
            doc,
            flags=re.S,
        )

    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename == "word/document.xml":
                data = doc.encode("utf-8")
            zout.writestr(item, data)

    if stats["tables"]:
        print(f"  表格边框已写成直接格式：{stats['tables']} 个表格，"
              f"{stats['header_rows']} 个表头行（WPS 下也能出三线表）")


if __name__ == "__main__":
    main()
