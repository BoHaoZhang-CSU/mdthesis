#!/usr/bin/env bash
# 回归测试：把 tests/cases/ 下的每个 markdown 跑一遍完整流程，做若干硬断言。
#
# 用法:
#   ./tests/regression.sh              # 跑全部
#   ./tests/regression.sh T1 T4        # 只跑名字里含 T1 / T4 的用例
#
# 改完 filters/thesis_template.lua 或 tools/prepare_template.py 后跑一下，
# 确保没有把之前修好的行为改坏。

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$HERE")"
# 模板解析（本仓库不带模板，见 tests/_template.sh）
. "$HERE/_template.sh"
resolve_tpl || exit 1
make_fixtures

# 输出目录：优先 $HERE/.out，但容器里根文件系统是只读的（read_only: true），
# 那种情况下自动退到可写位置，免得跑一次挂一次。
OUTDIR="${OUTDIR:-$HERE/.out}"
if ! mkdir -p "$OUTDIR" 2>/dev/null || ! [ -w "$OUTDIR" ]; then
  OUTDIR="${WORK_ROOT:-/tmp}/regression"
  echo "（$HERE/.out 不可写，改用 $OUTDIR）"
fi
FILTERS="${*:-}"

[ -f "$TPL" ] || { echo "找不到模板: $TPL" >&2; exit 1; }
mkdir -p "$OUTDIR"

pass=0
fail=0

check() { # check <说明> <条件结果 0/1>
  if [ "$2" -eq 0 ]; then
    printf '    ✓ %s\n' "$1"; pass=$((pass + 1))
  else
    printf '    ✗ %s\n' "$1"; fail=$((fail + 1))
  fi
}


# 按样式名在输出里找它的 styleId，再看正文有没有用到
uses_style() {  # uses_style <docx> <样式名> -> 0/1
  python3 -I -c "
import zipfile,re,sys
z=zipfile.ZipFile('$1')
s=z.read('word/styles.xml').decode(); d=z.read('word/document.xml').decode()
m=re.search(r'<w:style [^>]*w:styleId=\"([^\"]+)\"[^>]*>\s*<w:name w:val=\"$2\"', s)
print(1 if m and re.search(r'w:pStyle w:val=\"%s\"' % re.escape(m.group(1)), d) else 0)
"
}

