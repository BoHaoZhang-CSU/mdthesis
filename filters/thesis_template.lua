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
local stats = { stripped = 0, hr_dropped = 0, h1_demoted = 0, toc_dropped = 0,
                delims = 0, image_captions = 0, captions_from_name = 0,
                captions_number_only = 0, formula_blocks = 0, formula_lines = 0,
                text_blocks = 0, inline_codes = 0, bullets_flattened = 0 }

--[[
  多文件包（zip 里多个 md）模式下的「大标题」。

  服务端把文件名（去扩展名）放进 THESIS_DOC_TITLE。一包多个 md 说明是
  「章节集合」，每个文件自己的标题就是文件名 —— 于是：
    · 所有一级标题降级成章（它们本来就是各章的小节）
    · 文档开头补一个大标题段落

  单 md 上传不设这个变量，行为与从前完全一致。
  空文档不补标题（用户要的就是一个空 docx）。
]]
local DOC_TITLE = os.getenv("THESIS_DOC_TITLE")
if DOC_TITLE == "" then DOC_TITLE = nil end

--[[
  角色样式映射（由 tools/prepare_template.py 生成，convert.sh 通过环境变量传进来）。

  用户自带模板里，「大标题 / 摘要 / 目录标题」可能叫别的名字（有人叫「论文题目」，
  有人叫「封面标题」）。prepare_template 会从模板里识别出来并写成一份映射，
  这里读它，就知道该把内容套到哪个样式上。

  读不到（命令行单独跑 pandoc、或模板没加工过）就用我们模板的默认名 ——
  那些名字由 prepare_template 从基准模板补齐，一定存在。
]]
local STYLE = { title = "摘要上标题", abstract = "摘要", toc = "目录两个字",
                equation = "公式", unnumbered = "不编号标题" }

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

--[[
  「不编号章节」：摘要、目录、参考文献、致谢、附录……（用户 2026-10-17 报）

  这些标题在论文里不占章号，也不应该把后面的章号顶走。
  模板里 heading 2 带自动编号（numId=1），所以给它们套一个
  「不编号标题」样式（prepare_template 照 heading 2 克隆、numId=0）。
]]
local UNNUMBERED_HEADING = {
  ["摘要"] = true, ["目录"] = true, ["参考文献"] = true,
  ["参考资料"] = true, ["致谢"] = true, ["符号说明"] = true,
}

