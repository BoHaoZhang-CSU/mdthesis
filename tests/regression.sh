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

  # 注意：从 md 所在目录跑，这样相对路径的图片能解析
  (cd "$HERE/cases" && pandoc "$(basename "$md")" -o "$raw" \
      --reference-doc="$TPL" --lua-filter="$PROJ/filters/thesis_template.lua") 2>"$warn"
  rc=$?
  check "pandoc 退出码 0" "$rc"

  python3 -I "$PROJ/tools/strip_unused_media.py" "$raw" "$out" >/dev/null 2>&1
  check "瘦身脚本执行成功" "$?"

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

# 主文档基线：样式分布必须与已确认的版本一致。
# 只有用本项目的默认模板时才有意义 —— 演示模板的版式不同，跳过。
if [ "${TPL_IS_DEMO:-0}" = "1" ]; then
  echo "── 主用例基线断言：跳过（当前用的是中性演示模板，不是项目默认模板）"
else
echo "── 主用例 tests/论文1.md（基线断言）"
out="$OUTDIR/论文1.docx"
(cd "$HERE" && pandoc 论文1.md -o "$OUTDIR/论文1_raw.docx" \
    --reference-doc="$TPL" --lua-filter="$PROJ/filters/thesis_template.lua") 2>/dev/null
python3 -I "$PROJ/tools/strip_unused_media.py" "$OUTDIR/论文1_raw.docx" "$out" >/dev/null 2>&1

expect='Compact:51 Body Text:26 First Paragraph:22 heading 3:18 heading 2:7 摘要上标题:1 摘要:1 Block Text:1'
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
fi

echo
printf '结果: %d 通过, %d 失败\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
