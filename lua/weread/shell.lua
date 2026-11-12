--[[
The reading shell: what the window around the text does while a chapter is on
screen.
(阅读外壳：章节在屏幕上时，正文之外的那一圈窗口做什么)

A chapter is displayed in a normal Neovim window, so everything a book page does
not have — a statusline full of file paths, a blinking block cursor, a mouse
wheel that jumps three lines — has to be taken away while reading, and put back
afterwards. The values are saved on the way in and restored on the way out, and
never applied twice, because these are *global* options that other windows share.
(章节显示在普通的 Neovim 窗口里，因此书页上不该有的东西——写满文件路径的状态栏、闪烁
 的块光标、一次跳三行的滚轮——都要在阅读时收起来，之后放回去。这些是**全局**选项，
 其它窗口共用，因此进出时成对保存与恢复，且不会重复施加)

`laststatus = 0` hides the statusline entirely; the reading progress lives in the
winbar instead, which is where the app shows the book title.
(laststatus = 0 把状态栏整个藏起来；阅读进度改放在 winbar 上，也就是 App 显示书名的地方)

The cursor stays visible by default (`layout.cursor = "block"`, a block in the
palette's accent colour): a reader needs to see where they are and how far `j`
will take them. `"hidden"` is still there for
anyone who wants a bare page — it works through `blend = 100` on the cursor
highlight group, which Neovim turns into the terminal's "hide cursor" sequence
(in a TUI the cursor's *colours* from 'guicursor' are ignored).
(光标默认保留（`layout.cursor = "block"`，强调色方块）：读者需要看清自己在哪里、再按一下 j 会到哪。
 想要一张干净的页面可以设 `"hidden"`——它靠光标高亮组的 `blend = 100` 实现，Neovim 会把
 它变成终端的「隐藏光标」序列（TUI 会忽略 'guicursor' 里光标自己的颜色）)
]]

local M = {}

---Global options the shell takes over, with the values it found there.
---(外壳接管的全局选项，以及接管时它们的原值)
local saved = nil

---@return table
local function config()
  local layout = require("weread.config").get().layout or {}
  return {
    -- "off" hides the statusline, "window" gives the chapter window its own
    -- progress line, "keep" leaves the editor's statusline alone
    -- ("off" 藏起状态栏，"window" 给章节窗口一条自己的进度行，"keep" 不动编辑器的状态栏)
    statusline = layout.statusline or "off",
    cursor = layout.cursor or "block",
    mousescroll = layout.mousescroll or "ver:1,hor:1",
  }
end

---@return boolean is a chapter on screen(屏幕上是否是章节)
local function in_chapter()
  return require("weread.reader").buffer_info() ~= nil
end

---Define the highlight group that hides the cursor.
---(定义那个让光标消失的高亮组)
function M.define_highlights()
  -- blend = 100 is what makes Neovim emit the terminal's hide-cursor sequence
  -- (blend = 100 是让 Neovim 发出终端「隐藏光标」序列的关键)
  vim.api.nvim_set_hl(0, "WereadCursorHidden", { blend = 100, default = true })
  -- the reading cursor before a palette paints it: the editor's own colours
  -- (配色给它上色之前的阅读光标：沿用编辑器自己的颜色)
  vim.api.nvim_set_hl(0, "WereadCursor", { link = "Cursor", default = true })
end

---Take over the global options for reading.
---(接管阅读所需的全局选项)
---
---The original values are saved once, but the reading values are applied every
---time: a config change while a chapter is on screen (statusline mode, cursor)
---only reaches the editor through the next window event, and re-applying is what
---makes it arrive without closing the book.
---(原值只存一次，而阅读时的值每次都重新施加：屏幕上有章节时改配置（状态栏模式、光标）
--- 只能经由下一次窗口事件生效，而重新施加正是让它不必关掉书本就生效的原因)
function M.enter()
  if not in_chapter() then
    return
  end
  local opts = config()
  saved = saved
    or {
      laststatus = vim.o.laststatus,
      guicursor = vim.o.guicursor,
      mousescroll = vim.o.mousescroll,
      ruler = vim.o.ruler,
    }
  if opts.statusline == "off" then
    vim.o.laststatus = 0
    -- With no statusline to live in, 'ruler' moves to the message line, where
    -- it becomes the only piece of editor chrome left on the page.
    -- (没有状态栏可待时，'ruler' 会跑到消息行上，成为页面上唯一的编辑器痕迹)
    vim.o.ruler = false
  elseif opts.statusline == "window" then
    -- a statusline of its own per window; with the editor's global statusline
    -- (laststatus = 3) a window-local one would never be shown
    -- (每个窗口自己的状态栏；若编辑器用的是全局状态栏（laststatus = 3），窗口级的
    --  永远显示不出来)
    vim.o.laststatus = 2
    vim.o.ruler = saved.ruler
  else
    vim.o.laststatus = saved.laststatus
    vim.o.ruler = saved.ruler
  end
  if opts.cursor == "hidden" then
    vim.o.guicursor = "a:block-WereadCursorHidden"
  elseif opts.cursor == "block" then
    -- A block in the palette's accent: a thin bar gets lost between Chinese
    -- characters, and reading along with the cursor needs it found at a glance.
    -- In a TUI the group's background becomes the terminal cursor's colour.
    -- (调色板强调色的方块：细竖线夹在汉字之间很难找，而跟着光标读需要一眼就看到它。
    --  TUI 里该组的背景色会成为终端光标的颜色)
    vim.o.guicursor = (saved.guicursor ~= "" and (saved.guicursor .. ",") or "") .. "n:block-WereadCursor"
  elseif opts.cursor == "bar" then
    -- later entries win for the same mode, so visual and insert keep their shapes
    -- (同一模式后写的项生效，因此可视与插入模式保持原样)
    vim.o.guicursor = (saved.guicursor ~= "" and (saved.guicursor .. ",") or "") .. "n:ver25"
  else
    vim.o.guicursor = saved.guicursor
  end
  vim.o.mousescroll = opts.mousescroll
  if opts.statusline == "window" then
    local ok, reader = pcall(require, "weread.reader")
    if ok then
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if reader.buffer_info(buf) then
          vim.api.nvim_set_option_value("statusline", M.statusline(), { scope = "local", win = win })
        end
      end
    end
  end
end

---Put everything back. Idempotent.
---(把一切都放回去。幂等)
function M.leave()
  if not saved then
    return
  end
  vim.o.laststatus = saved.laststatus
  vim.o.guicursor = saved.guicursor
  vim.o.mousescroll = saved.mousescroll
  vim.o.ruler = saved.ruler
  saved = nil
end

---@return boolean
function M.active()
  return saved ~= nil
end

---Percentage of the book a chapter sits at, by word count where the catalog has
---it and by chapter count otherwise.
---(这一章位于全书的百分之几：目录有字数的按字数算，否则按章数算)
---
---Without `fraction` the chapter counts as read to its end (the winbar's
---"where this chapter takes you"); with it, only that share of the chapter
---counts, which is what a progress report should say.
---(不给 `fraction` 时整章算读完（winbar 显示「读完这一章到哪」）；给了就只算这一章的那一部分，
--- 进度上报要的正是这个)
---@param index integer|nil
---@param fraction number|nil share of the chapter read, 0..1(本章已读比例)
---@return integer
function M.book_percent(index, fraction)
  local reader = require("weread.reader")
  if not index then
    return 0
  end
  local chapters = (reader.state.catalog or {}).chapters or {}
  if #chapters == 0 then
    return 0
  end
  local share = fraction and math.max(0, math.min(1, fraction)) or 1
  local total, reached = 0, 0
  for position, chapter in ipairs(chapters) do
    local words = tonumber(chapter.wordCount) or 0
    total = total + words
    if position < index then
      reached = reached + words
    elseif position == index then
      reached = reached + words * share
    end
    if position == index and words == 0 then
      -- a cover or divider entry: fall back to the chapter count for it
      -- (封面或分隔页：对它退回按章数估算)
      reached = reached + share
      total = total + 1
    end
  end
  if total <= 0 then
    local position, count = reader.position_of(index)
    if fraction then
      return math.min(100, math.floor((position - 1 + share) / count * 100))
    end
    return count > 1 and math.floor((position - 1) / (count - 1) * 100) or 0
  end
  return math.min(100, math.floor(reached / total * 100))
end

---How far into the book a point of a chapter is, 0..1, by word count — the
---unrounded `book_percent`, for drawing.
---(某章的某一点位于全书多远处，0..1，按字数计——即未取整的 book_percent，供绘制用)
---@param index integer|nil
---@param fraction number|nil share of the chapter read, 0..1(本章已读比例)
---@return number
function M.book_fraction(index, fraction)
  local reader = require("weread.reader")
  local chapters = (reader.state.catalog or {}).chapters or {}
  if not index or #chapters == 0 then
    return 0
  end
  local share = fraction and math.max(0, math.min(1, fraction)) or 1
  local total, reached = 0, 0
  for position, chapter in ipairs(chapters) do
    local words = math.max(tonumber(chapter.wordCount) or 0, 0)
    total = total + words
    if position < index then
      reached = reached + words
    elseif position == index then
      reached = reached + words * share
    end
  end
  if total <= 0 then
    local position, count = reader.position_of(index)
    return count > 0 and math.min(1, (position - 1 + share) / count) or 0
  end
  return math.min(1, reached / total)
end

---Where the top level chapters start, as fractions of the book: the ticks on the
---folio's progress bar. The first chapter (at 0) has no tick.
---(顶层章节的起点在全书的位置（比例）：页脚进度条上的刻度。第一章（位于 0）没有刻度)
---@return number[]
function M.chapter_ticks()
  local reader = require("weread.reader")
  local chapters = (reader.state.catalog or {}).chapters or {}
  local top = math.huge
  local total = 0
  for _, chapter in ipairs(chapters) do
    top = math.min(top, math.max(math.floor(tonumber(chapter.level) or 1), 1))
    total = total + math.max(tonumber(chapter.wordCount) or 0, 0)
  end
  local ticks = {}
  if total <= 0 then
    return ticks
  end
  local reached = 0
  for _, chapter in ipairs(chapters) do
    local level = math.max(math.floor(tonumber(chapter.level) or 1), 1)
    if level == top and reached > 0 then
      ticks[#ticks + 1] = reached / total
    end
    reached = reached + math.max(tonumber(chapter.wordCount) or 0, 0)
  end
  return ticks
end

---Cells of a progress bar `width` cells wide, as { text, group } chunks: braille
---dots along the bottom of the cell, two to a cell so the bar moves in half
---cells, the read part in the accent, chapter starts raised as ticks.
---(宽 width 格的进度条，按 { 文字, 组 } 分段：沿字符格底部排的盲文点，每格两个点，因此进度以
--- 半格为单位前进；读过的部分用强调色，章节起点竖起来当刻度)
---@param width integer
---@param fraction number 0..1
---@param ticks number[]|nil
---@return { [1]: string, [2]: string }[]
function M.progress_cells(width, fraction, ticks)
  local dots = math.floor(math.max(0, math.min(1, fraction)) * width * 2 + 0.5)
  local marked = {}
  -- ticks only where they can be told apart (刻度只在分得清时才画)
  if ticks and #ticks > 0 and #ticks <= width / 3 then
    for _, at in ipairs(ticks) do
      local cell = math.floor(at * width) + 1
      if cell >= 1 and cell <= width then
        marked[cell] = true
      end
    end
  end
  local cells = {}
  for cell = 1, width do
    local done = math.max(0, math.min(2, dots - (cell - 1) * 2))
    local text
    if marked[cell] then
      -- a dot column raised on the left of the cell (格子左侧竖起的一列点)
      text = done == 0 and "⡇" or "⣇"
    else
      text = done == 1 and "⡀" or "⣀"
    end
    local group = done > 0 and "WereadPaperBarDone" or "WereadPaperBarTodo"
    if marked[cell] and done == 0 then
      group = "WereadPaperBarTick"
    end
    cells[cell] = { text, group }
  end
  return cells
end

---The progress text a book page shows: chapter, position in the book, percent.
---(书页上的进度文字：章节、全书位置、百分比)
---@param index integer|nil
---@return string|nil nil when the current buffer is not a chapter
function M.status(index)
  local reader = require("weread.reader")
  local info = reader.buffer_info()
  if not info then
    return nil
  end
  index = index or info.chapter_index
  local position, total = reader.position_of(index)
  local chapter = ((reader.state.catalog or {}).chapters or {})[index]
  local title = chapter and chapter.title or info.chapter_title or ""
  local prefix = info.title and (info.title .. " · ") or ""
  return string.format("%s%s  %d/%d · %d%%", prefix, title, position, total, M.book_percent(index))
end

---Window-local statusline for a chapter window: the reading progress, escaped
---for use in a 'statusline' value.
---(章节窗口的窗口级状态栏：阅读进度，并按 'statusline' 的转义规则处理)
---@return string
function M.statusline()
  local text = M.status()
  if not text then
    return ""
  end
  local group = require("weread.theme").winbar_highlight()
  -- only the text is escaped: the `%#group#` prefix is a real statusline item
  -- (只转义文本：`%#组#` 前缀是真正的状态栏语法)
  local body = (text:gsub("%%", "%%%%"))
  if group ~= "" then
    return "%#" .. group .. "# " .. body .. " "
  end
  return body
end

---An lualine component, for readers who keep their statusline.
---(给保留状态栏的人用的 lualine 组件)
---@return string
function M.lualine_component()
  local reader = require("weread.reader")
  local info = reader.buffer_info()
  if not info then
    return ""
  end
  return M.status(info.chapter_index) or ""
end

return M
