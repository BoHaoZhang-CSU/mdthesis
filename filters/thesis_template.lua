--[[
  论文模板适配 filter
  配合 "--reference-doc=毕业论文通用模板.docx" 使用。

  该模板的 heading 2/3 带真自动编号（numId=1：ilvl0="第%1章"、ilvl1="%1.%2"），
  所以 markdown 里不能手写编号，否则会双重编号。本 filter 做六件事：

    1. 一级标题 -> 用「摘要上标题」样式（docx 里 heading1 是 45pt 封面级字号且带分页，不适用）
    2. 内容为"摘要"的二级标题 -> 用「摘要」样式（必须脱离 heading 2，否则占用第1章导致全文编号错位）
    3. 二级标题去掉手写中文编号：## 一、引言      -> ## 引言
    4. 三级标题去掉手写数字编号：### 1.1 研究背景  -> ### 研究背景
    5. 参考资料章节里的列表 -> 转成普通段落（原论文的参考文献是普通段落，不是列表）
    6. 水平线 --- ：紧挨标题的丢弃（与「每章另起一页」重复）；其余渲染成正常横线

  另外：文档里出现多个一级标题（#）时会输出警告，提示用户修改 markdown。

  注意（踩过的坑）：
  - pandoc 的 docx writer 不接受 Header 上的 custom-style 属性，必须用 Div 包裹 + Plain
  - 编号剥离只改开头的 Str，不能整体 stringify 重建，否则标题里的粗体/代码会丢
  - 中文序号不能用 Lua 的字符类 [一二三]，Lua 字符类按字节匹配会出乱子
]]

--[[
  ============ 手写编号的识别与剥离 ============

  AI 生成的 markdown 有的在标题里写编号、有的不写，**同一份文档里也可能混着**，
  而且写法五花八门：`一、引言` / `第3章 递推` / `3 递推` / `1.1 背景` / `（一）概述`。

  难点：直接把「数字+空格」当编号削掉会误伤 —— `## 3 个要点` 会变成「个要点」。

  策略：**按层级统计占比**。某层标题里带手写编号的超过 60%，才认为这一层在用手写编号，
  然后整层剥离；否则认为那些数字是标题内容的一部分，一律不动。
  这样「有编号」和「没编号」的文档都能正确适配，混着写也不会翻车。
]]

-- 这次转换做了什么改动，最后汇总报告给调用方（网页界面会展示给用户看）。
-- 必须声明在所有用到它的函数之前 —— Lua 的 local 没有提升。
local stats = { stripped = 0, hr_dropped = 0, h1_demoted = 0, toc_dropped = 0, delims = 0 }

--[[
  角色样式映射（由 tools/prepare_template.py 生成，convert.sh 通过环境变量传进来）。

  用户自带模板里，「大标题 / 摘要 / 目录标题」可能叫别的名字（有人叫「论文题目」，
  有人叫「封面标题」）。prepare_template 会从模板里识别出来并写成一份映射，
  这里读它，就知道该把内容套到哪个样式上。

  读不到（命令行单独跑 pandoc、或模板没加工过）就用我们模板的默认名 ——
  那些名字由 prepare_template 从基准模板补齐，一定存在。
]]
local STYLE = { title = "摘要上标题", abstract = "摘要", toc = "目录两个字",
                equation = "公式" }

-- 中文章节序号。Lua 模式没有 | 交替，且 [一二三] 按字节匹配不安全，
-- 所以用「找顿号 -> 比对表」的方式做精确前缀匹配。
local CN_NUM = {}
for _, c in ipairs({
  "一", "二", "三", "四", "五", "六", "七", "八", "九", "十",
  "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
}) do
  CN_NUM[c] = true
end

-- 裸数字上限：章节序号不会超过这个数，用来挡住「2024 年度总结」这类误伤
local MAX_BARE_NUM = 99

