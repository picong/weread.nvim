--[[
Pages: the chapter is read a screen at a time, the way a book is.
(分页：像读书一样，一次读一屏)

A chapter is still one buffer, laid out once by the renderer. Paging is a way of
*looking* at it: the window shows a run of whole lines that fits its height,
the next page starts with the first line that did not fit, and nothing is ever
shown twice or skipped. The rows below the last whole line are covered, so a
page never ends on half of the next one, and the window's last row carries the
folio: page number, pages left in the chapter, how far into the book.
(章节仍然是一个 buffer，由渲染器排一次版。分页是一种**看**它的方式：窗口显示一段放得下的
 完整行，下一页从第一个没放下的行开始，任何内容都不会显示两次、也不会被跳过。最后一个完整行
 下面的那几行会被遮住，所以一页不会结束在下一页的半截上；窗口最后一行是页脚：页码、本章还剩
 几页、读到全书的哪里)

Heights come from `nvim_win_text_height`, which counts wrapped rows, inline
virtual text and the virtual lines an illustration occupies. Illustrations load
asynchronously and change those heights, so the next page is always measured
from the top of the page on screen, never from a stale list.
(高度取自 nvim_win_text_height：它会算上折行、行内虚拟文本，以及插图占用的虚拟行。插图是
 异步加载的，会改变这些高度，因此下一页总是从屏幕上这一页的顶端量起，而不是用过期的列表)

A line taller than a page (a long table row, a code line, a narrow window) is
read in slices: the window keeps it on top and scrolls into it with `skipcol`
(the window has 'smoothscroll'), one page of screen rows at a time, and those
slices are pages like any other.
(比一页还高的行（很长的表格行、代码行、很窄的窗口）分片来读：窗口把它留在顶端，用 skipcol
 （窗口开着 'smoothscroll'）一次滚进一页的屏行，这些分片和别的页一样算页)

The cover and the folio are one floating window per chapter window, sitting on
the window's own rows. It is not the statusline: statusline plugins rewrite
every window's statusline on their own clock.
(遮罩与页脚是每个章节窗口一个的浮窗，压在窗口自己的行上。它不是状态栏：状态栏插件会按自己的
 节奏改写每个窗口的状态栏)
]]

local M = {}

---Floating cover per chapter window: { win = float, buf = scratch }
---(每个章节窗口的浮动遮罩)
local covers = {}

---Last wheel page turn, so a burst of wheel events turns one page.
---(上一次滚轮翻页的时刻：一串滚轮事件只翻一页)
local last_wheel = 0
local WHEEL_THROTTLE_MS = 150

---Set while the pager moves the view itself, so its own scroll events are not
---taken for the reader's.
---(分页器自己移动视图时置位，免得把自己的滚动事件当成读者的)
local moving = false

---@return boolean
function M.enabled()
  local layout = require("weread.config").get().layout or {}
  return layout.page_mode ~= "scroll"
end

---@param win integer
---@return boolean
local function chapter_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  return require("weread.reader").buffer_info(vim.api.nvim_win_get_buf(win)) ~= nil
end

---Windows this short have no room for a folio: no cover, the page is the window.
---(这么矮的窗口放不下页脚：不加遮罩，整个窗口就是一页)
local MIN_COVERED_ROWS = 3

---Text rows a page may fill: the window's text area minus the folio row.
---(一页可以填几行：窗口正文区减去页脚那一行)
---@param win integer
---@return integer
function M.page_rows(win)
  local rows = vim.fn.winheight(win)
  if rows < MIN_COVERED_ROWS then
    return math.max(1, rows)
  end
  return rows - 1
end

---Columns of text a screen row holds: the window minus its statuscolumn.
---(一屏行能放多少列正文：窗口宽度减去 statuscolumn)
---
---Deliberately a separate copy from `preview.text_width`: this one is never
---below 1 (a page must always have a column to wrap in) and takes a window that
---is known to be valid; the preview version returns nil for an invalid window
---and does no clamping, because its caller skips the work then.
---(与 `preview.text_width` 有意分开：这里至少返回 1（分页总要有一列可折行），且假定窗口有效；
--- preview 版对无效窗口返回 nil、不做下限保护，调用方遇到 nil 会直接跳过)
---@param win integer
---@return integer
local function text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return math.max(1, vim.api.nvim_win_get_width(win) - (info and info.textoff or 0))
end

---Screen rows a buffer line takes, including the virtual lines under it.
---(一个 buffer 行在屏幕上占几行，含它下面的虚拟行)
---@param win integer
---@param line integer 1-based
---@param last integer line count
---@param skip integer|nil display columns of the line already read(这一行已读过的显示列)
---@return integer
function M.line_height(win, line, last, skip)
  local range = { start_row = line - 1, start_vcol = skip or 0 }
  if line < last then
    range.end_row = line
    range.end_vcol = 0
  end
  local ok, height = pcall(vim.api.nvim_win_text_height, win, range)
  if not ok or type(height) ~= "table" then
    return 1
  end
  return math.max(0, height.all or 1)
end

---Screen rows of a line's own text from `skip` on, without the virtual lines
---under it: only text can be scrolled into.
---(某行从 skip 起自身文字占几屏行，不含其下的虚拟行：能滚进去的只有文字)
---@param win integer
---@param line integer
---@param skip integer
---@return integer
local function text_rows(win, line, skip)
  local ok, height = pcall(vim.api.nvim_win_text_height, win, {
    start_row = line - 1,
    start_vcol = skip,
    end_row = line - 1,
  })
  if not ok or type(height) ~= "table" then
    return 1
  end
  return math.max(0, height.all or 1)
