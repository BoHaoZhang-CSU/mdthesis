#!/usr/bin/env bash
# md -> docx，套论文模板，并剥离 pandoc 带进来的无用图片。
#
# 用法:
#   ./tools/convert.sh <输入.md> <输出.docx> [模板.docx]
#
# 默认模板: <项目>/assets/templates/毕业论文通用模板.docx
#   （由 tools/prepare_template.py 从 assets/sources/ 里的原始模板加工而来：
#     给 heading 2 加了 pageBreakBefore 让每章另起一页，并剥掉模板自带图片）
#   可用环境变量 THESIS_TEMPLATE 覆盖，或传第三个参数。
# 输入 markdown 保持原样，所有模板适配逻辑都在 filters/thesis_template.lua 里。

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "用法: $0 <输入.md> <输出.docx> [模板.docx]" >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"

IN="$1"
OUT="$2"
TPL="${3:-${THESIS_TEMPLATE:-$ROOT/assets/templates/毕业论文通用模板.docx}}"

FILTER="$ROOT/filters/thesis_template.lua"
STRIP="$HERE/strip_unused_media.py"

for f in "$IN" "$TPL" "$FILTER" "$STRIP"; do
  [ -f "$f" ] || { echo "找不到文件: $f" >&2; exit 1; }
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# 目录：标题够多才生成。太少的话目录只有一行「目录」，纯属噪音。
# （--toc 由 pandoc 生成真正的 Word 目录域，标题用模板的 TOC 标题样式）
TOC_OPTS=()
if [ "$(grep -c -E '^#{1,3}[ \t]' "$IN" 2>/dev/null || echo 0)" -ge 3 ]; then
  TOC_OPTS=(--toc --toc-depth=3 -M toc-title=目录)
fi

# 角色样式映射：prepare_template 加工模板时会写一份 `<模板>.map.json`，
# 记录用户模板里「大标题 / 摘要 / 目录标题」各叫什么名字（用户可能用了自定义名）。
# filter 读它就知道该把自己的内容套到哪个样式上。
if [ -f "$TPL.map.json" ]; then
  export THESIS_STYLE_MAP="$(cat "$TPL.map.json")"
fi

# 1. 转换（内容不动，样式交给模板 + filter）
#    -f markdown-raw_attribute：禁用 `{=openxml}` 原始属性语法。
#    用户能用它往 document.xml 里塞任意 OOXML，构造出"别人打开文档时才触发"的引用。
#    关掉不影响正常 markdown（raw_html 保留 —— docx writer 本来就会丢弃它）。
pandoc "$IN" -f markdown-raw_attribute -o "$tmpdir/raw.docx" \
  --reference-doc="$TPL" \
  --lua-filter="$FILTER" \
  "${TOC_OPTS[@]}"

# 2. 剥掉模板带入但正文未引用的图片
python3 -I "$STRIP" "$tmpdir/raw.docx" "$tmpdir/s1.docx" >/dev/null

# 3. 把表格边框写成直接格式 —— 三线表的表头下线原本靠条件表格样式，
#    而 WPS 支持不完整（同一份文件 LibreOffice 三条线齐全、WPS 只剩两条）。
python3 -I "$HERE/set_table_borders.py" "$TPL" "$tmpdir/s1.docx" "$tmpdir/s2.docx"

# 4. 给目录域填上缓存条目 —— pandoc 生成的域 separate 和 end 之间是空的，
#    不刷新域的程序会显示成一片空白。
python3 -I "$HERE/build_toc.py" "$TPL" "$tmpdir/s2.docx" "$OUT"

echo "完成: $OUT ($(stat -c%s "$OUT") 字节)"
