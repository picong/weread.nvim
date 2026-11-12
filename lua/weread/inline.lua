--[[
Inline styling for chapter buffers.

Markdown punctuation stays in the cached file — that is what makes it greppable
and portable — but nobody wants to read `**加粗**`. This module turns the style
spans recorded by `weread.xhtml.convert` into extmarks: the markers get
concealed and the content gets the real attribute (bold, italic, underline,
strikethrough, highlight), so a bold phrase simply looks bold.
(章节 buffer 的行内样式：markdown 标点留在缓存文件里（便于 grep 与移植），但没人想
 读 `**加粗**`。本模块把 xhtml.convert 记录的样式区间变成 extmark：隐藏标记，给内容
 加上真实属性（粗体/斜体/下划线/删除线/高亮），于是加粗的句子就是加粗的样子)

Note that render-markdown.nvim deliberately does not handle emphasis (its inline
handler covers code spans, links, images and ==highlight== only), so there is no
double work happening here.
(注意 render-markdown.nvim 有意不处理强调——它的行内 handler 只管 code span、链接、
 图片与 ==高亮==——所以这里不存在重复处理)
]]

local M = {}

local text_util = require("weread.text")

local NAMESPACE = "weread.inline"

---Style kind -> highlight group.
---(样式种类 → 高亮组)
---Style kind -> highlight group.
---(样式种类 → 高亮组)
---
---These are the *reading palette's* groups, not the built-in `Bold`/`Italic`:
---those carry no colour of their own, so whatever the syntax highlighter painted
---underneath showed through — which is how a bold sentence came out in the
---colorscheme's blue on a black and white page. `theme = "none"` links them back
---to the built-ins.
---(用的是**阅读配色自己的**组，而不是内置的 `Bold`/`Italic`：那两组没有自己的颜色，底层语法
--- 高亮画什么就透出什么——黑白页面上的加粗句子显出配色方案的蓝色，就是这么来的。
--- `theme = "none"` 时它们会链回内置组)
local GROUPS = {
  bold = "WereadStrong",
  italic = "WereadItalic",
  underline = "WereadUnderline",
  strike = "WereadStrike",
  mark = "WereadMark",
  sup = "WereadSuperscript",
  sub = "WereadSubscript",
  small = "WereadSmall",
  code = "WereadCode",
  -- tables the converter lays out itself: header text and the box rules
  -- (转换器自己排的表格：表头文字与边框线)
  head = "WereadTableHead",
  rule = "WereadTableRule",
}

---@param kind string
---@return string
function M.group_for(kind)
  return GROUPS[kind] or "Normal"
end

---Heading group for a level: the chapter and section titles carry the accent,
---deeper levels are bold ink.
---(某级标题用的高亮组：章标题与节标题用强调色，更深的层级是加粗墨色)
---@param level integer|nil
---@return string
function M.heading_group(level)
  level = tonumber(level) or 1
  if level <= 1 then
    return "WereadHeading1"
  elseif level == 2 then
    return "WereadHeading2"
  end
  return "WereadHeading3"
end

