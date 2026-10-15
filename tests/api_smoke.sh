#!/usr/bin/env bash
# API 冒烟测试。可指向本机进程，也可指向容器映射出来的端口：
#   ./tests/api_smoke.sh http://127.0.0.1:8899
#   ./tests/api_smoke.sh http://127.0.0.1:8000     # 容器

set -uo pipefail

BASE="${1:-http://127.0.0.1:8899}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$HERE")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 模板解析（本仓库不带模板）+ 生成测试夹具
. "$HERE/_template.sh"
resolve_tpl || exit 1
make_fixtures

pass=0; fail=0
ok()   { printf '    ✓ %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '    ✗ %s\n' "$1"; fail=$((fail+1)); }
check(){ [ "$2" -eq 0 ] && ok "$1" || bad "$1"; }

py() { python3 -I -c "$1"; }

echo "目标: $BASE"

# ── 网页界面 ──
echo "── GET / （中文网页面板）"
curl -sf --max-time 20 "$BASE/" -o "$TMP/index.html"
check "返回 200" "$?"
py "
import re
h=open('$TMP/index.html',encoding='utf-8').read()
assert '毕业论文' in h, '缺中文标题'
assert 'id=\"drop\"' in h, '缺拖拽区'
assert 'id=\"go\"' in h, '缺转换按钮'
assert 'id=\"tplFile\"' in h, '缺自定义模板上传'
assert 'X-Report' in h, '前端没读自动修复报告'
# 转换完成后要自动触发下载，不该让用户再点一次
assert 'a.click()' in h, '没有自动下载逻辑'
assert 'id=\"dlBtn\"' not in h, '还留着多余的下载按钮'
# 拖拽必须绑在**整个页面**上 —— 只绑方框的话，用户拖到框外浏览器会直接
# 打开那个文件，页面跳走，只能刷新回来（用户报过）。
assert \"window.addEventListener('drop'\" in h or 'window.addEventListener(\"drop\"' in h, \
    '拖拽没绑到整个页面，拖到框外会把页面带走'
assert 'e.preventDefault()' in h, '没阻止浏览器打开被拖入的文件'
# 文件队列：多选、默认勾选、转完取消勾选、相对时间
assert 'multiple hidden' in h, '不支持一次选多个文件'
assert 'checked: true' in h and 'it.checked = false' in h, '缺勾选状态管理'
assert '分钟前' in h and 'setInterval(render' in h, '缺相对时间显示或刷新'
# 模板行必须排在状态区**前面**，否则会被提示挤下去
assert h.find('id=\"tplName\"') < h.find('id=\"status\"'), '模板行被排到状态区后面了'
# 转换成功的细节默认收起 —— 用户不在乎那些，摊开会造成视觉疲劳
assert 'class=\"more\" hidden' in h, '详情不是默认收起的'
assert \"classList.contains('tog')\" in h, '详情没有展开/收起开关'
# 同名文件要能区分
assert 'function uniqueName' in h, '没处理同名文件（会互相覆盖）'
# 用户明确要求：全站直角，不要圆角
assert not re.search(r'border-radius:\s*[1-9]', h), '还有圆角'
# 粘贴文本：默认折叠的入口 + 合成 File 走现有队列 + 从 # 标题取名
assert 'id=\"pasteToggle\"' in h and 'id=\"pastePanel\" hidden' in h, '粘贴入口不是默认折叠的'
assert 'new File([text]' in h and 'addFiles([new File' in h, '粘贴没走现有的文件队列'
assert 'function titleFromMd' in h, '没从 # 标题取名'
assert '粘贴只带文字' in h, '没提示粘贴只带文字'
" >/dev/null 2>&1
check "页面结构完整（拖拽 / 队列 / 勾选 / 时间 / 模板位置 / 自动下载）" "$?"

# ── /health ──
echo "── GET /health"
curl -sf --max-time 20 "$BASE/health" -o "$TMP/health.json"
check "返回 200 且是合法 JSON" "$?"
grep -q '"status": *"ok"' "$TMP/health.json"; check "status=ok" "$?"

# ── /templates ──
echo "── GET /templates"
curl -sf --max-time 20 "$BASE/templates" -o "$TMP/t.json"
check "返回 200" "$?"
n=$(py "import json;print(len(json.load(open('$TMP/t.json'))['templates']))")
[ "$n" -ge 1 ]; check "至少列出 1 个模板（实际 $n）" "$?"

# ── /check：多 H1 用例应报出告警 ──
echo "── POST /check （T1：多个一级标题）"
curl -sf --max-time 60 -X POST "$BASE/check" \
  -F "file=@$HERE/cases/T1_hash_chapters.md" -o "$TMP/check.json"
check "返回 200" "$?"
g=$(py "import json;print(len(json.load(open('$TMP/check.json')).get('guesses',[])))")
[ "$g" -ge 1 ]; check "报告了「猜了什么」（$g 条）" "$?"
c=$(py "import json;print(len(json.load(open('$TMP/check.json')).get('changes',[])))")
[ "$c" -ge 1 ]; check "报告了会自动做的改动（$c 条）" "$?"

# ── /check：合规文档应无告警 ──
echo "── POST /check （主用例，应干净）"
curl -sf --max-time 60 -X POST "$BASE/check" \
  -F "file=@$HERE/论文1.md" -o "$TMP/check2.json"
check "返回 200" "$?"
w=$(py "import json;print(len(json.load(open('$TMP/check2.json'))['warnings']))")
[ "$w" -eq 0 ]; check "无告警（实际 $w）" "$?"

# ── /normalize ──
echo "── POST /normalize （T1，应给出修复结果）"
curl -sf --max-time 60 -X POST "$BASE/normalize" \
  -F "file=@$HERE/cases/T1_hash_chapters.md" -o "$TMP/norm.json"
check "返回 200" "$?"
has=$(py "import json;d=json.load(open('$TMP/norm.json'));print(1 if d.get('markdown') else 0)")
[ "$has" -eq 1 ]; check "返回了修好的 markdown" "$?"
rem=$(py "import json;print(len(json.load(open('$TMP/norm.json')).get('remaining_warnings',[])))")
[ "$rem" -eq 0 ]; check "修复后复查无残留告警（实际 $rem）" "$?"

# ── /convert ──
echo "── POST /convert （主用例 → docx）"
curl -sf --max-time 180 -X POST "$BASE/convert" \
  -F "file=@$HERE/论文1.md" -D "$TMP/hdr.txt" -o "$TMP/out.docx"
check "返回 200" "$?"
head -c 2 "$TMP/out.docx" | grep -q "PK"; check "产物是 zip（docx）" "$?"
py "
import zipfile
z=zipfile.ZipFile('$TMP/out.docx')
d=z.read('word/document.xml').decode()
s=z.read('word/styles.xml').decode()
assert 'w:pStyle w:val=\"2\"' not in d, 'heading 1 不该被用到'
assert '摘要上标题' in s, '模板样式没带过来'
assert 'pageBreakBefore' in s, '分页属性丢了'
assert '<w:pict>' not in d, '出现空心横线'
assert 'w:numId w:val=\"1\"' in s or 'numId w:val=\"1\"' in s, '自动编号定义丢了'
print('OK')
" >/dev/null 2>&1
check "产物样式正确（摘要上标题 / 分页 / 无空心横线 / 编号）" "$?"

# ── /convert 的核心承诺：不合规的 md 也直接出可用文档（自动修复，不返工给用户）──
echo "── POST /convert （T1 不合规文档，应自动修复后成功）"
curl -sf --max-time 180 -X POST "$BASE/convert" \
  -F "file=@$HERE/cases/T1_hash_chapters.md" -D "$TMP/hdr3.txt" -o "$TMP/fixed.docx"
check "转换成功（没有让用户先回去改）" "$?"
g=$(grep -i '^x-guesses-count:' "$TMP/hdr3.txt" | tr -d '\r' | awk '{print $2}')
[ "${g:-0}" -ge 1 ]; check "报告了「猜了什么」（$g 条）" "$?"
py "
import zipfile, re
z=zipfile.ZipFile('$TMP/fixed.docx')
d=z.read('word/document.xml').decode()
s=z.read('word/styles.xml').decode()
# 按样式名查 styleId（styleId 是模板内的数字，不能写死）
sid=re.search(r'<w:style [^>]*w:styleId=\"([^\"]+)\"[^>]*>\s*<w:name w:val=\"摘要上标题\"', s).group(1)
n=len(re.findall(r'<w:pStyle w:val=\"%s\"' % sid, d))
assert n==1, f'自动修复后大标题应恰好 1 个，实际 {n} 个'
assert 'pageBreakBefore' in s, '模板样式没生效'
print('OK')" >/dev/null 2>&1
check "自动修复后大标题恰好 1 个、模板样式已生效" "$?"

# ── 目录（Word 目录域 + 缓存条目）──
echo "── POST /convert （目录生成）"
curl -sf --max-time 120 -X POST "$BASE/convert" \
  -F "file=@$HERE/cases/T14_manual_toc.md" -o "$TMP/toc.docx"
check "转换成功" "$?"
py "
import zipfile, re
z = zipfile.ZipFile('$TMP/toc.docx')
d = z.read('word/document.xml').decode()
s = z.read('word/styles.xml').decode()
st = z.read('word/settings.xml').decode()
# 真目录域
assert '<w:instrText' in d and 'TOC ' in d, '没有生成目录域'
# 目录标题要用模板自己的「目录两个字」样式，而不是 pandoc 默认的 TOC Heading
m = re.search(r'<w:style [^>]*w:styleId=\"([^\"]+)\"[^>]*>\s*<w:name w:val=\"目录两个字\"', s)
assert m, '模板里找不到「目录两个字」样式'
assert re.search(r'<w:pStyle w:val=\"%s\"' % m.group(1), d), '目录标题没用「目录两个字」样式'
# 打开「打开时更新域」——页码要靠这个自动写入
assert 'updateFields' in st, 'settings 没打开 updateFields，页码不会自动更新'
# 目录要夹在「摘要之后、第一章之前」，并且独立成页
# 样式 ID 按名字解析，不写死数字（不同模板的 ID 不一样）
Q = chr(34)   # 用 chr(34) 拼引号 —— 这段代码包在 bash 双引号里，写不了裸引号
def sid(name):
    rx = (r'<w:style [^>]*w:styleId=' + Q + r'([^' + Q + r']+)' + Q
          + r'[^>]*>\s*<w:name w:val=' + Q + name + Q)
    mm = re.search(rx, s)
    return mm.group(1) if mm else None

def para_pos(style_id):
    if not style_id: return -1
    mm = re.search(r'<w:p><w:pPr><w:pStyle w:val=' + Q + style_id + Q, d)
    return mm.start() if mm else -1

p_toc, p_h2, p_ab = para_pos(sid('目录两个字')), para_pos(sid('heading 2')), para_pos(sid('摘要'))
assert p_toc > 0 and p_h2 > 0, '找不到目录或章节标题'
assert p_toc < p_h2, '目录不在第一章之前'
assert p_ab < 0 or p_ab < p_toc, '目录不在摘要之后'
toc_para = re.search(r'<w:p><w:pPr><w:pStyle w:val=\"%s\"[^>]*>(.*?)</w:pPr>' % m.group(1), d, re.S)
assert toc_para and 'pageBreakBefore' in toc_para.group(1), '目录没有独立成页'
# 标题是中文，不是 pandoc 默认的 Table of Contents
assert 'Table of Contents' not in d, '目录标题还是英文'
# 缓存条目要填上（不刷新域的程序会显示成空白）
entries = re.findall(r'<w:p><w:pPr><w:pStyle w:val=\"[^\"]+\"/><w:tabs><w:tab w:val=\"right\" w:leader=\"dot\"', d)
assert len(entries) >= 2, f'目录缓存条目太少（{len(entries)}）'
# 两条结构性要求 —— 实测不满足时渲染器会整块丢弃目录
assert '<w:sdt>' not in d, '还套着 SDT 外壳（渲染器会忽略里面的内容）'
assert re.search(r'</w:r><w:r><w:instrText', d), 'fldChar 没各自独立成 run'
print('OK')" >/dev/null 2>&1
check "目录域 + 中文标题 + 缓存条目 + Word 标准结构" "$?"

# ── 表格必须是三线表（曾经因为样式引用悬空，一条线都没有）──
echo "── POST /convert （表格 → 三线表）"
curl -sf --max-time 120 -X POST "$BASE/convert" \
  -F "file=@$HERE/cases/T6_rich.md" -o "$TMP/tbl.docx"
check "转换成功" "$?"
py "
import zipfile, re
z = zipfile.ZipFile('$TMP/tbl.docx')
d = z.read('word/document.xml').decode()
s = z.read('word/styles.xml').decode()
assert '<w:tbl>' in d, '没有生成表格'
refs = re.findall(r'<w:tblStyle w:val=\"([^\"]+)\"', d)
ids = set(re.findall(r'<w:style [^>]*w:styleId=\"([^\"]+)\"', s))
assert refs, '表格没引用样式'
assert all(r in ids for r in refs), f'表格样式引用悬空：{refs} 不在 {sorted(ids)[:5]}...'
m = re.search(r'<w:style [^>]*w:styleId=\"%s\"[^>]*>.*?</w:style>' % re.escape(refs[0]), s, re.S)
x = re.sub(r'>\s+<','><', m.group(0))
assert 'w:sz=\"12\"' in x, '表格样式没有粗线（三线表的上下线）'
assert 'firstRow' in x, '表格样式没有表头行条件格式（缺表头下线）'
# 注意区分：边框是 <w:left w:val="single" .../>，而 <w:left w:type="dxa" w:w=.../> 是单元格边距，不算线
for side in ('left', 'right', 'insideV', 'insideH'):
    assert not re.search(r'<w:%s w:val=' % side, x), f'表格样式含多余的{side}边框'
print('OK')" >/dev/null 2>&1
check "表格样式是三线表（引用可解析 / 上下粗线 / 表头下线 / 无竖线）" "$?"

# 关键：表头下线原本靠条件表格样式，而 **WPS 支持不完整** —— 必须写成直接格式。
# 这条断言就是防止以后有人把 set_table_borders.py 从流程里拿掉。
py "
import zipfile, re
z = zipfile.ZipFile('$TMP/tbl.docx')
d = z.read('word/document.xml').decode()
tbl = re.search(r'<w:tbl>.*?</w:tbl>', d, re.S).group(0)
tp = re.search(r'<w:tblPr>.*?</w:tblPr>', tbl, re.S).group(0)
assert '<w:tblBorders>' in tp, '表格没有直接格式的上下边框（WPS 下会丢线）'
assert re.search(r'<w:top w:val=\"single\"', tp), '表格缺直接格式顶线'
assert re.search(r'<w:bottom w:val=\"single\"', tp), '表格缺直接格式底线'
assert re.search(r'<w:insideV w:val=\"none\"', tp), '表格未显式关闭竖线'
rows = re.findall(r'<w:tr\b.*?</w:tr>', tbl, re.S)
hdr = [r for r in rows if '<w:tblHeader' in r]
assert hdr, '没有表头行'
cells = re.findall(r'<w:tc>.*?</w:tc>', hdr[0], re.S)
assert cells, '表头行没有单元格'
assert all('<w:tcBorders>' in c and '<w:bottom' in c for c in cells), \
    '表头单元格没有直接格式的下边框（WPS 会丢这条线）'
print('OK')" >/dev/null 2>&1
check "表头下线是直接格式（WPS 也能渲染出三线表）" "$?"

# ── 手写编号：有编号的剥掉、没编号的不动（用户报的核心问题）──
echo "── POST /convert （T12 裸数字编号，应自动剥掉）"
curl -sf --max-time 120 -X POST "$BASE/convert" \
  -F "file=@$HERE/cases/T12_bare_numbering.md" -o "$TMP/t12.docx"
check "转换成功" "$?"
py "
import zipfile, re
t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>',
        zipfile.ZipFile('$TMP/t12.docx').read('word/document.xml').decode()))
