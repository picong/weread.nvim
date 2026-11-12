--[[
Reading statistics (:WeReadStats): how long, on which days, which books, at
what hours — the app's 阅读时长 page, from the official Agent API's
/readdata/detail.
(阅读统计 :WeReadStats：读了多久、哪几天读、读了哪些书、几点读——即 App 的「阅读时长」页，
 数据来自官方 Agent API 的 /readdata/detail)

The service only answers for whole calendar periods (a week, a month, a year,
everything), so the window steps between periods rather than taking a date
range. A week shows one bar per day, a month a calendar heat map, a year one
bar per month, everything one bar per year.
(服务端只按完整的自然周期回答（一周、一月、一年、全部），因此窗口是在周期之间切换，
 而不是接受任意日期区间。周按天出条形图，月出日历热力图，年按月出条形图，全部按年)
]]

local M = {}

local text_util = require("weread.text")

local MODES = { "weekly", "monthly", "annually", "overall" }
local MODE_NAMES = { weekly = "周", monthly = "月", annually = "年", overall = "全部" }
local WEEKDAYS = { "日", "一", "二", "三", "四", "五", "六" }
local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
---Seconds a fetched period stays fresh.
---(拉到的周期数据保持新鲜的时间)
local TTL = 300
local WIDTH = 62

---"mode:base" -> { at, data }
local cache = {}

function M.define_highlights()
  vim.api.nvim_set_hl(0, "WereadStatsBar", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "WereadStatsUp", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "WereadStatsDown", { link = "DiagnosticWarn", default = true })
  text_util.define_highlights()
end

-- ------------------------------------------------------------------ formatting

---3661 -> "1小时1分"; under an hour "35分钟", under a minute "不到1分钟".
---(秒数转成时长文字)
---@param seconds number|nil
---@return string
function M.duration(seconds)
  seconds = math.floor(tonumber(seconds) or 0)
  if seconds < 60 then
    return seconds > 0 and "不到1分钟" or "0分钟"
  end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then
    return minutes .. "分钟"
  end
  local hours = math.floor(minutes / 60)
  local rest = minutes % 60
  if rest == 0 then
    return hours .. "小时"
  end
  return string.format("%d小时%d分", hours, rest)
end

---The period a base time stands for, as a heading.
---(某个周期起点代表的时段，写成标题)
---@param mode string
---@param base integer period start, 0 = current(周期起点，0 为当前)
---@return string
function M.period_label(mode, base)
  if mode == "overall" then
    return "全部"
  end
  local at = (base and base > 0) and base or os.time()
  if mode == "weekly" then
    local finish = at + 6 * 86400
    return string.format("%s – %s", os.date("%Y-%m-%d", at), os.date("%m-%d", finish))
  elseif mode == "monthly" then
    return os.date("%Y年%m月", at)
  end
  return os.date("%Y年", at)
end

---Start of the period before (step = -1) or after (step = 1) a base time.
---Calendar arithmetic, not a fixed number of seconds: months and years differ
---in length.
---(某周期之前（-1）或之后（1）那个周期的起点。按日历算，而不是固定秒数：月与年长短不一)
---@param mode string
---@param base integer
---@param step integer
---@return integer|nil nil for "overall", which has no neighbours(「全部」没有相邻周期)
function M.step(mode, base, step)
  if mode == "overall" or not base or base <= 0 then
    return nil
  end
  if mode == "weekly" then
    -- through the calendar too: a DST change makes a day not 86400 seconds
    -- (同样按日历走：夏令时切换时一天不等于 86400 秒)
    local date = os.date("*t", base)
    date.day = date.day + 7 * step
    return os.time({ year = date.year, month = date.month, day = date.day, hour = 0 })
  end
  local date = os.date("*t", base)
  if mode == "monthly" then
    return os.time({ year = date.year, month = date.month + step, day = 1, hour = 0 })
  end
  return os.time({ year = date.year + step, month = 1, day = 1, hour = 0 })
end

---Cells kept for the value column on the right of a bar.
---(条形图右侧数值列占的单元格)
local VALUE_CELLS = 12

