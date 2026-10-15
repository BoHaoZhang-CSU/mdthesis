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
      has=$(python3 -I -c "
import zipfile,re
d=zipfile.ZipFile('$out').read('word/document.xml').decode()
print(1 if '<w:pBdr>' in d else 0)")
      [ "$has" = "1" ]; check "章节内的 --- 渲染成段落下边框" "$?"
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
grep -q "F9" "$rep" 2>/dev/null
check "目录统计里带了 F9 提示（页码得用户更新域才有）" "$?"

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

expect='Compact:51 Body Text:26 First Paragraph:22 toc 2:18 heading 3:18 toc 1:7 heading 2:7 摘要上标题:1 摘要:1 目录两个字:1 Block Text:1'
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

# 目录缓存里必须**带章号**。模板的编号是样式的自动编号（lvlText=第%1章 / %1.%2），
# 不在标题文字里 —— 不写进缓存的话，目录就成了没头没尾的「引言」（用户报过）。
toc=$(python3 -I -c "
import zipfile,re
z=zipfile.ZipFile('$out')
d=z.read('word/document.xml').decode(); s=z.read('word/styles.xml').decode()
ids={}
for m in re.finditer(r'<w:style [^>]*w:styleId=\"([^\"]+)\"[^>]*>\s*<w:name w:val=\"([^\"]*)\"\s*/>', s):
    ids.setdefault(m.group(2), m.group(1))
toc_ids={ids.get('toc 1'), ids.get('toc 2')}
n=ok=0
for m in re.finditer(r'<w:p\b.*?</w:p>', d, re.S):
    p=m.group(0)
    st=re.search(r'<w:pStyle w:val=\"([^\"]+)\"', p)
    if not st or st.group(1) not in toc_ids: continue
    t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', p)).strip()
    if not t: continue
    n+=1
    if re.match(r'^(第\d+章|\d+\.\d+) \S', t): ok+=1
print('%d/%d' % (ok, n))
")
[ "$toc" = "25/25" ]; check "目录缓存全部带章号（实际 $toc）" "$?"

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
    if l <= 2 and nm and not nm.startswith('heading'): bad.add(nm)
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