-- 从字符串开头剥掉手写编号，返回剩余部分（**允许为空**，因为编号可能跨 inline），
-- 不匹配返回 nil。
local function strip_prefix_str(s)
  local rest

  -- 1.1 / 1.1.1 层级编号
  rest = s:match("^%d+%.%d+[%.%d]*%s*(.*)$")
  if rest then return rest end

  -- 第X章 / 第X节 / 第X篇（在「第X部分」之前匹配，否则会被部分匹配吃掉）
  rest = s:match("^第[一二三四五六七八九十百0-9]+[章节篇]%s*(.*)$")
  if rest then return rest end
  rest = s:match("^第[一二三四五六七八九十百0-9]+部分%s*(.*)$")
  if rest then return rest end

  -- （一） / (2) / （3）
  rest = s:match("^[（(][一二三四五六七八九十百0-9]+[）)]%s*(.*)$")
  if rest then return rest end

  -- 中文数字 + 、   一、引言
  local i = s:find("、", 1, true) -- plain find，按字节安全
  if i and i > 1 and CN_NUM[s:sub(1, i - 1)] then
    return s:sub(i + #"、"):gsub("^%s+", "")
  end

  -- 阿拉伯数字 + 分隔符   1. / 1、/ 1：/ 1）
  rest = s:match("^%d+[%.、．:：）)]%s*(.*)$")
  if rest then return rest end

  -- 裸数字 + 空格   3 递推最小二乘法辨识方法
  local n, tail = s:match("^(%d+)%s+(.*)$")
  if n and tonumber(n) and tonumber(n) <= MAX_BARE_NUM then
    return tail
  end

  return nil
end

-- 检测用：整条标题文本是否以手写编号开头（且编号后面还有内容）
local function has_number_prefix(s)
  local rest = strip_prefix_str(s)
  return rest ~= nil and rest:match("%S") ~= nil
end

-- 动作：从标题的 inline 列表里把编号剥掉，**保留后续所有格式**（粗体、行内代码等）
local function strip_numbering(inlines)
  local first = inlines[1]
  if not first or first.t ~= "Str" then
    return false
  end

  -- 情况 A：形如 [Str "3", Space, Str "递推…"] —— 数字和空格是分开的 inline
  if first.text:match("^%d+$") and inlines[2] and inlines[2].t == "Space"
     and inlines[3] ~= nil then
    local n = tonumber(first.text)
    if n and n <= MAX_BARE_NUM then
      table.remove(inlines, 1)
      table.remove(inlines, 1)
      return true
    end
  end

  -- 情况 B：编号和文字挤在首个 Str 里，或编号单独成一个 Str
  local rest = strip_prefix_str(first.text)
  if rest then
    if rest == "" then
      table.remove(inlines, 1)
      if inlines[1] and inlines[1].t == "Space" then
        table.remove(inlines, 1)
      end
    else
      first.text = rest
    end
    return true
  end

  return false
end

--[[
  丢掉 markdown 里手写的目录。

  有些 AI 生成的 md 里带一段「目录」（往往是各级标题 + 页码的纯文本列表）。
  转换时 pandoc 会按标题层级生成真正的 Word 目录域，这段手写目录就成了重复内容
  而且格式不对。这里整段丢掉。

  判据：标题文字恰好是「目录 / 目 录 / contents / table of contents」，
  丢掉从它开始、到下一个同级或更高级标题之前的所有内容。
]]
local TOC_TITLES = {
  ["目录"] = true, ["目 录"] = true, ["目　录"] = true,
  ["contents"] = true, ["table of contents"] = true,
}

local function is_toc_title(s)
  return TOC_TITLES[s:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")] == true
end

local function strip_manual_toc(blocks)
  local out = {}
  local skipping, skip_level = false, 0
  for _, b in ipairs(blocks) do
    if b.t == "Header" then
      local txt = pandoc.utils.stringify(b.content)
      if skipping and b.level <= skip_level then
        skipping = false -- 碰到了同级/更高级标题，手写目录结束了
      end
      if not skipping and b.level >= 2 and is_toc_title(txt) then
        skipping, skip_level = true, b.level
        stats.toc_dropped = (stats.toc_dropped or 0) + 1
      end
    end
    if not skipping then
      out[#out + 1] = b
    end
  end
  return out
end

--[[
  ============ 公式编号（按章） ============

  中文论文的公式编号是「（章号-序号）」、右对齐；公式本身居中。
  排版靠模板里的「公式」样式 —— 该段落带两个制表位（居中位 + 右对齐位），
  所以正文是：<Tab> 公式 <Tab>（3-1）

  **只给「独占一段」的公式编号**（`$$...$$` 单独成段）。
  不想编号的，用 fenced div 包起来：

      ::: {.unnumbered}
      $$E = mc^2$$
      :::

  （试过用 `\[...\]` 区分，但 pandoc 把它和 `$$...$$` 都解析成 DisplayMath，
    AST 里分不出来 —— 所以只能用 Div。）
]]
local eq_chapter, eq_count = 0, 0

local function is_chapter_header(b)
  if b.t ~= "Header" or b.level ~= 2 then return false end
  return not pandoc.utils.stringify(b.content):match("^%s*摘要%s*$")
end

-- 目测标记：零宽空格。后处理脚本靠它认出「公式表格」并去掉边框
local ZWSP = "\226\128\139"

-- 生成 3 列表格：空 | 公式（居中）| 编号（右对齐）
-- 为什么用表格而不是制表位：pandoc 会把 DisplayMath **提升成独立段落**
-- （<m:oMathPara>），和别的 inline 放不进同一段 —— 制表位方案实测行不通。
-- 表格里公式单独占一个单元格，正好绕开这个限制，而且保留「显示式」排版
-- （行内式会把 \sum 的上下限变成角标，论文里不能接受）。
local function equation_table(math_el, num)
  -- 用 markdown 表格当模板：手工构造 Table AST 很繁琐且 API 不稳定，这样最省事
  local doc = pandoc.read(
    "|  |  |  |\n|:---|:---:|---:|\n| " .. ZWSP .. " | XXXEQXXX | XXXNUMXXX |\n",
    "markdown")
  return doc:walk({
    Str = function(el)
      -- 注意占位符不能写成 @EQ@ —— 那会被 pandoc 当成引用（citations 语法）
      if el.text == "XXXEQXXX" then return math_el end
      if el.text == "XXXNUMXXX" then return pandoc.Str(num) end
    end,
  }).blocks[1]
end

local function is_chapter_header(b)
  if b.t ~= "Header" or b.level ~= 2 then return false end
  return not pandoc.utils.stringify(b.content):match("^%s*摘要%s*$")
end

local function number_equations(blocks)
  local out = {}
  for _, b in ipairs(blocks) do
    if is_chapter_header(b) then          -- 进新的一章，重置本章计数
      eq_chapter, eq_count = eq_chapter + 1, 0
    end
    -- 只给「独占一段」的公式编号；包在 ::: {.unnumbered} 里的 Div 不动
    if b.t == "Para" and #b.content == 1
       and b.content[1].t == "Math" and b.content[1].mathtype == "DisplayMath" then
      eq_count = eq_count + 1
      out[#out + 1] = equation_table(b.content[1],
                                     string.format("（%d-%d）", eq_chapter, eq_count))
      stats.equations = (stats.equations or 0) + 1
    else
      out[#out + 1] = b
    end
  end
  return out
end

-- 每层是否启用手写编号剥离（由 Pandoc 入口扫描后填充）
local strip_level = {}

-- 扫描各层级的标题，决定哪些层要剥编号
local function scan_numbering(blocks)
  local stat = {}
  for _, b in ipairs(blocks) do
    if b.t == "Header" and b.level >= 2 then
      local st = stat[b.level] or { total = 0, hit = 0 }
      st.total = st.total + 1
      if has_number_prefix(pandoc.utils.stringify(b.content)) then
        st.hit = st.hit + 1
      end
      stat[b.level] = st
    end
  end
  for lvl, st in pairs(stat) do
    strip_level[lvl] = (st.hit / st.total) >= 0.6
  end
end

-- 用 custom-style 包裹内容。注：刻意把 Header 降级成 Plain，
-- 与原论文结构一致（原论文的大标题/摘要标题本身就是普通段落样式，不是 outline 标题）。
local function styled(el, style)
  return pandoc.Div(
    { pandoc.Plain(el.content) },
    pandoc.Attr("", {}, { ["custom-style"] = style })
  )
end

do
  local raw = os.getenv("THESIS_STYLE_MAP")
  if raw then
    -- 只解析扁平的 {"key":"value"}，够用了，不值得为此引入 JSON 库
    for k, v in raw:gmatch('"(%-?%w+)"%s*:%s*"([^"]*)"') do
      if STYLE[k] ~= nil and v ~= "" then STYLE[k] = v end
    end
  end
end

-- 记下当前是否处在「参考资料 / 参考文献」章节里（供列表转换判断）
local in_refs = false
-- 是否已经遇到过文档大标题（第一个一级标题）
local seen_h1 = false

local function Header(el)
  local txt = pandoc.utils.stringify(el.content)

  -- 统计章节数（给「识别结果」用）。摘要不是编号章节，不算进去。
  if el.level == 2 and not txt:match("^%s*摘要%s*$") then
    stats.chapters = stats.chapters + 1
  elseif el.level == 3 then
    stats.sections = stats.sections + 1
  end

  -- 遇到任何标题都重算一次：只有参考资料标题会让它为 true
  in_refs = (txt:match("^%s*参考资料%s*$") or txt:match("^%s*参考文献%s*$")) ~= nil

  -- 1. 文档大标题：只有第一个一级标题算
  if el.level == 1 then
    if not seen_h1 then
      seen_h1 = true
      return styled(el, STYLE.title)
    end
    -- 又出现一个一级标题：说明这篇 md 的层级用法有歧义（Pandoc 里会出告警）。
    -- 降级成章节，至少让文档结构不至于全烂。
    el.level = 2
    stats.h1_demoted = stats.h1_demoted + 1
  end

  -- 2. 摘要标题：必须脱离自动编号序列
  if el.level == 2 and txt:match("^%s*摘要%s*$") then
    return styled(el, STYLE.abstract)
  end

  -- 3. 去掉手写编号，保留标题语义（编号交给 Word 自动生成）
  --    只在「该层级确实在用手写编号」时才剥（scan_numbering 判定）
  if strip_level[el.level] and strip_numbering(el.content) then
    stats.stripped = stats.stripped + 1
  end
  return el
end

-- 5. 参考资料章节里的列表 -> 普通段落。
--    序数改用 [N] 前缀写进正文（原论文就是这个格式），编号不再是列表生成的，
--    这样段落就能拿到模板的 First Paragraph / Body Text 样式。
--    正文里的其他列表不受影响，仍是 Compact。
local function list_to_paras(el, numbered)
  local out = {}
  for i, item in ipairs(el.content) do
    local inl = {}
    for _, blk in ipairs(item) do
      if blk.t == "Plain" or blk.t == "Para" then
        for _, x in ipairs(blk.content) do
          inl[#inl + 1] = x
        end
      end
    end
    if numbered then
      table.insert(inl, 1, pandoc.Space())
      table.insert(inl, 1, pandoc.Str("[" .. i .. "]"))
    end
    out[#out + 1] = pandoc.Para(inl)
  end
  return out
end

local function OrderedList(el)
  if in_refs then
    return list_to_paras(el, true)
  end
  return nil
end

local function BulletList(el)
  if in_refs then
    return list_to_paras(el, false)
  end
  return nil
end

-- 6. 水平线。
--    pandoc 默认生成的 VML <v:rect o:hr="t"> 漏了 fillcolor 和 stroked="f"，
--    WPS 会把它画成空心的矩形边框。这里改成用段落下边框画横线，渲染稳定。
--    紧跟在标题前面的一条直接丢弃 —— 那是章节分隔线，与「每章另起一页」重复。
local HR_PARAGRAPH = '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" '
  .. 'w:space="1" w:color="auto"/></w:pBdr></w:pPr></w:p>'

local function Blocks(blocks)
  local out = {}
  for i, b in ipairs(blocks) do
    if b.t == "HorizontalRule" then
      local nxt = blocks[i + 1]
      local is_separator = nxt and (nxt.t == "Header" or nxt.t == "Div")
      if not is_separator then
        out[#out + 1] = pandoc.RawBlock("openxml", HR_PARAGRAPH)
      else
        stats.hr_dropped = stats.hr_dropped + 1
      end
    else
      out[#out + 1] = b
    end
  end
  return out
end

--[[
  资源引用安全校验（重要）

  pandoc 对图片引用**不做任何路径校验**，实测：
      ![y](/etc/hostname)              -> 文件内容原样嵌进 docx，rc=0，零警告
      ![y](http://internal/secret)     -> 真的发起 HTTP 请求（SSRF）
      ![y](../../README.md)            -> 相对穿越，同样读得到

  在服务端，这就是「任意文件读 + SSRF」原语：上传者能把服务器文件下载走，
  也能拿它探测内网。pandoc 没有开关能关掉（--resource-path 挡不住绝对路径，
  --sandbox 在本发行版不可用）。

  好在这个 filter 在 writer 抓取资源**之前**运行，所以拦得住。

  默认拦。命令行本地用可以设 THESIS_ALLOW_EXTERNAL_RESOURCES=1 放行
  （本地转换自己的文档时，绝对路径图片是合理需求）。

  另外 Link 也要扫：file:// 和 UNC 链接会被写成外部关系，
  用户在 Word 里打开时**他的机器**会去请求 —— 把 SSRF 转嫁给终端用户。
  （http/https 链接放行，那是正常的引用。）
]]
local ALLOW_EXTERNAL = os.getenv("THESIS_ALLOW_EXTERNAL_RESOURCES") == "1"
local blocked_resources = {}

local function unsafe_image_target(t)
  if not t or t == "" then return nil end
  if t:match("^data:") then return nil end                          -- 内联数据，无外部访问
  if t:match("^%a[%w+%.%-]*:") then return "外部协议" end            -- http: https: file: ftp:
  if t:match("^/") then return "绝对路径" end
  if t:match("^\\") then return "UNC 路径" end
  if t:match("^%a:[/\\]") then return "盘符路径" end
  if t:match("%.%.") then return "相对路径穿越" end
  return nil
end

local function unsafe_link_target(t)
  if not t or t == "" then return nil end
  if t:match("^file:") then return "本地文件协议" end
  if t:match("^\\") or t:match("^%a:[/\\]") then return "本地路径" end
  return nil
end

local function check_resources(doc)
  if ALLOW_EXTERNAL then
    return doc
  end
  return doc:walk({
    Image = function(el)
      local why = unsafe_image_target(el.src)
      if not why then return nil end
      blocked_resources[#blocked_resources + 1] =
        string.format("图片 %s —— %s", el.src, why)
      local alt = pandoc.utils.stringify(el.caption)
      return pandoc.Str(alt ~= "" and alt or "[图片已移除]")
    end,
    Link = function(el)
      local why = unsafe_link_target(el.target)
      if not why then return nil end
      blocked_resources[#blocked_resources + 1] =
        string.format("链接 %s —— %s", el.target, why)
      return el.content -- 保留链接文字，去掉链接
    end,
  })
end

--[[
  汇报通道。

  web 服务要能给用户一个「这次转换我做了/发现了什么」的清单，
  所以结果文件用 **JSONL**（一行一条），字段：kind / message
    kind = "warning"  用户需要处理的问题
         = "change"   我自动改掉的东西（无需用户操作）
         = "guess"    我做了判断的地方 —— 用户有权知道，因为可能猜错

  为什么不用 stderr：pandoc 会给脚本告警加
  "[WARNING] Scripting warning at ... line N column M:" 前缀，把内部实现细节
  当成 API 用；而且多行消息会和 pandoc 自己的告警混在同一条流里。

  命令行不设 THESIS_WARNINGS_FILE，行为与从前完全一致（只走 stderr）。
]]
local warnings_file = os.getenv("THESIS_WARNINGS_FILE")

-- Lua 的 %q 不是合法 JSON（它把换行转义成反斜杠+真实换行），得自己来
local function json_escape(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  return s
end

-- label 只有统计行（kind="stat"）用：网页上按「标签 → 值」两栏列出
local function emit(kind, msg, to_stderr, label)
  msg = msg:gsub("%s+$", "")
  if to_stderr then
    pandoc.log.warn(msg)
  end
  if warnings_file then
    local fh = io.open(warnings_file, "a")
    if fh then
      local lbl = label and string.format('"label":"%s",', json_escape(label)) or ""
      fh:write(string.format('{"kind":"%s",%s"message":"%s"}\n', kind, lbl, json_escape(msg)))
      fh:close()
    end
  end
end

-- 需要用户处理的问题：既报 stderr（CLI 可见），也进结果文件
local function warn(msg)
  emit("warning", msg, true)
end

-- 我自动改掉的东西 / 我的判断：只进结果文件，不打扰命令行
local function note(kind, msg)
  emit(kind, msg, false)
end

-- 「这篇文档里识别到了什么」—— 用户一眼就能看出有没有识别错（大标题挑错、章节数不对……）
local function stat(label, msg)
  emit("stat", msg, false, label)
end

-- 告警里最多列举几项，避免告警长度随用户输入无界增长
local MAX_LISTED = 5

-- 把列表拼成 "    a\n    b\n    …等共 N 项"
local function list_items(items)
  local n = math.min(#items, MAX_LISTED)
  local out = {}
  for i = 1, n do
    out[i] = "    " .. items[i]
  end
  local s = table.concat(out, "\n")
  if #items > MAX_LISTED then
    s = s .. string.format("\n    …等共 %d 项", #items)
  end
  return s
end

--[[
  括号自适应（2026-10-15 夜，用户报的）。

  LaTeX 里**普通** `[ ]` `( )` 不会随内容变高，pandoc 就生成普通字符 run；
  里面装着分式/求和这类「高个子」时括号框不住内容，看着像排版错了 ——
  向量/矩阵里带分式最容易露馅：
      φ_d(k)=[ i_d(k), −ω_e(k)i_q(k), (i_d(k+1)−i_d(k))/T_s ]^T
  紧贴的两个 `[ ]` 只有一行字高，中间那个分式是它的三倍。

  改成 \left…\right 后 pandoc 会生成 <m:d> + <m:grow>，Word/WPS 自动拉伸括号。

  判断保持保守，避免改坏本来正常的公式：
    · [ ] 与 ( ) 分开配对，数量必须相等、按出现顺序配（LaTeX 的 \left/\right 就是这么配的）
    · 括号内部 { } 必须平衡 —— \left/\right 不能跨组，跨了 LaTeX 会报错
    · **只有内部出现「高个子」记号时才动**：普通写法（x[i]、(k+1)）一律不碰
    · 已经写着 \left/\right 的不碰（不重复标记）
]]
local TALL_TOKENS = {
  "\\frac", "\\dfrac", "\\tfrac", "\\binom", "\\genfrac", "\\sqrt",
  "\\sum", "\\prod", "\\coprod", "\\int", "\\iint", "\\iiint", "\\oint",
  "\\bigcup", "\\bigcap", "\\substack", "\\stackrel",
  "\\overline", "\\underline", "\\overbrace", "\\underbrace", "\\begin{",
}

local function has_tall(inner)
  for _, tok in ipairs(TALL_TOKENS) do
    if inner:find(tok, 1, true) then return true end
  end
  return false
end

local function braces_balanced(inner)
  local depth, i = 0, 1
  while i <= #inner do
    local c = inner:sub(i, i)
    if c == "\\" then
      local cmd = inner:match("^\\[a-zA-Z]+", i)
      i = i + (cmd and #cmd or 2)     -- \frac / \} 这类整体跳过
    else
      if c == "{" then depth = depth + 1
      elseif c == "}" then depth = depth - 1 end
      if depth < 0 then return false end
      i = i + 1
    end
  end
  return depth == 0
end

local function promote_delimiters(s)
  local n_pairs = 0
  for _, ab in ipairs({ { "[", "]" }, { "(", ")" } }) do
    local open, close = ab[1], ab[2]
    local ops, cls = {}, {}
    local i = 1
    while i <= #s do
      local c = s:sub(i, i)
      if c == "\\" then
        local cmd = s:match("^\\[a-zA-Z]+", i)
        if cmd then
          i = i + #cmd
          -- \left[ / \right] 里那个括号已经标记过了，别重复收
          if (cmd == "\\left" or cmd == "\\right") and s:sub(i, i) == open then
            i = i + 1
          end
        else
          i = i + 2                     -- \{ 这类转义字符
        end
      else
        if c == open then ops[#ops + 1] = i
        elseif c == close then cls[#cls + 1] = i end
        i = i + 1
      end
    end

    if #ops > 0 and #ops == #cls then
      local edits = {}
      for k = 1, #ops do
        local a, b = ops[k], cls[k]
        if b > a + 1 then
          local inner = s:sub(a + 1, b - 1)
          if has_tall(inner) and braces_balanced(inner) then
            edits[#edits + 1] = { a, b }
          end
        end
      end
      for k = #edits, 1, -1 do        -- 从右往左替换，位置不会互相影响
        local a, b = edits[k][1], edits[k][2]
        s = s:sub(1, a - 1) .. "\\left" .. open .. s:sub(a + 1, b - 1)
            .. "\\right" .. close .. s:sub(b + 1)
        n_pairs = n_pairs + 1
      end
    end
  end
  return s, n_pairs
end

-- 入口：先做各种扫描与安全校验，再转换，最后汇报做了什么
function Pandoc(doc)
  -- 1. 资源引用安全校验 —— 必须在 writer 抓取资源之前跑
  blocked_resources = {}
  doc = check_resources(doc)

  -- 1.5 数一数文档里有什么（网页上的「识别结果」）。位置有讲究：
  --     在安全校验**之后**（被拦掉的图片不该算进来）、
  --     在公式编号**之前**（编号会把公式改写成表格，混进表格数里）。
  local counts = { tables = 0, images = 0, equations = 0 }
  doc:walk({
    Table = function() counts.tables = counts.tables + 1 end,
    Image = function() counts.images = counts.images + 1 end,
    Math = function(m)
      if m.mathtype == "DisplayMath" then counts.equations = counts.equations + 1 end
    end,
  })
  stats.chapters, stats.sections = 0, 0

  if #blocked_resources > 0 then
    warn(string.format(
      "已拦截 %d 处不安全的资源引用（图片/链接）：\n%s\n"
        .. "服务端不允许引用本地路径或外部地址 —— 那会变成「任意文件读 + SSRF」。\n"
        .. "图片请改成随文档一起上传的相对路径（如 figs/a.png）。\n"
        .. "本地转换自己的文档时，可设 THESIS_ALLOW_EXTERNAL_RESOURCES=1 放行。",
      #blocked_resources, list_items(blocked_resources)
    ))
  end

  -- 2. 一级标题数量检查
  local titles = {}
  for _, b in ipairs(doc.blocks) do
    if b.t == "Header" and b.level == 1 then
      titles[#titles + 1] = pandoc.utils.stringify(b.content)
    end
  end

  if #titles > 1 then
    -- 这既是「需要用户知道的问题」，也是「我的判断」——两个身份都汇报。
    -- to_stderr=true 是为了命令行可见（regression.sh 会 grep 它）。
    emit("guess", string.format(
      "文档里有 %d 个一级标题（#），无法判断哪个是论文大标题：\n%s\n"
        .. "已按「第一个当作大标题、其余当作章节」处理。如果猜错了，"
        .. "请把多余的 # 改成 ## 后重新转换（规范见 docs/markdown-规范.md）。",
      #titles, list_items(titles)
    ), true)
  end

  -- 3. 丢掉 markdown 里手写的目录（转换时会生成真正的 Word 目录域）
  stats.toc_dropped = 0
  doc.blocks = strip_manual_toc(doc.blocks)

  -- 4. 判定各层级是否在用手写编号（决定要不要剥）
  strip_level = {}
  scan_numbering(doc.blocks)

  -- 4.5 公式编号（在转换前做，此时标题还没被改写成 Div，层级信息还在）
  eq_chapter, eq_count, stats.equations = 0, 0, 0
  doc.blocks = number_equations(doc.blocks)

  -- 5. 转换
  local out = doc:walk({
    Header = Header,
    OrderedList = OrderedList,
    BulletList = BulletList,
    Blocks = Blocks,
    Math = function(el)
      local new, n = promote_delimiters(el.text)
      if n > 0 then
        el.text = new
        stats.delims = stats.delims + n
      end
      return el
    end,
  })

  -- 6. 汇报自动做的改动 —— 用户不需要操作，但有权知道
  if stats.equations > 0 then
    note("change", string.format(
      "给 %d 个公式加了编号（按章，形如「（3-1）」）。"
        .. "不想编号的公式，用 ::: {.unnumbered} … ::: 包起来。", stats.equations))
  end
  if stats.toc_dropped > 0 then
    note("change", "删掉了 markdown 里手写的目录（已自动生成 Word 目录域，格式与模板一致）")
  end
  if stats.stripped > 0 then
    note("change", string.format("去掉了 %d 处标题里手写的编号（编号由 Word 自动生成，避免重复）",
      stats.stripped))
  end
  if stats.hr_dropped > 0 then
    note("change", string.format("删掉了 %d 条紧挨章节标题的水平线 ---（每章已自动另起一页，不需要分隔线）",
      stats.hr_dropped))
  end
  if stats.h1_demoted > 0 then
    note("change", string.format("把 %d 个多余的一级标题降级成了二级标题 ##", stats.h1_demoted))
  end
  if stats.delims > 0 then
    note("change", string.format(
      "修正了 %d 处公式括号：普通 [ ] ( ) 不会随内容变高，里面装着分式时括号框不住 —— "
        .. "已改成自适应高度（\\left…\\right）", stats.delims))
  end

  -- 7. 识别结果：让用户一眼看出「我们从他文档里读到了什么」，识别错了当场就能发现
  if #titles > 0 then
    stat("大标题", titles[1])
  else
    stat("大标题", "没找到一级标题（#）—— 如果这篇有标题，请用 # 标出来")
  end
  if stats.chapters > 0 or stats.sections > 0 then
    stat("章节", string.format("%d 章 · %d 节", stats.chapters, stats.sections))
  end
  if counts.equations > 0 then
    local tail = (counts.equations == stats.equations)
        and "按章自动编号"
        or string.format("其中 %d 个按章编号", stats.equations)
    stat("公式", string.format("%d 个（%s）", counts.equations, tail))
  end
  if counts.tables > 0 then
    stat("表格", string.format("%d 个（转成三线表）", counts.tables))
  end
  if counts.images > 0 then
    stat("图片", string.format("%d 张", counts.images))
  end

  return out
end
