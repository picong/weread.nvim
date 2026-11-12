--[[
Tables, laid out by the converter itself: real lines of text in the chapter,
drawn with box characters and folded to the page width.
(表格由转换器自己排：章节里真实的文字行，用制表符画边框，按版心宽度折行)

They used to be markdown pipe tables, one row per line, that render-markdown drew
over with its own borders. That had two costs. A row too wide for the window was
drawn as *virtual* lines while its buffer line was hidden, and a hidden line
takes no rows on screen — the cursor could not land on it, so those rows could
not be selected, highlighted or looked up. And it folded the cells to the whole
window rather than to the page, so a full screen window stretched the table to
its right edge while the text around it stayed in its column.
(表格原来是 markdown 管道表格，一行一行，由 render-markdown 盖上它自己的边框。这有两个代价：
 窗口放不下的行被画成**虚拟行**、而它在 buffer 里的那一行被隐藏，被隐藏的行在屏幕上不占行——
 光标落不上去，这些行就没法选中、划线或查词。而且它按整个窗口而不是版心去折单元格，全屏时表格
 一直撑到窗口右边，周围的正文却还在版心里)

Here every line of a table is a line of the buffer. Cell text is written with
its source runes, exactly like prose, so selecting, highlighting and the offset
map work inside a table as they do everywhere else; the borders and the padding
are markers and stay out of the map.
(在这里，表格的每一行都是 buffer 的一行。单元格文字带着它的源 rune 写入，和正文完全一样，
 所以选中、划线和偏移表在表格里照常工作；边框与补白是标记，不进偏移表)
]]

local buffer_module = require("weread.xhtml_buffer")

local display_width = buffer_module.display_width

local M = {}

---Box characters. Exported so anything that reads a table line back as text
---(a selection, a lookup) can take them out again.
---(制表符。导出给把表格行读回文字的地方（选区、查词）用，以便把它们去掉)
M.BOX = {
  v = "│",
  h = "─",
  dash = "╌",
  top = { "┌", "┬", "┐" },
  mid = { "├", "┼", "┤" },
  bottom = { "└", "┴", "┘" },
}

---Every box character the layout draws.
---(排版会画出的全部制表符)
M.BOX_CHARS = { "│", "─", "╌", "┌", "┬", "┐", "├", "┼", "┤", "└", "┴", "┘" }

---Characters that may not start a line, carried back with the character before
---them (clreq), as the prose layout does.
---(不能出现在行首的字符：和正文排版一样，把它前面那个字一起带下去（clreq）)
local NO_START = {}
for _, char in ipairs({ "。", "，", "、", "；", "：", "？", "！", "）", "」", "』", "】", "〕", "》", "…", "”", "’", "%", "." , ",", ";", ":", "?", "!", ")" }) do
  NO_START[char] = true
end

---A cell is never squeezed narrower than this many cells (two Chinese
---characters), and a long word never sets a column wider than this.
---(单元格最窄不少于这么多格（两个汉字）；长单词撑出的列宽也不超过这么多格)
local MIN_CELLS, WORD_CAP = 4, 16

-- ------------------------------------------------------------------ units