---Icon drawn in front of a heading of this level, or nil when headings have none.
---(画在该级标题前的图标；标题不带图标时为 nil)
---@param level integer
---@return string|nil
function M.heading_icon(level)
  local icons = (require("weread.config").get().layout or {}).heading_icons
  if icons == nil then
    icons = require("weread.xhtml").HEADING_ICONS
  end
  if type(icons) ~= "table" or #icons == 0 then
    return nil
  end
  local icon = icons[math.min(math.max(1, level), #icons)]
  return icon ~= "" and icon or nil
end

---Hide the backslashes the converter put in front of prose that would otherwise
---open a block (`\- `, `\# ` at the start of a wrapped line).
---(隐藏转换器写在会被误读成块标记的正文前面的反斜杠（折行行首的 `\- `、`\# `）)
---@param buf integer
---@param escapes table[]|nil entries { line, col } 0-based
---@return integer concealed
function M.render_escapes(buf, escapes)
  if not vim.api.nvim_buf_is_valid(buf) or type(escapes) ~= "table" then
    return 0
  end
  local namespace = vim.api.nvim_create_namespace(NAMESPACE)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local concealed = 0
  for _, escape in ipairs(escapes) do
    local line, col = tonumber(escape.line), tonumber(escape.col)
    if line and col and line >= 0 and line < line_count then
      local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""
      if text:sub(col + 1, col + 1) == "\\" then
        pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, col, {
          end_col = col + 1,
          conceal = "",
          priority = 260,
        })
        concealed = concealed + 1
      end
    end
  end
  return concealed
end

---@param buf integer
function M.clear(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, vim.api.nvim_create_namespace(NAMESPACE), 0, -1)
end

---Draw the style spans on a chapter buffer.
---(在章节 buffer 上绘制样式区间)
---Paint heading lines in the reading colours and hide their `#` marks.
---(用阅读配色绘制标题行，并隐藏 `#` 标记)
---
---Doing it here instead of trusting the syntax highlighter is deliberate: a
---colorscheme gives `@markup.heading.*` its own foreground *and* background, and
---that band is exactly what breaks the paper look. An extmark with a higher
---priority wins over the syntax highlight.
---(在这里做、而不是信任语法高亮，是有意的：配色方案会给 `@markup.heading.*` 配前景
--- **和背景**，那条色带正是破坏纸页观感的元凶。优先级更高的 extmark 会压过语法高亮)
---@param buf integer
---@param headings table[]|nil entries { line, level }
---@return integer drawn
function M.render_headings(buf, headings)
  if not vim.api.nvim_buf_is_valid(buf) or type(headings) ~= "table" then
    return 0
  end
  local namespace = vim.api.nvim_create_namespace(NAMESPACE)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local drawn = 0

  for _, heading in ipairs(headings) do
    local line = tonumber(heading.line)
    local level = tonumber(heading.level) or 1
    if line and line >= 0 and line < line_count then
      local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""
      local ok = pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, 0, {
        end_col = #text,
        hl_group = M.heading_group(level),
        hl_mode = "replace",
        priority = 250,
      })
      if ok then
        drawn = drawn + 1
      end
      -- hide the `#` marks: the app shows a heading, not a hash
      -- (隐藏 `#` 标记：App 显示的是标题，不是井号)
      local marks = 0
      while text:sub(marks + 1, marks + 1) == "#" and marks < 12 do
        marks = marks + 1
      end
      if marks > 0 then
        pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, 0, {
          end_col = math.min(#text, marks + 1),
          conceal = "",
          priority = 260,
        })
        -- The level's icon in their place, as a markdown renderer draws it. The
        -- converter counted its width when it laid the heading out, so a line the
        -- heading wrapped onto gets the same width of blank instead, keeping its
        -- text under the first line's. The chapter title on the opening page has
        -- none: it stands alone.
        -- (在原处画出该级的图标，和 markdown 渲染器一样。转换器排标题时已算进它的宽度，因此标题
        --  折到的行改为同宽的空白，让文字与首行对齐。章首页上的章节标题不画：它独自成行)
        local icon = not heading.title and not heading.bare and M.heading_icon(level) or nil
        if icon then
          pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, 0, {
            virt_text = { { heading.continued and string.rep(" ", text_util.cells(icon)) or icon, M.heading_group(level) } },
            virt_text_pos = "inline",
            priority = 260,
          })
        end
      end
    end
  end
  return drawn
end