for md in "$HERE"/cases/*.md; do
  name="$(basename "$md" .md)"
  if [ -n "$FILTERS" ]; then
    keep=1
    for f in $FILTERS; do case "$name" in *"$f"*) keep=0 ;; esac; done
    [ "$keep" -eq 0 ] || continue
  fi

  echo "── $name"
  raw="$OUTDIR/${name}_raw.docx"
  out="$OUTDIR/${name}.docx"
  warn="$OUTDIR/${name}.stderr"

  # ⚠️ 必须走 convert.sh（真实管线），不能手工拼 pandoc ——
  # 之前就是手工拼的，结果 set_table_borders / build_toc 这两步后处理
  # **从来没被测到过**，表格边框和目录条目的问题只能靠人肉发现（踩过）。
  # 从 md 所在目录跑，这样相对路径的图片能解析。
  (cd "$HERE/cases" && "$PROJ/tools/convert.sh" "$(basename "$md")" "$out" "$TPL") 2>"$warn"
  rc=$?
  check "转换管线退出码 0" "$rc"

  # 通用断言：不能出现 pandoc 那个会渲染成空心矩形的 VML 横线
  n=$(python3 -I -c "
import zipfile,sys
try: print(zipfile.ZipFile('$out').read('word/document.xml').decode().count('<w:pict>'))
except Exception: print(999)")
  [ "$n" = "0" ]; check "无空心横线 <w:pict>（实际 $n）" "$?"

  # 通用断言：不能有悬空的图片关系
  dangling=$(python3 -I -c "
import zipfile,re
try:
    z=zipfile.ZipFile('$out'); names=set(z.namelist())
    rels=z.read('word/_rels/document.xml.rels').decode()
    bad=[t for t in re.findall(r'Target=\"([^\"]+)\"', rels)
         if not t.startswith(('http','/')) and ('word/'+t.lstrip('/')) not in names]
    print(len(bad))
except Exception: print(999)")
  [ "$dangling" = "0" ]; check "无悬空关系引用（实际 $dangling）" "$?"

  # 用例专属断言
  case "$name" in
    T1_hash_chapters|T2_multi_h1)
      grep -q "一级标题" "$warn"; check "输出了多个 # 的告警" "$?"
      ;;
    T4_refs_bullet|T5_refs_para)
      has=$(uses_style "$out" "Compact")
      [ "$has" = "0" ]; check "参考资料未残留 Compact 列表样式" "$?"
      ;;
    T8_styled_heading)
      has=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
print(1 if '<w:b />' in d or '<w:b/>' in d else 0)")
      [ "$has" = "1" ]; check "标题里的粗体格式被保留" "$?"
      ;;
    T3_real_hr)
      # 水平线**一律丢弃**（不再转成段落底边框）—— 论文里不需要，用户看到的灰线就是它。
      # 这条用例现在的作用变成"反向锁"：只要输出里出现 pBdr 就是回归 ✗
      has=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
print(1 if '<w:pBdr>' in d else 0)")
      [ "$has" = "0" ]; check "章节内的 --- 不画线（不留 pBdr）" "$?"
      ;;
    T9_with_image)
      has=$(python3 -I -c "
import zipfile
z=zipfile.ZipFile('$out')
print(1 if any('media' in n and not n.endswith('/') for n in z.namelist()) else 0)")
      [ "$has" = "1" ]; check "用户图片被保留" "$?"
      ;;
    T15_equations)
      # 按章编号：第1章两个（1-1）（1-2）、第2章一个（2-1）
      # 包在 ::: {.unnumbered} 里的不编号
      got=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
nums=[]
for t in re.findall(r'<w:tbl>.*?</w:tbl>', d, re.S):
    if chr(0x200b) in t or 'm:oMathPara' in t:
        txt=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', t)).replace(chr(0x200b),'').strip()
        nums.append(txt)

# 公式表格必须**显式声明**六条边为 nil —— 用 none 的话 Word 会回落到
# 模板 Table 样式的三线表边框，公式上下就出现黑线（实测踩过）。
# 注意：整段处在 bash 双引号里，Python 字符串里的双引号必须写成 \"
def _clean(t):
    b=re.search(r'<w:tblBorders>(.*?)</w:tblBorders>', t, re.S)
    if not b: return False
    sides=re.findall(r'<w:(?:top|bottom|left|right|insideH|insideV)\b[^>]*/>', b.group(1))
    return len(sides)==6 and all('w:val=\"nil\"' in s for s in sides)