assert '递推最小二乘法辨识方法' in t, '标题丢了'
assert '3 递推' not in t, '手写编号没剥掉'
print('OK')" >/dev/null 2>&1
check "「## 3 递推最小二乘法辨识方法」的编号已被剥掉" "$?"

echo "── POST /convert （T13 标题里的数字不是编号，不能削）"
curl -sf --max-time 120 -X POST "$BASE/convert" \
  -F "file=@$HERE/cases/T13_no_numbering.md" -o "$TMP/t13.docx"
check "转换成功" "$?"
py "
import zipfile, re
t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>',
        zipfile.ZipFile('$TMP/t13.docx').read('word/document.xml').decode()))
assert '3 个关键问题' in t, '正文里的数字被误削了'
print('OK')" >/dev/null 2>&1
check "「3 个关键问题」未被误削" "$?"

# ── /convert 用自定义模板 ──
echo "── POST /convert （上传自定义模板）"
curl -sf --max-time 180 -X POST "$BASE/convert" \
  -F "file=@$HERE/论文1.md" \
  -F "template_file=@$TPL" \
  -o "$TMP/out2.docx"
check "返回 200" "$?"
py "
import zipfile
d=zipfile.ZipFile('$TMP/out2.docx').read('word/document.xml').decode()
assert 'w:pStyle w:val=\"2\"' not in d
print('OK')" >/dev/null 2>&1
check "自定义模板产物可用" "$?"
# 用户模板里缺的样式必须从基准模板补齐 —— 否则悬空引用会让 Word 回落默认格式，
# 而不是我们这套调好的版式。
py "
import zipfile, re
z = zipfile.ZipFile('$TMP/out2.docx')
d = z.read('word/document.xml').decode(); s = z.read('word/styles.xml').decode()
ids = set(re.findall(r'<w:style [^>]*w:styleId=\"([^\"]+)\"', s))
used = set(re.findall(r'<w:pStyle w:val=\"([^\"]+)\"', d))
dead = sorted(used - ids)
assert not dead, f'有悬空样式引用（会回落默认格式）：{dead}'
print('OK')" >/dev/null 2>&1
check "自定义模板转换后无悬空样式引用" "$?"

