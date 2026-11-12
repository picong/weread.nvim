--[[
A small local reading journal: minutes actually read per day, and when each
book was first and last opened here. It feeds the little things that grow with
reading (the plant on the winbar, the garden in the statistics, the card at the
end of a book) and nothing else; WeRead's own statistics stay the record.
(一本小小的本地阅读日志：每天真正读了多少分钟，以及每本书在这里第一次、最后一次打开是什么时候。
 它只喂给那些随阅读生长的小东西（winbar 上的植物、统计里的花园、读完一本书时的卡片），别无他用；
 正式的记录仍是微信读书自己的统计)

Only time the pace module accepted as reading is counted: a page held between
4 seconds and 5 minutes. A page left open while the reader made tea counts for
nothing, so the plant cannot be grown by leaving the editor open.
(只计入阅读速度模块认可为「在读」的时间：一页停留 4 秒到 5 分钟之间。读者去泡茶时开着的那一页
 一秒都不算，所以开着编辑器不管，植物是长不大的)

Days are string keys ("2026-10-28"): sparse integer keys would make
`vim.json.encode` refuse the table as an excessively sparse array.
(日期用字符串键（"2026-10-28"）：稀疏的整数键会让 `vim.json.encode` 把表当成过于稀疏的数组拒绝)
]]

local M = {}

---Samples between two writes of the journal file.
---(两次写日志文件之间攒多少个样本)
local SAVE_EVERY = 5

---Days kept: enough for a year of garden.
---(保留多少天：够一年的花园)
local KEEP_DAYS = 400

local memory = { path = nil, data = nil }
local unsaved = 0

---Seconds added since the last save, per day: what this editor contributes,
---added onto whatever another editor wrote meanwhile.
---(上次保存之后新加的秒数，按天记：这是本编辑器的贡献，保存时加到另一个编辑器这期间写下的数上)
local pending = {}

---@return string
local function path()
  return require("weread.config").path("journal.json")
end

---@return table
local function current()
  local file = path()
  if memory.data == nil or memory.path ~= file then
    memory.path = file
    local data = require("weread.cache").read_json(file)
    if type(data) ~= "table" then
      data = {}
    end
    data.days = type(data.days) == "table" and data.days or {}
    data.books = type(data.books) == "table" and data.books or {}
    memory.data = data
  end
  return memory.data
end

---@param time integer|nil unix seconds, now by default(unix 秒，默认现在)
---@return string
function M.day(time)
  return os.date("%Y-%m-%d", time or os.time()) --[[@as string]]
end

---Drop the oldest days beyond what the garden shows.
---(丢掉花园用不到的最老的日子)
---@param data table
local function prune(data)
  local keys = vim.tbl_keys(data.days)
  if #keys <= KEEP_DAYS then
    return
  end
  table.sort(keys)
  for i = 1, #keys - KEEP_DAYS do
    data.days[keys[i]] = nil
  end
end

---Write the journal out.
---(把日志写出去)
---Read the file as it is on disk now, shaped.
---(按现在磁盘上的样子读文件，并整理好形状)
---@return table
local function read_disk()
  local data = require("weread.cache").read_json(path())
  if type(data) ~= "table" then
    data = {}
  end
  data.days = type(data.days) == "table" and data.days or {}
  data.books = type(data.books) == "table" and data.books or {}
  return data
end

---The earlier of two "YYYY-MM-DD" days, either may be nil.
---(两个日期里较早的那个，任一个都可以是 nil)
local function earlier(a, b)
  if a and b then
    return a < b and a or b
  end
  return a or b
end

local function later(a, b)
  if a and b then
    return a > b and a or b
  end
  return a or b
end

---Write the journal out, merged with what is on disk: two editors open at
---once each add their own minutes, and neither loses a finished book.
---(把日志写出去，并与磁盘上的内容合并：同时开着的两个编辑器各自加上自己的分钟数，谁也不会弄丢
--- 一本读完的书)
---@return boolean ok
function M.save()
  if not memory.data then
    return true
  end
  local disk = read_disk()
  for day, seconds in pairs(pending) do
    disk.days[day] = (tonumber(disk.days[day]) or 0) + seconds
  end
  for key, mine in pairs(memory.data.books) do
    local theirs = disk.books[key] or {}
    disk.books[key] = {
      first = earlier(mine.first, theirs.first),
      last = later(mine.last, theirs.last),
      finished = earlier(mine.finished, theirs.finished),
      chapters = math.max(tonumber(mine.chapters) or 0, tonumber(theirs.chapters) or 0),
      title = mine.title or theirs.title,
    }
  end
  prune(disk)
  local ok = require("weread.cache").write_json(path(), disk)
  if ok == true then
    pending, unsaved = {}, 0
    memory.data = disk
  end
  return ok == true