ft=[t for t in re.findall(r'<w:tbl>.*?</w:tbl>', d, re.S) if 'm:oMathPara' in t]
borderless = bool(ft) and all(_clean(t) for t in ft)
print(','.join(nums) + '|' + ('1' if borderless else '0'))
")
      [ "$got" = "（1-1）,（1-2）,（2-1）|1" ]
      check "按章编号正确且公式表无边框（实际 $got）" "$?"
      # 列宽不变量：首尾等宽（→ 公式列中心 = 页面中心）且总宽 = 正文宽度
      # （→ 编号右边缘落在版心右边距）。公式列尽量宽，长公式才不容易被折断。
      lw=$(python3 -I -c "
import re, zipfile
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
t=[x for x in re.findall(r'<w:tbl>.*?</w:tbl>', d, re.S) if 'm:oMathPara' in x][0]
g=[int(v) for v in re.findall(r'<w:gridCol w:w=\"(\d+)\"', t)]
# 不变量（不写死具体数字 —— 编号列按实际编号串自适应）：
#   首尾等宽 → 公式列中心 = 页面中心；总宽 = 正文宽度 → 编号右边缘落在版心右边距；
#   公式格 ≥ 6300 twips（315pt）→ 别偷偷把公式的宽度让给别处（WPS 会折断超宽公式）
ok = g[0] == g[2] and sum(g) == 8306 and g[1] >= 6300
print('OK' if ok else '坏:%s' % g)
")
      [ "$lw" = "OK" ]
      check "公式表列宽不变量（首尾等宽 / 总宽=正文宽 / 公式格≥6300）（实际 $lw）" "$?"
      ;;
    T16_delimiters)
      # 括号自适应：普通 [ ] ( ) 不会随内容变高 —— 装有分式的要改成 \left…\right
      # （pandoc 生成 <m:d> + <m:grow>，Word/WPS 才拉伸）。用户报的问题。
      got=$(python3 -I -c "
import re, zipfile
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
tbls=[x for x in re.findall(r'<w:tbl>.*?</w:tbl>', d, re.S) if 'm:oMathPara' in x]
def delim(t):
    m=re.search(r'<m:d>.*?</m:d>', t, re.S)
    if not m: return 'none'
    b=re.search(r'<m:begChr m:val=\"([^\"]*)\"', m.group(0))
    e=re.search(r'<m:endChr m:val=\"([^\"]*)\"', m.group(0))
    return ((b.group(1) if b else '?') + (e.group(1) if e else '?')
            + ('+grow' if 'm:grow' in m.group(0) else '-nogrow'))
inline={}
for om in re.findall(r'<m:oMath>.*?</m:oMath>', d, re.S):
    txt=''.join(re.findall(r'<m:t[^>]*>([^<]*)</m:t>', om))
    if txt in ('x[i]','(k+1)','ab','a[b]'):
        inline[txt]=om.count('<m:d>')
print('%s / %s / %s / x[i]=%d (k+1)=%d ab=%d a[b]=%d' % (
    delim(tbls[0]), delim(tbls[1]), delim(tbls[2]),
    inline.get('x[i]',-1), inline.get('(k+1)',-1), inline.get('ab',-1), inline.get('a[b]',-1)))
")
      [ "$got" = "[]+grow / ()+grow / none / x[i]=0 (k+1)=0 ab=1 a[b]=0" ]
      check "括号自适应正确（实括号撑开、下标/普通括号不动）（实际 $got）" "$?"
      rep2="$OUTDIR/T16.report.jsonl"; rm -f "$rep2"
      (cd "$HERE/cases" && THESIS_WARNINGS_FILE="$rep2" "$PROJ/tools/convert.sh" \
          T16_delimiters.md "$OUTDIR/T16_report.docx" "$TPL") >/dev/null 2>&1
      grep -q "修正了 2 处公式括号" "$rep2" 2>/dev/null
      check "报告里写明修正 2 处括号（change 行只进报告文件）" "$?"
      ;;
    T18_captions)
      # 表/图题：独立成段的加粗「表N 标题」→ 按章重编号（表2-1）+ 套模板题注样式
      # （黑体五号居中）。**不挨着表格/插图**的加粗文字不许动（对照组）。
      got=$(python3 -I -c "
import re, zipfile
z=zipfile.ZipFile('$out')
d=z.read('word/document.xml').decode(); s=z.read('word/styles.xml').decode()
m=re.search(r'<w:style [^>]*w:styleId=\"([^\"]+)\"[^>]*>\s*<w:name w:val=\"表上面的文字\"', s)
sid=m.group(1) if m else '无'
nums=[]; other=0
for p in re.findall(r'<w:p\b.*?</w:p>', d, re.S):
    t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', p)).strip()
    st=re.search(r'<w:pStyle w:val=\"([^\"]+)\"', p)
    if st and st.group(1)==sid:
        mm=re.match(r'^(表\d+-\d+)', t)
        if mm: nums.append(mm.group(1))
    if '不是题注' in t: other+=1
print(','.join(nums)+'|'+str(other))
")
      [ "$got" = "表1-1,表1-2,表2-1|1" ]
      check "表题按章重编号 + 套模板样式，且没误伤对照组（实际 $got）" "$?"
      ;;
    T17_backslash_math)
      # AI 生成的 md 普遍用 \( \) / \[ \] 写公式，而 pandoc 的 markdown reader
      # **默认不开** tex_math_single_backslash —— 于是 \(x\) 塌成字面量 (x)、
      # \[ ... \] 里的 \frac{}{} 变成 RawInline(tex) 被 docx writer **静默丢弃**，
      # 公式只剩 [ E_c= ] 这种残骸（退出码 0、零告警）。T15/T16 全用 $ $$，
      # 所以这个坑一直没被覆盖 —— 这条用例就是补这个盲区。
      got=$(python3 -I -c "
import zipfile,re
bs=chr(92)
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', d))
# 1) 正文文字里不许残留字面量 \( \[ ，也不许残留任何 LaTeX 命令（\frac \eta ...）
lit = sum(t.count(bs+c) for c in '([') + len(re.findall(bs + r'[a-zA-Z]+', t))
# 2) 行内公式：\frac{a}{b} 必须活下来（有 oMath 且里面有分式 m:f）
mt=''.join(re.findall(r'<m:t[^>]*>([^<]*)</m:t>', d))
inline = 1 if ('ab' in mt and '<m:f>' in d) else 0
# 3) 希腊字母没被吃掉（\eta \Delta 曾经连命令带字母一起消失）
greek = 1 if ('η' in mt and 'Δ' in mt) else 0
# 4) 显示式按章编号
nums=[]
for tb in re.findall(r'<w:tbl>.*?</w:tbl>', d, re.S):
    if 'm:oMathPara' in tb:
        nums.append(''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', tb))
                    .replace(chr(0x200b),'').strip())
print('%d|%d|%d|%s' % (lit, inline, greek, ','.join(nums)))
")
      [ "$got" = "0|1|1|（1-1）,（1-2）" ]
      check "反斜杠公式变成真公式（无字面量残留 / 分式与希腊字母在 / 按章编号）（实际 $got）" "$?"
      ;;
    T18_obsidian)
      # Obsidian 的 ![[…]] 不是 markdown 图片：不处理的话 pandoc 当纯文本，
      # 图片全部消失（真实样本里 31 张图一张都进不去）。
      # 第二个引用只写文件名、实际文件在 figures/ 下 —— 同时验证「目录名任意」。
      got=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', d))
