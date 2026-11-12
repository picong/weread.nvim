--[[
Page geometry for the reading window.

A book page is a text column with margins on both sides, not text running from
one edge of the screen to the other. In a terminal that is three numbers:
(书页是两侧留白的正文列，而不是从屏幕一边排到另一边的文字。在终端里就是三个数字：)

* `page_width` — how wide the text column is, in cells(正文列宽，单位单元格)
* `margin`     — how far it is inset from the window edges(离窗口两边多远)
* `statuscolumn` — the option that actually creates the left inset(真正做出左边距的选项)

`statuscolumn` is what makes this possible: it reserves real columns to the left
of the text area, and Neovim repeats it on *every* screen line of a long line,
so a wrapped paragraph keeps its margin. The width is written as literal spaces
rather than an expression, so Neovim does not evaluate anything per line.
(statuscolumn 是这件事得以成立的关键：它在文本区左侧真正占出若干列，而且长行折行后
 的**每一屏行**都会带上它，因此折行的段落仍然保持边距。宽度直接写成空格字面量而不是
 表达式，这样 Neovim 不必逐行求值)

The page width is clamped to the window: a page that touches an edge is not a
page, and a narrow terminal is better served by the full width than by a column
two characters wide.
(版心宽度会按窗口夹紧：贴住边缘的「页」不算页，而窄终端用满宽也好过一个只有两个字的列)
]]

local M = {}

---Defaults, also merged into `weread.config.defaults.layout`.
---(默认值，同时会并入 weread.config.defaults.layout)
M.defaults = {
  ---Text column width, in Chinese characters. 0 disables the page layout.
  ---(正文列宽，单位为汉字；0 表示关闭版心排版)
  page_chars = 26,
  ---Let the page follow the window width instead of a fixed number of
  ---characters. (让版心随窗口宽度浮动，而不是固定字数)
  adaptive = false,
}

---Bounds of an adaptive page, in characters a line.
---(自适应版心的上下限，单位为每行字数)
M.MIN_CHARS = 17
M.MAX_CHARS = 40

---Bounds of a line length chosen at runtime, in characters, and the step `+`/`-`
---take. Line-length studies on screens put the comfortable range at 50-75 Latin
---characters (25-38 Chinese ones); the range here is wider on purpose, it is the
---reader's call.
---(运行时可选的行宽上下限（单位汉字）与 `+`/`-` 每次的步长。屏幕行长研究给出的舒适区间是
--- 50-75 个拉丁字符（25-38 个汉字）；这里有意放宽，最终由读者决定)
M.CHOSEN_MIN = 12
M.CHOSEN_MAX = 60
M.STEP = 2

---Clamp a line length a reader asked for.
---(把读者要求的行宽夹到允许范围内)
---@param chars integer
---@return integer
function M.clamp_chars(chars)
  return math.max(M.CHOSEN_MIN, math.min(M.CHOSEN_MAX, math.floor(chars)))
end

---@return table { enabled, page_chars, adaptive }
function M.config()
  local opts = require("weread.config").get().layout or {}
  local page_chars = tonumber(opts.page_chars)
  if page_chars == nil then
    page_chars = M.defaults.page_chars
  end
  return {
    enabled = page_chars > 0,
    page_chars = page_chars,
    adaptive = opts.adaptive == true,
  }
end