# ── 安全：本地文件读取必须被拦 ──
# ── 用户模板样式残缺时从基准模板补齐（用户要求：缺什么用我们的，别回落 Word 默认）──
echo "── POST /convert （模板缺 9 个样式，应自动补齐）"
curl -sf --max-time 180 -X POST "$BASE/convert" \
  -F "file=@$HERE/cases/T12_bare_numbering.md" \
  -F "template_file=@$HERE/fixtures/weak_template.docx" -o "$TMP/weak.docx"
check "转换成功" "$?"
py "
import zipfile, re
z = zipfile.ZipFile('$TMP/weak.docx')
d = z.read('word/document.xml').decode(); s = z.read('word/styles.xml').decode()
ids = set(re.findall(r'<w:style [^>]*w:styleId=\"([^\"]+)\"', s))
used = set(re.findall(r'<w:pStyle w:val=\"([^\"]+)\"', d))
dead = sorted(used - ids)
assert not dead, f'样式没补齐，有悬空引用：{dead}'
assert re.search(r'<w:name w:val=\"摘要上标题\"', s), '缺的「摘要上标题」没补上'
assert re.search(r'<w:name w:val=\"First Paragraph\"', s), '缺的「First Paragraph」没补上'
print('OK')" >/dev/null 2>&1
check "残缺模板的样式已从基准模板补齐" "$?"

