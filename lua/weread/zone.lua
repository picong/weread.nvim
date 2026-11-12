--[[
Things to look at while not reading: `:WeReadZone` plays with the page on screen
(the letters fall like rain, or turn into a game of life), and a pixel fireplace
burns over the page after a long stretch away.
(不读书时看的东西：`:WeReadZone` 拿屏幕上这一页玩——字像雨一样落下，或者变成一局生命游戏；
 长时间离开之后，书页上会烧起一个像素壁炉)

All of it is drawn in one float over the chapter window, a copy of what is on
screen; the chapter buffer itself is never touched. Any key puts the page back:
the key is swallowed, so the first press after coming back does not also turn a
page or move the cursor.
(全部画在章节窗口上方的一个浮窗里——屏幕内容的一份拷贝；章节 buffer 本身从不改动。任意键让书页
 回来：这一下按键会被吞掉，所以回来后的第一下不会同时翻页或挪光标)
]]

local fx = require("weread.fx")

local M = {}

---The scenes `:WeReadZone` knows.
---(`:WeReadZone` 认得的场景)
M.SCENES = { "rain", "life", "fire" }

---Frame interval per scene, and the longest any of them plays: a zone left
---running in a terminal nobody looks at only burns power.
---(每个场景的帧间隔，以及任何场景播放的最长时间：没人看的终端里一直跑着，只是在耗电)
local INTERVAL = { rain = 70, life = 140, fire = 80 }
local MAX_MS = 10 * 60 * 1000

local SWALLOW_NS = vim.api.nvim_create_namespace("weread.zone.swallow")

---The scene playing now: { handle, view, win }.
---(正在播放的场景)
local current = nil

-- ------------------------------------------------------------------ the page as cells