caps=[''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', p))
      for p in re.findall(r'<w:p[ >].*?</w:p>', d, re.S)
      if 'w:pStyle w:val=\"86\"' in p]
imgp=d.count('w:pStyle w:val=\"46\"')
print('%d|%d|%d|%s' % (d.count('<w:drawing>'), t.count('![['), imgp, ','.join(caps)))
")
      [ "$got" = "2|0|2|图1-1 obs-1,图2-1 obs-2" ]
      check "Obsidian 嵌入变真图片、任意目录名能找回、套图片/图题样式（实际 $got）" "$?"
      # 包内多文件模式：大标题取文件名，md 里的 H1 降为章节
      (cd "$HERE/cases" && THESIS_DOC_TITLE="第一章 走进华为云" \
          "$PROJ/tools/convert.sh" T18_obsidian.md "$OUTDIR/T18_title.docx" "$TPL") \
          >/dev/null 2>&1
      tt=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$OUTDIR/T18_title.docx').read('word/document.xml').decode()
ps=[p for p in re.findall(r'<w:p[ >].*?</w:p>', d, re.S) if 'w:pStyle w:val=\"84\"' in p]
print(''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', ps[0])) if ps else '无')
")
      [ "$tt" = "第一章 走进华为云" ]
      check "包内多文件：大标题取自文件名（实际 $tt）" "$?"
      ;;
    T19_image_caption)
      # 题注优先级：图下加粗行 > alt > 文件名；行内图完全不动；
      # 有加粗行时不能再出 pandoc 的 Image Caption（双题注，踩过）。
      got=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
caps=[''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', p))
      for p in re.findall(r'<w:p[ >].*?</w:p>', d, re.S)
      if 'w:pStyle w:val=\"86\"' in p]