---Break a cell's characters into what a line may not split: a run of ASCII (a
---word, a number), any other single character, a space, a hard break.
---(把单元格的字符切成一行里不能拆开的单位：一串 ASCII（单词、数字）、其他单个字符、空格、硬换行)
---@param items table[] { char, from?, to?, white?, brk? }
---@return table[] units { items, cells, space?, brk? }
function M.units(items)
  local units, word = {}, nil
  for _, item in ipairs(items) do
    if item.brk then
      units[#units + 1] = { brk = true, items = {}, cells = 0 }
      word = nil
    elseif item.white or item.char == " " then
      units[#units + 1] = { space = true, items = { item }, cells = 1 }
      word = nil
    else
      local cells = display_width(item.char)
      local ascii = #item.char == 1
      if ascii and word then
        word.items[#word.items + 1] = item
        word.cells = word.cells + cells
      else
        local unit = { items = { item }, cells = cells }
        units[#units + 1] = unit
        word = ascii and unit or nil
      end
    end
  end
  return units
end

---Fold units into lines no wider than `width`. Spaces between words are kept,
---spaces at either end of a line are dropped, and a word wider than the column
---is cut where it has to be.
---(把单位折成不宽于 width 的行。词与词之间的空格保留，行首行尾的空格去掉，比列还宽的词在不得不断
--- 的地方断开)
---@param units table[]
---@param width integer
---@return table[] lines { items, cells }
function M.wrap(units, width)
  local lines = {}
  local line = { items = {}, cells = 0, units = {} }
  local space = nil
  local function push()
    lines[#lines + 1] = line
    line = { items = {}, cells = 0, units = {} }
    space = nil
  end
  local function add(unit)
    if space and line.cells > 0 then
      line.units[#line.units + 1] = space
      line.cells = line.cells + space.cells
    end
    space = nil
    line.units[#line.units + 1] = unit
    line.cells = line.cells + unit.cells
  end
  for _, unit in ipairs(units) do
    if unit.brk then
      push()
    elseif unit.space then
      if line.cells > 0 then
        space = unit
      end
    elseif unit.cells > width then
      -- a word longer than the column: cut it, character by character
      -- (比列还长的词：一个字符一个字符地切)
      for _, item in ipairs(unit.items) do
        local cells = display_width(item.char)
        local piece = { items = { item }, cells = cells }
        if line.cells + (space and line.cells > 0 and 1 or 0) + cells > width and line.cells > 0 then
          push()
        end
        add(piece)
      end
    else
      local needed = line.cells + ((space and line.cells > 0) and space.cells or 0) + unit.cells
      if needed > width and line.cells > 0 then
        local carried = nil
        local first = unit.items[1]
        if #unit.items == 1 and NO_START[first.char] and #line.units > 1 then
          -- `。` does not open a line: the character before it comes along
          -- (`。` 不起行：把它前面那个字一起带下去)
          carried = table.remove(line.units)
          line.cells = line.cells - carried.cells
          while #line.units > 0 and line.units[#line.units].space do
            local dropped = table.remove(line.units)
            line.cells = line.cells - dropped.cells
          end
        end
        push()
        if carried then
          add(carried)
        end
      end
      add(unit)
    end
  end
  if line.cells > 0 or #lines == 0 then
    push()
  end
  for _, done in ipairs(lines) do
    for _, unit in ipairs(done.units) do
      for _, item in ipairs(unit.items) do
        done.items[#done.items + 1] = item
      end
    end
    done.units = nil
  end
  return lines
end

-- ------------------------------------------------------------------ widths

---Natural width of a cell (its longest line unfolded) and the narrowest it may
---get (its longest word, capped).
---(单元格的自然宽度（不折行时最长的一行）以及它最窄能到多少（最长的词，有上限）)
---@param units table[]
---@return integer natural
---@return integer narrowest
local function measure(units)
  local natural, longest = 0, 0
  for _, line in ipairs(M.wrap(units, math.huge)) do
    natural = math.max(natural, line.cells)
  end
  for _, unit in ipairs(units) do
    if not unit.space and not unit.brk then
      longest = math.max(longest, unit.cells)
    end
  end
  return natural, math.min(natural, math.max(MIN_CELLS, math.min(longest, WORD_CAP)))
end

---Column widths for a table: the natural ones when they fit in `budget`, else
---every column at its narrowest and the rest of the budget handed, a cell at a
---time, to whichever column is furthest from its natural width.
---(表格的列宽：放得下时就用自然宽度；放不下时每列先取最窄，剩下的预算一格一格地分给离自然宽度
--- 最远的那一列)
---@param naturals integer[]
---@param narrowest integer[]
---@param budget integer cells for the text of all columns; <= 0 for no limit(所有列文字可用的格数；<= 0 表示不限)
---@return integer[]
function M.widths(naturals, narrowest, budget)
  local total = 0
  for _, width in ipairs(naturals) do
    total = total + width
  end
  if budget <= 0 or total <= budget then
    return vim.deepcopy(naturals)
  end
  local widths, used = {}, 0
  for i, width in ipairs(narrowest) do
    widths[i] = math.max(1, width)
    used = used + widths[i]
  end
  -- Not even every column at its narrowest fits: the widest ones give way, a
  -- cell at a time, down to one Chinese character each, then to a single cell.
  -- (连每列都取最窄也放不下：最宽的那些一格一格地让，先让到一个汉字，再让到一格)
  while used > budget do
    local widest, at = nil, used > budget + #widths and 1 or 2
    for i, width in ipairs(widths) do
      if width > at then
        widest, at = i, width
      end
    end
    if not widest then
      for i, width in ipairs(widths) do
        if width > 1 and (not widest or width > at) then
          widest, at = i, width
        end
      end
    end
    if not widest then
      break
    end
    widths[widest] = widths[widest] - 1
    used = used - 1
  end
  local left = budget - used
  while left > 0 do
    local best, gap = nil, 0
    for i, width in ipairs(widths) do
      local want = naturals[i] - width
      if want > gap then
        best, gap = i, want
      end
    end
    if not best then
      break
    end
    widths[best] = widths[best] + 1
    left = left - 1
  end
  return widths
end

-- ------------------------------------------------------------------ the grid

---Rows of cells as a grid: a cell spanning several columns (`colspan`) is
---followed by empty cells, one spanning several rows (`rowspan`) leaves an empty
---cell in its column on the rows below, so every cell lands in its own column.
---The text stays in the cell that holds it.
---(把单元格的行整理成网格：跨列（colspan）的格子后面补空格子，跨行（rowspan）的格子在下面几行
--- 的同一列留空格子，这样每个格子都落在自己那一列。文字留在写着它的那一格里)
---@param source_rows table[]
---@return table[] rows
function M.grid(source_rows)
  local rows = {}
  local carry = {} -- column -> rows still covered by a rowspan above(列 -> 还被上方 rowspan 盖住的行数)
  for _, source in ipairs(source_rows) do
    if #source.cells > 0 then
      local row = { cells = {}, header = source.header }
      local column = 1
      local function fill()
        while (carry[column] or 0) > 0 do
          carry[column] = carry[column] - 1
          row.cells[column] = { items = {}, styles = {}, spanned = true }
          column = column + 1
        end
      end
      for _, cell in ipairs(source.cells) do
        fill()
        row.cells[column] = cell
        local rowspan, colspan = cell.rowspan or 1, cell.colspan or 1
        for extra = 0, colspan - 1 do
          if extra > 0 then
            row.cells[column + extra] = { items = {}, styles = {}, spanned = true }
          end
          if rowspan > 1 then
            carry[column + extra] = rowspan - 1
          end
        end
        column = column + colspan
      end
      fill()
      rows[#rows + 1] = row
    end
  end
  return rows
end

-- ------------------------------------------------------------------ emitting

---Write a laid out table into the line buffer, one buffer line per screen line.
---(把排好的表格写进行缓冲：屏幕上的每一行就是 buffer 的一行)
---
---`styles` is the converter's own list: header cells get a "head" span,
---borders a "rule" span, a cell's inline styling its own spans. Every item
---learns the line and columns it landed on, which is how the caller places the
---footnote marks inside cells.
---(`styles` 是转换器自己的列表：表头单元格得到 "head" 区间，边框得到 "rule" 区间，单元格的
--- 行内样式得到各自的区间。每一项都会记下自己落在哪一行哪几列，调用方据此放置单元格里的脚注标记)
---@param buffer table weread.xhtml_buffer Buffer
---@param tbl table { rows = { { cells = { { items, styles, header } }, header } } }
---@param opts { page_width: integer, styles: table[] }
function M.emit(buffer, tbl, opts)
  local rows = M.grid(tbl.rows)
  if #rows == 0 then
    return
  end
  local columns = 0
  for _, row in ipairs(rows) do
    columns = math.max(columns, #row.cells)
  end
  -- units of every cell, and what each column wants
  -- (每个单元格的单位，以及每一列想要多宽)
  local naturals, narrowest = {}, {}
  for c = 1, columns do
    naturals[c], narrowest[c] = 1, 1
  end
  for _, row in ipairs(rows) do
    for c = 1, columns do
      local cell = row.cells[c] or { items = {}, styles = {} }
      row.cells[c] = cell
      cell.units = M.units(cell.items)
      local natural, narrow = measure(cell.units)
      naturals[c] = math.max(naturals[c], natural)
      narrowest[c] = math.max(narrowest[c], narrow)
    end
  end
  -- A border between and around the columns, and one space of padding on each
  -- side of every cell. A quote's `> ` takes its share of the page too.
  -- (列与列之间、两侧各一条边框，每个单元格左右各一格补白。引文的 `> ` 也占版心)
  local page = tonumber(opts.page_width) or 0
  local room = page > 0 and (page - display_width(buffer.layout.lead or "") - (columns + 1)) or 0
  -- One space either side of a cell's text, unless the page is so tight that
  -- the space is better spent on the text itself.
  -- (单元格文字两侧各留一格，除非版心紧到这一格更该留给文字本身)
  local padding = 1
  if page > 0 and room - 2 * columns < 2 * columns then
    padding = 0
  end
  -- one cell per column at the very least; a page narrower than that is the one
  -- case a table may stick out of
  -- (每列至少一格；只有版心比这还窄时，表格才会伸出版心)
  local budget = page > 0 and math.max(columns, room - 2 * padding * columns) or 0
  local widths = M.widths(naturals, narrowest, budget)

  local styles = opts.styles
  local box = M.BOX
  local function rule(kind, chars)
    buffer:marker(chars[1])
    for c = 1, columns do
      buffer:marker(string.rep(kind, widths[c] + 2 * padding))
      buffer:marker(c < columns and chars[2] or chars[3])
    end
    local line = #buffer.lines
    styles[#styles + 1] = { line = line, col_from = #(buffer.layout.lead or ""), col_to = buffer.col, kind = "rule", markers = 0 }
    buffer:newline()
  end
  local function border()
    local from = buffer.col
    buffer:marker(box.v)
    styles[#styles + 1] = { line = #buffer.lines, col_from = from, col_to = buffer.col, kind = "rule", markers = 0 }
  end

  ---Place a cell's line of items, mapped where the characters come from the
  ---book; every item learns its line and columns.
  ---(写出单元格的一行：来自书里的字符带着映射写入；每一项记下自己所在的行与列)
  local function place(items)
    local index = 1
    while index <= #items do
      local item = items[index]
      local first = index
      if item.from and item.to and item.to - item.from == 1 and not item.token then
        -- a run of characters with consecutive runes is one map segment
        -- (rune 连续的一串字符是一个 map 段落)
        while items[index + 1] do
          local next_item = items[index + 1]
          if next_item.token or not next_item.from or next_item.to - next_item.from ~= 1 or next_item.from ~= items[index].to then
            break
          end
          index = index + 1
        end
      elseif not item.from and not item.token then
        -- text that is not in the book (a translation) goes out in one piece
        -- (不在书里的文字（译文）整段写出)
        while items[index + 1] and not items[index + 1].from and not items[index + 1].token do
          index = index + 1
        end
      end
      local parts = {}
      for k = first, index do
        parts[#parts + 1] = items[k].char
      end
      local text = table.concat(parts)
      local col = buffer.col
      if items[first].token then
        buffer:place(text, nil, nil, "token")
      elseif items[first].from then
        buffer:place(text, items[first].from, items[index].to)
      else
        buffer:place(text)
      end
      for k = first, index do
        items[k].line = #buffer.lines
        items[k].col_from = col
        col = col + #items[k].char
        items[k].col_to = col
      end
      index = index + 1
    end
  end

  local multiline = false
  local heights = {}
  for r, row in ipairs(rows) do
    local height = 1
    for c = 1, columns do
      local cell = row.cells[c]
      cell.lines = M.wrap(cell.units, widths[c])
      height = math.max(height, #cell.lines)
    end
    heights[r] = height
    if height > 1 and not row.header then
      multiline = true
    end
  end

  rule(box.h, box.top)
  for r, row in ipairs(rows) do
    for k = 1, heights[r] do
      border()
      for c = 1, columns do
        local cell = row.cells[c]
        local line = cell.lines[k]
        buffer:marker(string.rep(" ", padding))
        local used = 0
        if line then
          place(line.items)
          used = line.cells
        end
        buffer:marker(string.rep(" ", widths[c] - used + padding))
        border()
      end
      buffer:newline()
    end
    local next_row = rows[r + 1]
    if next_row then
      if row.header and not next_row.header then
        rule(box.h, box.mid)
      elseif multiline and not row.header then
        -- rows that fold over several lines need a line between them, or the
        -- end of one row reads as the start of the next
        -- (折成多行的行之间要有一条线，否则一行的末尾读起来像下一行的开头)
        rule(box.dash, box.mid)
      end
    end
  end
  rule(box.h, box.bottom)

  -- spans over what was placed: header text, a cell's own styling, footnotes
  -- (为已写出的内容生成区间：表头文字、单元格自己的样式、脚注)
  local function spans_over(items, kind)
    local by_line = {}
    for _, item in ipairs(items) do
      if item.line and not item.white then
        local span = by_line[item.line]
        if not span then
          span = { line = item.line, col_from = item.col_from, col_to = item.col_to, kind = kind, markers = 0 }
          by_line[item.line] = span
        else
          span.col_from = math.min(span.col_from, item.col_from)
          span.col_to = math.max(span.col_to, item.col_to)
        end
      end
    end
    for _, span in pairs(by_line) do
      styles[#styles + 1] = span
    end
  end
  for _, row in ipairs(rows) do
    for c = 1, columns do
      local cell = row.cells[c]
      if cell.header or row.header then
        spans_over(cell.items, "head")
      end
      for _, style in ipairs(cell.styles or {}) do
        local covered = {}
        for k = style.from, math.min(style.to, #cell.items) do
          covered[#covered + 1] = cell.items[k]
        end
        spans_over(covered, style.kind)
      end
    end
  end
end

---Is a line (0-based) one of the table lines a converted chapter recorded?
---(某一行（0 基）是不是转换结果记下的表格行之一)
---@param meta table|nil a chapter's map (the converter's result or map.json)(章节的 map)
---@param line integer 0-based(0 基)
---@return boolean
function M.is_line(meta, line)
  for _, range in ipairs(type(meta) == "table" and type(meta.tables) == "table" and meta.tables or {}) do
    if line >= (tonumber(range[1]) or 0) and line <= (tonumber(range[2]) or -1) then
      return true
    end
  end
  return false
end

---Take the box characters out of text read back from a table line.
---(把从表格行读回来的文字里的制表符去掉)
---@param text string
---@return string
function M.strip(text)
  for _, char in ipairs(M.BOX_CHARS) do
    text = text:gsub(char, " ")
  end
  return (text:gsub("  +", " "))
end

return M