end

---Display column the slice after `rows` screen rows of a line starts at.
---(某行从 skip 起排满 rows 屏行之后，下一片从哪个显示列开始)
---@param win integer
---@param line integer
---@param skip integer
---@param rows integer
---@return integer
local function slice_end(win, line, skip, rows)
  local ok, height = pcall(vim.api.nvim_win_text_height, win, {
    start_row = line - 1,
    start_vcol = skip,
    end_row = line - 1,
    max_height = rows,
  })
  local column = ok and type(height) == "table" and height.end_vcol or 0
  if column <= skip then
    -- always move on, whatever the measurement says (无论量出什么，总要往前走)
    column = skip + rows * text_width(win)
  end
  return column
end

---Display column (0-based) a byte column of a line starts at.
---(某行某字节列的起始显示列，0 起)
---@param win integer
---@param line integer
---@param col integer 0-based byte
---@return integer
local function vcol_of(win, line, col)
  local span = vim.fn.virtcol({ line, col + 1 }, true, win)
  return math.max(0, (span[1] or 1) - 1)
end

---Byte column (0-based) of the first character starting at or after display
---column `vcol`. The space 'linebreak' stretches to the end of a row starts on
---the row before, so it never counts.
---(从显示列 vcol 起第一个字符的字节列（0 起）。'linebreak' 拉长到行尾的那个空格起始于上一屏行，
--- 不算)
---@param win integer
---@param line integer
---@param vcol integer
---@return integer
local function col_at(win, line, vcol)
  local col = vim.fn.virtcol2col(win, line, vcol + 1)
  if col <= 0 then
    return 0
  end
  local span = vim.fn.virtcol({ line, col }, true, win)
  if (span[1] or 1) - 1 < vcol then
    local after = vim.fn.virtcol2col(win, line, (span[2] or 0) + 1)
    if after > col then
      col = after
    end
  end
  return col - 1
end

---Display columns a line's text takes.
---(某行文字占多少显示列)
---@param win integer
---@param line integer
---@return integer
local function line_vcols(win, line)
  return math.max(0, vim.fn.virtcol({ line, "$" }, false, win) - 1)
end

---Lines a page never starts with: blank lines and the fences the page conceals.
---(一页不会以它们开头：空行，以及页面隐藏掉的围栏行)
---@param text string
---@return boolean
local function is_blank(text)
  return text:match("^%s*$") ~= nil or text:match("^%s*```") ~= nil
end

---@param text string
---@return boolean
local function is_heading(text)
  return text:match("^#+%s") ~= nil
end

---Fit one page starting at `start`.
---(从 start 开始排一页)
---
---A heading is never the last line of a page: it moves to the next one with the
---text it introduces, unless it is all the page has.
---(标题绝不做一页的最后一行：它跟着它引出的正文去下一页，除非这一页只有它)
---
---A first line taller than the page is cut into slices: the page is the next
---`rows` screen rows of it, and the following page is the same line again,
---further in. Its last slice is followed by whatever lines still fit.
---(比一页还高的首行切成分片：这一页就是它接下来的 rows 个屏行，下一页还是同一行、再往里一些。
--- 它的最后一片后面再接上放得下的行)
---@param win integer
---@param start integer 1-based first line
---@param lines string[] buffer lines
---@param rows integer
---@param skip integer|nil display columns of `start` read on earlier pages(start 行在前面几页已读过的显示列)
---@return integer next first line of the following page (count + 1 at the end; `start` for another slice)
---@return integer used rows taken on screen
---@return integer next_skip where the following page starts in its first line(下一页从它首行的哪个显示列开始)
function M.fit(win, start, lines, rows, skip)
  skip = skip or 0
  local last = #lines
  local used, line = 0, start
  local heights = {}
  if start <= last then
    local first = M.line_height(win, start, last, skip)
    if skip > 0 or first > rows then
      if text_rows(win, start, skip) > rows then
        local next_skip = slice_end(win, start, skip, rows)
        if next_skip < line_vcols(win, start) then
          return start, rows, next_skip
        end
      end
      -- the last slice, or a line whose figure overflows: it is the top of the
      -- page, and nothing can be scrolled into a virtual line
      -- (最后一片，或插图溢出的行：它就是页顶，虚拟行里是滚不进去的)
      used = math.min(first, rows)
      heights[start] = used
      line = start + 1
    end
  end
  while line <= last do
    local height = M.line_height(win, line, last)
    if line > start and used + height > rows then
      break
    end
    heights[line] = height
    used = used + height
    line = line + 1
  end
  if line <= last and line - 1 > start then
    local tail = line - 1
    while tail > start and (is_heading(lines[tail]) or is_blank(lines[tail])) do
      tail = tail - 1
    end
    if tail < line - 1 and not is_blank(lines[tail]) then
      for dropped = tail + 1, line - 1 do
        used = used - (heights[dropped] or 0)
      end
      line = tail + 1
    end
  end
  -- 孤行不成页 (clreq §7.1.2): the last line of a paragraph does not open a
  -- page on its own; the line before it goes along, so the next page starts
  -- with two lines of the paragraph rather than its stray end.
  -- (孤行不成页（clreq §7.1.2）：段落的最后一行不单独占据页首；把它前一行一起带过去，
  --  下一页以这段的两行开头，而不是一截孤零零的段尾)
  if line <= last and line - 3 > start and M.is_widow(lines, line) then
    used = used - (heights[line - 1] or 0)
    line = line - 1
  end
  return line, used, 0
end

