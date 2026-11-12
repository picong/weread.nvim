--[[
Tests for weread.pager: pages of whole lines, the cover below them, the folio,
and page turns that never show a line twice or skip one.
(pager 单测：由完整行组成的页、页下的遮罩、页脚，以及不会重复显示也不会跳过任何一行的翻页)

Headless Neovim does have a screen grid: `vim.o.lines`/`columns` take effect
and `screenstring` reads back what was drawn after `redraw!`.
(无界面 Neovim 也有屏幕网格：vim.o.lines/columns 会生效，`redraw!` 之后 screenstring 能读回画出的内容)
]]

local config = require("weread.config")
local pager = require("weread.pager")
local reader = require("weread.reader")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
config.setup({ data_dir = tmpdir, keymaps = false, sync_interval = 0 })

local saved_lines, saved_columns = vim.o.lines, vim.o.columns

---A buffer that passes for a chapter, with the given lines.
---(一个能冒充章节的 buffer)
---@param lines string[]
---@return integer buf
local function chapter(lines)
  vim.o.lines = 24
  vim.o.columns = 80
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.b[buf].weread = { book_id = "B", chapter_index = 1, chapter_key = "0001", chapter_uid = "1" }
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = true
  vim.wo.scrolloff = 0
  vim.wo.winbar = ""
  return buf
end

local function numbered(count)
  local lines = {}
  for index = 1, count do
    lines[index] = "line " .. index
  end
  return lines
end

local function cleanup(buf)
  pager.prune()
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  vim.o.lines, vim.o.columns = saved_lines, saved_columns
end

