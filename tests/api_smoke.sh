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
# 右上角仓库入口 + 「继续添加 md 文件」提示（用户要求）
assert 'github.com/BoHaoZhang-CSU/mdthesis' in h, '右上角缺仓库链接'
assert '继续添加 md' in h, '缺「继续添加 md」提示'
# 页码提示：WPS 不会打开就更新域，必须让用户看到「按 F9」
assert '页码按 F9 更新' in h, '缺「页码按 F9 更新」提示（WPS 不自动更新域）'
assert '更新域' in h, '页码提示里没写清楚怎么做'
assert '更新整个目录' in h, '页码提示漏了 Word 会弹对话框这一步'
# 添加区必须在文件列表**下面** —— 加过文件后视觉重心是列表本身（用户要求）
assert h.find('id=\"list\"') < h.find('id=\"drop\"'), '添加区跑到文件列表上面去了'
assert 'X-Report' in h, '前端没读自动修复报告'
assert '识别结果' in h, '前端没有展示「识别结果」（读到了什么）'
assert 'images' in h, '前端没有把图片一起上传'
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
import re, zipfile
z=zipfile.ZipFile('$TMP/out.docx')
d=z.read('word/document.xml').decode()
s=z.read('word/styles.xml').decode()
assert 'w:pStyle w:val=\"2\"' not in d, 'heading 1 不该被用到'
assert '摘要上标题' in s, '模板样式没带过来'
assert 'pageBreakBefore' in s, '分页属性丢了'
assert '<w:pict>' not in d, '出现空心横线'
assert 'w:numId w:val=\"1\"' in s or 'numId w:val=\"1\"' in s, '自动编号定义丢了'
# OPC：docx 包里不能有目录条目，也不能有指向目录的 Content_Types Override
assert not any(i.is_dir() for i in z.infolist()), 'docx 含目录条目（Word 会拒开）'
ct=z.read('[Content_Types].xml').decode()
assert not re.search(r'<Override[^>]*PartName=\"[^\"]*/\"', ct), 'Content_Types 含目录 Override'
print('OK')
" >/dev/null 2>&1
check "产物样式正确（摘要上标题 / 分页 / 无空心横线 / 编号 / 无目录条目）" "$?"