print('%d|%d|%s' % (d.count('<w:drawing>'), d.count('Image Caption'), ','.join(caps)))
")
      [ "$got" = "5|0|图1-1 系统架构,图2-1 test_img,图2-2 alt 文字,图2-3 加粗题注" ]
      check "题注来源优先级正确、无双题注、行内图不动（实际 $got）" "$?"
      ;;
    T21_obsidian_alias)
      # Obsidian 别名：纯数字/百分比 = 宽度，其余 = 题注文字
      got=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
w=[round(int(x)/914400,2) for x in re.findall(r'<wp:extent cx=\"(\d+)\"', d)]
caps=[''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', p))
      for p in re.findall(r'<w:p[ >].*?</w:p>', d, re.S)
      if 'w:pStyle w:val=\"86\"' in p]
print('%s|%s' % (w, ','.join(caps)))
")
      [ "$got" = "[2.5, 1.67, 1.67]|图1-1 obs-1,图1-2 云服务器架构,图1-3 obs-1" ]
      check "Obsidian 别名：宽度/题注分别生效（实际 $got）" "$?"
      ;;
    T22_false_caption)
      # 真实样本踩到：「**图表解读：…**」被当成图题，拆成「图 + 表解读：…」。
      # 题注前缀后面必须跟数字/空白/冒号，否则是正文小标题。
      got=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
caps=[''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', p))
      for p in re.findall(r'<w:p[ >].*?</w:p>', d, re.S)
      if 'w:pStyle w:val=\"86\"' in p]
t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', d))
print('%s|%d' % (','.join(caps), 1 if '图表解读：这不是题注' in t else 0))
")
      [ "$got" = "图1-1 原始数据分布|1" ]
      check "「图表解读」不被误判成图题（实际 $got）" "$?"
      ;;
    T23_code_formula)
      # 用户要求：```text 里的公式转成真公式（按章编号）；真代码（python）不动；
      # 非公式的 text 块转普通正文；行内代码转普通文本（不再用 Fira Code）。
      got=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', d))
nums=[]
for tb in re.findall(r'<w:tbl>.*?</w:tbl>', d, re.S):
    if 'm:oMathPara' in tb:
        nums.append(''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', tb)).replace(chr(0x200b),'').strip())
ok = 1 if ('video.mp4' in t and 'read_csv()' in t and 'ddof=0' in t) else 0
print('%d|%d|%d|%s|%d' % (d.count('<m:oMath>'), d.count('w:pStyle w:val=\"41\"'),
      d.count('w:rStyle w:val=\"40\"'), ','.join(nums), ok))
")
      [ "$got" = "2|1|0|（1-1）,（1-2）|1" ]
      check "代码块公式化 / 真代码保留 / 行内代码转普通文本（实际 $got）" "$?"
      ;;
    T24_lists)
      # 用户要求：无序列表去符号转正文（一级首行缩进两字）；
      # 嵌套项按层级缩进 +（1）（2）编号；有序列表保持自动编号。
      got=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', d))
