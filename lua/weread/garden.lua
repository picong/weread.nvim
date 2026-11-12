--[[
Things that grow with reading: a small pixel plant in the corner of the winbar,
which goes from a seed to fruit as today's reading adds up, and a pixel garden
in the statistics, one plant for every day read this month.
(随阅读生长的东西：winbar 角落里一株小小的像素植物，随今天的阅读累积从种子长到结果；以及统计里的
 像素花园，这个月读过的每一天一株植物)

Neither shows a number while reading, and neither punishes a missed day: a day
not read is empty ground, not a red cross, and the run that is counted is of
weeks, so one quiet evening does not end it.
(读的时候两者都不显示数字，也都不惩罚漏掉的一天：没读的日子是空地而不是红叉；计的是连续的周数，
 所以一个安静的晚上不会把它断掉)
]]

local M = {}

---Minutes of reading today each stage needs: seed, sprout, leaves, flower, fruit.
---(每个阶段需要今天读多少分钟：种子、发芽、长叶、开花、结果)
M.STAGES = { 0, 5, 15, 30, 60 }

---Stage names, as the winbar tooltip-free label would say them.
---(各阶段的名字)
M.NAMES = { "种子", "发芽", "长叶", "开花", "结果" }

---Glyphs of the plant per stage, one cell each, so the winbar does not shift.
---(每个阶段的植物字形，各占一格，winbar 不会因此挪动)
M.GLYPHS = { "⠂", "⡀", "⢷", "⣿", "⣿" }

---@param seconds number|nil today's reading, the journal's by default(今天的阅读，默认取日志)
---@return integer stage 1..#STAGES
function M.stage(seconds)
  seconds = seconds or require("weread.journal").seconds()
  local minutes = seconds / 60
  local stage = 1
  for i, need in ipairs(M.STAGES) do
    if minutes >= need then
      stage = i
    end
  end
  return stage
end

---Group the plant is drawn in: the quiet ink until it flowers, then the accent.
---(植物使用的高亮组：开花前用淡墨，开花后用强调色)
---@param stage integer
---@return string
function M.group(stage)
  return stage >= 4 and "WereadGardenBloom" or "WereadGardenLeaf"
end

function M.define_highlights()
  vim.api.nvim_set_hl(0, "WereadGardenLeaf", { link = "WereadPaperWinBar", default = true })
  vim.api.nvim_set_hl(0, "WereadGardenBloom", { link = "WereadPaperAccent", default = true })
end

---Whether the plant is shown.
---(是否显示植物)
---@return boolean
function M.enabled()
  return ((require("weread.config").get().animations or {}).plant) ~= false
end

---The plant as a winbar item, or "" when it is off.
---(植物作为 winbar 的一项；关闭时为 "")
---@return string
function M.winbar_item()
  if not M.enabled() then
    return ""
  end
  M.define_highlights()
  local stage = M.stage()
  return "%#" .. M.group(stage) .. "#" .. M.GLYPHS[stage] .. " "
end

---The stage the winbar last showed, so a page that grows the plant can say so.
---(winbar 上次显示的阶段，让把植物养大的那一页能说出来)
local shown_stage = nil
local shown_day = nil

---Draw every chapter window's winbar again (the plant lives there).
---(重画每个章节窗口的 winbar——植物就在那里)
local function repaint()
  pcall(function()
    local reader = require("weread.reader")
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if reader.buffer_info(vim.api.nvim_win_get_buf(win)) then
        reader.repaint(win)
      end
    end
  end)
end

---Called after a page was read: when the plant reaches a new stage, the
---winbar is drawn again and the new stage is played once.
---(读完一页之后调用：植物长到新阶段时，重画 winbar，并把新阶段播放一次)
function M.grew()
  if not M.enabled() then
    return
  end
  local stage = M.stage()
  local day = require("weread.journal").day()
  if shown_stage == nil or shown_day ~= day then
    -- a new day starts from its own seed: yesterday's fruit is put away quietly
    -- (新的一天从自己的种子开始：昨天的果实悄悄收起)
    local new_day = shown_day ~= nil
    shown_stage, shown_day = stage, day
    if new_day then
      repaint()
    end
    return
  end
  if stage <= shown_stage then
    return
  end
  shown_stage = stage
  repaint()
  -- the seedling puts out a leaf; at fruit, a cat curls up for a nap
  -- (幼苗长出一片叶子；结果的时候，一只猫蜷起来打盹)
  pcall(function()
    local sprites = require("weread.sprites")
    if stage >= #M.STAGES then
      sprites.moment("cat", "今天读了很久，歇一会儿？", { switch = "plant" })
    else
      sprites.moment("sprout", "今天的植物" .. M.NAMES[stage] .. "了", { switch = "plant" })
    end
  end)
  require("weread.ui").notify("weread: 今天的植物" .. M.NAMES[stage] .. "了", vim.log.levels.INFO, { routine = true })
end

-- ------------------------------------------------------------------ the garden

---A day's plant in the garden, by how long was read that day.
---(花园里某一天的植物，按那天读了多久)
---@param seconds number
---@return string glyph two cells wide(两格宽的字形)
---@return string group
function M.plot(seconds)
  if seconds <= 0 then
    -- braille dots: one cell each under every 'ambiwidth', unlike "·"
    -- (盲文点：在任何 'ambiwidth' 下都只占一格，"·" 则不然)
    return "⠂⠂", "WereadPreviewDim"
  end
  local stage = M.stage(seconds)
  local glyphs = { "⡀⠀", "⢀⡀", "⢰⡆", "⣴⣦", "⣾⣷" }
  return glyphs[stage], stage >= 4 and "WereadGardenBloomStats" or "WereadStatsBar"
end

---The garden rows of a month: a header of weekdays (Monday first), then a week
---a row, each day its number and its plant. Days come from the local journal,
---topped up with WeRead's own totals where those are larger.
---(某个月的花园行：一行星期（周一打头），然后每周一行，每天是日期加植物。日子取自本地日志；
--- 微信读书自己的统计更大时，用它补上)
---@param year integer
---@param month integer
---@param remote table<integer, number>|nil day of month -> seconds from WeRead(日 -> 微信读书给的秒数)
---@return table[][] rows of { text, group } segments
function M.month(year, month, remote)
  local journal = require("weread.journal")
  local weekdays = { "一", "二", "三", "四", "五", "六", "日" }
  local rows = {}
  local header = { { "  " } }
  for _, name in ipairs(weekdays) do
    header[#header + 1] = { " " .. name .. "  ", "WereadPreviewDim" }
  end
  rows[1] = header
  local first = os.time({ year = year, month = month, day = 1, hour = 12 })
  local days = os.date("*t", os.time({ year = year, month = month + 1, day = 0, hour = 12 })).day
  local weekday = (os.date("*t", first).wday + 5) % 7
  local row = { { "  " } }
  for _ = 1, weekday do
    row[#row + 1] = { "     " }
  end
  local today = journal.day()
  for day = 1, days do
    local key = string.format("%04d-%02d-%02d", year, month, day)
    local seconds = math.max(journal.seconds(key), tonumber((remote or {})[day]) or 0)
    local glyph, group = M.plot(seconds)
    row[#row + 1] = { string.format("%2d", day), key == today and "WereadPreviewCurrent" or "WereadPreviewDim" }
    row[#row + 1] = { glyph, group }
    row[#row + 1] = { " " }
    weekday = weekday + 1
    if weekday == 7 then
      rows[#rows + 1] = row
      row = { { "  " } }
      weekday = 0
    end
  end
  if #row > 1 then
    rows[#rows + 1] = row
  end
  return rows
end

return M
