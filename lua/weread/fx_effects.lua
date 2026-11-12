--[[
The effects themselves, played through `weread.fx`: each answers one moment on
the page and is gone within a second, except the loading book, which lasts as
long as the wait it fills.
(效果本身，经由 `weread.fx` 播放：每个只回应书页上的一个时刻，一秒内消失；只有加载中的书本
 例外——它持续的时间就是它所填补的那段等待)
]]

local fx = require("weread.fx")

local M = {}

-- ------------------------------------------------------------------ loading book

---Width of the pixel book and the column of its spine.
---(像素书本的宽度，以及书脊所在的列)
local BOOK_WIDTH, SPINE = 13, 7

---A page being turned, one pose per frame: none, lifting off the right page,
---upright on the spine, landing on the left.
---(正在翻的那一页，每帧一个姿态：没有、从右页掀起、立在书脊上、落向左页)
local LEAVES = { false, { 9, 11 }, { SPINE, SPINE }, { 3, 5 } }

---One frame of the open book, as a grid of colour keys: `p` paper, `l` the
---lines of text on it, `c` the cover, `f` the leaf being turned.
---(打开的书的一帧，用颜色键组成的网格：`p` 纸，`l` 纸上的文字行，`c` 封皮，`f` 正在翻的那页)
---@param pose integer 1..#LEAVES
---@return string[]
function M.book_frame(pose)
  local rows = {}
  for y = 1, 8 do
    rows[y] = {}
    for x = 1, BOOK_WIDTH do
      rows[y][x] = "."
    end
  end
  local function page(first, last)
    for y = 2, 6 do
      for x = first, last do
        rows[y][x] = (y % 2 == 1 and x > first and x < last) and "l" or "p"
      end
    end
  end
  page(2, SPINE - 1)
  page(SPINE + 1, BOOK_WIDTH - 1)
  for x = 1, BOOK_WIDTH do
    rows[7][x] = "c"
  end
  local leaf = LEAVES[pose]
  if leaf then
    for y = 1, 6 do
      for x = leaf[1], leaf[2] do
        rows[y][x] = "f"
      end
    end
  end
  local grid = {}
  for y, row in ipairs(rows) do
    grid[y] = table.concat(row)
  end
  return grid
end

---Wait before the book shows: a chapter from the cache opens faster than this,
---and an animation that flashes for one frame is worse than none.
---(书本出现前的等待：缓存里的章节比这更快就打开了，而只闪一帧的动画比没有更糟)
M.LOADING_DELAY = 150

