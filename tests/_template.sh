#!/usr/bin/env bash
# 两个测试脚本共用的模板解析逻辑。用 `source` 引入。
#
# 本仓库**不附带模板**（那是核心资产，不进版本库）。所以：
#   ① 优先用环境变量 THESIS_TEMPLATE 指定的
#   ② 其次用 assets/templates/ 下第一个 .docx（使用者自己放的）
#   ③ 都没有 → 用 pandoc 自带的 reference 模板现生成一份中性的，让测试仍能跑
#
# 第 ③ 种情况下，依赖「我们这份模板特有版式」的断言会跳过，并明确提示。

# 解析出模板路径，写入全局变量 TPL；同时设 TPL_IS_DEMO=1/0
resolve_tpl() {
  PROJ="${PROJ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  TPL_IS_DEMO=0

  if [ -n "${THESIS_TEMPLATE:-}" ] && [ -f "$THESIS_TEMPLATE" ]; then
    TPL="$THESIS_TEMPLATE"; return 0
  fi
  for f in "$PROJ"/assets/templates/*.docx; do
    if [ -f "$f" ]; then TPL="$f"; return 0; fi
  done

  # 生成中性演示模板（放在 .out 里，不进仓库）
  local d="$PROJ/tests/.out/.demo"
  mkdir -p "$d" 2>/dev/null || d="${TMPDIR:-/tmp}/pandoc-web-demo"
  mkdir -p "$d"
  if [ ! -f "$d/tpl.docx" ]; then
    echo "（assets/templates/ 下没有模板，改用 pandoc 自带的中性模板跑测试）"
    pandoc --print-default-data-file reference.docx > "$d/ref.docx" 2>/dev/null
    python3 -I "$PROJ/tools/prepare_template.py" "$d/ref.docx" "$d/tpl.docx" >/dev/null 2>&1 \
      || { echo "演示模板生成失败" >&2; return 1; }
  fi
  TPL="$d/tpl.docx"
  TPL_IS_DEMO=1
}

# 生成测试夹具（weak / custom_named）—— 都从当前模板派生，所以任何模板下都能跑。
# 不进仓库：它们含有模板的样式内容。
make_fixtures() {
  local dir="$PROJ/tests/fixtures"
  mkdir -p "$dir" 2>/dev/null || return 0
  python3 -I - "$TPL" "$dir" <<'PYEOF' 2>/dev/null
import sys, re, zipfile, pathlib
tpl, outdir = sys.argv[1], pathlib.Path(sys.argv[2])
try:
    zin = zipfile.ZipFile(tpl)
    styles = zin.read('word/styles.xml').decode('utf-8')
except Exception:
    sys.exit(0)

def write(path, new_styles):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        for i in zin.infolist():
            z.writestr(i, new_styles.encode('utf-8')
                          if i.filename == 'word/styles.xml' else zin.read(i.filename))

# ① 缺样式的模板：删掉几个管线要用的样式，验证补齐逻辑
DROP = ['摘要上标题', '摘要', '目录两个字', 'First Paragraph', 'Compact',
        'Block Text', 'TOC Heading', 'toc 1', 'toc 2']
s = styles
for name in DROP:
    m = re.search(r'<w:style\b(?:(?!</w:style>).)*?<w:name w:val="%s"\s*/>.*?</w:style>'
                  % re.escape(name), s, re.S)
    if m:
        s = s[:m.start()] + s[m.end():]
write(outdir / 'weak_template.docx', s)

# ② 标题样式改中文名的模板：验证按大纲级别识别并改名
s = styles
for old, new in [('heading 2', '一级标题'), ('heading 3', '二级标题')]:
    s = re.sub(r'(<w:name w:val=")' + re.escape(old) + r'(")',
               lambda m: m.group(1) + new + m.group(2), s, count=1)
write(outdir / 'custom_named_template.docx', s)
PYEOF
}