describe("pager", function()
  it("cuts a chapter into pages of whole lines", function()
    local buf = chapter(numbered(100))
    local win = vim.api.nvim_get_current_win()
    local rows = pager.page_rows(win)
    local starts = pager.pages(win)
    eq(starts[1], 1)
    eq(starts[2], rows + 1, "the second page starts right after the first")
    eq(pager.page_of(starts, rows), 1)
    eq(pager.page_of(starts, rows + 1), 2)
    cleanup(buf)
  end)

  it("counts the virtual lines an illustration takes", function()
    local buf = chapter(numbered(100))
    local win = vim.api.nvim_get_current_win()
    local ns = vim.api.nvim_create_namespace("pager_spec")
    local tall = {}
    for _ = 1, 5 do
      tall[#tall + 1] = { { "img" } }
    end
    vim.api.nvim_buf_set_extmark(buf, ns, 2, 0, { virt_lines = tall })
    local starts = pager.pages(win)
    eq(starts[2], pager.page_rows(win) + 1 - 5, "five rows of figure push five lines to the next page")
    cleanup(buf)
  end)

  it("keeps a heading with the text it introduces", function()
    local lines = numbered(60)
    local buf = chapter(lines)
    local win = vim.api.nvim_get_current_win()
    local rows = pager.page_rows(win)
    lines[rows] = "# A heading"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local starts = pager.pages(win)
    eq(starts[2], rows, "the heading opens the next page instead of closing this one")
    cleanup(buf)
  end)

  it("does not leave the last line of a paragraph alone at the top of a page", function()
    local buf = chapter(numbered(60))
    local win = vim.api.nvim_get_current_win()
    local rows = pager.page_rows(win)
    -- one-line paragraphs up to the break, then a three-line paragraph whose
    -- last line is exactly the first line of page two
    -- (分页点之前都是单行段落，接着一个三行的段落，它的末行正好是第二页的首行)
    local lines = {}
    for index = 1, rows - 2 do
      lines[index] = "　　one " .. index
    end
    lines[#lines + 1] = "　　first line of a paragraph"
    lines[#lines + 1] = "its middle line"
    lines[#lines + 1] = "and its last line"
    for index = 1, 30 do
      lines[#lines + 1] = "　　after " .. index
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    truthy(pager.is_widow(lines, rows + 1), "the paragraph end is where the page would break")
    local starts = pager.pages(win)
    eq(starts[2], rows, "the line before the paragraph end goes along")
    falsy(pager.is_widow(lines, starts[2]))
    cleanup(buf)
  end)

  it("never starts a page with a blank line", function()
    local lines = numbered(60)
    local buf = chapter(lines)
    local win = vim.api.nvim_get_current_win()
    local rows = pager.page_rows(win)
    lines[rows + 1] = ""
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local starts = pager.pages(win)
    eq(starts[2], rows + 2)
    cleanup(buf)
  end)

  it("turns pages without repeating or skipping a line", function()
    local buf = chapter(numbered(100))
    local win = vim.api.nvim_get_current_win()
    pager.show(win, 1)
    local seen = { vim.fn.line("w0") }
    for _ = 1, 3 do
      local bottom = pager.bottom(win)
      truthy(pager.next())
      eq(vim.fn.line("w0"), bottom + 1, "the next page starts after the last line shown")
      seen[#seen + 1] = vim.fn.line("w0")
    end
    truthy(pager.prev())
    eq(vim.fn.line("w0"), seen[#seen - 1], "and back again lands on the page before")
    eq(vim.fn.winsaveview().topfill, 0)
    cleanup(buf)
  end)

  it("covers the rows below the page and writes the folio", function()
    -- Floats live on their own grid, which headless screenstring does not read,
    -- so the cover is checked by its geometry and its text.
    -- (浮窗在自己的网格上，无界面的 screenstring 读不到，因此按几何与文字检查遮罩)
    local lines = numbered(100)
    lines[3] = string.rep("长", 60) -- wraps to two rows(折成两行)
    local buf = chapter(lines)
    local win = vim.api.nvim_get_current_win()
    pager.show(win, 1)
    local cover = pager.cover_of(win)
    truthy(cover, "a cover floats over the window")
    local config_ = vim.api.nvim_win_get_config(cover)
    local rows = vim.fn.winheight(win)
    local bottom = pager.bottom(win)
    local used = vim.api.nvim_win_text_height(win, { start_row = 0, end_row = bottom - 1 }).all
    eq(config_.row + config_.height, rows, "it reaches the bottom of the window")
    eq(config_.row, used, "and starts right under the last whole line")
    local folio = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(cover), -2, -1, false)[1]
    local total = #pager.pages(win)
    matches(folio, "1 / " .. total)
    matches(folio, "本章剩 " .. (total - 1) .. " 页")
    falsy(vim.api.nvim_win_get_config(cover).focusable, "the cover never takes the cursor")

    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, true))
    pager.prune()
    falsy(pager.cover_of(win), "leaving the chapter takes the cover away")
    cleanup(buf)
  end)

  it("lands on the page that holds a line", function()
    local buf = chapter(numbered(100))
    local win = vim.api.nvim_get_current_win()
    pager.show_line(win, 50)
    local starts = pager.pages(win)
    eq(vim.fn.line("w0"), starts[pager.page_of(starts, 50)])
    eq(vim.fn.line("."), 50, "with the cursor on the line itself")
    pager.show_line(win, 1, { at_end = true })
    eq(vim.fn.line("w0"), starts[#starts], "arriving from the next chapter: the last page")
    cleanup(buf)
  end)

  it("measures the whole chapter once per show_line and per prev", function()
    local buf = chapter(numbered(100))
    local win = vim.api.nvim_get_current_win()
    local pages = pager.pages
    local calls = 0
    pager.pages = function(...)
      calls = calls + 1
      return pages(...)
    end
    local ok, err = pcall(function()
      pager.show_line(win, 50)
      eq(calls, 1, "show_line hands its pages to show")
      eq(vim.fn.line("w0"), pages(win)[pager.page_of(pages(win), 50)])
      calls = 0
      pager.show_line(win, 1, { at_end = true })
      eq(calls, 1, "arriving at the end measures once too")
      calls = 0
      truthy(pager.prev())
      eq(calls, 1, "prev measures once")
      calls = 0
      truthy(pager.prev({ at_bottom = true }))
      eq(calls, 1, "and so does prev with the cursor at the bottom")
      calls = 0
      pager.show(win, 1)
      eq(calls, 1, "a bare show still measures for itself")
    end)
    pager.pages = pages
    cleanup(buf)
    truthy(ok, tostring(err))
  end)

  it("follows the cursor when a jump leaves the page", function()
    local buf = chapter(numbered(100))
    local win = vim.api.nvim_get_current_win()
    pager.show(win, 1)
    vim.api.nvim_win_set_cursor(win, { 80, 0 })
    pager.follow_cursor(win)
    local starts = pager.pages(win)
    eq(vim.fn.line("w0"), starts[pager.page_of(starts, 80)])
    cleanup(buf)
  end)

  it("turns into the next chapter at the end", function()
    local buf = chapter(numbered(30))
    local win = vim.api.nvim_get_current_win()
    local starts = pager.pages(win)
    pager.show(win, starts[#starts])
    local turned = nil
    local original = reader.turn
    reader.turn = function(forward)
      turned = forward
      return true
    end
    local ok, err = pcall(pager.next)
    reader.turn = original
    truthy(ok, tostring(err))
    eq(turned, true, "the last page hands over to the next chapter")
    cleanup(buf)
  end)

  it("throttles the mouse wheel to one page per burst", function()
    local buf = chapter(numbered(200))
    local win = vim.api.nvim_get_current_win()
    pager.show(win, 1)
    vim.wait(200, function()
      return false
    end)
    pager.wheel(true)
    local after_one = vim.fn.line("w0")
    pager.wheel(true)
    pager.wheel(true)
    eq(vim.fn.line("w0"), after_one, "a burst of notches turns one page")
    cleanup(buf)
  end)

  ---A chapter with one line far taller than the page between short ones.
  ---(短行中间夹着一个远比一页高的行)
  local function tall_chapter()
    local words = {}
    for index = 1, 900 do
      words[index] = string.format("w%04d", index)
    end
    local lines = numbered(40)
    lines[5] = table.concat(words, " ")
    local buf = chapter(lines)
    vim.wo.smoothscroll = true
    vim.wo.linebreak = true
    return buf
  end

  it("reads a line taller than the page in slices", function()
    local buf = tall_chapter()
    local win = vim.api.nvim_get_current_win()
    local rows = pager.page_rows(win)
    local height = vim.api.nvim_win_text_height(win, { start_row = 4, end_row = 4 }).all
    truthy(height > 2 * rows, "the line is more than two pages tall")
    local starts, skips = pager.pages(win)
    local slices = 0
    for index, start in ipairs(starts) do
      if start == 5 then
        slices = slices + 1
        if slices > 1 then
          truthy(skips[index] > skips[index - 1], "every slice is further in")
        end
      end
    end
    truthy(slices >= 3, "a slice per page of screen rows")

    pager.show(win, 1)
    truthy(pager.next())
    eq(vim.fn.line("w0"), 5)
    eq(vim.fn.winsaveview().skipcol, 0, "the line opens at its start")
    local seen = { 0 }
    for _ = 2, slices do
      truthy(pager.next())
      eq(vim.fn.line("w0"), 5, "still the same line")
      local skip = vim.fn.winsaveview().skipcol
      truthy(skip > seen[#seen], "further into it")
      eq(skip, seen[#seen] + rows * vim.api.nvim_win_get_width(win), "a page of screen rows further")
      seen[#seen + 1] = skip
      eq(vim.fn.line("."), 5, "the cursor stays on the slice")
      local folio = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(pager.cover_of(win)), -2, -1, false)[1]
      matches(folio, (1 + #seen) .. " / " .. #starts)
    end
    truthy(pager.next())
    truthy(vim.fn.line("w0") > 5, "past the last slice: the lines after it")
    for index = #seen, 1, -1 do
      truthy(pager.prev())
      eq(vim.fn.line("w0"), 5)
      eq(vim.fn.winsaveview().skipcol, seen[index], "back through the slices one by one")
    end
    truthy(pager.prev())
    eq(vim.fn.line("w0"), 1)
    cleanup(buf)
  end)

  it("lands on the slice that holds the cursor", function()
    local buf = tall_chapter()
    local win = vim.api.nvim_get_current_win()
    local line = vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]
    local col = line:find("w0700", 1, true) - 1
    vim.api.nvim_win_set_cursor(win, { 5, col })
    pager.refresh(win)
    eq(vim.fn.line("w0"), 5)
    truthy(vim.fn.winsaveview().skipcol > 0, "scrolled into the line")
    eq(vim.api.nvim_win_get_cursor(win), { 5, col }, "the cursor did not move")
    local starts, skips = pager.pages(win)
    local index = pager.page_of(starts, 5, skips, vim.fn.winsaveview().skipcol)
    eq(skips[index], vim.fn.winsaveview().skipcol)
    cleanup(buf)
  end)

  it("never stalls on lines that take no rows", function()
    local buf = chapter(numbered(60))
    local win = vim.api.nvim_get_current_win()
    vim.wo.conceallevel = 2
    local ns = vim.api.nvim_create_namespace("pager_spec_conceal")
    for row = 9, 30 do
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { conceal_lines = "" })
    end
    eq(pager.line_height(win, 15, 60), 0, "a concealed line is zero rows tall")
    local starts = pager.pages(win)
    for index = 2, #starts do
      truthy(starts[index] > starts[index - 1], "every page starts further on")
      truthy(starts[index] < 10 or starts[index] > 31, "and never on a concealed line")
    end
    eq(pager.page_of(starts, 60), #starts)
    pager.show(win, 1)
    local turns = 0
    while pager.next() and turns < 100 do
      turns = turns + 1
      if vim.fn.line("w0") >= starts[#starts] then
        break
      end
    end
    truthy(turns < 100, "paging reaches the end")
    eq(vim.fn.line("w0"), starts[#starts])
    cleanup(buf)
  end)

  it("keeps the cursor column when it follows the cursor", function()
    local buf = chapter(numbered(100))
    local win = vim.api.nvim_get_current_win()
    pager.show(win, 1)
    vim.api.nvim_win_set_cursor(win, { 80, 5 })
    pager.follow_cursor(win)
    eq(vim.api.nvim_win_get_cursor(win), { 80, 5 }, "a search match keeps its column")
    pager.show_line(win, 50)
    eq(vim.api.nvim_win_get_cursor(win), { 50, 5 })
    vim.api.nvim_win_set_cursor(win, { 50, 3 })
    pager.refresh(win)
    eq(vim.api.nvim_win_get_cursor(win), { 50, 3 })
    truthy(pager.next())
    eq(vim.api.nvim_win_get_cursor(win)[2], 0, "a page turn starts at the beginning of the page")
    cleanup(buf)
  end)

  it("leaves a selection alone", function()
    local buf = chapter(numbered(100))
    local win = vim.api.nvim_get_current_win()
    pager.show(win, 1)
    local original = vim.api.nvim_get_mode
    vim.api.nvim_get_mode = function()
      return { mode = "v", blocking = false }
    end
    vim.api.nvim_win_set_cursor(win, { 80, 0 })
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! zt")
    end)
    local ok, err = pcall(pager.follow_cursor, win)
    vim.api.nvim_get_mode = original
    truthy(ok, tostring(err))
    eq(vim.fn.line("w0"), 80, "visual mode: the view is the reader's")
    cleanup(buf)
  end)

  it("puts the page back after a scroll it did not make", function()
    local buf = chapter(numbered(100))
    local win = vim.api.nvim_get_current_win()
    pager.show(win, 1)
    local rows = pager.page_rows(win)
    local calls = 0
    local show = pager.show
    pager.show = function(...)
      calls = calls + 1
      return show(...)
    end
    pager.on_scrolled(win)
    eq(calls, 0, "the pager's own scroll is not re-snapped")
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    vim.cmd("normal! zt")
    eq(vim.fn.line("w0"), 5)
    pager.on_scrolled(win)
    pager.show = show
    eq(calls, 1)
    eq(vim.fn.line("w0"), 1, "the page that holds the cursor is back")
    eq(vim.fn.line("."), 5)
    vim.api.nvim_win_set_cursor(win, { rows + 3, 0 })
    vim.cmd("normal! zt")
    pager.on_scrolled(win)
    eq(vim.fn.line("w0"), rows + 1)
    cleanup(buf)
  end)

  it("centres the cursor line on zz", function()
    local buf = chapter(numbered(100))
    local win = vim.api.nvim_get_current_win()
    local rows = pager.page_rows(win)
    pager.show(win, 1)
    vim.api.nvim_win_set_cursor(win, { 40, 0 })
    pager.on_scrolled(win)
    pager.follow_cursor(win)
    pager.center(win)
    local top = vim.fn.line("w0")
    eq(vim.fn.line("."), 40, "the cursor stays on its line")
    eq(top, 40 - math.floor((rows - 1) / 2), "with half a page above it")
    -- and the view holds: the pager does not snap it back
    -- (视图稳住：分页器不会再把它弹回去)
    pager.on_scrolled(win)
    pager.follow_cursor(win)
    eq(vim.fn.line("w0"), top, "the centred page stays")
    -- the next page goes on from there, nothing skipped
    -- (下一页从这里接着翻，不跳行)
    local bottom = pager.bottom(win)
    pager.next()
    eq(vim.fn.line("w0"), bottom + 1)

    -- near the top there is nothing above to fill: the first page
    -- (靠近开头时上面没东西可填：就是第一页)
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    pager.center(win)
    eq(vim.fn.line("w0"), 1)
    eq(vim.fn.line("."), 3)
    cleanup(buf)
  end)

  it("refreshes every chapter window", function()
    local buf = chapter(numbered(100))
    local first = vim.api.nvim_get_current_win()
    pager.show(first, 1)
    vim.cmd("split")
    local second = vim.api.nvim_get_current_win()
    vim.wo[second].scrolloff = 0
    pager.show(second, 1)
    vim.api.nvim_win_call(first, function()
      vim.api.nvim_win_set_cursor(first, { 70, 0 })
      vim.cmd("normal! zt")
    end)
    pager.refresh_all()
    local starts = pager.pages(first)
    eq(vim.fn.line("w0", first), starts[pager.page_of(starts, 70)], "not only the current window")
    vim.cmd("close")
    cleanup(buf)
  end)

  it("gives a window too short for a folio no cover", function()
    local buf = chapter(numbered(100))
    vim.cmd("split")
    local win = vim.api.nvim_get_current_win()
    vim.wo[win].scrolloff = 0
    for _, height in ipairs({ 1, 2 }) do
      vim.api.nvim_win_set_height(win, height)
      eq(pager.page_rows(win), height, "the whole window is the page")
      pager.show(win, 1)
      falsy(pager.cover_of(win), "nothing covers the text")
      truthy(pager.next())
      eq(vim.fn.line("w0", win), height + 1, "and pages turn by whole lines")
    end
    vim.api.nvim_win_set_height(win, 3)
    eq(pager.page_rows(win), 2)
    pager.show(win, 1)
    truthy(pager.cover_of(win), "three rows have room for the folio")
    vim.cmd("close")
    cleanup(buf)
  end)

  it("snaps again once the chapter settles, unless the reader moved on", function()
    local buf = chapter(numbered(100))
    local win = vim.api.nvim_get_current_win()
    pager.show_line(win, 50)
    local top = vim.fn.line("w0")
    pager.resnap(win, buf, top, 50, false)
    eq(vim.fn.line("w0"), top)
    eq(vim.fn.line("."), 50)
    pager.show_line(win, 100, { at_end = true })
    top = vim.fn.line("w0")
    vim.api.nvim_win_set_cursor(win, { top, 0 })
    pager.resnap(win, buf, top, 100, true)
    eq(vim.fn.line("."), top, "a cursor that left the last line is not sent back")
    pager.show(win, 1)
    pager.resnap(win, buf, top, 100, true)
    eq(vim.fn.line("w0"), 1, "the reader turned the page: nothing happens")
    cleanup(buf)
  end)

  it("re-colours covers when the theme changes", function()
    local buf = chapter(numbered(100))
    local win = vim.api.nvim_get_current_win()
    pager.show(win, 1)
    local theme = require("weread.theme")
    local current = theme.current
    theme.current = function()
      return "none"
    end
    pager.retheme()
    local highlight = vim.wo[pager.cover_of(win)].winhighlight
    matches(highlight, "Normal:Normal")
    theme.current = function()
      return "paper"
    end
    pager.retheme()
    matches(vim.wo[pager.cover_of(win)].winhighlight, "WereadPaperMargin")
    theme.current = current
    cleanup(buf)
  end)

  it("places the cover in the text area when the window has a winbar", function()
    local buf = chapter(numbered(100))
    local win = vim.api.nvim_get_current_win()
    vim.wo[win].winbar = "BAR"
    pager.show(win, 1)
    local cover = pager.cover_of(win)
    truthy(cover)
    local placed = vim.api.nvim_win_get_config(cover)
    eq(placed.row + placed.height, vim.fn.winheight(win), "rows are counted from the text area, not the winbar")
    vim.wo[win].winbar = ""
    cleanup(buf)
  end)
end)

describe("pager zz with the originals hidden", function()
  it("never starts the page on a hidden original", function()
    local lines = {}
    local hidden = {}
    for i = 1, 60 do
      lines[#lines + 1] = "original " .. i
      hidden[#hidden + 1] = #lines - 1
      lines[#lines + 1] = "　　译文 " .. i
    end
    local buf = chapter(lines)
    vim.wo.conceallevel = 2
    require("weread.inline").render_originals(buf, hidden, true)
    local win = vim.api.nvim_get_current_win()
    local hidden_line = {}
    for _, value in ipairs(hidden) do
      hidden_line[value + 1] = true
    end
    for cursor = 10, 110, 7 do
      local line = cursor % 2 == 0 and cursor or cursor + 1
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      pager.center(win)
      local top = vim.fn.line("w0", win)
      falsy(hidden_line[top], "the page starts on a shown line, not on " .. top)
      eq(vim.api.nvim_win_get_cursor(win)[1], line, "the cursor stays")
    end
    cleanup(buf)
  end)
end)