---Does a paragraph start on this line? An indented line, or one after a
---blank line or a heading.
---(这一行是否开始一个段落：缩进的行，或者空行、标题之后的行)
---@param lines string[]
---@param line integer
---@return boolean
local function opens_paragraph(lines, line)
  if line <= 1 then
    return true
  end
  local text = lines[line] or ""
  return text:sub(1, 3) == "　" or is_blank(lines[line - 1] or "") or is_heading(lines[line - 1] or "")
end

---Is this line the stray last line of a paragraph that began above it?
---(这一行是不是从上面开始的某个段落的孤零零的末行？)
---@param lines string[]
---@param line integer
---@return boolean
function M.is_widow(lines, line)
  local text = lines[line]
  if not text or is_blank(text) or is_heading(text) or opens_paragraph(lines, line) then
    return false
  end
  local previous = lines[line - 1]
  if not previous or is_blank(previous) or is_heading(previous) then
    return false
  end
  local nxt = lines[line + 1]
  return nxt == nil or is_blank(nxt) or is_heading(nxt) or opens_paragraph(lines, line + 1)
end

---First line at or after `line` a page may start with.
---(从 line 起，第一个可以作为页首的行)
---@param lines string[]
---@param line integer
---@return integer
local function skip_blank(lines, line)
  while line <= #lines and is_blank(lines[line]) do
    line = line + 1
  end
  return line
end

---First line at or after `line` a page may start with in a window: not blank,
---and not a line that takes no rows (`conceal_lines`), which the window would
---never show on top.
---(在某窗口里，从 line 起第一个可以作为页首的行：不是空行，也不是不占行的行（conceal_lines）
--- ——窗口永远不会把它显示在顶端)
---@param win integer
---@param lines string[]
---@param line integer
---@return integer
local function first_shown(win, lines, line)
  line = skip_blank(lines, line)
  while line < #lines and M.line_height(win, line, #lines) == 0 do
    line = skip_blank(lines, line + 1)
  end
  return line
end