# ── 用户模板用自定义中文标题样式名（如「一级标题」）：靠大纲级别识别并改名 ──
echo "── POST /convert （模板标题样式叫「一级标题」，应自动识别）"
curl -sf --max-time 180 -X POST "$BASE/convert" \
  -F "file=@$HERE/论文1.md" \
  -F "template_file=@$HERE/fixtures/custom_named_template.docx" -o "$TMP/cn.docx"
check "转换成功" "$?"
py "
import zipfile, re
from collections import Counter
z = zipfile.ZipFile('$TMP/cn.docx')
d = z.read('word/document.xml').decode(); s = z.read('word/styles.xml').decode()
ids = set(re.findall(r'<w:style [^>]*w:styleId=\"([^\"]+)\"', s))
used = set(re.findall(r'<w:pStyle w:val=\"([^\"]+)\"', d))
assert not (used - ids), f'有悬空引用：{sorted(used - ids)}'
names = {}
for m in re.finditer(r'<w:style [^>]*w:styleId=\"([^\"]+)\"[^>]*>(.*?)</w:style>', s, re.S):
    nm = re.search(r'<w:name w:val=\"([^\"]*)\"', m.group(2))
    names[m.group(1)] = nm.group(1) if nm else ''
cnt = Counter(names.get(k, k) for k in re.findall(r'<w:pStyle w:val=\"([^\"]+)\"', d))
assert cnt.get('heading 2', 0) == 7 and cnt.get('heading 3', 0) == 18, \
    f'章节样式没识别对：{dict(cnt)}'