---The visible page as a grid of display cells: each is { char, width } where a
---wide character takes its own cell and leaves a continuation (width 0) after it.
---(屏幕上这一页，作为显示单元格网格：每格是 { 字符, 宽度 }，宽字符占自己那格，后面留一个续格（宽度 0）)
---@param win integer
---@return table[][] rows
---@return integer width
---@return integer height
function M.grab(win)
  local width = vim.api.nvim_win_get_width(win)
  local height = vim.api.nvim_win_get_height(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local top = vim.fn.line("w0", win)
  local rows = {}
  local margin = 0
  pcall(function()
    local reader = require("weread.reader")
    local page_width = reader.page_width() or 0
    if page_width > 0 then
      margin = require("weread.layout").margin_for(width, math.min(page_width, width))
    end
  end)
  local lines = vim.api.nvim_buf_get_lines(buf, top - 1, top - 1 + height, false)
  for y = 1, height do
    local row = {}
    for x = 1, width do
      row[x] = { " ", 1 }
    end
    local text = lines[y] or ""
    local x = margin + 1
    for _, char in ipairs(vim.fn.split(text, "\\zs")) do
      local cells = vim.fn.strdisplaywidth(char)
      if x + cells - 1 > width then
        break
      end
      if cells > 0 then
        row[x] = { char, cells }
        for extra = 1, cells - 1 do
          row[x + extra] = { "", 0 }
        end
        x = x + cells
      end
    end
    rows[y] = row
  end
  return rows, width, height
end

---A row of cells back into a line of text; a wide character cut in half by the
---scene becomes a space.
---(把一行单元格还原成文字；被场景切掉一半的宽字符变成空格)
---@param row table[]
---@return string
function M.join(row)
  local parts = {}
  local x = 1
  while x <= #row do
    local cell = row[x]
    if cell[2] == 0 then
      parts[#parts + 1] = " "
      x = x + 1
    elseif cell[2] > 1 then
      local whole = true
      for extra = 1, cell[2] - 1 do
        local next_cell = row[x + extra]
        if not next_cell or next_cell[2] ~= 0 then
          whole = false
        end
      end
      parts[#parts + 1] = whole and cell[1] or " "
      x = x + (whole and cell[2] or 1)
    else
      parts[#parts + 1] = cell[1]
      x = x + 1
    end
  end
  return table.concat(parts)
end

-- ------------------------------------------------------------------ rain

---Letters fall one by one, the lowest first, until the page is empty.
---(字一个接一个往下掉，最低的先掉，直到页面空了)
---@param rows table[][]
---@return table state
function M.rain_state(rows)
  local glyphs = {}
  for y, row in ipairs(rows) do
    for x, cell in ipairs(row) do
      if cell[2] > 0 and cell[1] ~= " " then
        glyphs[#glyphs + 1] = { x = x, y = y, char = cell[1], width = cell[2], speed = 0, falling = false }
      end
    end
  end
  return { glyphs = glyphs, height = #rows, width = rows[1] and #rows[1] or 0, step = 0 }
end

---One step of the rain: a few more letters let go, the falling ones speed up.
---(雨的一步：又松开几个字，正在掉的加速)
---@param state table
---@param seed integer varies which letters let go(决定哪些字松开)
---@return boolean alive some letter is still on screen(还有字在屏幕上)
function M.rain_step(state, seed)
  state.step = state.step + 1
  local count = #state.glyphs
  -- let go of a few, chosen by a cheap hash so the scene needs no randomness
  -- (松开几个，用一个廉价的散列挑选，这样场景不需要随机数)
  local release = math.max(1, math.floor(count / 40))
  for i = 1, release do
    local index = ((state.step * 7919 + i * 104729 + seed) % math.max(count, 1)) + 1
    local glyph = state.glyphs[index]
    if glyph then
      glyph.falling = true
    end
  end
  local alive = false
  for _, glyph in ipairs(state.glyphs) do
    if glyph.falling then
      glyph.speed = math.min(glyph.speed + 0.35, 3)
      glyph.y = glyph.y + glyph.speed
    end
    if math.floor(glyph.y) <= state.height then
      alive = true
    end
  end
  return alive
end

---@param state table
---@return string[]
function M.rain_lines(state)
  local rows = {}
  for y = 1, state.height do
    rows[y] = {}
    for x = 1, state.width do
      rows[y][x] = { " ", 1 }
    end
  end
  for _, glyph in ipairs(state.glyphs) do
    local y = math.floor(glyph.y)
    if y >= 1 and y <= state.height and glyph.x + glyph.width - 1 <= state.width then
      local row = rows[y]
      local free = true
      for extra = 0, glyph.width - 1 do
        if row[glyph.x + extra][1] ~= " " or row[glyph.x + extra][2] ~= 1 then
          free = false
        end
      end
      if free then
        row[glyph.x] = { glyph.char, glyph.width }
        for extra = 1, glyph.width - 1 do
          row[glyph.x + extra] = { "", 0 }
        end
      end
    end
  end
  local lines = {}
  for y, row in ipairs(rows) do
    lines[y] = M.join(row)
  end
  return lines
end

-- ------------------------------------------------------------------ life

---The page as a game of life: every inked cell is alive. Wide characters are
---two live cells, so the text keeps its shape in the first generation.
---(书页变成生命游戏：每个有墨的格子都是活的。宽字符是两个活格，所以第一代保留了文字的形状)
---@param rows table[][]
---@return table state
function M.life_state(rows)
  local cells = {}
  for y, row in ipairs(rows) do
    cells[y] = {}
    for x, cell in ipairs(row) do
      local inked = cell[2] == 0 or (cell[1] ~= " " and cell[1] ~= "")
      cells[y][x] = inked and 1 or 0
    end
  end
  return { cells = cells, height = #rows, width = rows[1] and #rows[1] or 0, generation = 0 }
end

---One generation, on a board that wraps at its edges.
---(一代，棋盘四边相接)
---@param state table
---@return boolean changed
function M.life_step(state)
  local h, w = state.height, state.width
  if h == 0 or w == 0 then
    return false
  end
  local old = state.cells
  local new = {}
  local changed = false
  for y = 1, h do
    new[y] = {}
    for x = 1, w do
      local n = 0
      for dy = -1, 1 do
        for dx = -1, 1 do
          if dy ~= 0 or dx ~= 0 then
            n = n + old[(y + dy - 1) % h + 1][(x + dx - 1) % w + 1]
          end
        end
      end
      local alive = old[y][x] == 1
      local next_alive = (alive and (n == 2 or n == 3)) or (not alive and n == 3)
      new[y][x] = next_alive and 1 or 0
      if next_alive ~= alive then
        changed = true
      end
    end
  end
  state.cells = new
  state.generation = state.generation + 1
  return changed
end

---@param state table
---@return string[]
function M.life_lines(state)
  local lines = {}
  for y = 1, state.height do
    local parts = {}
    for x = 1, state.width do
      parts[x] = state.cells[y][x] == 1 and "█" or " "
    end
    lines[y] = table.concat(parts)
  end
  return lines
end

-- ------------------------------------------------------------------ fire

---Heat levels of the fire, coldest first, as a ramp from the page to the
---accent and on to a pale flame core.
---(火焰的热度等级，从冷到热：从纸色渐变到强调色，再到浅色的焰心)
local FIRE_LEVELS = 10

---The DOOM fire: a heat field, hottest at the bottom row, every cell taking the
---heat of the one below it minus a little, nudged sideways.
---(DOOM 火焰：一个热度场，最底一行最热，每格取下面那格的热度再减一点，并左右偏一点)
---@param width integer
---@param height integer pixel rows (two per text line)(像素行数，每行文字两个)
---@return table state
function M.fire_state(width, height)
  local heat = {}
  for y = 1, height do
    heat[y] = {}
    for x = 1, width do
      heat[y][x] = y == height and FIRE_LEVELS or 0
    end
  end
  return { heat = heat, width = width, height = height, step = 0 }
end

---A small linear congruential generator kept in the scene's state: the fire
---needs noise, and a hash of the coordinates repeats in visible stripes.
---(场景状态里的一个小线性同余发生器：火焰需要噪声，而坐标散列会重复成看得见的条纹)
---@param state table
---@return number 0..1
local function noise(state)
  state.rand = (state.rand * 1103515245 + 12345) % 2147483648
  return state.rand / 2147483648
end

---@param state table
---@param seed integer
function M.fire_step(state, seed)
  state.step = state.step + 1
  state.rand = state.rand or (seed % 2147483647 + 1)
  local heat, w, h = state.heat, state.width, state.height
  for y = 1, h - 1 do
    for x = 1, w do
      local r = noise(state)
      -- heat climbs from below, losing a level about half the time and
      -- drifting a cell sideways now and then: that is what makes tongues
      -- (热度从下面往上爬，大约一半的时候掉一级，时不时向旁边偏一格：火舌就是这么来的)
      local decay = r < 0.45 and 0 or (r < 0.9 and 1 or 2)
      local drift = math.floor(noise(state) * 3) - 1
      local source = math.max(1, math.min(w, x + drift))
      heat[y][x] = math.max(0, heat[y + 1][source] - decay)
    end
  end
  -- the embers at the base flicker (底部的余烬闪烁)
  for x = 1, w do
    heat[h][x] = noise(state) < 0.15 and FIRE_LEVELS - 3 or FIRE_LEVELS
  end
end

---The fire's colour ramp from the page to a pale core.
---(火焰从纸色到浅色焰心的颜色梯度)
---@param colors table fx.colors()
---@return string[] index 0..FIRE_LEVELS
function M.fire_ramp(colors)
  local mix = require("weread.color").mix
  local ramp = {}
  local hot = mix(colors.accent, "#ffd27a", 0.55)
  local core = mix(hot, "#fff4d6", 0.6)
  for level = 0, FIRE_LEVELS do
    local t = level / FIRE_LEVELS
    if t < 0.5 then
      ramp[level] = mix(colors.bg, colors.accent, t * 2)
    elseif t < 0.85 then
      ramp[level] = mix(colors.accent, hot, (t - 0.5) / 0.35)
    else
      ramp[level] = mix(hot, core, (t - 0.85) / 0.15)
    end
  end
  return ramp
end

-- ------------------------------------------------------------------ playing

---Stop the scene, give the page back, and stop swallowing keys.
---(停下场景、还回书页，不再吞键)
function M.stop()
  local scene = current
  current = nil
  vim.on_key(nil, SWALLOW_NS)
  if scene then
    fx.stop(scene.handle)
    fx.close(scene.view)
  end
end

---@return boolean
function M.playing()
  return current ~= nil
end

---Play a scene over the chapter window.
---(在章节窗口上方播放一个场景)
---@param name string|nil "rain" | "life" | "fire"; nil cycles through them(nil 依次轮换)
---@param opts table|nil { win = integer, idle = boolean } idle: started by the screensaver(由屏保启动)
---@return boolean started
function M.play(name, opts)
  opts = opts or {}
  local win = opts.win or vim.api.nvim_get_current_win()
  local ok_reader, reader = pcall(require, "weread.reader")
  if not vim.api.nvim_win_is_valid(win) or not (ok_reader and reader.buffer_info(vim.api.nvim_win_get_buf(win))) then
    if not opts.idle then
      vim.notify("weread: 在章节里才能用 :WeReadZone", vim.log.levels.WARN)
    end
    return false
  end
  if name and not vim.tbl_contains(M.SCENES, name) then
    vim.notify("weread: 没有这个场景：" .. tostring(name) .. "（可选：" .. table.concat(M.SCENES, " / ") .. "）", vim.log.levels.WARN)
    return false
  end
  M.stop()
  if not name then
    local index = (vim.g.weread_zone_index or 0) % #M.SCENES + 1
    vim.g.weread_zone_index = index
    name = M.SCENES[index]
  end
  local rows, width, height = M.grab(win)
  local view = fx.float(win, { row = 0, col = 0, width = width, height = height, zindex = 55 })
  if not view then
    return false
  end
  local colors = fx.colors()
  fx.reset_groups()
  local seed = (vim.uv.hrtime() % 100000)
  local state
  local draw
  if name == "rain" then
    state = M.rain_state(rows)
    vim.api.nvim_set_hl(0, "WereadZoneText", { fg = colors.fg, bg = colors.bg })
    draw = function()
      local alive = M.rain_step(state, seed)
      local lines = M.rain_lines(state)
      local marks = {}
      for row, line in ipairs(lines) do
        marks[#marks + 1] = { row = row - 1, col = 0, end_col = #line, group = "WereadZoneText" }
      end
      fx.paint(view, lines, marks)
      return alive
    end
  elseif name == "life" then
    state = M.life_state(rows)
    vim.api.nvim_set_hl(0, "WereadZoneLife", { fg = colors.accent, bg = colors.bg })
    local still = 0
    draw = function()
      local changed = M.life_step(state)
      still = changed and 0 or still + 1
      local lines = M.life_lines(state)
      local marks = {}
      for row, line in ipairs(lines) do
        marks[#marks + 1] = { row = row - 1, col = 0, end_col = #line, group = "WereadZoneLife" }
      end
      fx.paint(view, lines, marks)
      -- a board that stopped changing is done (不再变化的棋盘就结束了)
      return still < 20
    end
  else
    local pixel_rows = math.min(height * 2, 24)
    state = M.fire_state(width, pixel_rows)
    local ramp = M.fire_ramp(colors)
    draw = function()
      M.fire_step(state, seed)
      local blank = height - pixel_rows / 2
      local grid, inks = {}, {}
      local keys = "0123456789A"
      for level = 0, FIRE_LEVELS do
        inks[keys:sub(level + 1, level + 1)] = ramp[level]
      end
      inks["0"] = nil
      for y = 1, state.height do
        local parts = {}
        for x = 1, state.width do
          parts[x] = keys:sub(state.heat[y][x] + 1, state.heat[y][x] + 1)
        end
        grid[y] = table.concat(parts)
      end
      local lines, marks = fx.pixels(grid, inks, colors.bg)
      local padded = {}
      for _ = 1, blank do
        padded[#padded + 1] = ""
      end
      for _, mark in ipairs(marks) do
        mark.row = mark.row + blank
      end
      vim.list_extend(padded, lines)
      fx.paint(view, padded, marks)
    end
  end
  -- Known before the first frame: a scene that ends on its first frame (a page
  -- with nothing on it) cleans up through `current`, and must not leave a key
  -- listener behind for a scene that never showed.
  -- (在第一帧之前就登记：第一帧就结束的场景（页面上什么都没有）经由 `current` 清理，不能为一个
  --  根本没出现的场景留下按键监听)
  current = { view = view, win = win, name = name }
  local handle = fx.play({
    interval = INTERVAL[name],
    max_ms = MAX_MS,
    -- the key that ends it is swallowed below instead
    -- (结束它的那个按键在下面被吞掉)
    stop_on_key = false,
    draw = draw,
    cleanup = function()
      if current and current.view == view then
        M.stop()
      else
        fx.close(view)
      end
    end,
  })
  if not current or current.view ~= view then
    return false
  end
  current.handle = handle
  -- The next key ends the scene and goes nowhere else. Registered on the next
  -- tick: the key that started the scene (the end of `:WeReadZone<CR>`) is
  -- still being processed now.
  -- (下一个按键结束场景，而且不再传给别处。在下一拍才注册：启动场景的那个按键
  --  （`:WeReadZone<CR>` 的结尾）此刻还在处理中)
  vim.schedule(function()
    if current and current.handle == handle then
      vim.on_key(function(_, typed)
        if typed == "" then
          return nil
        end
        vim.schedule(M.stop)
        return ""
      end, SWALLOW_NS)
    end
  end)
  return true
end

-- ------------------------------------------------------------------ screensaver

---How often the screensaver checks whether the reader is away.
---(屏保多久检查一次读者是否离开)
local CHECK_MS = 30 * 1000

local watcher = nil

---The absence the fireplace was already lit for (the time of the last key): a
---fire that burned out at its cap is not lit again until the reader has been
---back.
---(壁炉已经为哪一次离开点过火（以最后一次按键的时间记）：烧到上限熄灭的火，要等读者回来过才会再点)
local lit_for = nil

---Light the fireplace over the page after `animations.idle_minutes` without a
---key. Off unless that is set: the page is still the reader's while they think.
---(`animations.idle_minutes` 分钟没有按键之后，在书页上点起壁炉。没设置就不开：读者在思考时，
--- 书页仍然是他们的)
function M.watch_idle()
  require("weread.timer").stop(watcher)
  watcher = nil
  lit_for = nil
  local minutes = tonumber((require("weread.config").get().animations or {}).idle_minutes)
  if not minutes or minutes <= 0 then
    return
  end
  watcher = require("weread.timer").every(function()
    if current or not fx.enabled() then
      return
    end
    local state = require("weread.progress_state")
    if lit_for ~= nil and lit_for == state.last_input then
      return
    end
    if vim.uv.now() - (state.last_input or 0) < minutes * 60 * 1000 then
      return
    end
    if vim.fn.mode() ~= "n" then
      return
    end
    if M.play("fire", { idle = true }) then
      lit_for = state.last_input
    end
  end, CHECK_MS)
end

return M