# 「识别结果」——用户要能一眼看出我们从他文档里读到了什么
has=$(py "
import base64,json,re
raw=open('$TMP/hdr.txt',encoding='utf-8',errors='replace').read()
m=re.search(r'(?im)^x-report:\s*(\S+)', raw)
d=json.loads(base64.b64decode(m.group(1))) if m else {}
labels={s.get('label') for s in d.get('stats',[])}
print(1 if {'大标题','章节','目录'} <= labels else 0)
")
[ "$has" -eq 1 ]; check "识别结果里有大标题/章节/目录（实际 $has）" "$?"

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
# 域缓存里放的是**提示**（不是条目）：按 F9 后 Word/WPS 会把这段整体换成真目录。
# 提示现在放在**域开始段**里（TOC 指令 + separate + 提示）
seg = re.search(r'<w:p[ >](?:(?!</w:p>).)*?TOC (?:(?!</w:p>).)*?</w:p>', d, re.S)
cache = seg.group(0) if seg else ''
assert 'F9' in cache, '目录缓存里没有 F9 提示'
assert '<w:pStyle' not in cache, '目录缓存里还有条目（现在应该只放提示）'
# 两条结构性要求 —— 实测不满足时渲染器会整块丢弃目录
assert '<w:sdt>' not in d, '还套着 SDT 外壳（渲染器会忽略里面的内容）'
assert re.search(r'</w:r><w:r><w:instrText', d), 'fldChar 没各自独立成 run'
# 结束符必须在第一章标题段开头（没有独立末尾空段）—— WPS F9 后不会多出空白页
endp = re.search(r'<w:p[ >](?:(?!</w:p>).)*?<w:fldChar w:fldCharType=' + Q + r'end' + Q + r'(?:(?!</w:p>).)*?</w:p>', d, re.S)
h2 = sid('heading 2')
assert endp and ('w:pStyle w:val=' + Q + h2 + Q in endp.group(0)) and ('F9' not in endp.group(0)), 'TOC 结束符没有放到第一章标题段'
print('OK')" >/dev/null 2>&1
check "目录域 + 中文标题 + F9 提示占位 + Word 标准结构" "$?"

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
# 必须是 nil 不是 none —— Word 看到直接格式写 none 会认为「这层没规定」，
# 回落模板 Table 样式的三线表粗线，公式表上下就出现黑线（用户实测报过）
assert re.search(r'<w:insideV w:val=\"nil\"', tp), '表格未显式关闭竖线（要用 nil，none 会被 Word 回落）'
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
# 参考文献现在用「不编号标题」（不再占章号），所以 chapter-level 标题 = heading 2 + 不编号标题
assert cnt.get('heading 2', 0) + cnt.get('不编号标题', 0) == 7 and cnt.get('heading 3', 0) == 18, \
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

# ── 图片：md 与图片分开上传（目录名任意）──
echo "── POST /convert （md + 图片分开上传）"
curl -sf --max-time 180 -X POST "$BASE/convert" \
  -F "file=@$HERE/cases/T18_obsidian.md" \
  -F "images=@$HERE/cases/figures/obs-1.png" \
  -F "images=@$HERE/cases/figures/obs-2.png" \
  -D "$TMP/himg2.txt" -o "$TMP/img2.docx"
check "返回 200" "$?"
n=$(py "
import zipfile,re
d=zipfile.ZipFile('$TMP/img2.docx').read('word/document.xml').decode()
t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', d))
print('%d|%d' % (d.count('<w:drawing>'), t.count('![[')))
")
[ "$n" = "2|0" ]; check "两张图都嵌进去了、无 ![[ 残留（实际 $n）" "$?"

# ── zip：一个 md + 图片文件夹 ──
echo "── POST /convert （zip：一个 md + figures）"
py "
import zipfile
z=zipfile.ZipFile('$TMP/one.zip','w')
z.write('$HERE/cases/T18_obsidian.md','doc.md')
z.write('$HERE/cases/figures/obs-1.png','figures/obs-1.png')
z.write('$HERE/cases/figures/obs-2.png','figures/obs-2.png')
z.close()"
curl -sf --max-time 180 -X POST "$BASE/convert" -F "file=@$TMP/one.zip" \
  -D "$TMP/hzip1.txt" -o "$TMP/zip1.bin"
check "返回 200" "$?"
grep -qi '^content-type: *application/vnd' "$TMP/hzip1.txt"
check "单个 md 直接返回 docx（不是 zip）" "$?"
name=$(py "
import base64,re
h=open('$TMP/hzip1.txt',encoding='utf-8',errors='replace').read()
m=re.search(r'(?im)^x-output-name:\s*(\S+)',h)
print(base64.b64decode(m.group(1)).decode() if m else '')")
[ "$name" = "doc.docx" ]; check "下载名用内层 md 的名字（实际 $name）" "$?"
n=$(py "
import zipfile
d=zipfile.ZipFile('$TMP/zip1.bin').read('word/document.xml').decode()
print(d.count('<w:drawing>'))")
[ "$n" = "2" ]; check "zip 里的图片读到了（实际 $n）" "$?"

# ── zip：多个 md → 每个一个 docx，打包返回 ──
echo "── POST /convert （zip：多个 md）"
py "
import zipfile
z=zipfile.ZipFile('$TMP/multi.zip','w')
z.writestr('a.md', '# 甲\n\n## 一\n\n正文。\n')
z.writestr('b.md', '# 乙\n\n## 一\n\n正文。\n')
z.close()"
curl -sf --max-time 180 -X POST "$BASE/convert" -F "file=@$TMP/multi.zip" \
  -D "$TMP/hmulti.txt" -o "$TMP/multi.bin"
check "返回 200" "$?"
grep -qi '^content-type: *application/zip' "$TMP/hmulti.txt"
check "多个 md 打包成 zip 返回" "$?"
got=$(py "
import zipfile,re,io
z=zipfile.ZipFile('$TMP/multi.bin')
names=sorted(z.namelist())
titles=[]
for n in names:
    d=zipfile.ZipFile(io.BytesIO(z.read(n))).read('word/document.xml').decode()
    ps=[p for p in re.findall(r'<w:p[ >].*?</w:p>', d, re.S) if 'w:pStyle w:val=\"84\"' in p]
    titles.append(''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', ps[0])) if ps else '无')
print('%s|%s' % (','.join(names), ','.join(titles)))")
[ "$got" = "a.docx,b.docx|甲,乙" ]
check "每个 md 一个 docx，md 自带 H1 时优先用 H1 当标题（实际 $got）" "$?"

# ── zip：空 md 也出一个空 docx ──
echo "── POST /convert （zip：空 md）"
py "
import zipfile
z=zipfile.ZipFile('$TMP/empty.zip','w')
z.writestr('empty.md','')
z.close()"
curl -sf --max-time 180 -X POST "$BASE/convert" -F "file=@$TMP/empty.zip" \
  -o "$TMP/empty.docx"
check "返回 200" "$?"
got=$(py "
import zipfile,re
d=zipfile.ZipFile('$TMP/empty.docx').read('word/document.xml').decode()
print('empty' if not ''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', d)).strip() else 'nonempty')")
[ "$got" = "empty" ]; check "空 md 产出空 docx（实际 $got）" "$?"

# ── zip：md 在子目录，图片用 ../figures 引用；非 md 文件忽略 ──
echo "── POST /convert （zip：md 在子目录 + ../figures 引用）"
py "
import zipfile
z=zipfile.ZipFile('$TMP/updir.zip','w')
z.writestr('docs/report.md', '# 报告\n\n## 一\n\n![架构图](../figures/a.png)\n\n正文。\n')
z.write('$HERE/cases/figures/obs-1.png','figures/a.png')
z.writestr('docs/data.csv','a,b\n1,2\n')
z.writestr('docs/meta.json','{\"x\":1}')
z.close()"
curl -sf --max-time 180 -X POST "$BASE/convert" -F "file=@$TMP/updir.zip" \
  -o "$TMP/updir.docx"
check "返回 200" "$?"
got=$(py "
import zipfile,re
d=zipfile.ZipFile('$TMP/updir.docx').read('word/document.xml').decode()
caps=[''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', p))
      for p in re.findall(r'<w:p[ >].*?</w:p>', d, re.S)
      if 'w:pStyle w:val=\"86\"' in p]
print('%d|%s' % (d.count('<w:drawing>'), ','.join(caps)))")
[ "$got" = "1|图1-1 架构图" ]
check "../ 图片引用能解析、CSV/JSON 被忽略（实际 $got）" "$?"

# ── 多文件包：每个 md 自己有一个 H1 时，用它当大标题（不要用文件名）──
echo "── POST /convert （zip 多文件：md 自带 H1 标题）"
py "
import zipfile
z=zipfile.ZipFile('$TMP/titles.zip','w')
z.writestr('a.md','# 甲标题\\n\\n## 摘要\\n\\n摘要。\\n\\n## 1 引言\\n\\n正文。\\n\\n## 参考文献\\n\\n[1] x\\n')
z.writestr('b.md','# 乙标题\\n\\n## 1 一\\n\\n正文。\\n')
z.close()"
curl -sf --max-time 180 -X POST "$BASE/convert" -F "file=@$TMP/titles.zip" \
  -o "$TMP/titles.bin"
check "返回 200" "$?"
got=$(py "
import zipfile,io,re
z=zipfile.ZipFile('$TMP/titles.bin')
def info(b):
    zz=zipfile.ZipFile(io.BytesIO(b)); d=zz.read('word/document.xml').decode(); s=zz.read('word/styles.xml').decode()
    nm={}
    for m in re.finditer(r'<w:style [^>]*w:styleId=\"([^\"]+)\"[^>]*>(.*?)</w:style>', s, re.S):
        x=re.search(r'<w:name w:val=\"([^\"]+)\"', m.group(2)); nm[m.group(1)]=x.group(1) if x else '?'
    title='-'; ref='-'
    for p in re.findall(r'<w:p[ >].*?</w:p>', d, re.S):
        t=''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', p)).strip()
        st=re.search(r'<w:pStyle w:val=\"([^\"]+)\"', p)
        name=nm.get(st.group(1), '?') if st else '?'
        if name == '摘要上标题' and title == '-': title = t
        if t == '参考文献': ref = name
    return title, ref
out=[]
for n in sorted(z.namelist()):
    title, ref = info(z.read(n))
    out.append('%s:%s:%s' % (n, title, ref))
print(','.join(out))")
[ "$got" = "a.docx:甲标题:不编号标题,b.docx:乙标题:-" ]
check "自带 H1 的 md 用 H1 当大标题、参考文献不编号（实际 $got）" "$?"

# ── 压缩包格式：tar.gz / 7z ──
echo "── POST /convert （tar.gz 压缩包）"
mkdir -p "$TMP/tarsrc/figures"
printf '# 报告\n\n## 一\n\n![架构图](figures/a.png)\n' > "$TMP/tarsrc/report.md"
cp "$HERE/cases/figures/obs-1.png" "$TMP/tarsrc/figures/a.png"
tar czf "$TMP/pkg.tar.gz" -C "$TMP/tarsrc" .
curl -sf --max-time 180 -X POST "$BASE/convert" -F "file=@$TMP/pkg.tar.gz" \
  -o "$TMP/targz.docx"
check "返回 200" "$?"
got=$(py "
import zipfile,re
d=zipfile.ZipFile('$TMP/targz.docx').read('word/document.xml').decode()
caps=[''.join(re.findall(r'<w:t[^>]*>([^<]*)</w:t>', p))
      for p in re.findall(r'<w:p[ >].*?</w:p>', d, re.S)
      if 'w:pStyle w:val=\"86\"' in p]
print('%d|%s' % (d.count('<w:drawing>'), ','.join(caps)))")
[ "$got" = "1|图1-1 架构图" ]
check "tar.gz 里的 md+图片转换正常（实际 $got）" "$?"

SZ=$(command -v 7z || command -v 7zz || true)
if [ -n "$SZ" ]; then
  echo "── POST /convert （7z 压缩包）"
  (cd "$TMP/tarsrc" && "$SZ" a -t7z "$TMP/pkg.7z" report.md figures >/dev/null 2>&1)
  curl -sf --max-time 180 -X POST "$BASE/convert" -F "file=@$TMP/pkg.7z" \
    -o "$TMP/pkg7z.docx"
  check "返回 200" "$?"
  got=$(py "
import zipfile
d=zipfile.ZipFile('$TMP/pkg7z.docx').read('word/document.xml').decode()
print(d.count('<w:drawing>'))")
  [ "$got" = "1" ]; check "7z 里的图片转换正常（实际 $got）" "$?"

  echo "── 安全：加密的 7z"
  (cd "$TMP/tarsrc" && "$SZ" a -t7z -psecret "$TMP/enc.7z" report.md >/dev/null 2>&1)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -X POST "$BASE/convert" \
    -F "file=@$TMP/enc.7z")
  [ "$code" = "422" ]; check "加密压缩包被拒绝（HTTP $code）" "$?"
else
  echo "── 跳过 7z 测试（本机没有 7z/7zz）"
fi

# ── 安全：tar 路径穿越 / zip 路径穿越 / 非图片文件 ──
echo "── 安全：tar 里带 ../ 路径"
py "
import tarfile,io
with tarfile.open('$TMP/evil.tar.gz','w:gz') as tf:
    data=b'# evil'
    ti=tarfile.TarInfo('../evil.md'); ti.size=len(data)
    tf.addfile(ti, io.BytesIO(data))"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -X POST "$BASE/convert" \
  -F "file=@$TMP/evil.tar.gz")
[ "$code" = "400" ]; check "被拒绝（HTTP $code）" "$?"
echo "── 安全：zip 里带 ../ 路径"
py "
import zipfile
z=zipfile.ZipFile('$TMP/evilzip.zip','w')
z.writestr('../evil.md','# x\n')
z.close()"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -X POST "$BASE/convert" \
  -F "file=@$TMP/evilzip.zip")
[ "$code" = "400" ]; check "被拒绝（HTTP $code）" "$?"

echo "── 安全：把非图片文件当图片上传"
printf 'not an image\n' > "$TMP/fake.png"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -X POST "$BASE/convert" \
  -F "file=@$HERE/论文1.md" -F "images=@$TMP/fake.png")
[ "$code" = "400" ]; check "被拒绝（HTTP $code）" "$?"

echo
printf '结果: %d 通过, %d 失败\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