---Pad a string with spaces to a display width.
---(用空格把字符串补到某个显示宽度)
---@param text string
---@param width integer
---@return string
local function pad(text, width)
  return text .. string.rep(" ", math.max(0, width - text_util.cells(text)))
end

---A row of bars: label, bar, value.
---(一行条形图：标签、条、数值)
---@param add fun(segments: table[])
---@param label string
---@param seconds number
---@param max number
---@param room integer
local function bar_row(add, label, seconds, max, room)
  local bar_room = math.max(room - text_util.cells(label) - 2 - 1 - VALUE_CELLS, 4)
  local filled = max > 0 and math.floor(seconds / max * bar_room + 0.5) or 0
  if seconds > 0 and filled == 0 then
    filled = 1
  end
  add({
    { label, "WereadPreviewDim" },
    { "  " },
    { string.rep("█", filled), "WereadStatsBar" },
    { string.rep(" ", bar_room - filled + 1) },
    { seconds > 0 and M.duration(seconds) or "", nil },
  })
end

---Section header.
---(分区标题)
local function section(add, blank, name, extra)
  blank()
  add({ { "▎" .. name, "WereadPreviewSection" }, { extra and ("  " .. extra) or "", "WereadPreviewDim" } })
end

---Render a period's statistics.
---(渲染一个周期的统计)
---@param data table from api_gateway.read_stats
---@param opts table|nil { width = integer }
---@return string[] lines
---@return table[] highlights { row, col, end_col, group }
function M.build_lines(data, opts)
  opts = opts or {}
  local width = math.max(tonumber(opts.width) or WIDTH, 40)
  local room = width - 2
  local lines, highlights = {}, {}

  local function add(segments)
    local parts, col, row = { " " }, 1, #lines + 1
    for _, segment in ipairs(segments) do
      local text = segment[1] or ""
      if segment[2] and text ~= "" then
        highlights[#highlights + 1] = { row = row, col = col, end_col = col + #text, group = segment[2] }
      end
      parts[#parts + 1] = text
      col = col + #text
    end
    lines[row] = #segments == 0 and "" or table.concat(parts)
  end
  local function blank()
    if #lines > 0 and lines[#lines] ~= "" then
      add({})
    end
  end

  local mode = data.mode or "monthly"
  local tabs = {}
  for _, name in ipairs(MODES) do
    tabs[#tabs + 1] = { " " .. MODE_NAMES[name] .. " ", name == mode and "WereadPreviewCurrent" or "WereadPreviewDim" }
    tabs[#tabs + 1] = { " " }
  end
  add(tabs)
  add({ { M.period_label(mode, data.base_time), "WereadPreviewTitle" } })
  add({ { string.rep("─", room), "WereadPreviewRule" } })

  -- headline: total time, the average and the change against the last period
  -- (头条：总时长、日均、与上一周期相比的变化)
  local head = { { "共读 " }, { M.duration(data.total), "WereadPreviewTitle" } }
  if data.read_days and data.read_days > 0 then
    head[#head + 1] = { string.format("  ·  %d 天", data.read_days), "WereadPreviewDim" }
  end
  if data.day_average and data.day_average > 0 then
    head[#head + 1] = { "  ·  日均 " .. M.duration(data.day_average), "WereadPreviewDim" }
  end
  add(head)
  local compare = tonumber(data.compare)
  if compare and mode ~= "overall" and compare ~= 0 then
    local percent = math.floor(math.abs(compare) * 100 + 0.5)
    local word = ({ weekly = "上周", monthly = "上月", annually = "去年" })[mode] or "上期"
    add({
      { "比" .. word .. " " , "WereadPreviewDim" },
      { (compare > 0 and "↑ " or "↓ ") .. percent .. "%", compare > 0 and "WereadStatsUp" or "WereadStatsDown" },
    })
  end
  if #(data.facts or {}) > 0 then
    local parts = {}
    for _, fact in ipairs(data.facts) do
      parts[#parts + 1] = fact.name .. " " .. fact.value
    end
    add({ { text_util.fit(table.concat(parts, " · "), room), "WereadPreviewDim" } })
  end

  -- per-bucket view(分桶视图)
  local buckets = data.buckets or {}
  local max = 0
  for _, bucket in ipairs(buckets) do
    max = math.max(max, bucket.seconds)
  end
  if mode == "monthly" and #buckets > 0 then
    -- A garden rather than a heat map: every day read grows a plant, sized by
    -- how long; a day not read is empty ground, never a mark against it.
    -- (花园而不是热力图：每个读过的日子长一株植物，大小看读了多久；没读的日子只是空地，绝不是
    --  一个记过)
    local garden = require("weread.garden")
    garden.define_highlights()
    vim.api.nvim_set_hl(0, "WereadGardenBloomStats", { link = "WereadStatsUp", default = true })
    local streak = require("weread.journal").week_streak()
    section(add, blank, "日历", streak > 1 and string.format("像素花园 · 连续 %d 周都读过", streak) or "像素花园")
    local by_day = {}
    for _, bucket in ipairs(buckets) do
      by_day[tonumber(os.date("%d", bucket.at))] = bucket.seconds
    end
    local first = os.date("*t", data.base_time > 0 and data.base_time or buckets[1].at)
    for _, row in ipairs(garden.month(first.year, first.month, by_day)) do
      add(row)
    end
  elseif #buckets > 0 then
    local name = ({ weekly = "每天", annually = "每月", overall = "每年" })[mode] or "分布"
    section(add, blank, name)
    for _, bucket in ipairs(buckets) do
      local label
      if mode == "weekly" then
        label = os.date("%m-%d", bucket.at) .. " 周" .. WEEKDAYS[tonumber(os.date("%w", bucket.at)) + 1]
      elseif mode == "annually" then
        label = os.date("%m月", bucket.at)
      else
        label = os.date("%Y年", bucket.at)
      end
      bar_row(add, label, bucket.seconds, max, room)
    end
  end

  if data.prefer_time then
    -- the service starts the day at 06:00(服务端的一天从 6 点算起)
    local peak = 0
    for _, seconds in ipairs(data.prefer_time) do
      peak = math.max(peak, seconds)
    end
    if peak > 0 then
      section(add, blank, "时段", data.prefer_time_word)
      local spark = {}
      for _, seconds in ipairs(data.prefer_time) do
        local level = math.max(1, math.ceil(seconds / peak * #SPARK))
        spark[#spark + 1] = seconds > 0 and SPARK[level] or " "
      end
      add({ { "  " }, { table.concat(spark), "WereadStatsBar" } })
      add({ { "  6     12    18    0    5", "WereadPreviewDim" } })
    end
  end

  if #(data.longest or {}) > 0 then
    section(add, blank, "读得最久")
    for index, book in ipairs(data.longest) do
      if index > 5 then
        break
      end
      local value = M.duration(book.seconds)
      local number = string.format("%d. ", index)
      local title_room = room - text_util.cells(number) - 2 - VALUE_CELLS
      local title = book.title ~= "" and book.title or (book.audio and "听书" or "（未知书名）")
      if book.audio and book.title ~= "" then
        title = "🎧 " .. title
      end
      add({
        { number, "WereadPreviewDim" },
        { pad(text_util.fit(title, title_room), title_room) },
        { "  " },
        { value, "WereadStatsBar" },
      })
      if #book.tags > 0 then
        add({ { string.rep(" ", text_util.cells(number)) .. text_util.fit(table.concat(book.tags, " · "), title_room), "WereadPreviewDim" } })
      end
    end
  end

  local categories = {}
  for _, category in ipairs(data.categories or {}) do
    if category.seconds >= 60 and category.title ~= "" then
      categories[#categories + 1] = category
    end
  end
  if #categories > 0 then
    section(add, blank, "分类", data.prefer_category_word)
    local top = 0
    for _, category in ipairs(categories) do
      top = math.max(top, category.seconds)
    end
    for index, category in ipairs(categories) do
      if index > 5 then
        break
      end
      bar_row(add, pad(text_util.fit(category.title, 8), 8), category.seconds, top, room)
    end
  end

  if data.total == 0 and #buckets == 0 then
    blank()
    add({ { "这段时间没有阅读记录", "WereadPreviewDim" } })
  end
  blank()
  add({ { "w/m/y/a 切换周期 · [ ] 上一期/下一期 · q 关闭", "WereadPreviewDim" } })
  return lines, highlights
end

-- ------------------------------------------------------------------ window

---@param mode string
---@param base integer
---@param callback fun(ok: boolean, data: table|string)
local function fetch(mode, base, callback)
  local key = mode .. ":" .. tostring(base)
  local hit = cache[key]
  if hit and os.time() - hit.at < TTL then
    callback(true, hit.data)
    return
  end
  require("weread.api_gateway").read_stats(mode, base, function(ok, data)
    if ok then
      cache[key] = { at = os.time(), data = data }
    end
    callback(ok, data)
  end)
end

---Drop cached periods (tests).
---(清空缓存的周期——测试用)
function M.invalidate()
  cache = {}
end

---Open the statistics window.
---(打开阅读统计窗口)
---@param mode string|nil weekly|monthly|annually|overall, default monthly
function M.open(mode)
  mode = vim.tbl_contains(MODES, mode) and mode or "monthly"
  M.define_highlights()
  local width = math.min(WIDTH, vim.o.columns - 4)
  local view = require("weread.float").open({
    title = " 阅读统计 ",
    width = width,
    height = math.min(36, vim.o.lines - 4),
    lines = { "", "  正在加载…" },
    wrap = false,
  })
  if not view then
    return
  end
  local ns = vim.api.nvim_create_namespace("weread.stats")
  local current = { mode = mode, base = 0 }
  -- a fetch that lands after the reader stepped on must not paint over
  -- (读者已经切到别的周期后才到的结果，不许盖上来)
  local ticket = 0

  local function paint(lines, highlights)
    if not view:is_open() then
      return
    end
    view:set_lines(lines)
    -- the window follows the content, within the screen
    -- (窗口高度跟着内容走，但不超出屏幕)
    if vim.api.nvim_win_is_valid(view.win) then
      local height = math.max(3, math.min(#lines, vim.o.lines - 4))
      vim.api.nvim_win_set_config(view.win, {
        relative = "editor",
        height = height,
        row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      })
    end
    vim.api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
    for _, mark in ipairs(highlights or {}) do
      pcall(vim.api.nvim_buf_set_extmark, view.buf, ns, mark.row - 1, mark.col, {
        end_col = mark.end_col,
        hl_group = mark.group,
      })
    end
  end

  local function load()
    ticket = ticket + 1
    local mine = ticket
    fetch(current.mode, current.base, function(ok, data)
      if mine ~= ticket then
        return
      end
      if not ok then
        paint({ "", "  加载失败：" .. tostring(data) }, nil)
        return
      end
      -- remember where the service says this period starts, so stepping
      -- works from "the current one" (base 0)
      -- (记下服务端认定的周期起点，「当前周期」（base 0）也能往前后翻)
      current.start = data.base_time
      paint(M.build_lines(data, { width = width }))
    end)
  end

  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = view.buf, nowait = true, silent = true })
  end
  for key, name in pairs({ w = "weekly", m = "monthly", y = "annually", a = "overall" }) do
    map(key, function()
      current = { mode = name, base = 0 }
      load()
    end)
  end
  local function step(direction)
    local start = current.start or current.base
    local base = M.step(current.mode, start, direction)
    if not base then
      return
    end
    if direction > 0 and base > os.time() then
      -- nothing has been read in the future(未来还没读过)
      return
    end
    current = { mode = current.mode, base = base }
    load()
  end
  map("[", function()
    step(-1)
  end)
  map("]", function()
    step(1)
  end)
  map("h", function()
    step(-1)
  end)
  map("l", function()
    step(1)
  end)
  load()
end

return M
