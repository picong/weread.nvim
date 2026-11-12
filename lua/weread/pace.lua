--[[
Reading pace: how fast this reader reads, learned from page turns, and how long
the rest of the chapter will take at that pace.
(阅读速度：从翻页中学到这位读者读得多快，并据此估计本章剩下的部分还要读多久)

This is the Kindle "time left in chapter" idea, done the way KOReader does it:
every forward page turn is one sample (time spent on the page, text it held),
samples that cannot be reading are dropped, and the rest are averaged. Here the
average is a moving one weighted towards recent pages, because a reader's pace
changes with the book, and it is kept in the preferences so a new session does
not start from zero.
(这是 Kindle「本章剩余时间」的思路，按 KOReader 的做法实现：每次向后翻页是一个样本
 （这一页停了多久、页上有多少字），不可能是在读的样本丢掉，其余的取平均。这里用偏向最近
 几页的移动平均，因为读速随书而变；结果存进偏好，新会话不必从零开始)

Text is counted in display cells, not characters: a Chinese character is two
cells and a Latin letter one, which is roughly the reading effort either takes,
and it is what the renderer already measures. The pace is in cells per minute.
(文字按显示单元格计，而不是字符数：汉字两格、拉丁字母一格，大致就是读它们各自所花的
 力气，也正是渲染器本来就在量的东西。速度单位是每分钟单元格数)
]]

local M = {}

---Pace assumed before any page has been timed: 350 Chinese characters a
---minute, the middle of what silent-reading studies of adults report.
---(还没量过任何一页时假定的速度：每分钟 350 个汉字，成人默读研究报告的中间值)
M.DEFAULT_CELLS_PER_MINUTE = 700

---A page turned sooner than this was skipped, not read.
---(比这更快翻走的页是跳过，不是读过)
M.MIN_SECONDS = 4

---A page held longer than this was left open, not read: the reader looked away,
---answered a message, went for tea.
---(停留比这更久的页是开着没读：读者走开了、回了条消息、去泡了杯茶)
M.MAX_SECONDS = 300

---Paces outside this range are not reading: flipping through, or away from
---the keyboard with the page open.
---(超出这个范围的速度不是在读：要么是在翻，要么是开着页面离开了键盘)
M.MIN_CELLS_PER_MINUTE = 120
M.MAX_CELLS_PER_MINUTE = 6000

---Weight of the newest sample in the moving average.
---(移动平均里最新样本的权重)
M.WEIGHT = 0.15

---Samples taken between two writes of the preferences file.
---(两次写偏好文件之间攒多少个样本)
local SAVE_EVERY = 5

---Page on screen per window: { buf, start, cells, at }
---(每个窗口屏幕上的那一页)
local shown = {}

---In-memory pace: { cells_per_minute, samples }; nil until first read.
---(内存里的速度；首次读取前为 nil)
local learned = nil
local unsaved = 0

---@return table
local function current()
  if not learned then
    local stored = require("weread.prefs").get("pace")
    if type(stored) == "table" and tonumber(stored.cells_per_minute) then
      learned = { cells_per_minute = tonumber(stored.cells_per_minute), samples = tonumber(stored.samples) or 0 }
    else
      learned = { cells_per_minute = M.DEFAULT_CELLS_PER_MINUTE, samples = 0 }
    end
  end
  return learned
end

local function save()
  unsaved = 0
  require("weread.prefs").set("pace", { cells_per_minute = learned.cells_per_minute, samples = learned.samples })
end

---Forget the in-memory pace and the pages on screen. For tests.
---(丢掉内存里的速度与屏幕上的页；供测试使用)
function M._reset()
  learned = nil
  unsaved = 0
  shown = {}
end

---@return number cells per minute(每分钟单元格数)
function M.cells_per_minute()
  return current().cells_per_minute
end

