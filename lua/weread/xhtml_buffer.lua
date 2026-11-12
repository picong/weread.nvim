--[[
Line buffer for the XHTML -> Markdown converter, and the text primitives it is
built on (character width, rune counting, line-break rules).
(XHTML → Markdown 转换器的行缓冲，以及它依赖的文本原语：字符宽度、rune 计数、折行禁则)

Split out of xhtml.lua, unchanged: the buffer is the half of the converter that
knows about columns, wrapping and typesetting, and nothing in it reads the
config or the stylesheet. xhtml.lua decides *what* goes into the buffer; this
file decides *where* it lands. The offset map the annotations rely on is built
from the columns recorded here, so any change must keep `xhtml.VERSION` in mind.
(从 xhtml.lua 原样拆出：缓冲是转换器里懂列号、折行和排版的那一半，不读 config 也不读
 样式表。xhtml.lua 决定放进缓冲的**内容**，本文件决定它落在**哪里**。划线依赖的 offset
 map 由这里记录的列号构成，所以改动时要想着 `xhtml.VERSION`)
]]

---Characters that open a block when a line starts with them: a list item, a
---heading, a quote. Prose that happens to start a line with one is escaped.
---(行首出现时会开启一个块的字符：列表项、标题、引文。恰好以它们起行的正文会被转义)
local BLOCK_STARTS = {
  ["-"] = true,
  ["+"] = true,
  ["*"] = true,
  ["#"] = true,
  [">"] = true,
  ["="] = true,
}

local function count_runes(text)
  local count = 0
  for index = 1, #text do
    local byte = text:byte(index)
    if byte < 0x80 or byte >= 0xC0 then
      count = count + 1
    end
  end
  return count
end

---Leading run of ASCII and full-width spaces. Lua patterns work on bytes, so a
---class like `[ 　]` is really { 0x20, 0xE3, 0x80 } and swallowed the first two
---bytes of `《` (E3 80 8A), splitting the character.
---(开头连续的半角与全角空格。Lua 模式按字节匹配，`[ 　]` 实际是 { 0x20, 0xE3, 0x80 }，
--- 会吞掉 `《`（E3 80 8A）的前两个字节，把字符拆开)
---@param text string
---@return string
local function leading_white(text)
  local index = 1
  while true do
    if text:sub(index, index) == " " then
      index = index + 1
    elseif text:sub(index, index + 2) == "　" then
      index = index + 3
    else
      return text:sub(1, index - 1)
    end
  end
end

---Display width of one UTF-8 character, in terminal cells.
---(一个 UTF-8 字符在终端里占几个单元格)
---
---Memoised: a chapter holds tens of thousands of characters but only a few
---thousand distinct ones, and every cache miss is a Vimscript call.
---(做了记忆化：一章上万字符里只有几千个不同的字符，而每次未命中都是一次 Vimscript 调用)
local CHAR_WIDTHS = {}
---@param char string
---@return integer
local function char_width(char)
  local cached = CHAR_WIDTHS[char]
  if cached == nil then
    cached = vim.fn.strdisplaywidth(char)
    CHAR_WIDTHS[char] = cached
  end
  return cached
end