---Move the cursor one screen row, the way `gj`/`gk` do, but never onto a line
---that takes no rows: an original hidden under its translation, or a table row
---render-markdown draws elsewhere. `gj` stops on such a line, the cursor
---vanishes and stays put on screen, and it took several presses to go on.
---(像 gj/gk 那样把光标移一个屏行，但绝不停在不占屏行的行上：藏在译文上方的原文，或者
--- render-markdown 画到别处的表格行。gj 会停在这种行上，光标看不见、在屏幕上也不动，
--- 要连按好几次才走得动)
---@param win integer
---@param forward boolean
---@param count integer|nil
---@return boolean moved
function M.step(win, forward, count)
  local buf = vim.api.nvim_win_get_buf(win)
  local last = vim.api.nvim_buf_line_count(buf)
  local moved = false
  for _ = 1, math.max(1, count or 1) do
    local before = vim.api.nvim_win_get_cursor(win)
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! " .. (forward and "gj" or "gk"))
    end)
    local line = vim.api.nvim_win_get_cursor(win)[1]
    if M.line_height(win, line, last) == 0 then
      local target = line
      while target >= 1 and target <= last and M.line_height(win, target, last) == 0 do
        target = target + (forward and 1 or -1)
      end
      if target < 1 or target > last then
        -- nothing shown past it: stay where the cursor was
        -- (再往前没有显示的行了：留在原处)
        vim.api.nvim_win_set_cursor(win, before)
        break
      end
      local text = vim.api.nvim_buf_get_lines(buf, target - 1, target, false)[1] or ""
      -- going up lands on the last screen row of the line, as `gk` would
      -- (向上走落在那一行的最后一个屏行上，与 gk 一致)
      vim.api.nvim_win_set_cursor(win, { target, forward and 0 or math.max(0, #text - 1) })
    end
    local after = vim.api.nvim_win_get_cursor(win)
    if after[1] == before[1] and after[2] == before[2] then
      break
    end
    moved = true
  end
  return moved
end

---Every page of the chapter in a window, as first lines. A line read in slices
---appears once per slice, with the display column each slice starts at.
---(章节在某个窗口里的全部页，以每页首行表示。分片读的行每片出现一次，并附上每片起始的显示列)
---@param win integer
---@return integer[] starts
---@return integer[] skips display column each page starts at in its first line(每页从首行的哪个显示列开始)
function M.pages(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local rows = M.page_rows(win)
  local starts, skips = {}, {}
  local start, skip = 1, 0
  while start <= #lines do
    starts[#starts + 1] = start
    skips[#skips + 1] = skip
    local next_line, _, next_skip = M.fit(win, start, lines, rows, skip)
    if next_line == start and next_skip > skip then
      skip = next_skip
    else
      start = first_shown(win, lines, math.max(next_line, start + 1))
      skip = 0
    end
  end
  if #starts == 0 then
    starts[1] = 1
    skips[1] = 0
  end
  return starts, skips
end

---Index of the page a line is on; with `skips` and `vcol`, the slice of the line
---that holds that display column.
---(某行在第几页；给了 skips 与 vcol 时，是该行里含这个显示列的那一片)
---@param starts integer[]
---@param line integer
---@param skips integer[]|nil
---@param vcol integer|nil 0-based display column in `line`
---@return integer
function M.page_of(starts, line, skips, vcol)
  vcol = vcol or 0
  local function at_or_before(index)
    if starts[index] ~= line then
      return starts[index] < line
    end
    if not skips then
      -- slices unknown: the line's first page (不知道分片：取该行的第一页)
      return index == 1 or starts[index - 1] ~= line
    end
    return (skips[index] or 0) <= vcol
  end
  local low, high = 1, #starts
  while low < high do
    local mid = math.floor((low + high + 1) / 2)
    if at_or_before(mid) then
      low = mid
    else
      high = mid - 1
    end
  end
  return low
end

-- ------------------------------------------------------------------ cover

---@param win integer
local function close_cover(win)
  local cover = covers[win]
  covers[win] = nil
  if cover and vim.api.nvim_win_is_valid(cover.win) then
    pcall(vim.api.nvim_win_close, cover.win, true)
  end
end

---The folio text: page number in the middle of the text column, and pages
---left, the time they take at the reader's pace and the book percentage at its
---right edge. What does not fit is dropped from the left of that list, the time
---first: the page number is what a reader looks for.
---(页脚文字：页码在正文列中间；本章剩余页数、按读者速度读完它们要多久、全书百分比靠正文列
--- 右缘。放不下时依次舍去，先舍时间：读者要找的是页码)
---@param win integer
---@param page integer
---@param total integer
---@param remaining integer|nil display cells of text from this page to the chapter end(从这一页到章末的文字量)
---@return string
function M.folio(win, page, total, remaining)
  local width = vim.api.nvim_win_get_width(win)
  local reader = require("weread.reader")
  local page_width = reader.page_width() or 0
  local column = page_width > 0 and math.min(page_width, width) or width
  local margin = require("weread.layout").margin_for(width, column)
  local center = string.format("%d / %d", page, total)
  local info = reader.buffer_info(vim.api.nvim_win_get_buf(win))
  local choices = { "" }
  if info then
    local ok, percent = pcall(function()
      return require("weread.shell").book_percent(info.chapter_index, total > 0 and page / total or 1)
    end)
    local left_pages = total - page
    local pages = left_pages > 0 and string.format("本章剩 %d 页", left_pages) or "本章完"
    local book = string.format("%d%%", ok and percent or 0)
    choices = { pages .. " · " .. book, "" }
    if left_pages > 0 and remaining and remaining > 0 then
      table.insert(choices, 1, pages .. " · " .. require("weread.pace").label(remaining) .. " · " .. book)
    end
  end
  local center_width = vim.fn.strdisplaywidth(center)
  local center_at = margin + math.max(0, math.floor((column - center_width) / 2))
  for _, right in ipairs(choices) do
    local right_width = vim.fn.strdisplaywidth(right)
    local right_at = margin + column - right_width
    if right == "" then
      return string.rep(" ", center_at) .. center
    end
    if right_at >= center_at + center_width + 2 then
      return string.rep(" ", center_at) .. center .. string.rep(" ", right_at - center_at - center_width) .. right
    end
  end
  return string.rep(" ", center_at) .. center
end

---Widest the folio's progress bar gets, in cells.
---(页脚进度条最宽多少格)
local BAR_CELLS = 16

---The progress bar on the folio line, left of the page number, as overlay
---chunks and the column they start at; nil when the bar is off or there is no
---room. With the bookworm on, it sits on the bar where the page is, arched on
---odd pages and stretched out on even ones — a step per page, and still while
---the page is read.
---(页脚行上、页码左边的进度条：返回覆盖用的分段及起始列；进度条关闭或放不下时返回 nil。
--- 开着书虫时，它停在进度条上这一页的位置：奇数页拱起、偶数页伸直——一页一步，读这一页时不动)
---@param win integer
---@param page integer
---@param total integer
---@return table[]|nil chunks
---@return integer|nil col
function M.folio_bar(win, page, total)
  local opts = require("weread.config").get()
  if (opts.layout or {}).progress_bar == false then
    return nil
  end
  local reader = require("weread.reader")
  local info = reader.buffer_info(vim.api.nvim_win_get_buf(win))
  if not info then
    return nil
  end
  local width = vim.api.nvim_win_get_width(win)
  local page_width = reader.page_width() or 0
  local column = page_width > 0 and math.min(page_width, width) or width
  local margin = require("weread.layout").margin_for(width, column)
  local center = string.format("%d / %d", page, total)
  local center_at = margin + math.max(0, math.floor((column - vim.fn.strdisplaywidth(center)) / 2))
  local cells = math.min(BAR_CELLS, center_at - margin - 3)
  if cells < 6 then
    return nil
  end
  local shell = require("weread.shell")
  local fraction = shell.book_fraction(info.chapter_index, total > 0 and page / total or 1)
  local chunks = shell.progress_cells(cells, fraction, shell.chapter_ticks())
  local fx = require("weread.fx")
  if fx.enabled("bookworm") then
    local colors = fx.colors()
    local at = math.max(1, math.min(cells - 2, math.floor(fraction * cells + 0.5) - 1))
    local worm = require("weread.fx_effects").worm_cells(page % 2 == 1 and 1 or 2, colors.accent, { colors.bg, colors.bg, colors.bg })
    for i = 1, 3 do
      chunks[at + i - 1] = worm[i]
    end
  end
  return chunks, margin
end

---Colour a cover like the page around it: the paper margin, or plain Normal
---without a reading theme.
---(把遮罩涂成周围书页的颜色：纸张边距色；没有阅读主题时就是普通的 Normal)
---@param float integer
local function paint(float)
  local page_group = require("weread.theme").current() == "none" and "Normal" or "WereadPaperMargin"
  vim.wo[float].winhighlight = "Normal:" .. page_group .. ",NormalFloat:" .. page_group
end

---Re-colour every cover after the reading theme changed.
---(阅读主题换了之后，重新给所有遮罩上色)
function M.retheme()
  for _, cover in pairs(covers) do
    if vim.api.nvim_win_is_valid(cover.win) then
      paint(cover.win)
    end
  end
end

---Cover the rows below the page and write the folio on the last one.
---(盖住页面下方的行，并在最后一行写上页脚)
---@param win integer
---@param used integer rows the page takes
---@param page integer
---@param total integer
---@param remaining integer|nil display cells of text left in the chapter(本章余下的文字量)
function M.cover(win, used, page, total, remaining)
  local rows = vim.fn.winheight(win)
  if rows < MIN_COVERED_ROWS then
    -- a cover would hide all there is (遮罩会把仅有的几行全盖住)
    close_cover(win)
    return
  end
  local height = math.max(1, rows - math.min(used, rows - 1))
  local width = vim.api.nvim_win_get_width(win)
  -- A `relative = "win"` float is placed in the text area, below the winbar:
  -- adding the winbar's row again put the folio on the statusline.
  -- (`relative = "win"` 的浮窗从正文区算起，在 winbar 之下：再加一次 winbar 的行数，
  --  页脚就落到了状态栏上)
  local row = rows - height
  local cover = covers[win]
  if not cover or not vim.api.nvim_win_is_valid(cover.win) or not vim.api.nvim_buf_is_valid(cover.buf) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local ok, float = pcall(vim.api.nvim_open_win, buf, false, {
      relative = "win",
      win = win,
      row = row,
      col = 0,
      width = width,
      height = height,
      focusable = false,
      style = "minimal",
      noautocmd = true,
      zindex = 20,
    })
    if not ok then
      return
    end
    cover = { win = float, buf = buf }
    covers[win] = cover
  else
    pcall(vim.api.nvim_win_set_config, cover.win, {
      relative = "win",
      win = win,
      row = row,
      col = 0,
      width = width,
      height = height,
    })
  end
  paint(cover.win)
  vim.wo[cover.win].wrap = false
  local lines = {}
  for _ = 1, height - 1 do
    lines[#lines + 1] = ""
  end
  local folio = M.folio(win, page, total, remaining)
  lines[#lines + 1] = folio
  vim.bo[cover.buf].modifiable = true
  vim.api.nvim_buf_set_lines(cover.buf, 0, -1, false, lines)
  vim.bo[cover.buf].modifiable = false
  local namespace = vim.api.nvim_create_namespace("weread.pager")
  vim.api.nvim_buf_clear_namespace(cover.buf, namespace, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, cover.buf, namespace, height - 1, 0, {
    end_col = #folio,
    hl_group = "WereadFooter",
  })
  local bar, bar_col = M.folio_bar(win, page, total)
  if bar then
    pcall(vim.api.nvim_buf_set_extmark, cover.buf, namespace, height - 1, 0, {
      virt_text = bar,
      virt_text_win_col = bar_col,
      hl_mode = "replace",
    })
  end
  -- the last page of a chapter gets its stamp, over the bar
  -- (一章的最后一页盖上印章，压在进度条上)
  pcall(function()
    require("weread.milestone").page_shown(win, page, total)
  end)
end

---The cover of a chapter window, for tests and health checks.
---(章节窗口的遮罩，供测试与自检)
---@param win integer
---@return integer|nil float window
function M.cover_of(win)
  local cover = covers[win]
  return cover and vim.api.nvim_win_is_valid(cover.win) and cover.win or nil
end

---Drop covers whose window is gone or no longer shows a chapter.
---(清掉那些窗口已经不在、或不再显示章节的遮罩)
function M.prune()
  for win in pairs(covers) do
    if not chapter_window(win) or not M.enabled() then
      close_cover(win)
    end
  end
end


-- ------------------------------------------------------------------ moving

---Window state remembered per chapter window: the page on screen (its first
---line and how far into it, the screen `skipcol`) and where the next one starts.
---(每个章节窗口记住的状态：屏幕上这一页（首行，以及读进它多少，即 skipcol），以及下一页从哪里开始)
---@type table<integer, { buf: integer, start: integer, skip: integer, next: integer, next_skip: integer, tick: integer }>
local views = {}

---Where the window's view starts: first line on screen and the screen columns
---of it scrolled away.
---(窗口视图从哪里开始：屏幕上的首行，以及它被滚掉的屏幕列数)
---@param win integer
---@return integer top
---@return integer skip
local function position(win)
  local top = vim.fn.line("w0", win)
  local saved = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  if saved.topline ~= top then
    return top, 0
  end
  return top, saved.skipcol or 0
end

---Byte column of the last character that starts before display column `vcol`.
---(显示列 vcol 之前最后一个字符的字节列)
---@param win integer
---@param line integer
---@param vcol integer
---@return integer
local function col_before(win, line, vcol)
  if vcol <= 0 then
    return 0
  end
  return math.max(0, vim.fn.virtcol2col(win, line, vcol) - 1)
end

---Show the page that starts at `start` (`skip` display columns into it), with
---the cursor on `cursor` at byte column `col`, kept inside the page.
---(显示从 start 开始（读进它 skip 个显示列）的那一页，光标放在 cursor 行的 col 字节列上，并保持在页内)
---@param win integer
---@param start integer
---@param cursor integer|nil defaults to the first line of the page
---@param col integer|nil 0-based byte column; defaults to the start of the page's text
---@param skip integer|nil display columns of `start` read on earlier pages
---@param known { [1]: integer[], [2]: integer[] }|nil `{ starts, skips }` the caller just measured with `M.pages(win)`; saves measuring the whole chapter twice(调用方刚用 M.pages 量好的整章分页，省得再量一遍)
function M.show(win, start, cursor, col, skip, known)
  if not chapter_window(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  start = math.max(1, math.min(start, #lines))
  skip = math.max(0, skip or 0)
  if skip >= line_vcols(win, start) then
    skip = 0
  end
  local next_line, used, next_skip = M.fit(win, start, lines, M.page_rows(win), skip)
  local sliced = next_line == start
  local bottom = sliced and start or math.max(start, next_line - 1)
  cursor = math.max(start, math.min(cursor or start, bottom))
  if col == nil then
    col = cursor == start and col_at(win, start, skip + (skip > 0 and 1 or 0)) or 0
  end
  col = math.max(0, math.min(col, math.max(0, #(lines[cursor] or "") - 1)))
  if cursor == start and (skip > 0 or sliced) then
    -- The cursor has to be on the slice, or the window scrolls back to it. Its
    -- very first column counts as off it: the window resets `skipcol` unless
    -- the cursor is past it.
    -- (光标必须落在这一片上，否则窗口会滚回光标那里。片的第一列也算在片外：光标不越过
    --  skipcol，窗口就会把它重置)
    local first = skip > 0 and col_at(win, start, skip + 1) or col_at(win, start, skip)
    local vcol = vcol_of(win, start, col)
    if vcol < skip or (skip > 0 and vcol == skip) then
      col = first
    elseif sliced and vcol >= next_skip then
      col = math.max(first, col_before(win, start, next_skip))
    end
  end
  moving = true
  local actual = skip
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = start, lnum = cursor, col = col, topfill = 0, skipcol = skip, leftcol = 0 })
    -- validate now, so the state remembered is the one on screen
    -- (立刻校验视图，记下的就是屏幕上的状态)
    vim.fn.winline()
    actual = vim.fn.winsaveview().skipcol or 0
  end)
  moving = false
  -- Pages are not cached across calls on purpose: figures, tables and virtual
  -- text change row heights without bumping `changedtick`, so only a pass the
  -- caller made a moment ago (nothing moved since) may be reused.
  -- (分页不跨调用缓存是有意的：插图、表格、虚拟文本会改行高却不改 changedtick；
  --  只复用调用方刚量过、期间没有任何变动的那一遍)
  local starts, skips
  if known then
    starts, skips = known[1], known[2]
  else
    starts, skips = M.pages(win)
  end
  local page = M.page_of(starts, start, skips, skip)
  views[win] = {
    buf = buf,
    start = start,
    skip = actual,
    next = next_line,
    next_skip = sliced and next_skip or 0,
    tick = vim.api.nvim_buf_get_changedtick(buf),
  }
  -- the page on screen times the one before it, and what is left of the
  -- chapter is what the folio estimates
  -- (屏幕上的这一页给前一页计时；本章余下的部分就是页脚要估计的)
  local pace = require("weread.pace")
  local bottom_line = sliced and start or math.max(start, next_line - 1)
  pace.page_shown(win, buf, start, pace.cells_of(lines, start, bottom_line))
  M.cover(win, used, page, #starts, pace.cells_of(lines, start, #lines))
end

---The remembered view, if it still describes what the window shows.
---(记住的视图——前提是它仍然描述着窗口里显示的东西)
---@param win integer
---@return table|nil
local function current_view(win)
  local view = views[win]
  if not view or view.buf ~= vim.api.nvim_win_get_buf(win) then
    return nil
  end
  local top, skip = position(win)
  if view.start ~= top or view.skip ~= skip then
    return nil
  end
  return view
end

---Last line of the page on screen in a window.
---(窗口里当前这一页的最后一行)
---@param win integer
---@return integer
function M.bottom(win)
  local view = views[win]
  if view and view.start == vim.fn.line("w0", win) then
    return math.max(view.start, view.next - 1)
  end
  return vim.fn.line("w$", win)
end

---Show the page a line is on: the slice of it that holds the cursor column.
---(显示某行所在的那一页：该行里含光标列的那一片)
---@param win integer
---@param line integer
---@param opts table|nil { at_end = boolean, col = integer|nil } col defaults to the cursor's
function M.show_line(win, line, opts)
  opts = opts or {}
  if not chapter_window(win) then
    return
  end
  local starts, skips = M.pages(win)
  if opts.at_end then
    -- arriving from the next chapter: its last page, at its last line
    -- (从下一章回来：最后一页，停在最后一行)
    local last = #starts
    M.show(win, starts[last], vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)), 0, skips[last], { starts, skips })
    return
  end
  local col = opts.col or vim.api.nvim_win_get_cursor(win)[2]
  local text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), line - 1, line, false)[1] or ""
  col = math.max(0, math.min(col, math.max(0, #text - 1)))
  local index = M.page_of(starts, line, skips, vcol_of(win, line, col))
  M.show(win, starts[index], line, col, skips[index], { starts, skips })
end

---`zz`: show a page with the cursor line in the middle of it.
---(`zz`：显示一页，让光标所在行落在这一页的正中)
---
---The native `zz` scrolls the window, and the pager then puts the page that
---holds the cursor back, so it seemed to do nothing. Here the page itself starts
---higher up: whole lines above the cursor line fill half of what is left of the
---page, and turning pages goes on from there.
---(原生的 `zz` 滚动的是窗口，随后分页器又把光标所在的那一页放回来，所以看起来毫无反应。这里
--- 改为让页本身从更靠上的地方开始：光标行上方用完整的行填满页面剩余高度的一半，之后翻页从这里接着翻)
---@param win integer|nil
function M.center(win)
  win = win or vim.api.nvim_get_current_win()
  if not chapter_window(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local line, col = cursor[1], cursor[2]
  local rows = M.page_rows(win)
  local own = M.line_height(win, line, #lines)
  if own >= rows then
    -- taller than the page: it is read in slices, there is no middle to put it in
    -- (比一页还高：它按分片读，没有「正中」可言)
    M.show_line(win, line, { col = col })
    return
  end
  local half = math.floor((rows - own) / 2)
  local start, used = line, 0
  while start > 1 do
    local height = M.line_height(win, start - 1, #lines)
    if used + height > half then
      break
    end
    used = used + height
    start = start - 1
  end
  -- A page never starts on a line that takes no rows: an original hidden under
  -- its translation would be the window's `topline` while showing nothing,
  -- and the window draws the rows above the first shown line from what was on
  -- screen before.
  -- (页首绝不放在不占屏行的行上：藏在译文上方的原文成了窗口的 topline 却什么都不显示，窗口会拿
  --  之前屏幕上的内容去画第一条显示行上面的那些行)
  start = math.min(first_shown(win, lines, start), line)
  -- The page must still hold the cursor line: a heading the fit moves to the
  -- next page would take the cursor with it.
  -- (这一页仍要容得下光标行：被挪到下一页的标题会把光标一起带走)
  local next_line = M.fit(win, start, lines, rows, 0)
  if next_line <= line then
    M.show_line(win, line, { col = col })
  else
    M.show(win, start, line, col, 0)
  end
  -- Redraw the whole window, not the rows the scroll thinks changed: hidden
  -- lines make the scroll's row bookkeeping wrong, and a stale row stays on
  -- screen as a second copy of a line.
  -- (整窗重画，而不是只画滚动认为变了的那些行：被隐藏的行会让滚动的行簿记出错，残留的旧行就成了
  --  某一行在屏幕上的第二份)
  pcall(vim.api.nvim__redraw, { win = win, valid = false, flush = true })
end

---Re-measure the page on screen, e.g. after an illustration loaded or the window
---changed size. The cursor stays where it is.
---(重新量一下屏幕上这一页，例如插图加载完、窗口变了尺寸之后。光标保持不动)
---@param win integer|nil
function M.refresh(win)
  win = win or vim.api.nvim_get_current_win()
  if not M.enabled() or not chapter_window(win) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  M.show_line(win, cursor[1], { col = cursor[2] })
end

---Re-measure every window that shows a chapter, in every tab.
---(重新量一遍所有显示章节的窗口，所有标签页)
function M.refresh_all()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if chapter_window(win) then
      M.refresh(win)
    end
  end
end

---Next page; at the end of the chapter, the next chapter.
---(下一页；到了章末就是下一章)
---@return boolean moved
function M.next()
  local win = vim.api.nvim_get_current_win()
  local reader = require("weread.reader")
  local buf = vim.api.nvim_win_get_buf(win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local top, skip = position(win)
  local next_line, _, next_skip = M.fit(win, top, lines, M.page_rows(win), skip)
  if next_line == top and next_skip > skip then
    -- further into a line taller than the page (继续读比一页还高的那一行)
    M.show(win, top, top, nil, next_skip)
    return true
  end
  next_line = first_shown(win, lines, math.max(next_line, top + 1))
  if next_line > #lines then
    local info = reader.buffer_info(buf)
    require("weread.fx").emit("WereadChapterEnd", { buf = buf, win = win, index = info and info.chapter_index })
    if reader.auto_next() then
      return reader.turn(true)
    end
    return false
  end
  M.show(win, next_line, next_line, 0)
  require("weread.fx").emit("WereadPageTurn", { buf = buf, win = win, forward = true })
  return true
end

---Previous page; at the top of the chapter, the end of the previous one.
---(上一页；到了章首就是上一章的末尾)
---@param opts table|nil { at_bottom = boolean } cursor on the last line of the page(光标放在这一页的最后一行)
---@return boolean moved
function M.prev(opts)
  opts = opts or {}
  local win = vim.api.nvim_get_current_win()
  local reader = require("weread.reader")
  local top, skip = position(win)
  local starts, skips = M.pages(win)
  local index = M.page_of(starts, top, skips, skip)
  if starts[index] == top and skips[index] >= skip then
    -- on a page start: the page before it (正在页首：去前一页)
    index = index - 1
  end
  if index < 1 then
    if reader.auto_next() then
      return reader.turn(false)
    end
    return false
  end
  local target, target_skip = starts[index], skips[index]
  local turned = { buf = vim.api.nvim_win_get_buf(win), win = win, forward = false }
  if not opts.at_bottom then
    M.show(win, target, target, nil, target_skip, { starts, skips })
    require("weread.fx").emit("WereadPageTurn", turned)
    return true
  end
  -- the last line the page shows; in a slice, its last character
  -- (这一页显示的最后一行；分片时是片里的最后一个字符)
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  local next_line = M.fit(win, target, lines, M.page_rows(win), target_skip)
  local sliced = next_line == target
  local bottom = sliced and target or math.max(target, next_line - 1)
  M.show(win, target, bottom, sliced and #(lines[target] or "") or 0, target_skip, { starts, skips })
  require("weread.fx").emit("WereadPageTurn", turned)
  return true
end

---The mouse wheel turns pages, one per burst of notches.
---(滚轮翻页：一串滚动只翻一页)
---@param forward boolean
---@return boolean
function M.wheel(forward)
  local now = vim.uv.now()
  if now - last_wheel < WHEEL_THROTTLE_MS then
    last_wheel = now
    return false
  end
  last_wheel = now
  if forward then
    return M.next()
  end
  return M.prev()
end

---Modes in which the pager keeps its hands off the view: a selection, a pending
---operator, typing, the command line (an incremental search scrolls on its own).
---(分页器不碰视图的模式：选区、等待中的操作符、输入、命令行（增量搜索会自己滚动）)
---@return boolean
local function busy()
  local mode = vim.api.nvim_get_mode().mode
  local first = mode:sub(1, 1)
  if mode:sub(1, 2) == "no" or first == "i" or first == "R" or first == "c" or first == "t" then
    return true
  end
  return first == "v" or first == "V" or first == "\22" or first == "s" or first == "S" or first == "\19"
end

---Is the cursor on the page a view shows?
---(光标在视图显示的这一页上吗？)
---@param win integer
---@param view table
---@param line integer
---@param col integer
---@return boolean
local function on_page(win, view, line, col)
  if view.next == view.start then
    -- a slice: the cursor has to be in it (分片：光标必须在片内)
    if line ~= view.start then
      return false
    end
    local vcol = vcol_of(win, line, col)
    return vcol >= view.skip and vcol < view.next_skip
  end
  if line == view.start and view.skip > 0 and vcol_of(win, line, col) < view.skip then
    -- the earlier slices of the page's first line (这一页首行前面的那些分片)
    return false
  end
  return line >= view.start and line < view.next
end

---Keep the page whole when the cursor leaves it some other way — `j` past the
---last line, a search, `G`: the page that holds the cursor is shown instead.
---The cursor keeps its column, so `n` goes on from the match.
---(光标用别的方式离开这一页时——`j` 越过最后一行、搜索、`G`——改为显示光标所在的那一页，
--- 保持整页。光标列不变，`n` 才能从匹配处接着找)
---@param win integer|nil
function M.follow_cursor(win)
  win = win or vim.api.nvim_get_current_win()
  if moving or not M.enabled() or not chapter_window(win) or busy() then
    return
  end
  local view = current_view(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local line, col = cursor[1], cursor[2]
  if view and on_page(win, view, line, col) then
    return
  end
  if view and view.next ~= view.start and line == view.next then
    -- walking off the bottom of the page lands on the top of the next one
    -- (从页底走下去，落在下一页的顶上)
    local buf = vim.api.nvim_win_get_buf(win)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local start = first_shown(win, lines, line)
    M.show(win, start, math.max(start, line), start == line and col or 0)
    return
  end
  M.show_line(win, line, { col = col })
end

---The window scrolled (WinScrolled). A scroll the pager did not make — `zt`,
---`<C-e>` from another plugin, a search — leaves half a page on screen; put the
---page that holds the cursor back. The pager's own scrolls arrive after it has
---returned, so the state is compared rather than trusting `moving` alone: a
---view that matches what `show()` left is not touched.
---(窗口滚动了（WinScrolled）。不是分页器做的滚动——`zt`、别的插件的 `<C-e>`、搜索——会让屏幕上
--- 只剩半页；把光标所在的那一页放回来。分页器自己的滚动事件在它返回之后才到，所以比较状态，
--- 而不只信 `moving`：与 show() 留下的状态一致的视图不动)
---@param win integer|nil
function M.on_scrolled(win)
  win = win or vim.api.nvim_get_current_win()
  if moving or not M.enabled() or not chapter_window(win) or busy() then
    return
  end
  if current_view(win) then
    return
  end
  local top, skip = position(win)
  local tick = vim.api.nvim_buf_get_changedtick(vim.api.nvim_win_get_buf(win))
  local view = views[win]
  if view and view.drift and view.drift[1] == top and view.drift[2] == skip and view.drift[3] == tick then
    -- re-snapping already ended up here once: the window will not hold the page
    -- (re-snap 一次之后还是这里：窗口留不住这一页，不再反复)
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local bottom = vim.fn.line("w$", win)
  if cursor[1] >= top and cursor[1] <= bottom then
    M.show_line(win, cursor[1], { col = cursor[2] })
  else
    M.show_line(win, top, { col = 0 })
  end
  local after = views[win]
  if after then
    local now_top, now_skip = position(win)
    if now_top ~= after.start or now_skip ~= after.skip then
      after.drift = { now_top, now_skip, tick }
    end
  end
end

---Measure the page once more a moment after a chapter opened, when its
---decorations and illustrations have settled — unless the reader has moved on.
---(章节打开片刻之后、装饰与插图落定时再量一次页——除非读者那时已经翻走了)
---@param win integer
---@param buf integer
---@param top integer w0 right after the chapter was shown(章节刚显示时的 w0)
---@param cursor integer cursor line right after the chapter was shown(章节刚显示时的光标行)
---@param at_end boolean|nil the chapter was entered from the next one(从下一章回来)
function M.resnap(win, buf, top, cursor, at_end)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  if vim.fn.line("w0", win) ~= top then
    return
  end
  local now = vim.api.nvim_win_get_cursor(win)
  if at_end and now[1] == vim.api.nvim_buf_line_count(buf) then
    M.show_line(win, now[1], { at_end = true })
    return
  end
  -- w0 is unchanged, so the cursor is still where the chapter put it, or moved
  -- within the page since: either way it is the line to keep
  -- (w0 没变，光标要么还在章节放它的地方，要么之后只在页内动过：不管哪种都以它为准)
  local line = now[1] > 0 and now[1] or cursor
  M.show_line(win, line, { col = now[2] })
end

return M