---Width of the text column for a window width, in cells. 0 means "no page".
---(给定窗口宽度下正文列的宽度，单位单元格。0 表示不做版心排版)
---
---Kept as a pure function of the column count so the arithmetic can be tested
---without a GUI: in `--headless` Neovim there is no screen, and window widths
---cannot be set(把它写成「列数的纯函数」，这样不用图形界面也能测算法：在 --headless 的 Neovim 里
--- 没有屏幕，窗口宽度改不动)
---@param columns integer window width in cells(窗口宽度，单位单元格)
---@param config_layout table|nil pre-read config, to avoid re-reading it per call
---@return integer
function M.page_width_for(columns, config_layout)
  local layout = config_layout or M.config()
  if not layout.enabled or columns < 30 then
    -- Below this there is no page left after two margins: use the whole window.
    -- (比这更窄就剩不下什么页面了：直接用满窗口)
    return 0
  end
  local wanted = layout.page_chars * 2
  if layout.adaptive then
    -- round to an even number of cells, so two-cell characters line up
    -- (取偶数格，让两格宽的汉字对齐)
    wanted = math.floor(columns * 0.6 / 2) * 2
    -- held between 17 and 40 characters a line, the range Chinese body text
    -- is set in (clreq §7.1.1): a wide monitor must not make a 60-character line
    -- (夹在每行 17 到 40 字之间，即中文正文的排版区间（clreq §7.1.1）：宽屏不该排出 60 字的长行)
    wanted = math.max(M.MIN_CHARS * 2, math.min(wanted, M.MAX_CHARS * 2))
  end
  -- four cells of slack, so the last character of the page still fits
  -- (留四格余量，让版心最后一格仍然放得下汉字)
  return math.min(wanted, columns - 4)
end

---@param win integer|nil window number, 0 or nil for the current one(窗口号，0 或 nil 表示当前窗口)
---@param config_layout table|nil pre-read config, to avoid re-reading it per call
---@return integer
function M.page_width(win, config_layout)
  win = M.window(win)
  if not win then
    return 0
  end
  return M.page_width_for(vim.api.nvim_win_get_width(win), config_layout)
end

---Resolve a window number: 0 and nil mean the current window, and anything
---that is not a window means "no page at all".
---(解析窗口号：0 与 nil 表示当前窗口，不是窗口的则视为「没有版心」)
---@param win integer|nil
---@return integer|nil
function M.window(win)
  if not win or win == 0 then
    win = vim.api.nvim_get_current_win()
  end
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  return win
end

---@param columns integer
---@param page_width integer
---@return integer cells
function M.margin_for(columns, page_width)
  if not page_width or page_width <= 0 then
    return 0
  end
  return math.max(0, math.floor((columns - page_width) / 2))
end

---@param win integer|nil window number, 0 or nil for the current one
---@param page_width integer
---@return integer cells
function M.margin(win, page_width)
  win = M.window(win)
  if not win then
    return 0
  end
  return M.margin_for(vim.api.nvim_win_get_width(win), page_width)
end

---`statuscolumn` value that insets the text by the margin.
---(把正文按边距内缩的 statuscolumn 值)
---@param columns integer window width in cells(窗口宽度)
---@param page_width integer
---@return string
function M.statuscolumn_for(columns, page_width)
  local pad = M.margin_for(columns, page_width)
  if pad <= 0 then
    return ""
  end
  return "%#WereadMargin#" .. string.rep(" ", pad)
end

---@param win integer|nil window number, 0 or nil for the current one
---@param page_width integer
---@return string
function M.statuscolumn(win, page_width)
  win = M.window(win)
  if not win then
    return ""
  end
  return M.statuscolumn_for(vim.api.nvim_win_get_width(win), page_width)
end

---Apply the page layout to a window: the left inset, nothing else. Right
---margin comes from the rendered line width.
---(把版心排版施加到窗口：只设置左边距，右边距由渲染出的行宽决定)
---@param win integer|nil window number, 0 or nil for the current one
---@param page_width integer|nil
---@return integer page_width actually applied(实际施加的版心宽度)
function M.apply(win, page_width)
  win = M.window(win)
  if not win then
    return 0
  end
  page_width = page_width or M.page_width(win)
  -- Written only when it changes: every assignment invalidates the window's
  -- text offset until the next redraw, and pages measured in between come out
  -- for a window without margins.
  -- (只在值变化时写：每次赋值都会让窗口的正文偏移失效到下一次重绘为止，期间量出来的页
  --  就是按没有边距的窗口算的)
  local value = M.statuscolumn(win, page_width)
  if vim.wo[win].statuscolumn ~= value then
    vim.api.nvim_set_option_value("statuscolumn", value, { scope = "local", win = win })
    pcall(vim.api.nvim__redraw, { win = win, valid = true })
  end
  return page_width
end

return M