---Fold one timed page into the pace. Returns whether it counted.
---(把一页的计时并入速度；返回它是否算数)
---@param cells integer text the page held(页上的文字量)
---@param seconds number time spent on it(在这一页上停了多久)
---@return boolean
function M.sample(cells, seconds)
  if not cells or cells <= 0 or not seconds or seconds < M.MIN_SECONDS or seconds > M.MAX_SECONDS then
    return false
  end
  local rate = cells / seconds * 60
  if rate < M.MIN_CELLS_PER_MINUTE or rate > M.MAX_CELLS_PER_MINUTE then
    return false
  end
  local pace = current()
  -- the first sample replaces the guess and the next few weigh more, so the
  -- estimate is the reader's own after a handful of pages
  -- (第一个样本直接替换掉猜测值，之后几个权重更大，翻几页之后估计就是读者自己的了)
  local weight = math.max(M.WEIGHT, 1 / (pace.samples + 1))
  pace.cells_per_minute = pace.cells_per_minute * (1 - weight) + rate * weight
  pace.samples = pace.samples + 1
  unsaved = unsaved + 1
  if unsaved >= SAVE_EVERY then
    save()
  end
  return true
end

---A page was put on screen. A forward turn times the page it replaced; a page
---shown again (a re-measure, a resize) keeps its clock; going back restarts it.
---(一页上了屏。向后翻页给被替换的那一页计时；同一页再显示一次（重新量页、resize）不重置时钟；
--- 往回翻则重新计时)
---@param win integer
---@param buf integer
---@param start integer first line of the page(页首行)
---@param cells integer text the page holds(页上的文字量)
---@param now number|nil seconds, for tests(秒，供测试注入)
function M.page_shown(win, buf, start, cells, now)
  now = now or vim.uv.now() / 1000
  local before = shown[win]
  if before and before.buf == buf and before.start == start then
    before.cells = cells
    return
  end
  if before and (before.buf ~= buf or start > before.start) then
    local seconds = now - before.at
    if M.sample(before.cells, seconds) then
      -- a page that was read counts towards today's reading
      -- (读过的这一页计入今天的阅读)
      pcall(function()
        require("weread.journal").add(seconds)
        require("weread.garden").grew()
      end)
    end
  end
  shown[win] = { buf = buf, start = start, cells = cells, at = now }
end

---Minutes the given amount of text takes at the reader's pace, rounded up.
---(按读者的速度读完这么多文字要几分钟，向上取整)
---@param cells integer
---@return integer
function M.minutes(cells)
  if not cells or cells <= 0 then
    return 0
  end
  return math.ceil(cells / M.cells_per_minute())
end

---Short label for the time a stretch of text takes: "约 5 分钟", "约 1 小时 20 分".
---(一段文字需要多久的短标签)
---@param cells integer
---@return string
function M.label(cells)
  local minutes = M.minutes(cells)
  if minutes <= 1 then
    return "不到 1 分钟"
  end
  if minutes < 60 then
    return string.format("约 %d 分钟", minutes)
  end
  local hours, rest = math.floor(minutes / 60), minutes % 60
  if rest == 0 then
    return string.format("约 %d 小时", hours)
  end
  return string.format("约 %d 小时 %d 分", hours, rest)
end

---Display cells of buffer lines, blank ones counting nothing. The markdown an
---illustration is written in (a long cache path) is not text anyone reads.
---(若干 buffer 行的显示单元格总数，空行不计。插图的 markdown 写法（一长串缓存路径）不是
--- 谁会去读的文字)
---@param lines string[]
---@param from integer 1-based, inclusive
---@param to integer 1-based, inclusive
---@return integer
function M.cells_of(lines, from, to)
  local total = 0
  for line = math.max(1, from), math.min(#lines, to) do
    local text = lines[line]
    if text and text ~= "" then
      text = text:gsub("!%[[^%]]*%]%([^)]*%)", "")
      total = total + vim.api.nvim_strwidth(text)
    end
  end
  return total
end

---Write the pace out now (on exit), if anything is pending.
---(有没写盘的样本就立刻写出（退出时用）)
function M.flush()
  if learned and unsaved > 0 then
    save()
  end
end

return M