paras=re.findall(r'<w:p[ >].*?</w:p>', d, re.S)
def txt(p): return ''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', p))
unord=[p for p in paras if any(x in txt(p) for x in ('第一点内容','第二点内容','第三点内容','嵌套的一点','嵌套的第二点','更深一层'))]
with_num=sum(1 for p in unord if '<w:numPr>' in p)
s2=d.count('w:pStyle w:val=\"列表正文二级\"')
s3=d.count('w:pStyle w:val=\"列表正文三级\"')
pref=1 if ('（1）嵌套的一点' in t and '（2）嵌套的第二点' in t and '（1）更深一层' in t) else 0
print('%d|%d|%d|%d' % (with_num, s2, s3, pref))
")
      [ "$got" = "0|2|1|1" ]
      check "无序列表转正文、嵌套缩进编号、有序列表保留编号（实际 $got）" "$?"
      ;;
    T25_unnumbered)
      # 用户要求：摘要/目录/参考文献/致谢/附录不占章号。
      # 参考文献/致谢/附录套「不编号标题」样式，摘要用「摘要」样式。
      got=$(python3 -I -c "
import zipfile,re
z=zipfile.ZipFile('$out')
d=z.read('word/document.xml').decode(); s=z.read('word/styles.xml').decode()
nm={}
for m in re.finditer(r'<w:style [^>]*w:styleId=\"([^\"]+)\"[^>]*>(.*?)</w:style>', s, re.S):
    x=re.search(r'<w:name w:val=\"([^\"]+)\"', m.group(2)); nm[m.group(1)]=x.group(1) if x else '?'
def style_of(text):
    for p in re.findall(r'<w:p[ >].*?</w:p>', d, re.S):
        t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', p)).strip()
        if t == text:
            st=re.search(r'<w:pStyle w:val=\"([^\"]+)\"', p)
            return nm.get(st.group(1), '?') if st else '?'
    return '缺'
print('%s|%s|%s|%s' % (style_of('摘要'), style_of('参考文献'), style_of('致谢'), style_of('附录A 补充数据')))
")
      [ "$got" = "摘要|不编号标题|不编号标题|不编号标题" ]
      check "摘要/参考文献/致谢/附录使用不编号样式（实际 $got）" "$?"
      ;;
    T20_empty)
      # 用户明确要求：包里的空 md 也出一个空 docx，而不是跳过
      got=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', d)).strip()
print('empty' if not t else 'nonempty')
")
      [ "$got" = "empty" ]
      check "空 md 产出空 docx（实际 $got）" "$?"
      ;;
    T12_bare_numbering)
      # 手写的裸数字编号（## 3 递推…）必须被剥掉
      has=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', d))
print(1 if '递推最小二乘法辨识方法' in t and '3 递推' not in t else 0)")
      [ "$has" = "1" ]; check "裸数字编号被剥离" "$?"
      ;;
    T13_no_numbering)
      # 反向：正文里的数字不能被误削（「3 个关键问题」是标题内容）
      has=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', d))
print(1 if '3 个关键问题' in t else 0)")
      [ "$has" = "1" ]; check "无编号文档里的数字未被误削" "$?"
      ;;
    T11_unsafe_resources)
      # 安全底线：本地文件 / 外部地址的图片必须被拦下，不能出现在产出里
      leak=$(python3 -I -c "
import zipfile
try:
    z=zipfile.ZipFile('$out')
    media=[n for n in z.namelist() if 'media' in n and not n.endswith('/')]
    hit=any(b'root:' in z.read(m) or b'radxa' in z.read(m) for m in media)
    print(1 if (media and hit) else 0)
except Exception: print(0)")
      [ "$leak" = "0" ]; check "本地文件没有被嵌进产出" "$?"
      grep -q "不安全的资源引用" "$warn"; check "输出了资源拦截告警" "$?"
      ;;
    T10_state_leak)
      has=$(uses_style "$out" "Compact")
      [ "$has" = "1" ]; check "参考资料之后的章节列表仍是 Compact" "$?"
      ;;
  esac
done

# ── 「识别结果」统计行（网页上那一栏的数据源）──
# 用户要能一眼看出「我们从他文档里读到了什么」，识别错了当场发现。
echo "── 识别结果统计行"
rep="$OUTDIR/report.jsonl"
rm -f "$rep"
(cd "$HERE/cases" && THESIS_WARNINGS_FILE="$rep" "$PROJ/tools/convert.sh" \
    T15_equations.md "$OUTDIR/T15_stats.docx" "$TPL") >/dev/null 2>&1
for want in 大标题 章节 公式 目录; do
  grep -q "\"label\":\"$want\"" "$rep" 2>/dev/null
  check "统计里有「$want」" "$?"
done
# 页码提示（「按 F9 更新域」）现在由**网页**在成功行上给，不在报告里 ——
# 所以这条只在 api_smoke 里断言（见那边「页码按 F9 更新」）。

# 主文档基线：样式分布必须与已确认的版本一致。
# 只有用本项目的默认模板时才有意义 —— 演示模板的版式不同，跳过。
if [ "${TPL_IS_DEMO:-0}" = "1" ]; then
  echo "── 主用例基线断言：跳过（当前用的是中性演示模板，不是项目默认模板）"