print('OK')" >/dev/null 2>&1
check "自定义中文标题样式已按大纲级别识别（章 7 / 节 18）" "$?"

# ── 图片读不到时必须告诉用户（pandoc 自己的警告只在 stderr，要单独捞）──
echo "── POST /convert （引用了一张不存在的图）"
printf '# 文档\n\n## 一节\n\n![图](figs/nope.png)\n\n正文。\n' > "$TMP/withimg.md"
curl -sf --max-time 120 -X POST "$BASE/convert" \
  -F "file=@$TMP/withimg.md" -D "$TMP/himg.txt" -o /dev/null
check "转换成功" "$?"
grep -qi '^x-warnings-count: *[1-9]' "$TMP/himg.txt"
check "报告了图片没读到（不是静默丢掉）" "$?"

echo "── 安全：markdown 里引用本地文件"
printf '![x](/etc/hostname)\n' > "$TMP/evil.md"
curl -sf --max-time 120 -X POST "$BASE/convert" \
  -F "file=@$TMP/evil.md" -D "$TMP/hdr2.txt" -o "$TMP/evil.docx"
check "请求本身成功（拦截而非报错）" "$?"
leak=$(py "
import zipfile
try:
    z=zipfile.ZipFile('$TMP/evil.docx')
    media=[n for n in z.namelist() if 'media' in n and not n.endswith('/')]
    hit=any(b'radxa' in z.read(m) or b'root:' in z.read(m) for m in media)
    print(1 if hit else 0)
except Exception: print(0)")
[ "$leak" -eq 0 ]; check "文件内容没有被嵌进 docx" "$?"

# ── 安全：非法模板名 ──
echo "── 安全：路径穿越的模板名"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$BASE/convert" \
  -F "file=@$HERE/论文1.md" -F "template=../../../etc/passwd")
[ "$code" = "400" ] || [ "$code" = "404" ]
check "被拒绝（HTTP $code）" "$?"

echo
printf '结果: %d 通过, %d 失败\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