---@param buf integer
---@param lines table|nil entries { align, small, accent, cells, fill } keyed by 0-based line
---@param page_width integer|nil the width they were laid out for(它们为之排版的版心宽度)
---@param style string|nil highlight group for the padding(补白用高亮组)
---@param bands table<integer, string>|nil group for the padding of a heading line, by
---  0-based line: the heading's band runs on under its centring(标题行补白用的组，按 0 基行号：
---  标题色带延伸到居中补白之下)
---@return integer drawn
function M.render_lines(buf, lines, page_width, style, bands)
  if not vim.api.nvim_buf_is_valid(buf) or type(lines) ~= "table" then
    return 0
  end
  local namespace = vim.api.nvim_create_namespace(NAMESPACE)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local page = tonumber(page_width) or 0
  local drawn = 0

  for index, info in pairs(lines) do
    local line = tonumber(index)
    if line and line >= 0 and line < line_count then
      local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""

      -- Centering and right alignment are done with padding that is *not* part
      -- of the buffer: inserting spaces in the text would shift every column on
      -- the line, and the offset map that highlights rely on would no longer
      -- match.
      -- (居中与右对齐用「不属于 buffer 的补白」实现：把空格写进文本会让这一行所有列号
      --  平移，划线依赖的偏移表就对不上了)
      local align = info.align
      if align and page > 0 and #text > 0 then
        local cells = tonumber(info.cells) or text_util.cells(text)
        local pad
        if align == "center" then
          pad = math.floor(math.max(0, page - cells) / 2)
        elseif align == "right" then
          pad = math.max(0, page - cells)
        end
        if pad and pad > 0 then
          pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, 0, {
            virt_text = { { string.rep(" ", pad), (bands and bands[line]) or style or "Normal" } },
            virt_text_pos = "inline",
            priority = 240,
          })
          drawn = drawn + 1
        end
      end

      -- Justification: the slack of a wrapped line, drawn between characters so
      -- the right margin is straight. Like the padding it is not in the buffer.
      -- (两端对齐：折行的剩余宽度画在字符之间，让右侧页边整齐。和补白一样，它不在 buffer 里)
      if type(info.fill) == "table" and page > 0 then
        for _, gap in ipairs(info.fill) do
          local col = tonumber(gap.col)
          local cells = tonumber(gap.cells) or 0
          if col and cells > 0 and col > 0 and col < #text then
            pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, col, {
              virt_text = { { string.rep(" ", cells), style or "Normal" } },
              virt_text_pos = "inline",
              hl_mode = "combine",
              priority = 240,
            })
            drawn = drawn + 1
          end
        end
      end

      local group
      if info.accent then
        group = "WereadHeading"
      elseif info.translation then
        -- the translation under a paragraph, quieter than the original
        -- (段落下方的译文，比原文安静)
        group = "WereadTranslation"
      elseif info.small then
        group = "WereadSmall"
      end
      if group then
        pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, 0, {
          end_col = #text,
          hl_group = group,
          hl_mode = "combine",
          priority = 180,
        })
        drawn = drawn + 1
      end
    end
  end

  return drawn
end

---Lines that exist for other readers of the file, not for this one.
---(这些行是为了别的读者/工具存在的，不是给读者看的)
---
---A code fence and a table's `| --- |` separator carry no text: the first is
---markdown's way of saying "this is a listing", the second is what makes the block
---a table at all. Concealing them leaves the listing and the table intact for
---every other tool while the page shows neither.
---(代码围栏与表格的 `| --- |` 分隔行本身不是内容：前者是 markdown 表示「这是清单」的方式，
--- 后者是让整块成为表格的前提。把它们藏起来，别的工具看到的清单与表格仍然完整，而页面上
--- 两者都不出现)
---@param buf integer
---@return integer concealed
function M.conceal_structure(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  local namespace = vim.api.nvim_create_namespace(NAMESPACE)
  local concealed = 0
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for index, text in ipairs(lines) do
    local trimmed = vim.trim(text)
    local separator = trimmed:find("^|") and trimmed:match("^|[%s|%-:]*$") ~= nil and trimmed:find("%-") ~= nil
    -- matched separately: the language is optional, and a bare fence must still be
    -- concealed rather than fall through the pattern
    -- (分开匹配：语言是可选的，而空白围栏也必须被隐藏，不能整个漏掉)
    local fence = trimmed:match("^```")
    local language = trimmed:match("^```(%a[%w+%-]*)")
    if fence or separator then
      pcall(vim.api.nvim_buf_set_extmark, buf, namespace, index - 1, 0, {
        end_col = #text,
        conceal = "",
      })
      concealed = concealed + 1
    end
    -- The language a listing was written in, in the margin of the fence line.
    -- render-markdown names it too, but it puts the name on the empty line *above*
    -- the fence, and an `overlay` virt_text is not drawn on an empty line — so the
    -- page says it itself. It has to be here rather than there: this line carries
    -- text, which is what an overlay needs.
    -- (清单是用哪种语言写的，写在围栏行的页边。render-markdown 也会写语言名，但它把名字放在
    --  围栏**上方**的空行上，而 `overlay` 类虚拟文本在空行上不会被绘制——因此由书页自己说。
    --  位置必须是这里而不是那里：这一行有文本，而叠加内容正是需要文本)
    if fence and language and language ~= "" then
      pcall(vim.api.nvim_buf_set_extmark, buf, namespace, index - 1, 0, {
        virt_text = { { language, "WereadSmall" } },
        virt_text_pos = "overlay",
        priority = 245,
      })
      concealed = concealed + 1
    end
  end
  return concealed
end

---Paint footnote marks so they read as marks, not as body text.
---(给脚注标记上色，让它们读起来是标记而不是正文)
---@param buf integer
---@param footnotes table[]|nil entries { line, col_from, col_to, text }
---@return integer drawn
function M.render_footnotes(buf, footnotes)
  if not vim.api.nvim_buf_is_valid(buf) or type(footnotes) ~= "table" then
    return 0
  end
  local namespace = vim.api.nvim_create_namespace(NAMESPACE)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local drawn = 0
  for _, footnote in ipairs(footnotes) do
    local line = tonumber(footnote.line)
    local from = tonumber(footnote.col_from)
    local to = tonumber(footnote.col_to)
    if line and from and to and to > from and line >= 0 and line < line_count then
      local ok = pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, from, {
        end_col = to,
        hl_group = "WereadFootnote",
        hl_mode = "replace",
        priority = 210,
      })
      if ok then
        drawn = drawn + 1
      end
    end
  end
  return drawn