else
echo "── 主用例 tests/论文1.md（基线断言）"
out="$OUTDIR/论文1.docx"
# 和上面的用例一样必须走 convert.sh —— 基线锁的是**整条管线**的产出。
# 实测：换管线后只多了 build_toc 填的目录条目（toc 2:18 + toc 1:7 + 目录标题:1，
# 正好等于 heading 3 / heading 2 的数量），其余 8 个样式一字未变。
(cd "$HERE" && "$PROJ/tools/convert.sh" 论文1.md "$out" "$TPL") 2>/dev/null

# 目录条目不再由我们写进缓存（改成 F9 提示占位），所以这份基线里**没有 toc 1 / toc 2** ——
# 那两种样式是 Word/WPS 更新域时才生成的。其余每一项都必须和以前逐字相同。
# 2026-10-17：无序列表转正文（用户要求）。这里只有那 3 个 bullet 项有差异：
#   3 个 Compact → Body Text；列表后紧跟的「原稿中……」由 First Paragraph → Body Text
#   （列表变成普通段落后，它不再是「新块的第一段」）。其余 9 个样式一字未变。
# 2026-10-17（第二次）：参考文献改成「不编号标题」样式（用户要求不占章号）。
#   heading 2 -1（参考文献）、不编号标题 +1；
#   参考文献后紧跟的段落由 First Paragraph → Body Text（它不再算「标题后的第一段」）。
expect='Compact:48 Body Text:31 First Paragraph:20 heading 3:18 heading 2:6 摘要上标题:1 摘要:1 目录两个字:1 不编号标题:1 Block Text:1'
got=$(python3 -I -c "
import zipfile,re
from collections import Counter
z=zipfile.ZipFile('$out')
d=z.read('word/document.xml').decode()
s=z.read('word/styles.xml').decode()
nm={m.group(1):(re.search(r'<w:name w:val=\"([^\"]*)\"',m.group(2)).group(1) if re.search(r'<w:name w:val=\"([^\"]*)\"',m.group(2)) else '') for m in re.finditer(r'<w:style [^>]*w:styleId=\"([^\"]+)\"[^>]*>(.*?)</w:style>',s,re.S)}
c=Counter(re.findall(r'<w:pStyle w:val=\"([^\"]+)\"',d))
print(' '.join(f'{nm.get(k,k)}:{v}' for k,v in c.most_common()))
")
[ "$got" = "$expect" ]; check "样式分布与基线一致" "$?"
[ "$got" != "$expect" ] && { echo "      期望: $expect"; echo "      实际: $got"; }

# 目录域缓存里放的是**提示**（不是条目）：按 F9 后会被整体换成真正的目录。
# 为什么不用"条目占位"：没人按 F9 时它看起来像目录、但页码全空 —— 容易被直接交上去 ✗；
# 提示占位是一行醒目的字，不会有人看不见 ✓（详见 build_toc.py 里的注释）。
toc=$(python3 -I -c "
import re, zipfile
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
# F9 提示现在放在**域开始段**里（TOC 指令 + separate + 提示）；没有 pStyle 说明缓存不是条目
m=re.search(r'<w:p[ >](?:(?!</w:p>).)*?TOC (?:(?!</w:p>).)*?</w:p>', d, re.S)
seg=m.group(0) if m else ''
styled=len(re.findall(r'<w:pStyle', seg))
ok=(styled==0) and ('F9' in seg)
print('OK' if ok else '坏 styled=%d F9=%s' % (styled, 'F9' in seg))
")
[ "$toc" = "OK" ]; check "目录缓存是 F9 提示、没有条目（实际 $toc）" "$?"

# 结束符必须在第一章标题段开头（没有独立的末尾空段）—— 用户实测这个结构
# 在 WPS 里 F9 后不产生空白页（2026-10-17）。
endpt=$(python3 -I -c "
import re,zipfile
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
s=zipfile.ZipFile('$out').read('word/styles.xml').decode()
mh=re.search(r'<w:style [^>]*w:styleId=\"([^\"]+)\"[^>]*>\s*<w:name w:val=\"heading 2\"\s*/>', s, re.S)
h2=mh.group(1) if mh else '5'
m=re.search(r'<w:p[ >](?:(?!</w:p>).)*?<w:fldChar w:fldCharType=\"end\"\s*/>(?:(?!</w:p>).)*?</w:p>', d, re.S)
p=m.group(0) if m else ''
ok=('w:pStyle w:val=\"%s\"' % h2 in p) and ('F9' not in p) and ('F9' in d)
print('OK' if ok else '坏 h2=%s F9inP=%s' % (h2, 'F9' in p))
")
[ "$endpt" = "OK" ]; check "目录域结束符在第一章标题段开头、没有独立空段（实际 $endpt）" "$?"

# 页边批注方案已撤（正文里写提示就够，批注是否显示还取决于 WPS 设置）。
# 这里留着防回归：**不许**再往 docx 里塞同名重复部件（pandoc 本来就有 comments.xml，
# 写重了 zip 里会出现两个同名条目，读取器挑哪个不一定）。
dup=$(python3 -I -c "
import zipfile
n=zipfile.ZipFile('$out').namelist()
print(','.join(sorted(x for x in set(n) if n.count(x)>1)) or '无')
")
[ "$dup" = "无" ]; check "docx 里没有同名重复部件（实际 $dup）" "$?"

# 只有章节标题能进目录：其他样式一律不得带大纲级别 0-2。
# TOC 域指令里有 \u（按段落大纲级别收录），谁带了级别谁就会被 Word 收进目录 ——
# 「目录    2」自己变成一条目录就是这么来的（用户 F9 后实测报的）。
# ⚠️ 这类 bug 平时看不见：我们写的缓存不含它们，**只有更新域才暴露**，所以必须锁在这里。
stray=$(python3 -I -c "
import zipfile,re
z=zipfile.ZipFile('$out')
d=z.read('word/document.xml').decode(); s=z.read('word/styles.xml').decode()
lvl={}
for m in re.finditer(r'<w:style [^>]*w:styleId=\"([^\"]+)\"[^>]*>(.*?)</w:style>', s, re.S):
    nm=re.search(r'<w:name w:val=\"([^\"]*)\"', m.group(2))
    ol=re.search(r'<w:outlineLvl w:val=\"(\d+)\"', m.group(2))
    if nm and ol: lvl[m.group(1)]=(nm.group(1), int(ol.group(1)))
bad=set()
for sid in set(re.findall(r'<w:pStyle w:val=\"([^\"]+)\"', d)):
    nm, l = lvl.get(sid, ('', 99))
    # 不编号标题故意保留大纲级别（参考文献/致谢/附录要进目录，只是不带章号）
    if l <= 2 and nm and not nm.startswith('heading') and nm != '不编号标题':
        bad.add(nm)
print(','.join(sorted(bad)) or '无')
")
[ "$stray" = "无" ]; check "没有非章节样式会混进目录（实际 $stray）" "$?"
fi

# ── 没有模板时的提示（全新 clone 的用户最容易卡在这一步）──
echo "── 模板缺失时的提示"
msg=$("$PROJ/tools/convert.sh" "$HERE/论文1.md" /tmp/.never.docx /nonexistent/tpl.docx 2>&1 || true)
has()   { case "$msg" in *"$1"*) return 0;; *) return 1;; esac; }
lack()  { case "$msg" in *"$1"*) return 1;; *) return 0;; esac; }
has  "找不到 Word 模板"        && check "说清了是模板的问题" 0 || check "说清了是模板的问题" 1
has  "prepare_template.py"    && check "给了具体怎么做" 0    || check "给了具体怎么做" 1
has  "assets/templates/README" && check "指向了文档" 0        || check "指向了文档" 1
lack "毕业论文通用模板.docx"    && check "没暴露对用户无意义的文件名" 0 || check "没暴露对用户无意义的文件名" 1

echo
printf '结果: %d 通过, %d 失败\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