---Play the loading book in the middle of a window while a chapter is fetched.
---Stop it with `fx.stop` when the chapter is there.
---(在窗口中央播放加载中的书本，直到章节下载完成。章节到了用 `fx.stop` 停掉它)
---@param win integer
---@param label string|nil the line under the book(书本下面的那行字)
---@return table|nil handle
function M.loading(win, label)
  if not fx.enabled("loading") or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  label = label or "正在取回本章…"
  local view
  local width = math.max(BOOK_WIDTH, vim.fn.strdisplaywidth(label))
  return fx.play({
    -- a fetch that hangs is not drawn forever
    -- (卡住的下载不会被一直画下去)
    max_ms = 60000,
    interval = 140,
    delay = M.LOADING_DELAY,
    -- the reader may well keep reading the old page meanwhile
    -- (这段时间读者完全可能还在读旧的那页)
    stop_on_key = false,
    start = function()
      fx.reset_groups()
      local rows = vim.api.nvim_win_get_height(win)
      local cols = vim.api.nvim_win_get_width(win)
      view = fx.float(win, {
        row = math.floor((rows - 5) / 2),
        col = math.floor((cols - width) / 2),
        width = width,
        height = 5,
        zindex = 45,
      })
      if not view then
        error("no room")
      end
    end,
    draw = function(frame)
      if not view or not vim.api.nvim_win_is_valid(view.win) then
        return false
      end
      local colors = fx.colors()
      local mix = require("weread.color").mix
      local inks = {
        p = colors.mark,
        l = colors.muted,
        c = colors.accent,
        f = mix(colors.mark, colors.fg, 0.3),
      }
      local lines, marks = fx.pixels(M.book_frame((frame - 1) % #LEAVES + 1), inks, colors.bg)
      local pad = string.rep(" ", math.floor((width - BOOK_WIDTH) / 2))
      for i, line in ipairs(lines) do
        lines[i] = pad .. line
      end
      for _, mark in ipairs(marks) do
        mark.col = mark.col + #pad
        mark.end_col = mark.end_col + #pad
      end
      local label_pad = string.rep(" ", math.floor((width - vim.fn.strdisplaywidth(label)) / 2))
      lines[#lines + 1] = label_pad .. label
      vim.api.nvim_set_hl(0, "WereadFxLabel", { fg = colors.muted, bg = colors.bg })
      marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #lines[#lines], group = "WereadFxLabel" }
      fx.paint(view, lines, marks)
    end,
    cleanup = function()
      fx.close(view)
    end,
  })
end

-- ------------------------------------------------------------------ ink spread

local INK_NS = vim.api.nvim_create_namespace("weread.fx.ink")

---Frames the ink takes to reach both ends of the passage, then to dry.
---(墨从中间洇到两端所用的帧数，以及之后变干所用的帧数)
local SPREAD_FRAMES, DRY_FRAMES = 7, 4

---The characters a passage covers, as { row (0-based), from_byte, to_byte }.
---(一段文字覆盖的字符，每个是 { 行（从 0 起）, 起始字节, 结束字节 })
---@param buf integer
---@param from integer[] { line (1-based), col (0-based) }
---@param to integer[] same, exclusive(同上，右开)
---@return table[]
function M.passage_chars(buf, from, to)
  if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then
    from, to = to, from
  end
  local chars = {}
  local lines = vim.api.nvim_buf_get_lines(buf, from[1] - 1, to[1], false)
  for offset, text in ipairs(lines) do
    local line = from[1] + offset - 1
    local first = line == from[1] and from[2] or 0
    local last = line == to[1] and to[2] or #text
    local starts = vim.str_utf_pos(text)
    for i, start in ipairs(starts) do
      local byte = start - 1
      local after = (starts[i + 1] or (#text + 1)) - 1
      if byte >= first and byte < last and not text:sub(start, after):match("^%s+$") then
        chars[#chars + 1] = { line - 1, byte, after }
      end
      if #chars >= 4000 then
        return chars
      end
    end
  end
  return chars
end

---Draw a run of characters in one group, a run per line.
---(用一个组画出一段字符，每行一段)
---@param buf integer
---@param chars table[]
---@param first integer
---@param last integer
---@param group string
local function stroke(buf, chars, first, last, group)
  local run = nil
  local function flush()
    if run then
      pcall(vim.api.nvim_buf_set_extmark, buf, INK_NS, run[1], run[2], {
        end_col = run[3],
        hl_group = group,
        priority = 250,
      })
    end
  end
  for i = math.max(1, first), math.min(#chars, last) do
    local char = chars[i]
    if run and run[1] == char[1] then
      run[3] = char[3]
    else
      flush()
      run = { char[1], char[2], char[3] }
    end
  end
  flush()
end

---Ink spreading out from the middle of a new highlight to both ends, then
---drying into the highlight's own rule.
---(墨从新划线的中间向两端洇开，然后干成划线本来的样子)
---@param buf integer
---@param from integer[]
---@param to integer[]
---@return table|nil handle
function M.ink(buf, from, to)
  if not fx.enabled("highlight") or not vim.api.nvim_buf_is_valid(buf) or vim.fn.bufwinid(buf) == -1 then
    return nil
  end
  local chars = M.passage_chars(buf, from, to)
  if #chars == 0 then
    return nil
  end
  local colors = fx.colors()
  local mix = require("weread.color").mix
  local inks = {}
  for i, share in ipairs({ 0.42, 0.3, 0.18, 0.08 }) do
    inks[i] = "WereadFxInk" .. i
    vim.api.nvim_set_hl(0, inks[i], { bg = mix(colors.bg, colors.accent, share) })
  end
  local middle = math.floor((#chars + 1) / 2)
  return fx.play({
    frames = SPREAD_FRAMES + DRY_FRAMES,
    interval = 35,
    draw = function(frame)
      if not vim.api.nvim_buf_is_valid(buf) then
        return false
      end
      vim.api.nvim_buf_clear_namespace(buf, INK_NS, 0, -1)
      if frame <= SPREAD_FRAMES then
        local reach = math.ceil(frame / SPREAD_FRAMES * (#chars / 2 + 1))
        stroke(buf, chars, middle - reach, middle + reach, inks[1])
      else
        stroke(buf, chars, 1, #chars, inks[math.min(#inks, frame - SPREAD_FRAMES)])
      end
    end,
    cleanup = function()
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, INK_NS, 0, -1)
      end
    end,
  })
end

-- ------------------------------------------------------------------ bookmark ribbon

---Pixel rows the ribbon hangs down, and how long it stays before it goes.
---(缎带垂下的像素行数，以及它停留多久再消失)
local RIBBON_PIXELS, RIBBON_HOLD_MS, RIBBON_STEP_MS = 8, 700, 25

---The ribbon `length` pixels long, three pixels wide, with the swallowtail
---notch cut into its last row.
---(长 length 像素、宽 3 像素的缎带，最后一行剪出燕尾缺口)
---@param length integer
---@return string[]
function M.ribbon_grid(length)
  local grid = {}
  for y = 1, RIBBON_PIXELS do
    if y < length then
      grid[y] = "rrr"
    elseif y == length then
      grid[y] = length >= 3 and "r.r" or "rrr"
    else
      grid[y] = "..."
    end
  end
  return grid
end

---A ribbon drops from the top of the page when a bookmark is set, and is pulled
---back up when one is removed.
---(加书签时，一条缎带从页面顶端垂下；删书签时，缎带被抽回去)
---@param win integer
---@param added boolean
---@return table|nil handle
function M.ribbon(win, added)
  if not fx.enabled("bookmark") or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local width = vim.api.nvim_win_get_width(win)
  local reader = require("weread.reader")
  local page_width = reader.page_width() or 0
  local column = page_width > 0 and math.min(page_width, width) or width
  local margin = require("weread.layout").margin_for(width, column)
  local view
  local hold = math.floor(RIBBON_HOLD_MS / RIBBON_STEP_MS)
  return fx.play({
    frames = RIBBON_PIXELS + (added and hold or 0),
    interval = RIBBON_STEP_MS,
    start = function()
      fx.reset_groups()
      view = fx.float(win, {
        row = 0,
        col = math.max(0, margin + column - 4),
        width = 3,
        height = RIBBON_PIXELS / 2,
        zindex = 46,
      })
      if not view then
        error("no room")
      end
    end,
    draw = function(frame)
      if not view or not vim.api.nvim_win_is_valid(view.win) then
        return false
      end
      local length = added and math.min(frame, RIBBON_PIXELS) or (RIBBON_PIXELS - frame)
      local colors = fx.colors()
      local lines, marks = fx.pixels(M.ribbon_grid(length), { r = colors.accent }, colors.bg)
      fx.paint(view, lines, marks)
    end,
    cleanup = function()
      fx.close(view)
    end,
  })
end

-- ------------------------------------------------------------------ bookworm

---The bookworm on the progress bar, two poses that alternate with every page
---turn: arched, then stretched out — an inchworm, a step per page.
---(进度条上的书虫，两种姿态随每次翻页交替：拱起、再伸直——一只尺蠖，一页一步)
local WORM = {
  { ".x.", "x.x" },
  { "...", "xxx" },
}

---Cells of the worm in a pose, ready for a statusline string: each is a `▀` with
---its own top and bottom colour.
---(某个姿态下书虫的字符格，可直接拼进状态栏字符串：每个都是带上下两种颜色的 `▀`)
---@param pose integer 1 or 2
---@param ink string worm colour(书虫的颜色)
---@param under string[] colour under each of the three cells(三个格子底下的颜色)
---@return { [1]: string, [2]: string }[] { char, group }
function M.worm_cells(pose, ink, under)
  local shape = WORM[pose] or WORM[1]
  local cells = {}
  for x = 1, 3 do
    local top = shape[1]:sub(x, x) == "x" and ink or under[x]
    local bottom = shape[2]:sub(x, x) == "x" and ink or under[x]
    cells[x] = { "▀", fx.pixel_group(top, bottom) }
  end
  return cells
end

return M