end

---@param buf integer
---@param styles table[]|nil entries { line, col_from, col_to, kind, markers }
---@param headings table[]|nil entries { line, level }
---@param lines table|nil per line display attributes(逐行显示属性)
---@param page_width integer|nil
---@param footnotes table[]|nil entries { line, col_from, col_to, text }
---@return integer drawn
function M.attach(buf, styles, headings, lines, page_width, footnotes)
  M.clear(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  M.render_headings(buf, headings)
  M.render_footnotes(buf, footnotes)
  -- A code fence and a table's delimiter row carry no content, so they are
  -- concealed whether or not render-markdown is drawing the page: it replaces them
  -- with its own overlay (the language label, the `├───┼───┤` rule), and an overlay
  -- is drawn over concealed characters — while a page that shows a bare
  -- `| --- |` row at all is simply wrong.
  -- (代码围栏与表格分隔行不带内容，因此无论 render-markdown 是否在绘制这一页都要隐掉：它会用
  --  自己的叠加内容替换这两行（语言标签、`├───┼───┤` 分隔线），而叠加内容是画在被隐藏的字符
  --  之上的——反过来说，页面上露出 `| --- |` 本身就是错的)
  M.conceal_structure(buf)
  local bands = {}
  for _, heading in ipairs(type(headings) == "table" and headings or {}) do
    local line, level = tonumber(heading.line), tonumber(heading.level)
    if line and level then
      bands[line] = "RenderMarkdownH" .. math.min(6, math.max(1, level)) .. "Bg"
    end
  end
  local drawn = M.render_lines(buf, lines, page_width, "WereadMargin", bands)
  if type(styles) ~= "table" then
    return drawn
  end

  local namespace = vim.api.nvim_create_namespace(NAMESPACE)
  local line_count = vim.api.nvim_buf_line_count(buf)

  for _, style in ipairs(styles) do
    local line = tonumber(style.line)
    local from = tonumber(style.col_from)
    local to = tonumber(style.col_to)
    local kind = style.kind
    local markers = tonumber(style.markers) or 0

    if line and from and to and to > from and line >= 0 and line < line_count then
      -- the attribute itself
      local ok = pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, from, {
        end_col = to,
        hl_group = M.group_for(kind),
        -- replace, not combine: the palette's ink wins over whatever the syntax
        -- highlighter had put there
        -- (用 replace 而不是 combine：以配色的墨色为准，压过语法高亮原本的颜色)
        hl_mode = "replace",
        priority = 200,
      })
      if ok then
        drawn = drawn + 1
      end

      -- Chinese bold barely shows in a terminal (often a synthetic bold of
      -- the same weight), so CJK emphasis also gets the dotted rule Chinese
      -- typesetting uses for 着重号 — under the characters, never under the
      -- punctuation (clreq §5.3.1). Latin bold keeps reading as bold.
      -- (终端里的中文粗体几乎看不出来——经常只是同一字重的伪粗体——因此中文的强调另外加上中文
      --  排版里表示着重号的点状下划线：画在字下面，不画在标点下面（clreq §5.3.1）。
      --  拉丁文的粗体照旧是粗体)
      if ok and kind == "bold" and M.emphasis_dots() then
        drawn = drawn + M.dot_cjk(buf, namespace, line, from, to)
      end

      -- and hide the markdown markers around it
      if markers > 0 then
        pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, math.max(0, from - markers), {
          end_col = from,
          conceal = "",
        })
        pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, to, {
          end_col = to + markers,
          conceal = "",
        })
      end
    end
  end

  return drawn
end