local function is_unnumbered_heading(txt)
  local t = (txt or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if UNNUMBERED_HEADING[t] then return true end
  if t:lower() == "abstract" then return true end
  if t:sub(1, #"附录") == "附录" then return true end
  if t:sub(1, #"攻读学位期间") == "攻读学位期间" then return true end
  return false
end

local function is_chapter_header(b)
  if b.t ~= "Header" or b.level ~= 2 then return false end
  return not is_unnumbered_heading(pandoc.utils.stringify(b.content))
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

  -- 统计章节数（给「识别结果」用）。摘要/参考文献/致谢/附录等不编号章节不算。
  if el.level == 2 and not is_unnumbered_heading(txt) then
    stats.chapters = stats.chapters + 1
  elseif el.level == 3 then
    stats.sections = stats.sections + 1
  end

  -- 遇到任何标题都重算一次：只有参考资料标题会让它为 true
  in_refs = (txt:match("^%s*参考资料%s*$") or txt:match("^%s*参考文献%s*$")) ~= nil

  -- 1. 文档大标题：只有第一个一级标题算
  if el.level == 1 then
    if DOC_TITLE then
      -- 包内多文件模式：大标题取自文件名，md 里的 H1 一律当章节
      el.level = 2
      stats.h1_demoted = stats.h1_demoted + 1
    elseif not seen_h1 then
      seen_h1 = true
      return styled(el, STYLE.title)
    else
      -- 又出现一个一级标题：说明这篇 md 的层级用法有歧义（Pandoc 里会出告警）。
      -- 降级成章节，至少让文档结构不至于全烂。
      el.level = 2
      stats.h1_demoted = stats.h1_demoted + 1
    end
  end

  -- 2. 摘要标题：必须脱离自动编号序列
  if el.level == 2 and txt:match("^%s*摘要%s*$") then
    return styled(el, STYLE.abstract)
  end

  -- 2.5 不编号章节：参考文献 / 致谢 / 附录 / 目录 / Abstract …
  --     套「不编号标题」样式（照 heading 2 克隆、numId=0），不占章号，
  --     也不影响后面章节的自动编号。
  if el.level == 2 and is_unnumbered_heading(txt) then
    return styled(el, STYLE.unnumbered)
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

-- 6. 水平线 —— **一律丢弃**（详见下面 Blocks 里的注释）。
--    早年那段"转成段落下边框"的 HR_PARAGRAPH 常量已删：它在 Word/WPS 里画出来的
--    就是用户抱怨的那条灰线。

local function Blocks(blocks)
  local out = {}
  for i, b in ipairs(blocks) do
    if b.t == "HorizontalRule" then
      -- 论文里不需要水平线：**一律丢弃**。
      -- 早期只丢"紧挨章节标题"的那些，章节内的会被转成**段落底边框** ——
      -- 用户在 Word/WPS 里看到的那条灰线就是它（2026-10-15 报的）。
      -- 而 pandoc 自己生成的 <v:rect> 横线在 WPS 里会渲染成空心矩形（更早踩过）。
      -- 所以两种做法都不留，直接全丢。
      stats.hr_dropped = stats.hr_dropped + 1
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

--[[
  公式的另一种写法：\begin{equation}…\end{equation}（2026-10-15 用户报）。

  pandoc 只把 $…$ / $$…$$ / \[…\] 当数学；LaTeX 环境原样变成 **RawInline(tex)**，
  而 docx writer 遇到 raw tex **直接丢掉** —— 公式凭空消失、零警告（最坏的失败方式）。
  这里把 equation / equation* / displaymath 转成显示式数学；其余环境（align、gather、
  split、cases…）和认不出的 LaTeX 一律**保留成可见文字 + 报警** —— 宁可难看地露出来，
  也不要静默消失。
]]
local MATH_ENVS = { ["equation"] = true, ["equation*"] = true, ["displaymath"] = true }

local function rescue_latex(doc)
  local converted, left = 0, {}
  doc = doc:walk({
    RawInline = function(el)
      if el.format ~= "tex" then return nil end
      local env, body = el.text:match("^%s*\\begin%s*{([%w*]+)}%s*(.-)%s*\\end%s*{%1}%s*$")
      if env and MATH_ENVS[env] then
        body = body:gsub("\\label%s*{[^}]*}", "")      -- 标签没法解析，去掉
        body = body:gsub("^%s+", ""):gsub("%s+$", "")
        if body ~= "" then
          converted = converted + 1
          return pandoc.Math("DisplayMath", body)
        end
      end
      left[#left + 1] = el.text:gsub("%s+", " ")
      return pandoc.Str(el.text:gsub("%s+", " "))       -- 认不出的：留在正文里
    end,
  })
  return doc, converted, left
end

-- ── 表/图题（2026-10-15 用户报）─────────────────────────────────────────────
-- AI 生成的 md 常把题注写成**独立一行的加粗文字**：`**表10 与既有研究结果对比**`。
-- 学位论文的规范是「**表题在表上方、图题在图下方**」（这份 md 里表题本来就在上方 ✓），
-- 排版照模板（黑体·五号·居中）。这里做三件事：剥掉手写的号、按章重编号（表2-1）、
-- 套上模板的题注样式（`prepare_template` 会照「图下面的文字」克隆出「表上面的文字」）。
--
-- 只在**紧挨着**表格/插图时才认 —— 否则正文里一句加粗的「图3 说明…」会被误伤。
local STYLE_CAPTION = { ["表"] = "表上面的文字", ["图"] = "图下面的文字" }

local function caption_of(p)
  -- 认「整段只有一个加粗块，且以 表N / 图N 开头」
  --
  -- ⚠️ 中文**不能写进 Lua 的字符类** `[表图]` —— Lua 模式是按字节匹配的，
  -- 「表」是 3 个字节，字符类会去匹配单个字节，整个模式就废了（踩过）。
  -- 所以这里一律用字面量比较 + 分步 gsub。
  local c = p.content
  if #c ~= 1 or c[1].t ~= "Strong" then return nil end
  local txt = pandoc.utils.stringify(c[1].content)
  local lead = txt:gsub("^%s+", "")
  for _, kind in ipairs({ "表", "图" }) do
    if lead:sub(1, #kind) == kind then
      local after = lead:sub(#kind + 1)
      -- ⚠️ 只有后面跟数字/空白/冒号/结尾时才算题注。
      -- 否则「**图表解读：…**」「**表示…**」这类正文小标题会被误当成图题，
      -- 被拆成「图 + 表解读：…」（真实样本踩到）。
      if after == "" or after:match("^%d") or after:match("^%s")
         or after:match("^[：:]") then
        local rest = after
        rest = rest:gsub("^%s*[%d%.%-]+", "", 1)      -- 手写的号：10 / 2.1 / 2-1
        rest = rest:gsub("^%s*[：:]", "", 1)
        rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
        if rest == "" then return nil end
        return kind, rest
      end
    end
  end
  return nil
end

local cap_chapter, cap_n = 0, { ["表"] = 0, ["图"] = 0 }

--[[
  图片（2026-10-17 用户要求）

  · 独立成段的图片套模板的「图片」样式（居中）
  · **每张图都出题注**，图号一律按章、按出现顺序重编
  · 题注文字优先级：图下加粗行 > alt / Obsidian 别名 > 文件名
  · 纯编号文件名（2-1.png）只出「图2-1」，不重复旧号；
    描述性文件名（云服务器架构.png）出「图2-1 云服务器架构」
  · 行内图（正文里夹着的）完全不动
]]
local function image_inlines(b)
  -- 返回 (inlines, Image, 原块)；不是「独立成段的图片」则返回 nil
  if b.t == "Para" and #b.content == 1 and b.content[1].t == "Image" then
    return b.content, b.content[1], b
  end
  if b.t == "Figure" then
    local img = nil
    b:walk({ Image = function(el) if not img then img = el end end })
    if not img then return nil end
    for _, blk in ipairs(b.content) do
      if (blk.t == "Plain" or blk.t == "Para") and blk.content then
        return blk.content, img, b
      end
    end
  end
  return nil
end

local function figure_text(b)
  if b.t ~= "Figure" then return "" end
  local ok, txt = pcall(function() return pandoc.utils.stringify(b.caption) end)
  if ok and txt then return txt:gsub("^%s+", ""):gsub("%s+$", "") end
  return ""
end

-- 去掉「图」「图2-1」「2-1」「：」这些前缀，只留说明本身；返回空串 = 只要编号
local function clean_caption_text(txt, kind)
  txt = (txt or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if kind == "图" then
    local had_kind = txt:match("^图") ~= nil
    if had_kind then txt = txt:gsub("^图%s*", "", 1) end
    local rest = txt:gsub("^%d+[%-%.]%d+%s*", "", 1)
    if rest == txt and (had_kind or txt:match("^%d+%s") ) then
      rest = txt:gsub("^%d+%s+", "", 1)
    end
    txt = rest
  end
  txt = txt:gsub("^%s*[：:]%s*", "", 1)
  return (txt:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function next_number(kind)
  cap_n[kind] = cap_n[kind] + 1
  return (cap_chapter > 0)
    and string.format("%s%d-%d", kind, cap_chapter, cap_n[kind])
    or string.format("%s%d", kind, cap_n[kind])
end

-- custom-style 只能靠「Div 包 Plain」生效（直接给 Para 加属性会串到下一段，踩过）
local function styled_para(inlines, style)
  return pandoc.Div({ pandoc.Plain(inlines) },
    pandoc.Attr("", {}, { ["custom-style"] = style }))
end

local function filename_of(src)
  local name = (src or ""):match("([^/\\]+)$") or (src or "")
  return (name:gsub("%.[^%.]*$", ""))
end

local function number_captions(blocks)
  local out = {}
  for i, b in ipairs(blocks) do
    if is_chapter_header(b) then
      -- ⚠️ 必须用 is_chapter_header（它排除了「摘要」）—— 摘要被 styled 成**不编号**的样式，
      -- 所以它不算一章；算进去的话全文表题/图题编号整体 +1（用户报过：第 4 章的表编成了 5-1）。
      cap_chapter = cap_chapter + 1
      cap_n = { ["表"] = 0, ["图"] = 0 }
      out[#out + 1] = b
    else
      local inlines, img, orig = image_inlines(b)
      if inlines then
        -- 图片段落：先套「图片」样式（居中）
        out[#out + 1] = styled_para(inlines, "图片")
        -- 下一行是加粗图题？那就交给它，别出第二个题注（踩过：alt + 加粗行 = 双题注）
        local nxt = blocks[i + 1]
        local bold_kind = nil
        if nxt and nxt.t == "Para" then bold_kind = caption_of(nxt) end
        if bold_kind ~= "图" then
          local txt = clean_caption_text(figure_text(orig), "图")
          if txt == "" then
            local from_name = clean_caption_text(filename_of(img.src), "图")
            txt = from_name
            if from_name ~= "" then
              stats.captions_from_name = stats.captions_from_name + 1
            else
              stats.captions_number_only = stats.captions_number_only + 1
            end
          end
          local num = next_number("图")
          stats.captions = stats.captions + 1
          stats.image_captions = stats.image_captions + 1
          out[#out + 1] = styled_para(
            { pandoc.Str(num .. ((txt ~= "") and (" " .. txt) or "")) },
            STYLE_CAPTION["图"])
        end
      elseif b.t == "Para" then
        local kind, rest = caption_of(b)
        local adjacent = false
        if kind == "表" then
          local nxt = blocks[i + 1]
          adjacent = nxt ~= nil and nxt.t == "Table"
        elseif kind == "图" then
          local prv = blocks[i - 1]
          if prv then prv:walk({ Image = function() adjacent = true end }) end
        end
        if kind and adjacent then
          local num = next_number(kind)
          stats.captions = stats.captions + 1
          out[#out + 1] = styled_para({ pandoc.Str(num .. " " .. rest) },
                                      STYLE_CAPTION[kind])
        else
          out[#out + 1] = b
        end
      else
        out[#out + 1] = b
      end
    end
  end
  return out
end

-- ── 代码块里的公式 / 行内代码（2026-10-17 用户要求）───────────────────────
-- AI 生成的报告常把公式写进 ```text 代码块：
--     Age_scaled = (Age - 训练集年龄均值) / 训练集年龄标准差
-- 走 Source Code 样式（Fira Code + 5% 灰底）很难看；这里把它们转成真正的
-- Word 公式，并沿用按章编号。判定保持保守，转换结果作为「猜测」汇报。
--
-- 语言标记：
--   math / latex / tex  → 无条件当公式
--   python / js / bash … → 永远是代码
--   text / 无语言        → 逐行判定；像代码的整块保留；公式行转公式，
--                          其余行转普通正文（用户拍板）
local MATH_LANGS = { math = true, latex = true, tex = true }
local CODE_LANGS = {
  python = true, py = true, javascript = true, js = true, typescript = true, ts = true,
  bash = true, sh = true, shell = true, zsh = true, c = true, cpp = true, ["c++"] = true,
  ["c#"] = true, java = true, go = true, rust = true, sql = true, json = true,
  yaml = true, yml = true, xml = true, html = true, css = true, ruby = true, php = true,
  swift = true, kotlin = true, scala = true, r = true, matlab = true,
  powershell = true, ps1 = true, dockerfile = true, makefile = true,
  -- 显式「这就是代码」的标记：内容再像公式也保持 Source Code
  code = true,
}
local RELATIONS = { "==", "=", "≈", "≤", "≥", "≠" }
local MATH_FUNCS = { ln = true, log = true, lg = true, sin = true, cos = true,
                     tan = true, sqrt = true, exp = true, max = true, min = true,
                     abs = true }
local UNI_OPS = {
  ["×"] = "\\times ", ["÷"] = "\\div ", ["−"] = "-", ["≤"] = "\\le ",
  ["≥"] = "\\ge ", ["≠"] = "\\ne ", ["≈"] = "\\approx ", ["±"] = "\\pm ",
  ["∑"] = "\\sum ", ["∫"] = "\\int ", ["√"] = "\\surd ",
}
local CODE_TOKENS = { ";", "{", "}", "[", "]", "#", "//", "/*", '"', "'", "`",
  "def ", "import ", "return ", "print(", "function ", "class ", "for ", "while ",
  "if (", "=>", "->", "::" }

local function has_non_ascii(s)
  for i = 1, #s do if s:byte(i) > 127 then return true end end
  return false
end

local function latex_escape(s)
  s = s:gsub("\\", "\\backslash ")
  s = s:gsub("([{}_%%&#$])", "\\%1")
  return s
end

local function is_formula_line(s)
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" or #s > 200 then return false end
  local rel = false
  for _, r in ipairs(RELATIONS) do
    if s:find(r, 1, true) then rel = true; break end
  end
  if not rel then return false end
  for _, tok in ipairs(CODE_TOKENS) do
    if s:find(tok, 1, true) then return false end
  end
  if has_non_ascii(s) then return true end
  for c in s:gmatch(".") do
    if c == "+" or c == "-" or c == "*" or c == "/" or c == "^" then return true end
  end
  for sym in pairs(UNI_OPS) do
    if s:find(sym, 1, true) then return true end
  end
  for fn in pairs(MATH_FUNCS) do
    if s:find(fn .. "(", 1, true) then return true end
  end
  return false
end

local function looks_like_code(lines)
  for _, l in ipairs(lines) do
    for _, tok in ipairs(CODE_TOKENS) do
      if l:find(tok, 1, true) then return true end
    end
  end
  return false
end

local function is_digit(c) return c ~= "" and c:match("%d") ~= nil end
local function is_alpha(c) return c ~= "" and c:match("[A-Za-z]") ~= nil end

-- 一行文本 → LaTeX。中文走 \text{}，标识符走 \mathit{}，函数名走 \ln 等。
local function line_to_latex(line)
  local out, i, n = {}, 1, #line
  while i <= n do
    local c = line:sub(i, i)
    local b = line:byte(i)
    if b > 127 and not UNI_OPS[c] then
      -- 文本段：吃掉后面的 中文/数字/空格/常见标点，遇到 ASCII 字母或运算符停
      local j = i
      while j <= n do
        local cj, bj = line:sub(j, j), line:byte(j)
        if bj > 127 and not UNI_OPS[cj] then j = j + 1
        elseif cj:match("[%d%s%.,:;%%]") then j = j + 1
        else break end
      end
      out[#out + 1] = "\\text{" .. latex_escape(line:sub(i, j - 1)) .. "}"
      i = j
    elseif is_alpha(c) then
      local j = i + 1
      while j <= n and line:sub(j, j):match("[%w_]") do j = j + 1 end
      local w = line:sub(i, j - 1)
      local lw = w:lower()
      if MATH_FUNCS[lw] and line:sub(j, j) == "(" then
        out[#out + 1] = "\\" .. lw
      else
        out[#out + 1] = "\\mathit{" .. latex_escape(w) .. "}"
      end
      i = j
    elseif is_digit(c) or (c == "." and is_digit(line:sub(i + 1, i + 1))) then
      local j = i
      while j <= n and line:sub(j, j):match("[%d%.]") do j = j + 1 end
      out[#out + 1] = line:sub(i, j - 1)
      i = j
    else
      local two = line:sub(i, i + 1)
      if two == "==" then out[#out + 1] = "="; i = i + 2
      elseif two == "<=" then out[#out + 1] = "\\le "; i = i + 2
      elseif two == ">=" then out[#out + 1] = "\\ge "; i = i + 2
      elseif two == "!=" then out[#out + 1] = "\\ne "; i = i + 2
      elseif UNI_OPS[c] then out[#out + 1] = UNI_OPS[c]; i = i + 1
      elseif c == "*" then out[#out + 1] = "\\cdot "; i = i + 1
      elseif c == "%" then out[#out + 1] = "\\%"; i = i + 1
      elseif c == "_" or c == "&" or c == "#" then out[#out + 1] = "\\" .. c; i = i + 1
      elseif c == "\\" then out[#out + 1] = "\\backslash "; i = i + 1
      else out[#out + 1] = c; i = i + 1 end
    end
  end
  return table.concat(out)
end

local function formula_latex(converted)
  if #converted == 1 then return converted[1] end
  return "\\begin{array}{l}\n" .. table.concat(converted, " \\\\\n") .. "\n\\end{array}"
end

local function text_lines_para(lines)
  local inl = {}
  for i, l in ipairs(lines) do
    if i > 1 then inl[#inl + 1] = pandoc.LineBreak() end
    inl[#inl + 1] = pandoc.Str(l)
  end
  return pandoc.Para(inl)
end

-- 返回：新块列表、公式块数、公式行数、转成正文的块数
local function convert_code_blocks(blocks)
  local out, n_formula, n_lines, n_text = {}, 0, 0, 0
  for _, b in ipairs(blocks) do
    if b.t ~= "CodeBlock" then
      out[#out + 1] = b
    else
      local lang = (b.classes[1] or ""):lower()
      local lines = {}
      for line in (b.text .. "\n"):gmatch("(.-)\n") do
        local t = line:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then lines[#lines + 1] = t end
      end
      if MATH_LANGS[lang] then
        if #lines > 0 then
          local converted = {}
          for _, l in ipairs(lines) do converted[#converted + 1] = l end
          out[#out + 1] = pandoc.Para({ pandoc.Math("DisplayMath", formula_latex(converted)) })
          n_formula = n_formula + 1
          n_lines = n_lines + #lines
        end
      elseif CODE_LANGS[lang] then
        out[#out + 1] = b
      elseif #lines == 0 then
        -- 空代码块：丢掉
      elseif looks_like_code(lines) then
        -- 没写语言但确实是代码：保持 Source Code，别动
        out[#out + 1] = b
      else
        local has_formula = false
        for _, l in ipairs(lines) do
          if is_formula_line(l) then has_formula = true; break end
        end
        if not has_formula then
          out[#out + 1] = text_lines_para(lines)
          n_text = n_text + 1
        else
          local run, text_run = {}, {}
          local function flush_run()
            if #run == 0 then return end
            out[#out + 1] = pandoc.Para({ pandoc.Math("DisplayMath", formula_latex(run)) })
            run = {}
          end
          local function flush_text()
            if #text_run == 0 then return end
            out[#out + 1] = text_lines_para(text_run)
            text_run = {}
          end
          for _, l in ipairs(lines) do
            if is_formula_line(l) then
              flush_text()
              run[#run + 1] = line_to_latex(l)
              n_lines = n_lines + 1
            else
              flush_run()
              text_run[#text_run + 1] = l
            end
          end
          flush_run(); flush_text()
          n_formula = n_formula + 1
        end
      end
    end
  end
  return out, n_formula, n_lines, n_text
end

-- ── 无序列表（2026-10-17 用户要求）─────────────────────────────────────────
-- 论文/报告的规范做法是「分条列项用编号 + 按层级缩进」，不用 • 项目符号
-- （GB/T 7713.1、各校撰写规范；这份模板的原论文正文也没有 bullet）。
--   一级项   → 正文段落（首行缩进 2 字，模板 Body Text 自带）
--   二级及以下 → 左缩进 2 字符/级 +「（1）（2）」编号（每个父项内重新计数）
-- 有序列表保持 Word 自动编号，不动。
local LIST_STYLE = { [1] = "列表正文二级", [2] = "列表正文三级", [3] = "列表正文四级" }

local flatten_bullets
local function map_list_items(items, level)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = flatten_bullets(item, level)
  end
  return out
end

local function map_table_cells(tbl, level)
  local function do_rows(rows)
    for _, row in ipairs(rows) do
      for _, cell in ipairs(row.cells) do
        cell.contents = flatten_bullets(cell.contents, level)
      end
    end
  end
  if tbl.head then do_rows(tbl.head.rows) end
  for _, body in ipairs(tbl.bodies or {}) do do_rows(body.body) end
  if tbl.foot then do_rows(tbl.foot.rows) end
  return tbl
end

flatten_bullets = function(blocks, level)
  local out = {}
  for _, b in ipairs(blocks) do
    if b.t == "BulletList" then
      local n = 0
      for _, item in ipairs(b.content) do
        n = n + 1
        stats.bullets_flattened = stats.bullets_flattened + 1
        local first = true
        for _, ib in ipairs(item) do
          if ib.t == "BulletList" then
            local sub = flatten_bullets({ ib }, level + 1)
            for _, x in ipairs(sub) do out[#out + 1] = x end
          elseif ib.t == "OrderedList" then
            -- 有序列表保留自动编号；里面若还有无序列表，按下一级处理
            ib.content = map_list_items(ib.content, level + 1)
            out[#out + 1] = ib
            first = false
          elseif ib.t == "Div" or ib.t == "BlockQuote" then
            ib.content = flatten_bullets(ib.content, level)
            out[#out + 1] = ib
            first = false
          elseif ib.t == "Plain" or ib.t == "Para" then
            local inl = {}
            if level > 0 and first then
              inl[#inl + 1] = pandoc.Str(string.format("（%d）", n))
            end
            for _, x in ipairs(ib.content) do inl[#inl + 1] = x end
            if level > 0 then
              -- 左缩进靠模板样式；Div 包 Plain 才能让 custom-style 生效（踩过）
              out[#out + 1] = pandoc.Div(
                { pandoc.Plain(inl) },
                pandoc.Attr("", {}, {
                  ["custom-style"] = LIST_STYLE[math.min(level, 3)],
                }))
            else
              out[#out + 1] = pandoc.Para(inl)
            end
            first = false
          else
            out[#out + 1] = ib
            first = false
          end
        end
      end
    elseif b.t == "Div" or b.t == "BlockQuote" then
      b.content = flatten_bullets(b.content, level)
      out[#out + 1] = b
    elseif b.t == "OrderedList" then
      b.content = map_list_items(b.content, level + 1)
      out[#out + 1] = b
    elseif b.t == "Table" then
      out[#out + 1] = map_table_cells(b, level)
    else
      out[#out + 1] = b
    end
  end
  return out
end

-- 入口：先做各种扫描与安全校验，再转换，最后汇报做了什么
function Pandoc(doc)
  -- 1. 资源引用安全校验 —— 必须在 writer 抓取资源之前跑
  blocked_resources = {}
  doc = check_resources(doc)

  -- 1.2 代码块：公式块 → 真公式（后面统一按章编号）；非代码的 text 块 → 普通正文
  doc.blocks, stats.formula_blocks, stats.formula_lines, stats.text_blocks =
    convert_code_blocks(doc.blocks)

  -- 1.3 无序列表 → 正文段落；嵌套项按层级缩进并编号（有序列表保持自动编号）
  doc.blocks = flatten_bullets(doc.blocks, 0)

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

  -- 1.6 公式的 LaTeX 环境写法（\begin{equation}…）→ 显示式数学。
  --     必须在公式编号**之前**做，这样救回来的公式也能拿到编号。
  local latex_left
  doc, stats.latex_rescued, latex_left = rescue_latex(doc)

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

  if #titles > 1 and not DOC_TITLE then
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

  -- 3.5 包内多文件：大标题取自文件名。空文档不补（用户要的就是空 docx）。
  if DOC_TITLE and #doc.blocks > 0 then
    table.insert(doc.blocks, 1, styled_para({ pandoc.Str(DOC_TITLE) }, STYLE.title))
  end

  -- 4. 判定各层级是否在用手写编号（决定要不要剥）
  strip_level = {}
  scan_numbering(doc.blocks)

  -- 4.5 公式编号（在转换前做，此时标题还没被改写成 Div，层级信息还在）
  eq_chapter, eq_count, stats.equations = 0, 0, 0
  doc.blocks = number_equations(doc.blocks)

  -- 4.6 表/图题：剥手写号 + 按章重编号 + 套模板的题注样式（同理，也要在改写成 Div 之前）
  cap_chapter, stats.captions = 0, 0
  doc.blocks = number_captions(doc.blocks)

  -- 5. 转换
  local out = doc:walk({
    Header = Header,
    -- 行内代码：模板的 Verbatim Char 是 Fira Code + 灰底，中文/路径/URL 都很难看。
    -- 用户要求直接按普通英文排；真正的行内公式请用 $…$（不会走到这里）。
    Code = function(el)
      if el.text == "" then return nil end
      stats.inline_codes = stats.inline_codes + 1
      return pandoc.Str(el.text)
    end,
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
        .. "不想编号的公式，用 ::: {.unnumbered} … ::: 包起来；"
        .. "正文里手写的「式（2）」这类引用不会跟着变，请核对。", stats.equations))
  end
  if stats.captions - stats.image_captions > 0 then
    note("change", string.format(
      "给 %d 个表/图题加了编号（按章，形如「表2-1」），并套上模板的题注样式（黑体·五号·居中）。"
        .. "正文里手写的「由表10可知」这类引用不会跟着变，请核对。",
      stats.captions - stats.image_captions))
  end
  if stats.image_captions > 0 then
    local tail = ""
    if stats.captions_from_name > 0 then
      tail = string.format("，其中 %d 张的题注文字取自文件名", stats.captions_from_name)
    end
    if stats.captions_number_only > 0 then
      tail = tail .. string.format("，%d 张只有编号（文件名为纯编号）", stats.captions_number_only)
    end
    note("change", string.format(
      "给 %d 张图片加了题注（按章，形如「图2-1」）%s", stats.image_captions, tail))
  end
  if stats.formula_blocks > 0 then
    note("guess", string.format(
      "有 %d 个代码块看起来是公式，已转成 Word 公式（共 %d 行，按章编号）。"
        .. "如果其中有真代码，把代码块的语言标记写成 python / bash 等就不会转。",
      stats.formula_blocks, stats.formula_lines))
  end
  if stats.text_blocks > 0 then
    note("change", string.format(
      "把 %d 个非代码的 text 代码块改成了普通正文（等宽字体对中文不友好）",
      stats.text_blocks))
  end
  if stats.inline_codes > 0 then
    note("change", string.format(
      "把 %d 处行内代码改成了普通文本（行内公式请用 $…$ 写）", stats.inline_codes))
  end
  if stats.bullets_flattened > 0 then
    note("change", string.format(
      "把 %d 个无序列表项转成了正文段落（一级项空两字起排，嵌套项按层级缩进并编号）",
      stats.bullets_flattened))
  end
  if stats.toc_dropped > 0 then
    note("change", "删掉了 markdown 里手写的目录（已自动生成 Word 目录域，格式与模板一致）")
  end
  if stats.stripped > 0 then
    note("change", string.format("去掉了 %d 处标题里手写的编号（编号由 Word 自动生成，避免重复）",
      stats.stripped))
  end
  if stats.hr_dropped > 0 then
    note("change", string.format(
      "删掉了 %d 条水平线 ---（每章已自动另起一页，论文里不需要分隔线；"
        .. "pandoc 生成的那种在 WPS 里还会渲染成空心矩形）", stats.hr_dropped))
  end
  if stats.h1_demoted > 0 then
    if DOC_TITLE then
      note("change", string.format(
        "把 %d 个一级标题降级成了章节（包内多文件：大标题取自文件名）", stats.h1_demoted))
    else
      note("change", string.format("把 %d 个多余的一级标题降级成了二级标题 ##", stats.h1_demoted))
    end
  end
  if stats.latex_rescued and stats.latex_rescued > 0 then
    note("change", string.format(
      "把 %d 处 \\begin{equation} 写法的公式转成了正常公式（pandoc 原本会把它们整段丢掉）",
      stats.latex_rescued))
  end
  if latex_left and #latex_left > 0 then
    warn(string.format(
      "有 %d 处 LaTeX 内容没能转换，已原样保留在正文里（请改成 $…$ 或 $$…$$ 写法）：\n%s",
      #latex_left, list_items(latex_left)))
  end
  if stats.delims > 0 then
    note("change", string.format(
      "修正了 %d 处公式括号：普通 [ ] ( ) 不会随内容变高，里面装着分式时括号框不住 —— "
        .. "已改成自适应高度（\\left…\\right）", stats.delims))
  end

  -- 7. 识别结果：让用户一眼看出「我们从他文档里读到了什么」，识别错了当场就能发现
  if DOC_TITLE then
    stat("大标题", DOC_TITLE .. "（取自文件名）")
  elseif #titles > 0 then
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
    local tail = (stats.image_captions > 0)
      and string.format("，%d 张带题注", stats.image_captions) or ""
    stat("图片", string.format("%d 张%s", counts.images, tail))
  end

  return out
end