end

---Write it now if anything is pending (on exit).
---(有没写盘的内容就立刻写出（退出时用）)
function M.flush()
  if unsaved > 0 then
    M.save()
  end
end

---Forget the in-memory copy. For tests.
---(丢弃内存副本，供测试使用)
function M._reset()
  memory.path, memory.data, unsaved = nil, nil, 0
  pending = {}
end

---Count seconds of reading towards today.
---(把若干秒的阅读记到今天)
---@param seconds number
---@param time integer|nil unix seconds, for tests(unix 秒，供测试)
function M.add(seconds, time)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then
    return
  end
  local data = current()
  local key = M.day(time)
  data.days[key] = (tonumber(data.days[key]) or 0) + seconds
  pending[key] = (pending[key] or 0) + seconds
  unsaved = unsaved + 1
  if unsaved >= SAVE_EVERY then
    M.save()
  end
end

---Seconds read on a day.
---(某天读了多少秒)
---@param key string|nil "YYYY-MM-DD", today by default(默认今天)
---@return number
function M.seconds(key)
  return tonumber(current().days[key or M.day()]) or 0
end

---Note that a book was open today: the first and the last day it was read here.
---(记下某本书今天打开过：它在这里第一次与最后一次被读的日子)
---@param book_id string
---@param title string|nil
function M.opened(book_id, title)
  if not book_id then
    return
  end
  local data = current()
  local key = tostring(book_id)
  local entry = data.books[key] or {}
  local today = M.day()
  local changed = entry.first == nil or entry.last ~= today or (title and entry.title ~= title)
  entry.first = entry.first or today
  entry.last = today
  entry.title = title or entry.title
  data.books[key] = entry
  if changed then
    M.save()
  end
end

---@param book_id string
---@param fresh boolean|nil read the file again first: another editor may have finished it(先重读文件：别的编辑器可能已经读完了它)
---@return table|nil { first, last, title, finished, chapters }
function M.book(book_id, fresh)
  if fresh and memory.data then
    local disk = read_disk().books[tostring(book_id)]
    local mine = memory.data.books[tostring(book_id)]
    if disk and mine then
      mine.finished = earlier(mine.finished, disk.finished)
      mine.chapters = math.max(tonumber(mine.chapters) or 0, tonumber(disk.chapters) or 0)
    elseif disk then
      memory.data.books[tostring(book_id)] = disk
    end
  end
  local entry = current().books[tostring(book_id)]
  return entry and vim.deepcopy(entry) or nil
end

---Note that a book was read to its last page.
---(记下某本书读到了最后一页)
---@param book_id string
---@param chapters integer|nil chapters in the catalog then(当时目录里的章节数)
function M.finished(book_id, chapters)
  local data = current()
  local key = tostring(book_id)
  local entry = data.books[key] or { first = M.day() }
  entry.finished = entry.finished or M.day()
  entry.chapters = math.max(tonumber(entry.chapters) or 0, tonumber(chapters) or 0)
  entry.last = M.day()
  data.books[key] = entry
  M.save()
end

---Weeks in a row, up to this one, with reading on at least one day. A week is
---not lost to a missed day, and the week just begun counts as kept until it
---ends, so the count does not drop on a Monday morning.
---(到本周为止，连续多少周至少有一天读过书。漏一天不会丢掉这一周；刚开始的这一周在结束前都算
--- 保住了，所以周一早上计数不会掉下来)
---@param now integer|nil unix seconds, for tests(unix 秒，供测试)
---@return integer
function M.week_streak(now)
  now = now or os.time()
  local days = current().days
  local t = os.date("*t", now)
  -- Monday of this week, at noon so daylight saving never moves the date
  -- (本周一的中午：这样夏令时永远不会挪动日期)
  local monday = os.time({ year = t.year, month = t.month, day = t.day - (t.wday + 5) % 7, hour = 12 })
  local streak = 0
  for week = 0, 104 do
    local read = false
    for offset = 0, 6 do
      local key = M.day(monday - week * 7 * 86400 + offset * 86400)
      if (tonumber(days[key]) or 0) > 0 then
        read = true
        break
      end
    end
    if read then
      streak = streak + 1
    elseif week > 0 then
      break
    end
  end
  return streak
end

return M