---Is the dotted emphasis rule on? `layout.emphasis_dots = false` turns it off.
---(是否画着重号点线；`layout.emphasis_dots = false` 关闭)
---@return boolean
function M.emphasis_dots()
  return (require("weread.config").get().layout or {}).emphasis_dots ~= false
end

---Is a character a CJK ideograph or kana (punctuation excluded)?
---(是否为中日文字符——不含标点)
---@param code integer
---@return boolean
local function is_cjk_letter(code)
  return (code >= 0x4E00 and code <= 0x9FFF)
    or (code >= 0x3400 and code <= 0x4DBF)
    or (code >= 0xF900 and code <= 0xFAFF)
    or (code >= 0x3040 and code <= 0x30FF)
    or (code >= 0x20000 and code <= 0x2FFFF)
end

---Draw the dotted emphasis rule under the CJK characters of a span, one run
---of consecutive characters at a time so punctuation stays bare.
---(在一个区间的中文字符下画着重号点线，按连续字符成段地画，标点保持不加)
---@param buf integer
---@param namespace integer
---@param line integer 0-based
---@param from integer byte column
---@param to integer byte column
---@return integer drawn
function M.dot_cjk(buf, namespace, line, from, to)
  local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""
  local drawn = 0
  local run_from = nil
  local index = from + 1
  local function close(at)
    if run_from and at > run_from then
      if pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, run_from, {
        end_col = at,
        hl_group = "WereadEmphasisDots",
        hl_mode = "combine",
        priority = 201,
      }) then
        drawn = drawn + 1
      end
    end
    run_from = nil
  end
  while index <= math.min(to, #text) do
    local byte = text:byte(index)
    local length = byte >= 0xF0 and 4 or byte >= 0xE0 and 3 or byte >= 0xC0 and 2 or 1
    local code = vim.fn.char2nr(text:sub(index, index + length - 1))
    if is_cjk_letter(code) then
      run_from = run_from or (index - 1)
    else
      close(index - 1)
    end
    index = index + length
  end
  close(math.min(to, #text))
  return drawn
end

---Namespace of the hidden originals, apart from the rest so the choice can be
---flipped without drawing the page again.
---(隐藏原文用的命名空间，与其余的分开：切换时不必重画整页)
local ORIGINALS = "weread.originals"

---Show a translated page as the translation alone, or as both: the lines of the
---original that have a translation under them take no rows. The text stays in
---the buffer, so offsets, highlights and progress are untouched.
---(把译过的页面显示成只有译文，或者双语：下方带译文的原文行不占屏幕行。文字仍在 buffer 里，
--- 偏移、划线与进度都不受影响)
---@param buf integer
---@param originals integer[]|nil 0-based lines(0 基行号)
---@param hide boolean
---@return integer hidden
function M.render_originals(buf, originals, hide)
  if not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  local namespace = vim.api.nvim_create_namespace(ORIGINALS)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  local hidden = {}
  if hide and type(originals) == "table" then
    local line_count = vim.api.nvim_buf_line_count(buf)
    for _, value in ipairs(originals) do
      local line = tonumber(value)
      if line and line >= 0 and line < line_count then
        local ok = pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line, 0, {
          end_row = line,
          conceal_lines = "",
        })
        if ok then
          hidden[#hidden + 1] = line
        end
      end
    end
  end
  vim.b[buf].weread_hidden_originals = hidden
  return #hidden
end

---First line at or after `line` (1-based) that is not a hidden original: the
---cursor must not sit on a line the page does not show.
---(从 line（1 基）起第一个不是被隐藏原文的行：光标不能停在页面不显示的行上)
---@param buf integer
---@param line integer
---@return integer
function M.shown_line(buf, line)
  local hidden = {}
  for _, value in ipairs(vim.b[buf].weread_hidden_originals or {}) do
    hidden[value + 1] = true
  end
  local last = vim.api.nvim_buf_line_count(buf)
  local at = line
  while hidden[at] and at < last do
    at = at + 1
  end
  if hidden[at] then
    -- the last lines are all hidden: the nearest shown line above
    -- (末尾几行全被隐藏：取上方最近的显示行)
    at = line
    while hidden[at] and at > 1 do
      at = at - 1
    end
  end
  return at
end

---Read the style spans recorded next to a chapter's offset map.
---(读取与章节 offset map 一起记录的样式区间)
---@param meta table|nil the parsed map.json
---@return table[]
function M.from_meta(meta)
  if type(meta) ~= "table" or type(meta.styles) ~= "table" then
    return {}
  end
  return meta.styles
end

return M
