--[[
Small pixel animations around the page: they mark a moment (a chapter being
fetched, a bookmark set, a passage highlighted) and then get out of the way.
(书页周围的小像素动画：标记某个时刻——章节在下载、加了书签、划了一段——然后立刻让开)

The rules every effect here keeps, because the page is for reading:
(这里的每个效果都守着这些规矩，因为书页是用来读的)

* Nothing moves once the page has settled: an effect plays at a change of state
  and ends within a second, or plays while the reader is away.
  (书页停稳之后不再有东西在动：效果只在状态改变的那一刻播放、一秒内结束，或者在读者不在时播放)
* Nothing is written into the chapter buffer: effects draw in floats of their
  own or in extmarks of their own namespace that take no room (no virtual
  lines, no inline text), so pages are measured exactly as before and the
  offset map of the highlights stays true.
  (绝不写进章节 buffer：效果画在自己的浮窗里，或画在自己命名空间、不占位置的 extmark 里（没有
   虚拟行、没有行内文本），因此分页量出来与原来完全一样，划线依赖的偏移映射也不受影响)
* Any key stops every effect at once, and a headless editor or
  `animations.enabled = false` (or `vim.g.weread_animations = false`, or
  snacks' `vim.g.snacks_animate = false`) turns them all off.
  (任意按键立刻停掉所有效果；无界面编辑器、`animations.enabled = false`（或
   `vim.g.weread_animations = false`、snacks 的 `vim.g.snacks_animate = false`）全部关闭)

Pixels are half blocks: `▀` with the upper pixel as the foreground and the lower
one as the background gives two square-ish pixels per cell, the trick timg and
friends use.
(像素用半块字符：`▀` 的前景是上面的像素、背景是下面的像素，一个字符格得到两个近似方形的像素，
 timg 之类的工具就是这么做的)
]]

local M = {}

local timer = require("weread.timer")

---Frame interval used when an effect does not say: 20 frames a second is smooth
---enough for a few cells and cheap over SSH or a multiplexer.
---(效果没指定时的帧间隔：每秒 20 帧，对几个字符格来说足够流畅，走 SSH 或复用器也不贵)
M.DEFAULT_INTERVAL = 50

---Run every frame synchronously, for tests: the clock is not real there.
---(同步执行每一帧，供测试用：那里没有真实时钟)
M._sync = false

---Play effects even without a UI, for tests.
---(没有界面也播放效果，供测试用)
M._force = false

---Playing effects by id.
---(正在播放的效果，按 id)
---@type table<integer, table>
local playing = {}
local next_id = 0

local KEY_NS = vim.api.nvim_create_namespace("weread.fx.keys")

---@return table
local function settings()
  return (require("weread.config").get().animations or {})
end

---Whether effects may play at all, or one kind of them.
---(效果是否允许播放；给了 kind 时问的是这一种)
---@param kind string|nil a key of `animations` ("loading", "bookmark"...)(`animations` 里的键)
---@return boolean
function M.enabled(kind)
  local opts = settings()
  if opts.enabled == false or vim.g.weread_animations == false or vim.g.snacks_animate == false then
    return false
  end
  if not M._force and #vim.api.nvim_list_uis() == 0 then
    return false
  end
  if kind then
    local value = opts[kind]
    return value ~= false and value ~= nil
  end
  return true
end

---Stop listening for keys once nothing is left that a key should stop.
---(没有需要按键打断的效果时，停止监听按键)
local function refresh_listener()
  local wanted = false
  for _, effect in pairs(playing) do
    if effect.stop_on_key then
      wanted = true
      break
    end
  end
  if wanted then
    vim.on_key(function(_, typed)
      -- keys a plugin feeds (`:normal!`, feedkeys) are not the reader
      -- (插件送进来的按键（`:normal!`、feedkeys）不是读者按的)
      if typed == "" then
        return
      end
      -- Only the effects playing when the key came: the key may start a new
      -- one (a highlight, a bookmark), and that one must play.
      -- (只停按键到来时正在播放的效果：这个按键可能正要开始一个新效果（划线、书签），新的那个要能播完)
      local before = {}
      for _, effect in pairs(playing) do
        if effect.stop_on_key then
          before[#before + 1] = effect
        end
      end
      -- the key is processed first; effects stop right after
      -- (按键照常处理；效果紧接着停下)
      vim.schedule(function()
        for _, effect in ipairs(before) do
          M.stop(effect)
        end
      end)
    end, KEY_NS)
  else
    vim.on_key(nil, KEY_NS)
  end
end

---Stop one effect: its timer, then its own cleanup.
---(停掉一个效果：先停定时器，再做它自己的清理)
---@param handle table|nil
function M.stop(handle)
  if type(handle) ~= "table" or not playing[handle.id] then
    return
  end
  playing[handle.id] = nil
  timer.stop(handle.timer)
  timer.stop(handle.delay)
  handle.timer, handle.delay = nil, nil
  if handle.cleanup then
    pcall(handle.cleanup)
  end
  refresh_listener()
end

---Stop every effect (any key does this).
---(停掉全部效果——任意按键都会这么做)
---@param opts table|nil { keyed = boolean } a key asked for it: effects that ignore keys stay(由按键触发：不理会按键的效果留着)
function M.stop_all(opts)
  local keyed = type(opts) == "table" and opts.keyed
  for _, handle in pairs(vim.tbl_values(playing)) do
    if not keyed or handle.stop_on_key then
      M.stop(handle)
    end
  end
end

---@return integer
function M.count()
  return vim.tbl_count(playing)
end

---Play an effect: `draw(i)` for frames 1..`frames`, one every `interval` ms,
---then `cleanup`. Without `frames` it runs until stopped (or `max_ms`).
---(播放一个效果：每 interval 毫秒调一次 draw(i)，i 从 1 到 frames，然后 cleanup。没给 frames
--- 就一直播到被停掉（或到 max_ms）)
---
---`draw` returning false ends the effect early. `delay` waits before the first
---frame, so an effect for something that turns out instant never shows.
---(draw 返回 false 会提前结束。delay 是第一帧之前的等待，于是为一件结果瞬间完成的事准备的效果
--- 根本不会出现)
---@param spec { draw: fun(i: integer): boolean|nil, frames?: integer, interval?: integer, delay?: integer, max_ms?: integer, start?: fun(), cleanup?: fun(), stop_on_key?: boolean }
---@return table handle
function M.play(spec)
  next_id = next_id + 1
  local handle = {
    id = next_id,
    cleanup = spec.cleanup,
    stop_on_key = spec.stop_on_key ~= false,
  }
  playing[handle.id] = handle
  local interval = spec.interval or M.DEFAULT_INTERVAL
  local limit = spec.frames or math.huge
  if spec.max_ms then
    limit = math.min(limit, math.max(1, math.floor(spec.max_ms / interval)))
  end
  local frame = 0
  local function step()
    if not playing[handle.id] then
      return
    end
    frame = frame + 1
    local ok, result = pcall(spec.draw, frame)
    if not ok or result == false or frame >= limit then
      M.stop(handle)
      return
    end
    pcall(vim.cmd.redraw)
  end
  local function begin()
    if not playing[handle.id] then
      return
    end
    if spec.start then
      local ok = pcall(spec.start)
      if not ok then
        M.stop(handle)
        return
      end
    end
    if M._sync then
      while playing[handle.id] and frame < limit and frame < 10000 do
        step()
      end
      return
    end
    step()
    if playing[handle.id] then
      handle.timer = timer.every(step, interval)
    end
  end
  refresh_listener()
  if spec.delay and spec.delay > 0 and not M._sync then
    handle.delay = timer.defer(begin, spec.delay)
  else
    begin()
  end
  return handle
end

-- ------------------------------------------------------------------ colours

---The inks effects are drawn in: the reading palette when one is on, otherwise
---the colorscheme's own groups (with a guess when they carry no colour).
---(效果使用的墨色：开着阅读配色就取配色，否则取配色方案自己的组（组里没颜色时按明暗猜一个）)
---@return { bg: string, fg: string, accent: string, muted: string, mark: string }
function M.colors()
  local theme = require("weread.theme")
  local palette = theme.palettes[theme.current()]
  if palette then
    return { bg = palette.bg, fg = palette.fg, accent = palette.accent, muted = palette.muted, mark = palette.mark }
  end
  local function get(name, key)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and type(hl) == "table" and hl[key] then
      return string.format("#%06x", hl[key])
    end
    return nil
  end
  local dark = vim.o.background == "dark"
  local bg = get("Normal", "bg") or (dark and "#1e1e1e" or "#ffffff")
  local fg = get("Normal", "fg") or (dark and "#d0d0d0" or "#202020")
  local mix = require("weread.color").mix
  return {
    bg = bg,
    fg = fg,
    accent = get("Title", "fg") or get("Special", "fg") or fg,
    muted = get("Comment", "fg") or mix(bg, fg, 0.6),
    mark = mix(bg, fg, 0.12),
  }
end

---Groups made for pixel pairs, keyed by "top/bottom". Cleared at every effect
---start: `:colorscheme` wipes them and the inks may have changed.
---(为像素对建的组，按「上/下」为键。每个效果开始时清空：`:colorscheme` 会抹掉它们，墨色也可能变了)
local pixel_groups = {}

function M.reset_groups()
  pixel_groups = {}
end

---The group drawing `▀` with a top and a bottom colour.
---(用上、下两种颜色画 `▀` 的组)
---@param top string "#rrggbb"
---@param bottom string "#rrggbb"
---@return string
function M.pixel_group(top, bottom)
  local key = top .. "/" .. bottom
  local group = pixel_groups[key]
  -- `:colorscheme` wipes the group but not this cache (`:colorscheme` 会抹掉组，但不会抹掉这份缓存)
  if group and next(vim.api.nvim_get_hl(0, { name = group })) == nil then
    group = nil
  end
  if not group then
    group = "WereadFxPx" .. top:sub(2) .. bottom:sub(2)
    vim.api.nvim_set_hl(0, group, { fg = top, bg = bottom })
    pixel_groups[key] = group
  end
  return group
end

---Turn a grid of colour keys into half block lines. Rows are paired, so a grid
---of 2n rows gives n lines. Keys not in `inks` are the page.
---(把颜色键组成的网格变成半块字符行。行两两成对，2n 行的网格得到 n 行文字。`inks` 里没有的键
--- 就是纸色)
---@param grid string[] rows of single character keys(由单字符键组成的行)
---@param inks table<string, string> key -> "#rrggbb"
---@param page string "#rrggbb" the page colour
---@return string[] lines
---@return table[] marks { row (0-based), col, end_col, group }
function M.pixels(grid, inks, page)
  local lines, marks = {}, {}
  for pair = 1, math.ceil(#grid / 2) do
    local top_row = grid[pair * 2 - 1] or ""
    local bottom_row = grid[pair * 2] or ""
    local width = math.max(#top_row, #bottom_row)
    local parts, col = {}, 0
    for x = 1, width do
      local top = inks[top_row:sub(x, x)] or page
      local bottom = inks[bottom_row:sub(x, x)] or page
      local text = (top == page and bottom == page) and " " or "▀"
      parts[#parts + 1] = text
      marks[#marks + 1] = { row = pair - 1, col = col, end_col = col + #text, group = M.pixel_group(top, bottom) }
      col = col + #text
    end
    lines[pair] = table.concat(parts)
  end
  return lines, marks
end

-- ------------------------------------------------------------------ floats

---A float of its own over a window, never focused, never firing autocommands.
---(盖在某个窗口上的独立浮窗：从不获得焦点，也不触发自动命令)
---@param win integer the window it sits on(它所覆盖的窗口)
---@param opts { row: integer, col: integer, width: integer, height: integer, zindex?: integer }
---@return { win: integer, buf: integer }|nil
function M.float(win, opts)
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local width = math.max(1, math.min(opts.width, vim.api.nvim_win_get_width(win)))
  local height = math.max(1, math.min(opts.height, vim.api.nvim_win_get_height(win)))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local ok, float = pcall(vim.api.nvim_open_win, buf, false, {
    relative = "win",
    win = win,
    row = math.max(0, opts.row),
    col = math.max(0, opts.col),
    width = width,
    height = height,
    style = "minimal",
    focusable = false,
    noautocmd = true,
    zindex = opts.zindex or 50,
  })
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil
  end
  local colors = M.colors()
  local group = "WereadFxPage"
  vim.api.nvim_set_hl(0, group, { fg = colors.fg, bg = colors.bg })
  vim.wo[float].winhighlight = "Normal:" .. group .. ",NormalFloat:" .. group .. ",EndOfBuffer:" .. group
  vim.wo[float].wrap = false
  return { win = float, buf = buf, width = width, height = height }
end

---Write lines and their highlights into an effect float.
---(把行和它们的高亮写进效果浮窗)
---@param view { win: integer, buf: integer }
---@param lines string[]
---@param marks table[]|nil
function M.paint(view, lines, marks)
  if not view or not vim.api.nvim_buf_is_valid(view.buf) then
    return
  end
  local ns = vim.api.nvim_create_namespace("weread.fx")
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
  for _, mark in ipairs(marks or {}) do
    pcall(vim.api.nvim_buf_set_extmark, view.buf, ns, mark.row, mark.col, {
      end_col = mark.end_col,
      hl_group = mark.group,
    })
  end
end

---@param view { win: integer }|nil
function M.close(view)
  if view and view.win and vim.api.nvim_win_is_valid(view.win) then
    pcall(vim.api.nvim_win_close, view.win, true)
  end
end

-- ------------------------------------------------------------------ events

---Tell whoever listens (and the effects) that something happened on the page:
---`User WereadPageTurn`, `WereadChapterOpen`, `WereadChapterEnd`, `WereadBookEnd`.
---(告诉监听者（以及效果）书页上发生了什么：`User WereadPageTurn`、`WereadChapterOpen`、
--- `WereadChapterEnd`、`WereadBookEnd`)
---@param name string
---@param data table|nil
function M.emit(name, data)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = name, modeline = false, data = data or {} })
end

return M