---Byte length of the character starting at `index`.
---(从下标 index 起那个字符占几个字节)
---@param text string
---@param index integer
---@return integer
local function char_bytes(text, index)
  local byte = text:byte(index)
  if not byte then
    return 0
  end
  local length = 1
  if byte >= 0xF0 then
    length = 4
  elseif byte >= 0xE0 then
    length = 3
  elseif byte >= 0xC0 then
    length = 2
  end
  -- a truncated sequence at the end of the text must not read past it
  -- (末尾被截断的多字节序列不能越界)
  return math.min(length, #text - index + 1)
end

---@param text string
---@return integer cells
local function display_width(text)
  local cells, index = 0, 1
  while index <= #text do
    local length = char_bytes(text, index)
    cells = cells + char_width(text:sub(index, index + length - 1))
    index = index + length
  end
  return cells
end

---Start of the last character of a string (1-based byte index).
---(字符串中最后一个字符的起始字节下标)
---@param text string
---@return integer|nil
local function last_char_start(text)
  if text == "" then
    return nil
  end
  local index = #text
  while index > 1 do
    local byte = text:byte(index)
    if byte < 0x80 or byte >= 0xC0 then
      break
    end
    index = index - 1
  end
  return index
end

---Characters a line may not begin with: closing punctuation and marks belong to
---the line above. 标点禁则的「行首禁则」
---
---Instead of moving such a character up (which would need the previous line to
---grow), it is allowed to hang one cell past the margin, which is what Chinese
---typesetting does with punctuation anyway.
---(与其让上一行变长来收下它，不如让它悬挂出格一格——中文排版本来就这么处理标点)
local NO_START = {
  ["。"] = true,
  ["，"] = true,
  ["、"] = true,
  ["；"] = true,
  ["："] = true,
  ["？"] = true,
  ["！"] = true,
  ["）"] = true,
  ["》"] = true,
  ["」"] = true,
  ["』"] = true,
  ["】"] = true,
  ["〕"] = true,
  ["〉"] = true,
  ["｝"] = true,
  ["］"] = true,
  ["＞"] = true,
  ["”"] = true,
  ["’"] = true,
  ["…"] = true,
  ["—"] = true,
  ["·"] = true,
  ["%"] = true,
  ["‰"] = true,
  ["℃"] = true,
  ["°"] = true,
  [","] = true,
  ["."] = true,
  [";"] = true,
  [":"] = true,
  ["!"] = true,
  ["?"] = true,
  [")"] = true,
  ["]"] = true,
  ["}"] = true,
}

---Characters a line may not end with: an opening bracket belongs to what follows
---it, so it is carried to the next line. 标点禁则的「行尾禁则」
---Cells of closing punctuation (and footnote marks) allowed to stick out past
---the margin: `……` and `。」` are one unit as far as a reader is concerned.
---(允许悬挂出格的收尾标点（以及脚注标记）格数：`……` 与 `。」` 在读者眼里是一个整体)
local HANG_BUDGET = 4


local NO_END = {
  ["（"] = true,
  ["《"] = true,
  ["「"] = true,
  ["『"] = true,
  ["【"] = true,
  ["〔"] = true,
  ["｛"] = true,
  ["〈"] = true,
  ["［"] = true,
  ["<"] = true,
  ["“"] = true,
  ["‘"] = true,
  ["("] = true,
  ["["] = true,
  ["{"] = true,
}

---Line buffer that tracks byte columns so segments can record their position.
---(行缓冲：跟踪字节列号，以便段落记录自己的位置)
---
---Typesetting notes. A Chinese book separates paragraphs by indentation, while
---markdown normally uses a blank line; with one blank line per paragraph half of
---every screen is empty, so compact mode emits a plain line break and queues a
---first-line indent instead.
---(排版说明：中文书靠首行缩进区分段落，而 markdown 惯例是空行；每段一个空行意味着
--- 每屏一半是空白，因此紧凑模式改为换行 + 首行缩进)
---
---With a page width set it also breaks long paragraphs itself, which is what lets
---the reader put margins on both sides of a page instead of letting text run to
---the edge of the window.
---(设定了版心宽度后，它还会自己折长段落——这正是阅读器能做出两侧页边距、而不是让
--- 文字一直跑到窗口边缘的原因)
---
---A *block* (paragraph, heading, quote) may carry layout of its own, resolved
---from the book stylesheet: centered titles, indented reference blocks, small
---print. That layout lives in one place and is replaced whenever a new block
---starts.
---(一个**块**（段落、标题、引文）可以带自己的排版，来自书籍样式表：居中标题、缩进的引文
--- 块、小字。这份排版集中放在一处，新块开始时被替换)
local Buffer = {}
Buffer.__index = Buffer

---Mid-sentence punctuation a justified line may widen after: the pause is
---already there, a little more air reads naturally.
---(两端对齐时可以在其后加宽的句中标点：这里本来就有停顿，多一点留白读起来自然)
local MID_PUNCT = {
  ["，"] = true,
  ["、"] = true,
  ["；"] = true,
  ["："] = true,
}

---@param opts table|nil { compact, indent, no_gap, width, auto_space, justify }
function Buffer.new(opts)
  opts = opts or {}
  local buffer = setmetatable({
    lines = {},
    current = {},
    -- What each chunk of `current` is: "text", "space" (injected), "marker"
    -- (concealed syntax), "indent" (first-line indent or inset) or "token" (a
    -- footnote mark). Justification must know where concealed markers sit.
    -- (`current` 中每块是什么："text"、"space"（注入的空格）、"marker"（被隐藏的语法）、
    --  "indent"（首行缩进或内缩）、"token"（脚注标记）。两端对齐必须知道隐藏标记在哪)
    kinds = {},
    -- The line about to be flushed ends because the page is full, not because
    -- the paragraph does: only such a line is justified.
    -- (即将落盘的这一行是因为版心满了才结束，而不是段落结束：只有这种行才两端对齐)
    wrapping = false,
    col = 0,
    cells = 0,
    map = {},
    -- Per line display attributes for the reader: { [line] = { align, small, accent, cells } }
    -- (交给阅读器的逐行显示属性)
    lines_meta = {},
    compact = opts.compact ~= false,
    indent = opts.indent or "",
    no_gap = opts.no_gap == true,
    pending_indent = false,
    -- Verbatim text (a `<pre>` listing): line breaks and leading spaces are the
    -- content, so the buffer adds no indent, no spacing and no automatic
    -- Chinese/Latin space.
    -- (逐字文本（`<pre>` 清单）：换行与前导空格就是内容，因此行缓冲不加缩进、不留白、也不做
    --  中西文自动空格)
    verbatim = false,
    -- Space between a Chinese character and a Latin word, the way the app does
    -- it. Off by default so callers that predate it keep their exact output.
    -- (中西文之间的自动留白，和 App 一样。默认关闭，让此前的调用方输出不变)
    auto_space = opts.auto_space == true,
    -- Page width in cells; 0 means "never wrap", which keeps callers written
    -- before the page layout byte-identical.
    -- (版心宽度，单位单元格；0 表示不折行——这让页版出现之前的调用方输出逐字节不变)
    width = math.max(0, tonumber(opts.width) or 0),
    -- Spread a wrapped line's slack across it so both margins are straight.
    -- (把折行的剩余宽度分摊到行内，让左右两侧页边都齐)
    justify = opts.justify ~= false,
    -- Hooks around a wrap: `convert` uses them to close inline markers before a
    -- line ends and reopen them on the next one.
    -- (折行前后的钩子：convert 用它在一行结束前闭合行内标记、在下一行重新打开)
    before_wrap = nil,
    after_wrap = nil,
    -- Style entries whose opening marker waits for the first content character.
    -- Writing `**` the moment `<b>` opens left it dangling at the end of a line
    -- whenever the page broke right after it.
    -- (等待第一个内容字符才写出开启标记的样式项。`<b>` 一打开就写 `**`，版心恰好在它后面
    --  折断时，它就悬在行尾)
    pending = {},
    -- Style spans `convert` has recorded, so a flush can clamp the ones the
    -- trimmed tail of a line cut short.
    -- (convert 记录下的样式区间：flush 据此夹住被行尾裁剪截短的那些)
    styles = nil,
    -- Footnote marks, supplied by `convert`: `mark_start(line, col)` says where a
    -- mark ending at `col` starts, so a wrap carries it whole, and
    -- `on_carry(old_line, cut_col, new_line, new_col)` moves the records of what
    -- was carried.
    -- (脚注标记，由 convert 提供：`mark_start(line, col)` 告知止于 `col` 的标记从哪开始，
    --  让折行把它整个带走；`on_carry(...)` 则把被带走部分的记录挪到新位置)
    mark_start = nil,
    on_carry = nil,
    -- The line holds nothing yet but a list item's marker: the `<p>` an item
    -- wraps its text in must not end that line.
    -- (这一行目前只有列表项的标记：列表项包住文字的 `<p>` 不能把这一行结束掉)
    awaiting_item = false,
    -- Backslashes written in front of text that would otherwise open a block
    -- (`- `, `# `, `> `, `1. ` at the start of a wrapped line), so markdown keeps
    -- it a paragraph. The reader conceals them. { line, col } 0-based.
    -- (写在会被误读成块标记的文字前面的反斜杠——折行行首的 `- `、`# `、`> `、`1. `——让
    --  markdown 仍把它当作段落。阅读器会隐藏它们。{ line, col }，0 基)
    escapes = {},
  }, Buffer)
  buffer:set_layout({})
  return buffer
end

---Set the layout of the block that is about to be written.
---(设定即将写入的块的排版)
---@param layout table|nil
---  align string|nil center/right, what the reader pads the line with
---  small boolean|nil small print, drawn in a muted colour
---  translation boolean|nil a machine translation of the block before it(上一块的机器译文)
---  accent boolean|nil the book paints this block in a real colour
---  indent string|nil first line indent text; nil keeps the default
---  pad_left integer|nil inset on both sides, in cells (small print, quotes)
---  pad_right integer|nil
---  lead string|nil written at the start of every line: the `> ` of a quote
---  hang string|nil written at the start of every line but the first: the room
---    a list item's continuation lines leave for its marker
---  (lead：每一行开头都写，即引文的 `> `；hang：除首行外每行开头都写，即列表项续行给标记留的位置)
function Buffer:set_layout(layout)
  layout = layout or {}
  local pad_left = math.max(0, tonumber(layout.pad_left) or 0)
  local pad_right = math.max(0, tonumber(layout.pad_right) or 0)
  local lead = layout.lead or ""
  local hang = layout.hang or ""
  local indent = layout.indent
  if indent == nil then
    indent = self.indent
  end
  if layout.align then
    -- a centered or right aligned line is not indented on its first line
    -- (居中或右对齐的行不做首行缩进)
    indent = ""
  end
  -- An inset is made of full-width spaces (and a no-break space for an odd
  -- cell), never of ASCII ones: four leading spaces make markdown read the line
  -- as an indented code block.
  -- (内缩用全角空格（奇数格补一个不换行空格）而不是半角空格：行首四个半角空格会让 markdown
  --  把这一行当成缩进代码块)
  local pad = pad_left > 0 and (string.rep("　", math.floor(pad_left / 2)) .. string.rep("\194\160", pad_left % 2))
    or ""
  self.layout = {
    align = layout.align,
    small = layout.small == true,
    translation = layout.translation == true,
    accent = layout.accent == true,
    -- an inset block is inset on its first line too, and the paragraph indent
    -- sits inside that inset
    -- (内缩块的首行同样内缩，段落缩进落在这层内缩之内)
    indent = lead .. hang .. pad .. indent,
    -- and its continuation lines stay inset, without repeating the indent
    -- (续行保持内缩，但不重复首行缩进)
    rest = lead .. hang .. pad,
    lead = lead,
    -- the left inset is part of the written line, the right one is not
    -- (左内缩写在行内，右内缩不在行内)
    width = self.width > 0 and math.max(10, self.width - pad_right) or 0,
  }
end

---Write text onto the current line and remember where it came from.
---(把文本写到当前行，并记下它的来源)
---@param text string
---@param src_from integer|nil rune offset in the source(源 rune 下标)
---@param src_to integer|nil
---@param kind string|nil chunk kind, "text" by default(块类型，默认 "text")
function Buffer:place(text, src_from, src_to, kind)
  if text == "" then
    return
  end
  if self.col == 0 and kind ~= "indent" then
    -- the first thing on a line: a quote's `> ` goes in front of it
    -- (行上的第一样东西：引文的 `> ` 写在它前面)
    self:flush_indent()
  end
  local content = kind == nil or kind == "text"
  if content and #self.pending > 0 and not self.verbatim then
    -- An opening `*` followed by a space is not emphasis, and at the start of a
    -- line it is a list item: the whitespace goes in front of the marker.
    -- (开启的 `*` 后面跟着空格就不是强调了，放在行首还会变成列表项：空白写在标记前面)
    local white = leading_white(text)
    if white ~= "" then
      local runes = count_runes(white)
      local splittable = src_from == nil or (src_to or (src_from + count_runes(text))) - src_from == count_runes(text)
      if #white == #text then
        self:place_text(text, src_from, src_to)
        return
      elseif splittable then
        self:place_text(white, src_from, src_from and (src_from + runes) or nil)
        self:place(text:sub(#white + 1), src_from and (src_from + runes) or nil, src_to, kind)
        return
      end
    end
  end
  if content and not self.verbatim and self:only_indent() and text:sub(1, 1) == " " then
    -- an ASCII space at the start of a line is not indentation the book wrote
    -- (full-width ones are), and four of them make a code block
    -- (行首的半角空格不是书写的缩进（全角的才是），四个还会变成代码块)
    local white = text:match("^ +")
    local splittable = src_from == nil or (src_to or (src_from + count_runes(text))) - src_from == count_runes(text)
    if splittable then
      if #white == #text then
        return
      end
      self:place(text:sub(#white + 1), src_from and (src_from + #white) or nil, src_to, kind)
      return
    end
  end
  if content and not self.verbatim and self:only_indent() then
    local first = text:sub(1, 1)
    if BLOCK_STARTS[first] then
      -- written as a marker, so it stays out of the offset map and costs no cell
      -- (作为标记写入：不进 offset map，也不占单元格)
      self.escapes[#self.escapes + 1] = { line = #self.lines, col = self.col }
      self.current[#self.current + 1] = "\\"
      self.kinds[#self.current] = "marker"
      self.col = self.col + 1
    end
  end
  if content then
    self.awaiting_item = false
  end
  if kind == nil or kind == "text" or kind == "token" then
    -- content: the opening markers waiting for it go first
    -- (这是内容：等着它的开启标记先写)
    self:open_pending()
  end
  if src_from then
    local runes = count_runes(text)
    src_to = src_to or (src_from + runes)
    self.map[#self.map + 1] = {
      src_from = src_from,
      src_to = src_to,
      line = #self.lines,
      col_from = self.col,
      col_to = self.col + #text,
      -- One character standing for a different number of source runes: an
      -- entity (`&amp;` is five) or collapsed whitespace. Such a segment is
      -- indivisible, since nothing inside it maps to a column of its own.
      -- (一个字符代表的源 rune 数不等于一：实体（`&amp;` 是五个）或折叠后的空白。这种段落
      --  不可分割，因为它内部没有哪个 rune 能对应到自己的列)
      atom = runes ~= src_to - src_from or nil,
    }
  end
  self.current[#self.current + 1] = text
  self.kinds[#self.current] = kind or "text"
  self.col = self.col + #text
  local cells = display_width(text)
  self.cells = self.cells + cells
  if cells > 0 then
    -- the last *visible* character, so auto spacing can look past concealed
    -- markers like `**`
    -- (最后一个**可见**字符：自动留白要能跳过 `**` 这类被隐藏的标记)
    self.last_visible = text:sub(last_char_start(text))
  end
end

---Write text without opening the styles waiting for content.
---(写入文本，但不打开等待内容的样式)
---@param text string
---@param src_from integer|nil
---@param src_to integer|nil
function Buffer:place_text(text, src_from, src_to)
  local pending = self.pending
  self.pending = {}
  self:place(text, src_from, src_to, "text")
  self.pending = pending
end

---Does the current line hold nothing but indentation so far?
---(当前行到目前为止是否只有缩进？)
---@return boolean
function Buffer:only_indent()
  for index = 1, #self.current do
    if self.kinds[index] ~= "indent" then
      return false
    end
  end
  return true
end

---Chinese characters, kana and hangul: the scripts that want a space next to a
---Latin word. Punctuation is deliberately excluded, so `（O` does not gain one.
---(汉字、假名与谚文：需要在拉丁词旁边加空格的文字。刻意排除标点，`（O` 因此不会多出空格)
---@param char string
---@return boolean
local function is_cjk(char)
  local code = vim.fn.char2nr(char)
  return (code >= 0x3400 and code <= 0x4DBF) -- CJK ext A(CJK 扩展 A)
    or (code >= 0x4E00 and code <= 0x9FFF)
    or (code >= 0x3040 and code <= 0x30FF) -- kana(假名)
    or (code >= 0xAC00 and code <= 0xD7AF) -- hangul(谚文)
    or (code >= 0xF900 and code <= 0xFAFF)
    or code == 0x3005
    or code == 0x3007
end

---@param char string
---@return boolean
local function is_latin(char)
  local byte = char:byte(1)
  if not byte or byte >= 0x80 then
    return false
  end
  return (byte >= 0x30 and byte <= 0x39) or (byte >= 0x41 and byte <= 0x5A) or (byte >= 0x61 and byte <= 0x7A)
end

---@param char string|nil
---@return boolean
local function is_space(char)
  return char == " " or char == "　" or char == "\t"
end

---Would the app put a space between these two characters?
---(App 会在这两个字符之间留空格吗？)
---@param left string|nil
---@param right string|nil
---@return boolean
local function needs_space(left, right)
  if not left or not right or is_space(left) or is_space(right) then
    return false
  end
  if is_cjk(left) then
    return is_latin(right)
  end
  if is_latin(left) then
    return is_cjk(right)
  end
  return false
end

---Cells taken by the Latin word starting at `index`.
---(从 index 开始的拉丁词占多少格)
---@param text string
---@param index integer
---@return integer
local function latin_run_cells(text, index)
  local cells, position = 0, index
  while position <= #text do
    local length = char_bytes(text, position)
    local char = text:sub(position, position + length - 1)
    if not is_latin(char) then
      break
    end
    cells = cells + char_width(char)
    position = position + length
  end
  return cells
end

---Page width the current block wraps at, or 0 when it never wraps.
---(当前块折行用的版心宽度；不折行时为 0)
---@return integer
function Buffer:wrap_width()
  if self.layout.width > 0 then
    return self.layout.width
  end
  return self.width
end

---Write the opening markers of the styles waiting for content.
---(写出等待内容的样式的开启标记)
function Buffer:open_pending()
  if #self.pending == 0 then
    return
  end
  local pending = self.pending
  self.pending = {}
  self:flush_indent()
  for _, entry in ipairs(pending) do
    if entry.marker then
      self:marker(entry.marker, 0)
    end
    entry.line = #self.lines
    entry.col_from = self.col
    entry.opened = true
  end
end

---Take back a marker that is the last thing on the line.
---(收回位于行尾的标记)
---@param text string
---@return boolean
function Buffer:unmark(text)
  while #self.current > 0 and self.current[#self.current] == "" do
    self.kinds[#self.current] = nil
    self.current[#self.current] = nil
  end
  local index = #self.current
  if index == 0 or self.current[index] ~= text or self.kinds[index] ~= "marker" then
    return false
  end
  self.current[index] = nil
  self.kinds[index] = nil
  self.col = self.col - #text
  return true
end

---Take the last character off the current line when `accept` wants it, so a
---wrap can carry it to the next line. The map segment that owned it shrinks.
---(当 `accept` 同意时把本行最后一个字符取下来，让折行把它带到下一行；拥有它的 map 段落同步缩短)
---@param accept fun(char: string): boolean
---@return string|nil char
---@return integer|nil src_from rune of the character, when it is mapped(字符对应的 rune，有映射时)
---@return integer|nil src_to rune the character ends at(字符结束处的 rune)
function Buffer:take_last_char(accept)
  local index = #self.current
  local chunk = self.current[index]
  if not chunk or chunk == "" or self.kinds[index] ~= "text" then
    return nil
  end
  local start = last_char_start(chunk)
  local char = chunk:sub(start)
  if not accept(char) then
    return nil
  end
  if start == 1 then
    self.current[index] = nil
    self.kinds[index] = nil
  else
    self.current[index] = chunk:sub(1, start - 1)
  end
  self.col = self.col - #char
  self.cells = self.cells - char_width(char)

  local src_from, src_to = nil, nil
  local segment = self.map[#self.map]
  if segment and segment.line == #self.lines and segment.col_to == self.col + #char then
    src_to = segment.src_to
    segment.col_to = self.col
    if segment.atom then
      -- an atom leaves whole, with every rune it stands for(不可分段落整个带走，连同它代表的全部 rune)
      src_from = segment.src_from
    else
      segment.src_to = math.max(segment.src_from, (segment.src_to or 0) - 1)
      src_from = segment.src_to
    end
    if segment.col_to <= segment.col_from then
      self.map[#self.map] = nil
    end
  end
  return char, src_from, src_to
end

---Take the end of a full line along to the next one: closing punctuation and
---footnote marks hanging there, and the character they follow — so the next line
---opens with that character instead of with `。` or a mark.
---(把满行的末尾一起带到下一行：悬挂在那儿的收尾标点与脚注标记，以及它们跟随的那个字符——
--- 这样下一行以那个字符开头，而不是以 `。` 或标记开头)
---@return table[] items { text, src_from?, kind } in line order(按行内顺序)
function Buffer:take_hanging_tail()
  local items = {}
  local rest_cells = display_width(self.layout.rest)
  -- never empty the line: something has to stay behind
  -- (绝不把整行掏空：总得留下点什么)
  local function keeps_line(cells)
    return self.cells - cells > rest_cells
  end
  local function take_char(accept)
    local char, src_from, src_to = self:take_last_char(function(char)
      return accept(char) and keeps_line(char_width(char))
    end)
    if char then
      table.insert(items, 1, { text = char, src_from = src_from, src_to = src_to, kind = "text" })
    end
    return char ~= nil
  end
  -- A mark leaves whole or not at all: half of `[12]` on each line is worse
  -- than a mark sticking out.
  -- (标记要么整个走，要么不走：`[12]` 一半在这行一半在下行，比悬挂出格更糟)
  local function take_mark()
    local from = self.mark_start and self.mark_start(#self.lines, self.col)
    if not from or from >= self.col then
      return false
    end
    if not keeps_line(display_width(table.concat(self.current):sub(from + 1))) then
      return false
    end
    while self.col > from do
      local index = #self.current
      local kind = self.kinds[index]
      if kind == "token" then
        local text = self.current[index]
        self.current[index] = nil
        self.kinds[index] = nil
        self.col = self.col - #text
        self.cells = self.cells - display_width(text)
        table.insert(items, 1, { text = text, kind = "token" })
      elseif kind ~= "text" or not take_char(function()
        return true
      end) then
        break
      end
    end
    return true
  end

  while take_mark() or take_char(function(char)
    return NO_START[char] == true
  end) do
  end
  if not take_mark() then
    take_char(function(char)
      return not NO_START[char] and not is_space(char)
    end)
  end
  -- and an opening bracket in front of it(还有它前面的开启括号)
  while take_char(function(char)
    return NO_END[char] == true
  end) do
  end
  return items
end

---End a line because the page is full.
---(因为版心已满而结束一行)
---
---What moves to the next line is taken off first, and only then are the open
---styles closed: closing them first left the span (and the closing `**`) after a
---character that was about to leave the line.
---(先取下要挪到下一行的内容，再闭合打开中的样式：先闭合的话，样式区间（以及闭合的 `**`）
--- 会落在一个马上要离开本行的字符之后)
---@param take_tail boolean|nil carry the hanging tail rather than an opening bracket
---  (带走悬挂的行尾，而不只是开启括号)
function Buffer:wrap(take_tail)
  local carried = {}
  if take_tail then
    carried = self:take_hanging_tail()
  end
  if #carried == 0 then
    local char, src_from, src_to = self:take_last_char(function(char)
      return NO_END[char] == true
    end)
    if char then
      carried = { { text = char, src_from = src_from, src_to = src_to, kind = "text" } }
    end
  end
  local old_line, cut_col = #self.lines, self.col
  if self.before_wrap then
    self.before_wrap(self)
  end
  self.wrapping = true
  self:newline()
  self.wrapping = false
  if self.after_wrap then
    self.after_wrap(self)
  end
  if self.layout.rest ~= "" and self.col == 0 then
    -- an inset block keeps its inset on every line
    -- (内缩块的每一行都保持内缩)
    self:place(self.layout.rest, nil, nil, "indent")
  end
  if #carried == 0 then
    return
  end
  -- what was carried is content, so reopened styles go in front of it
  -- (被带过来的是内容，重新打开的样式写在它前面)
  self:open_pending()
  if self.on_carry then
    self.on_carry(old_line, cut_col, #self.lines, self.col)
  end
  for _, item in ipairs(carried) do
    if item.kind == "token" then
      self:place(item.text, nil, nil, "token")
    else
      self:place(item.text, item.src_from, item.src_from and (item.src_to or item.src_from + 1) or nil)
    end
  end
end

---Is the character at `index` the last letter of `text`, with only closing
---punctuation (and spaces) after it?
---(位于 index 的字符是否是 text 里最后一个字——后面只剩收尾标点和空白？)
---@param text string
---@param index integer byte index of the character(该字符的字节下标)
---@return boolean
local function lone_tail(text, index)
  local after = index + char_bytes(text, index)
  while after <= #text do
    local length = char_bytes(text, after)
    local char = text:sub(after, after + length - 1)
    if not NO_START[char] and not is_space(char) then
      return false
    end
    after = after + length
  end
  return true
end

---Place a run of text with the page width in mind.
---(按版心宽度安放一段文本)
---
---The line breaks before the character that would overflow, and two Chinese
---typesetting rules are honoured: no line starts with closing punctuation (it
---hangs one character past the margin instead) and no line ends with an opening
---bracket (it is carried to the next line).
---(折点落在会溢出的字符之前，并遵守两条中文排版规则：行首不出现收尾标点（改为悬挂出格
--- 一个字符）、行尾不留开启括号（挪到下一行）)
---@param text string
---@param src_from integer|nil
---@param spans integer[]|nil source runes of every character, flat pairs
---  `{ from1, to1, from2, to2, ... }`; without it the characters are taken to be
---  the source runes from `src_from` on, one for one
---  (每个字符的源 rune，扁平的成对数组；不传时视为从 src_from 起与源 rune 一一对应)
function Buffer:flow(text, src_from, spans)
  -- width 0 = the caller never wraps: the line grows as long as it likes and
  -- only the automatic spacing is left to do
  -- (width 0 表示调用方不要折行：行想多长就多长，只剩自动留白要做)
  local width = self.layout.width > 0 and self.layout.width or (self.width > 0 and self.width or math.huge)
  local rune = src_from or 0
  -- Text without a source offset (the chapter title on the opening page) is
  -- written outside the offset map: it has no rune to point at.
  -- (没有源偏移的文本（章首页上的章节标题）写在 offset map 之外：它没有 rune 可指)
  local mapped = src_from ~= nil
  local index = 1
  local ordinal = 0
  local piece = {}
  local piece_from = rune
  -- the piece holds a single character that stands for more (or fewer) runes
  -- than one, and must be written on its own
  -- (piece 里只有一个代表的 rune 数不为一的字符，必须单独写出)
  local piece_atom = false
  local after_break = false
  -- Width the fresh line held right after the break: its inset, or the marker
  -- of a heading that goes on.
  -- (刚折行时新行已占的宽度：内缩，或者继续着的标题的标记)
  local break_cells = -1
  -- Width already taken on the current line, including the characters still
  -- waiting in `piece`. Tracking `self.cells` alone would ignore everything not
  -- yet written, and the line would never look full.
  -- (当前行已占的宽度，包含仍留在 `piece` 里还没落盘的字符。只看 self.cells 会漏掉
  --  尚未写下的部分，行就永远不会显示为满)
  local cells = self.cells
  -- Last visible character of the line, used for Chinese/Latin spacing
  -- (本行最后一个可见字符，用于中西文之间留白)
  local previous = self.last_visible

  -- Characters are collected into one map segment per line, so a highlight that
  -- starts or ends inside the run still resolves to the right column.
  -- (字符按行收集成一个个 map 段落，因此起点/终点落在这段文本内部的划线仍能落对列)
  ---@param src_to integer|nil rune offset the piece ends at(本段结束的 rune 下标)
  local function write_piece(src_to)
    if #piece == 0 then
      return
    end
    if mapped then
      self:place(table.concat(piece), piece_from, src_to or rune)
    else
      self:place(table.concat(piece))
    end
    piece = {}
    piece_from = src_to or rune
    piece_atom = false
    cells = self.cells
  end

  ---End the line because the page is full.
  ---(因为版心已满而结束本行)
  ---@param take_tail boolean|nil carry the hanging tail along(把悬挂的行尾一起带走)
  local function break_line(take_tail)
    -- A book space left at the wrap point would be trimmed by the flush, while
    -- its map segment still covered it: the line break now does the separating
    -- the space used to do, so it is dropped here, runes and all.
    -- (留在折点上的书内空格会被 flush 裁掉，而它的 map 段落还覆盖着它：折行接替了空格
    --  原本的分隔作用，因此在这里连同 rune 一起去掉)
    local dropped = 0
    while #piece > 0 and piece[#piece] == " " do
      piece[#piece] = nil
      dropped = dropped + 1
    end
    write_piece(rune - dropped)
    piece_atom = false
    self:wrap(take_tail and width < math.huge)
    -- the fresh line starts (nearly) empty; carrying the local width over from
    -- the line that just ended made every following line one character long
    -- (新行几乎是空的；把上一行的宽度留在局部变量里，会让后面每一行都只剩一个字符)
    piece = {}
    piece_from = rune
    cells = self.cells
    previous = self.last_visible
    after_break = true
    break_cells = self.cells
  end

  while index <= #text do
    local length = char_bytes(text, index)
    local char = text:sub(index, index + length - 1)
    local char_cells = char_width(char)
    ordinal = ordinal + 1
    -- Source runes of this character: an entity is one character but several
    -- runes, and a stripped space leaves a gap. Either way the segment has to
    -- end there, or every character after it would point at the wrong rune.
    -- (这个字符的源 rune：实体是一个字符却占多个 rune，被去掉的空格会留下空隙。两种情况
    --  段落都必须在此断开，否则它后面的每个字符都会指错 rune)
    local char_from, char_to = rune, rune + 1
    if spans then
      char_from, char_to = spans[ordinal * 2 - 1], spans[ordinal * 2]
    end

    -- Measure a Latin word before placing any of it. A year, a name or a URL
    -- that does not fit moves to the next line whole; only a word longer than
    -- the page itself ends up cut in half.
    -- (先量整个拉丁词再决定怎么放：放不下的年份、名称或 URL 整词挪到下一行，只有比
    --  版心还长的词才会被切开)
    local starts_word = is_latin(char) and not (previous and is_latin(previous))
    if starts_word and cells > 0 then
      local run = latin_run_cells(text, index)
      -- the space auto spacing is about to put in front of the word is part of
      -- what has to fit(自动留白即将插在词前的空格，也算在要放下的宽度里)
      local space = (self.auto_space and not self.verbatim and not after_break and needs_space(previous, char)) and 1
        or 0
      if cells + space + run > width then
        break_line()
      end
    end

    -- A space that lands on a fresh wrapped line is not indentation. Only a
    -- wrap can put it there: a space at the start of a text run is kept as the
    -- book wrote it.
    -- (落到新起折行上的空格不是缩进。只有折行会把空格放到行首：文本段开头的空格
    --  按书里写的保留)
    if not (char == " " and after_break and (cells == 0 or cells == break_cells)) then
      if self.auto_space and not self.verbatim and not after_break and needs_space(previous, char) then
        if cells + 1 <= width then
          -- The space is written on its own, outside any map segment: it has no
          -- source rune, and letting it inside one would push every rune after
          -- it one column to the right — which is exactly what breaks the
          -- mapping either way round (drawing a highlight, or turning a
          -- selection back into a range).
          -- (空格单独写出，不属于任何 map 段落：它在源文里没有对应 rune，若混进段落，
          --  其后的每个 rune 都会右移一列——那正是双向映射（画划线、把选区变回 range）
          --  出错的原因)
          write_piece()
          self:place(" ", nil, nil, "space")
          piece_from = rune
          cells = self.cells
        end
        -- when it does not fit, the line break is the separator
        -- (放不下时，折行本身就充当了间隔)
      end
      if cells + char_cells > width and cells > 0 then
        if NO_START[char] and cells + char_cells <= width + HANG_BUDGET then
          -- hanging punctuation: it is better to stick out a couple of cells
          -- than to open a line with `。` or split `……`. The budget is measured
          -- from the margin, so a footnote mark already hanging there counts.
          -- (悬挂标点：出格一两格好过让 `。` 起行或者把 `……` 拆开。预算从页边量起，
          --  因此已经悬在那儿的脚注标记也算在内)
        else
          -- Closing punctuation that cannot hang any further takes the end of
          -- the line along, so the next line opens with a character, not `。`.
          -- (悬挂不下的收尾标点带走行尾，让下一行以文字而不是 `。` 开头)
          --
          -- 孤字不成行 (clreq §7.1.2): when this character is all the run has
          -- left (punctuation aside), the line gives up its last character too,
          -- so the new line holds two characters instead of one alone.
          -- (孤字不成行（clreq §7.1.2）：如果这个字是本段文字剩下的唯一一个字（标点不算），
          --  本行把最后一个字也让出去，新行就是两个字，而不是孤零零的一个)
          local orphan = not NO_START[char] and lone_tail(text, index) and cells >= width / 2
          break_line(NO_START[char] == true or orphan)
        end
      end
      -- the space this break replaced does not open the new line
      -- (被这次折行替代的空格不放到新行开头)
      if char == " " and after_break and cells == break_cells then
        goto next_char
      end
      local atom = char_to - char_from ~= 1
      if #piece > 0 and (piece_atom or atom or char_from ~= rune) then
        write_piece()
      end
      if #piece == 0 then
        piece_from = char_from
      end
      piece[#piece + 1] = char
      piece_atom = atom
      cells = cells + char_cells
      -- Spaces count as "seen" too: a space the book already provides must stop
      -- the next character from getting a second one (`1，000 条` used to end up
      -- with two).
      -- (空格也算「已见过的字符」：书里本来就有的空格必须阻止下一个字符再加一个
      --  （`1，000 条` 曾经变成两个空格）)
      previous = char
    end
    ::next_char::
    index = index + length
    rune = char_to
  end
  write_piece()
end

---@param text string
---@param src_from integer|nil
---@param src_to integer|nil
---@param spans integer[]|nil source runes of every character(每个字符的源 rune)，see `flow`
function Buffer:append(text, src_from, src_to, spans)
  if text == "" then
    return
  end
  if self.pending_indent then
    -- TXT books already carry a full-width indent; adding another would double
    -- it. Same for text that starts with an ASCII space.
    -- (TXT 型书籍自带全角缩进，再加一次就重复了；以半角空格开头的同理)
    local head = text:sub(1, 3)
    if head == "　" or text:sub(1, 1) == " " then
      self.pending_indent = false
    else
      self:flush_indent()
    end
  end
  self:flow(text, src_from, spans)
end

---Append inline syntax with no counterpart in the source (`*`, `**`, `` ` ``).
---Markers are deliberately kept out of the offset map: a zero-width segment
---could never contain a rune and would only bloat the map. A queued indent
---survives, so a paragraph that opens with emphasis still gets indented.
---(追加源码中没有对应物的行内标记（`*`、`**`、反引号）。标记刻意不写入 offset
--- map：零宽段落永远不可能包含某个 rune，只会让 map 膨胀。排队的缩进会保留，
--- 因此以强调开头的段落仍然能正确缩进)
---@param text string
---@param cells integer|nil width to account for; markdown punctuation the reader
---  conceals costs nothing on screen, so callers pass 0(记为 0：阅读器会把这类标记隐藏)
function Buffer:marker(text, cells)
  -- Write a queued indent first: `*注意*...` must become `　　*注意*...`, not
  -- `*　　注意*...`.
  -- (先把排队的缩进落下去：`*注意*…` 应当是 `　　*注意*…`，不能变成 `*　　注意*…`)
  self:flush_indent()
  if text == "" then
    return
  end
  self.current[#self.current + 1] = text
  self.kinds[#self.current] = "marker"
  self.col = self.col + #text
  self.cells = self.cells + (cells ~= nil and cells or display_width(text))
end

---Write a short mark with no counterpart in the source (a footnote number).
---Like closing punctuation it may hang past the margin but never starts a line,
---so it always stays on the line it follows; it is kept out of the offset map.
---(写入一个在源文里没有对应物的小标记（脚注序号）。和收尾标点一样，它可以悬挂出格但
--- 绝不起行，因此总是留在它跟随的那一行；它不进入 offset map)
---@param text string
---@return integer line 0-based line it landed on(落在哪一行，0 基)
---@return integer col_from 0-based byte column(0 基字节列)
---@return integer col_to
function Buffer:token(text)
  self:flush_indent()
  local width = self:wrap_width()
  if width > 0 and self.cells + display_width(text) > width + HANG_BUDGET then
    -- hanging punctuation in front already used the budget: the mark takes the
    -- end of the line along instead of sticking out further
    -- (前面的悬挂标点已经用掉了预算：标记带着行尾一起换行，而不是继续出格)
    self:wrap(true)
  end
  self:place(text, nil, nil, "token")
  return #self.lines, self.col - #text, self.col
end

---Write the queued paragraph indent, if any.
---(把排队的段落缩进写下去)
function Buffer:flush_indent()
  if self.verbatim then
    return
  end
  local indent = nil
  if self.pending_indent then
    self.pending_indent = false
    indent = self.layout.indent
  elseif self.col == 0 then
    -- No paragraph indent queued, but a quote still marks every line it holds
    -- (没有排队的段落缩进，但引文仍要给它的每一行加上标记)
    indent = self.layout.lead
  end
  if indent ~= nil and indent ~= "" then
    self.current[#self.current + 1] = indent
    self.kinds[#self.current] = "indent"
    self.col = self.col + #indent
    self.cells = self.cells + display_width(indent)
  end
end

---Same, for markers that own a whole line (`# `, `- `, `> `, figures). These are
---structural, so a queued paragraph indent must be dropped.
---(同上，用于独占一行的标记（`# `、`- `、`> `、插图）。它们是结构性的，因此必须
--- 丢弃排队中的段落缩进)
---@param text string
---@param cells integer|nil
function Buffer:block_marker(text, cells)
  self.pending_indent = false
  self:marker(text, cells)
end

function Buffer:is_empty()
  return self.col == 0
end

---Where a wrapped line takes its slack, so it ends flush with the margin.
---(折行把剩余宽度放在哪里，使它与右侧页边对齐)
---
---The slack is drawn by the reader as inline virtual text, never written into
---the line: the offset map stays exactly as it was. One cell per gap at most,
---taken first after existing spaces, then after `，、；：`, then spread evenly
---between Chinese characters; only spaces may take more when nothing else is
---left. A gap never opens before closing punctuation, after an opening bracket,
---next to a concealed marker or inside the first-line indent.
---(剩余宽度由阅读器以行内虚拟文本绘制，绝不写进行内：offset map 原样不动。每个间隙最多
--- 一格，先给已有空格之后，再给 `，、；：` 之后，最后在汉字之间均匀铺开；只有在别处都
--- 用完时，空格才可以多拿。间隙绝不出现在收尾标点之前、开启括号之后、被隐藏的标记旁边
--- 或首行缩进之内)
---@param stripped string the line as it will be written(将要写下的行)
---@param slack integer cells to distribute(要分摊的格数)
---@return table[] fill { { col, cells } }, col a 0-based byte column(0 基字节列)
function Buffer:fill_gaps(stripped, slack)
  local chars = {}
  local col = 0
  -- inside a code span every character is literal and must not be spaced out
  -- (行内代码里的每个字符都是字面量，不能被拉开)
  local in_code = false
  for index, chunk in ipairs(self.current) do
    local kind = self.kinds[index] or "text"
    if kind == "marker" and chunk == "`" then
      in_code = not in_code
    elseif in_code and kind == "text" then
      kind = "code"
    end
    local position = 1
    while position <= #chunk and col + position - 1 < #stripped do
      local length = char_bytes(chunk, position)
      if kind ~= "marker" then
        chars[#chars + 1] = {
          char = chunk:sub(position, position + length - 1),
          col = col + position - 1,
          bytes = length,
          kind = kind,
        }
      end
      position = position + length
    end
    col = col + #chunk
  end

  local spaces, punct, cjk = {}, {}, {}
  local seen_text = false
  for index = 1, #chars - 1 do
    local left, right = chars[index], chars[index + 1]
    local usable = (left.kind == "text" or left.kind == "space")
      and (right.kind == "text" or right.kind == "space")
      -- contiguous bytes: nothing concealed sits between them(字节相邻：中间没有被隐藏的东西)
      and left.col + left.bytes == right.col
      and not NO_END[left.char]
      and not NO_START[right.char]
      and not is_space(right.char)
    if usable then
      if is_space(left.char) then
        -- a space before any text is indentation the book wrote itself
        -- (正文之前的空格是书自己写的缩进)
        if seen_text then
          spaces[#spaces + 1] = right.col
        end
      elseif MID_PUNCT[left.char] then
        punct[#punct + 1] = right.col
      elseif char_width(left.char) == 2 and char_width(right.char) == 2 then
        cjk[#cjk + 1] = right.col
      end
    end
    if left.kind ~= "indent" and not is_space(left.char) then
      seen_text = true
    end
  end

  local fill_at = {}
  local remaining = slack
  ---Give one cell to `take` of the gaps, spread evenly along the line.
  ---(给其中 `take` 个间隙各一格，沿整行均匀分布)
  local function spread(gaps)
    local take = math.min(remaining, #gaps)
    for k = 1, take do
      local col_at = gaps[math.floor((k - 0.5) * #gaps / take) + 1]
      fill_at[col_at] = (fill_at[col_at] or 0) + 1
    end
    remaining = remaining - take
  end
  spread(spaces)
  spread(punct)
  spread(cjk)
  if remaining > 0 and #spaces > 0 then
    for k = 0, remaining - 1 do
      local col_at = spaces[k % #spaces + 1]
      fill_at[col_at] = fill_at[col_at] + 1
    end
  end

  local fill = {}
  for col_at, cells in pairs(fill_at) do
    fill[#fill + 1] = { col = col_at, cells = cells }
  end
  table.sort(fill, function(a, b)
    return a.col < b.col
  end)
  return fill
end

---Trim trailing spaces, which markdown only sees as noise.
---(去掉行尾空格，markdown 里只会变成噪音)
function Buffer:flush()
  local line = table.concat(self.current)
  -- Trailing whitespace is noise in markdown, full-width spaces included: a
  -- line holding nothing but a queued indent must disappear.
  -- (行尾空白在 markdown 里是噪音，全角空格同理：只有缩进的空行必须消失)
  -- (`　+$` would repeat only the last byte of the full-width space, so strip
  -- them one at a time)(`　+$` 只会重复全角空格的最后一个字节，所以逐个去掉)
  local stripped = line
  repeat
    local before = stripped
    stripped = stripped:gsub("[ \t]+$", ""):gsub("　$", "")
  until stripped == before
  if #stripped < #line then
    -- What the trim cut off must not stay inside a map segment or a style span:
    -- they would point past the end of the line.
    -- (被裁掉的部分不能还留在 map 段落或样式区间里：它们会指到行尾之外)
    local limit, line_index = #stripped, #self.lines
    for index = #self.map, 1, -1 do
      local segment = self.map[index]
      if segment.line ~= line_index then
        break
      end
      if segment.col_to > limit then
        -- the runes cut off go too, so src_to - src_from still counts what is
        -- on the line(被裁掉的 rune 一并去掉，src_to - src_from 仍等于行上的字符数)
        local cut = count_runes(line:sub(math.max(segment.col_from, limit) + 1, segment.col_to))
        segment.src_to = math.max(segment.src_from, segment.src_to - cut)
        segment.col_to = math.max(segment.col_from, limit)
        if segment.col_to <= segment.col_from then
          table.remove(self.map, index)
        end
      end
    end
    for _, style in ipairs(self.styles or {}) do
      if style.line == line_index and style.col_to > limit then
        style.col_to = math.max(style.col_from, limit)
      end
    end
  end
  local layout = self.layout
  -- The reader needs the line's real width to place it on the page: it cannot
  -- measure it itself, because the text still holds markers it conceals.
  -- (阅读器需要这一行的真实宽度才能把它摆到页面上：它自己量不准，因为文本里还带着被隐藏的标记)
  local concealed_cells = math.max(0, display_width(line) - self.cells)
  local cells = math.max(0, display_width(stripped) - concealed_cells)
  local meta = nil
  if layout.align or layout.small or layout.accent or layout.translation then
    meta = {
      align = layout.align,
      small = layout.small or nil,
      translation = layout.translation or nil,
      accent = layout.accent or nil,
      cells = cells,
    }
  end
  -- Only a line the page broke is justified: the last line of a paragraph ends
  -- where the paragraph does, ragged, as in any book.
  -- (只有被版心折断的行才两端对齐：段落末行在段落结束处收尾、参差不齐，任何书都是这样)
  if self.wrapping and self.justify and not self.verbatim and not layout.align and layout.width > 0 then
    local slack = layout.width - cells
    if slack > 1 then
      local fill = self:fill_gaps(stripped, slack)
      if #fill > 0 then
        meta = meta or { cells = cells }
        meta.fill = fill
      end
    end
  end
  if meta then
    self.lines_meta[#self.lines] = meta
  end
  self.lines[#self.lines + 1] = stripped
  self.current = {}
  self.kinds = {}
  self.col = 0
  self.cells = 0
  self.last_visible = nil
end

function Buffer:newline()
  if self.col > 0 then
    self:flush()
  end
end

---Force a blank line: used around headings, figures and rules, where the extra
---breathing room is worth the vertical space.
---(强制空行：用于标题/插图/分隔线，这些地方留白值得)
function Buffer:gap()
  if self.no_gap then
    self:newline()
    return
  end
  self:newline()
  self:blank()
end

---Add an empty line unless there is one already. Inside a quote the empty line
---is a bare `>`, or it would end the quote.
---(补一个空行，已有则不补。引文里的空行是一个单独的 `>`，否则引文就此结束)
function Buffer:blank()
  local lines = self.lines
  local empty = vim.trim(self.layout.lead or "")
  if #lines > 0 and lines[#lines] ~= "" and lines[#lines] ~= empty then
    lines[#lines + 1] = empty
  end
end

---Separate the next paragraph from the current one.
---(分隔下一段：紧凑模式只换行并排队缩进，经典模式插入空行)
function Buffer:separate()
  if self.awaiting_item then
    -- the item's own `<p>`: its text goes on the marker's line
    -- (列表项自己的 `<p>`：文字写在标记那一行)
    return
  end
  self:newline()
  if self.compact then
    -- Armed unconditionally: how much to indent depends on the block that opens
    -- next, and `separate` runs before that block's tag has been looked at.
    -- (无条件置位：缩进多少取决于接下来打开的块，而 separate 在该块的标签被解析之前就执行了)
    self.pending_indent = true
  else
    self:gap()
  end
end

---@return string
function Buffer:get()
  self:newline()
  -- a bare `>` left by the last quote is a blank line too
  -- (最后一个引文留下的单独 `>` 也算空行)
  while #self.lines > 0 and self.lines[#self.lines]:match("^[> ]*$") do
    table.remove(self.lines)
  end
  return table.concat(self.lines, "\n")
end

return {
  Buffer = Buffer,
  HANG_BUDGET = HANG_BUDGET,
  count_runes = count_runes,
  leading_white = leading_white,
  char_bytes = char_bytes,
  display_width = display_width,
}
