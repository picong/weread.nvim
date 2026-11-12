--[[
The reader session: what every reader module reads and nobody owns.
(阅读会话：每个阅读器模块都要读、却不归任何一个模块所有的东西)

`reader.lua` used to hold all of this next to the keymaps, the window setup and
the fetching, so any module that only wanted "which chapter is this buffer" had
to depend on the whole reader. This module depends on leaves only (config, cache,
xhtml, log, layout), which is what lets the window, keymap, pipeline and
autocmd modules sit beside each other without ever forming a load-time cycle.
(以前这些都和键位、窗口装配、抓取挤在 reader.lua 里，于是只想知道「这个 buffer 是哪一章」的
 模块也得依赖整个阅读器。本模块只依赖叶子模块（config、cache、xhtml、log、layout），
 窗口、键位、流水线、自动命令这些模块才能并排放着，加载时永远不会成环)

`reader.state` is this module's `state` table, not a copy of it: the apps that
poke at it from outside see the same book and catalog the reader does.
(`reader.state` 就是本模块的 `state` 表本身而不是副本：从外面戳它的模块看到的书和目录与阅读器一致)
]]

local cache = require("weread.cache")
local config = require("weread.config")
local layout = require("weread.layout")
local log = require("weread.log")
local xhtml = require("weread.xhtml")

local M = {}

M.state = {
  book = nil, -- { book_id, title, author, psvts, pclts, token }
  catalog = nil, -- { chapters = {...} }
  index = 0,
  inflight = {},
}
local state = M.state

-- ------------------------------------------------------------------ catalog

---Chapters of the loaded catalog (an empty list when none is loaded).
---(已加载目录的章节列表，没加载时为空表)
---@return table[]
function M.chapters()
  return (state.catalog or {}).chapters or {}
end

---A chapter is readable when it carries text. WeRead lists cover and divider
---entries with `wordCount = 0`.
---(wordCount 为 0 的是封面/分页条目，不参与阅读)
---@param chapter table
---@return boolean
function M.is_readable(chapter)
  local words = tonumber(chapter.wordCount)
  if words == nil then
    return true
  end
  return words > 0
end

---@return integer[] indices of readable chapters
function M.readable_indices()
  local indices = {}
  for index, chapter in ipairs(M.chapters()) do
    if M.is_readable(chapter) then
      indices[#indices + 1] = index
    end
  end
  return indices
end

---@param index integer
---@return integer next readable index, or the same index when there is none
function M.next_readable(index)
  local chapters = M.chapters()
  for candidate = index + 1, #chapters do
    if M.is_readable(chapters[candidate]) then
      return candidate
    end
  end
  return index
end

---@param index integer
---@return integer
function M.prev_readable(index)
  for candidate = index - 1, 1, -1 do
    if M.is_readable(M.chapters()[candidate]) then
      return candidate
    end
  end
  return index
end

---@param index integer
---@return integer position among readable chapters (1-based)
---@return integer total readable chapters
function M.position_of(index)
  local indices = M.readable_indices()
  for position, candidate in ipairs(indices) do
    if candidate == index then
      return position, #indices
    end
  end
  return 1, math.max(1, #indices)
end

-- ------------------------------------------------------------------ buffers

---@param buf integer|nil
---@return table|nil the `vim.b.weread` marker of a chapter buffer
function M.buffer_info(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ok, info = pcall(vim.api.nvim_buf_get_var, buf, "weread")
  if not ok or type(info) ~= "table" then
    return nil
  end
  return info
end

---@return table|nil the session, when the current buffer is a chapter of the loaded book
function M.current()
  local info = M.buffer_info()
  if not info or not state.book or state.book.book_id ~= info.book_id then
    return nil
  end
  return state
end

---@param book_id string
---@param chapter_key string
---@return integer|nil
function M.find_chapter_buffer(book_id, chapter_key)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local info = M.buffer_info(buf)
    if info and info.book_id == book_id and info.chapter_key == chapter_key then
      return buf
    end
  end
  return nil
end

---The catalog entry a chapter buffer shows.
---(章节 buffer 所显示的目录条目)
---@param info table|nil buffer marker(buffer 标记)
---@return table|nil
function M.chapter_of(info)
  return info and M.chapters()[info.chapter_index] or nil
end

-- ------------------------------------------------------------------ page width

---Page width the chapters of this session are rendered for. Kept next to the
---session state because a re-render triggered by a resize must not fetch
---anything: it re-lays out the cached source at the new width.
---(本次会话章节所用的版心宽度。放在会话状态旁边，因为 resize 触发的重排不能联网：
--- 它只是用新宽度把缓存里的源重新排一遍)
local session_page_width = nil

---@return integer|nil the page width the current session is laid out for
function M.page_width()
  return session_page_width
end

---@param width integer|nil
function M.set_page_width(width)
  session_page_width = width
end

---Page width a chapter opened right now should be laid out for.
---(此刻打开的章节应当按多宽的版心排版)
---@return integer
function M.current_page_width()
  if session_page_width then
    return session_page_width
  end
  return layout.page_width(vim.api.nvim_get_current_win())
end

-- ------------------------------------------------------------------ chapter map

---How many parsed maps are kept. A reader only ever touches the chapter on
---screen and its neighbours, so a handful is all that is worth the memory.
---(最多保留几份解析结果。读者只会碰屏幕上这一章和相邻的几章，留几份就够了)
M.MAP_CACHE_LIMIT = 3

---Parsed `map.json` per path, plus the paths from least to most recently used.
---(按路径缓存的 map.json 解析结果，以及按最近使用程度从旧到新排列的路径)
local map_cache = {}
local map_order = {}

---Identity of the file as it is on disk: a rewrite changes the size or the
---modification time, down to the nanosecond.
---(文件在磁盘上的身份：重写会改变大小或修改时间，精确到纳秒)
---@param path string
---@return string|nil nil when the file does not exist(文件不存在时为 nil)
local function map_stamp(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  return string.format("%d.%09d:%d", stat.mtime.sec, stat.mtime.nsec or 0, stat.size)
end

---@param path string
local function map_forget(path)
  map_cache[path] = nil
  for position, candidate in ipairs(map_order) do
    if candidate == path then
      table.remove(map_order, position)
      return
    end
  end
end

---@param path string
local function map_touch(path)
  for position, candidate in ipairs(map_order) do
    if candidate == path then
      table.remove(map_order, position)
      break
    end
  end
  map_order[#map_order + 1] = path
end

---Parsed map.json of a chapter, kept until the file changes.
---(章节的 map.json 解析结果，文件未变则一直复用)
---
---A map is 150-320 KB of JSON. Reading it on every position checkpoint would
---parse that every few seconds; reading it never would leave the offset map
---unavailable, which is exactly when a re-render at a new page width needs it.
---Every reader of the file goes through here so the cost is paid once.
---(一份 map 是 150-320KB 的 JSON。每次保存位置都解析一遍太浪费；完全不读又会在换版心宽度
--- 重排之后拿不到偏移表。所有读这个文件的地方都走这里，解析的代价只付一次)
---@param book_id string
---@param chapter table
---@return table|nil
function M.chapter_map(book_id, chapter)
  local path = cache.chapter_file(book_id, chapter, "map.json")
  local stamp = map_stamp(path)
  if not stamp then
    map_forget(path)
    return nil
  end
  local cached = map_cache[path]
  if cached and cached.stamp == stamp then
    map_touch(path)
    return cached.meta
  end
  local meta = cache.read_json(path)
  map_cache[path] = { stamp = stamp, meta = meta }
  map_touch(path)
  while #map_order > M.MAP_CACHE_LIMIT do
    map_cache[table.remove(map_order, 1)] = nil
  end
  return meta
end

---Forget the parsed map of a chapter. Called wherever the file is written or
---deleted, because a rewrite within the clock's resolution that keeps the size
---would otherwise look like the old file.
---(忘掉某章已解析的 map。凡写入或删除这个文件的地方都要调：在时钟精度之内、大小又没变的
--- 重写，否则会被当成旧文件)
---@param book_id string
---@param chapter table
function M.invalidate_chapter_map(book_id, chapter)
  map_forget(cache.chapter_file(book_id, chapter, "map.json"))
end

-- ------------------------------------------------------------------ offsets

---Rune offset the first character of a rendered line came from.
---(渲染行第一个字符对应的源 rune 偏移)
---
---This is what makes the reading position survive a re-render: line numbers
---change when the page is laid out again, but the sentence a reader stopped at
---does not.
---(这正是阅读位置能扛过重排的原因：重新排版后行号会变，但读者停下的那句话不会)
---@param meta table|nil parsed map.json
---@param line integer 0-based rendered line(0 基的渲染行号)
---@return integer|nil
function M.rune_of_line(meta, line)
  if type(meta) ~= "table" or type(meta.map) ~= "table" then
    return nil
  end
  local on_line, next_line, previous_line = nil, nil, nil
  for _, segment in ipairs(meta.map) do
    if segment.src_from then
      if segment.line == line then
        if not on_line or segment.src_from < on_line then
          on_line = segment.src_from
        end
      elseif segment.line > line then
        -- the cursor sits on a blank line between paragraphs, or on a figure:
        -- the reader wants the next sentence that came from the source
        -- (光标落在段间空行或插图上：读者想要的是下一句来自源文的正文)
        if not next_line or segment.src_from < next_line then
          next_line = segment.src_from
        end
      elseif not previous_line or segment.src_from > previous_line then
        previous_line = segment.src_from
      end
    end
  end
  -- A translation under a paragraph has no runes of its own: it stands for the
  -- paragraph above it, not the next one.
  -- (段落下方的译文自己没有 rune：它代表上面那一段，而不是下一段)
  local lines = type(meta.lines) == "table" and meta.lines or {}
  local shown = lines[tostring(line)] or lines[line]
  if not on_line and type(shown) == "table" and shown.translation and previous_line then
    return previous_line
  end
  return on_line or next_line or previous_line
end

---Source rune offset of the cursor: the coordinate the WeRead apps report
---progress in (`chapterOffset`), the same one highlight ranges use.
---(光标处的源 rune 偏移：微信读书各端上报进度用的坐标（chapterOffset），与划线 range 同一套)
---
---A rendered offset would count indents, margins and newlines the app never
---sees, and land another device somewhere else in the chapter.
---(渲染后的偏移会把 App 看不到的缩进、边距、换行算进去，另一端就会跳到章里别的地方)
---@param buf integer|nil
---@param win integer|nil
---@return integer|nil offset
---@return integer|nil source_runes length of the chapter source, for a fraction(章节源文长度，用来算比例)
function M.source_offset(buf, win)
  win = win or vim.api.nvim_get_current_win()
  buf = buf or vim.api.nvim_win_get_buf(win)
  local info = M.buffer_info(buf)
  if not info or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
    return nil
  end
  local chapter = M.chapter_of(info)
  if not chapter then
    return nil
  end
  local meta = M.chapter_map(info.book_id, chapter)
  if type(meta) ~= "table" or type(meta.map) ~= "table" then
    return nil
  end
  if not M.map_matches(buf) then
    -- laid out again behind the buffer: its line numbers mean nothing in this
    -- map, and the position remembered when it was shown is the truth
    -- (在 buffer 背后被重排过：它的行号在这份 map 里没有意义，以显示时记下的位置为准)
    local remembered = vim.b[buf].weread_source_offset
    return remembered, tonumber(meta.source_runes)
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local text = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1] or ""
  local offset = xhtml.rune_at(meta, cursor[1] - 1, cursor[2], text) or M.rune_of_line(meta, cursor[1] - 1)
  -- kept on the buffer, for the moment the map on disk is replaced under it
  -- (记在 buffer 上，供磁盘上的 map 被替换之后使用)
  vim.b[buf].weread_source_offset = offset
  return offset, tonumber(meta.source_runes)
end

---Is the offset map on disk the one the buffer was laid out with? A chapter
---can be laid out again behind a buffer (a prefetch, a translation arriving);
---until the buffer is reloaded, its line numbers belong to the old map, and
---reading them against the new one lands somewhere else in the chapter.
---(磁盘上的 offset map 是不是这个 buffer 排版时用的那份？章节可能在 buffer 背后被重排（预取、
--- 译文到达）；buffer 重新载入之前，它的行号属于旧 map，拿新 map 去读就会落到章里别的地方)
---@param buf integer
---@return boolean
function M.map_matches(buf)
  local info = M.buffer_info(buf)
  if not info then
    return false
  end
  local chapter = M.chapter_of(info)
  local meta = chapter and M.chapter_map(info.book_id, chapter)
  if type(meta) ~= "table" then
    return false
  end
  local shown = info.translated == true and "weread" or info.translated
  local mapped = meta.translated == true and "weread" or meta.translated
  return shown == mapped
    and (tonumber(info.page_width) or 0) == (tonumber(meta.page_width) or 0)
    and info.renderer == meta.renderer
end

---Source rune offset a rendered line starts at, without moving the cursor.
---(某渲染行起点的源 rune 偏移，不移动光标)
---@param buf integer
---@param line integer 1-based
---@return integer|nil
function M.line_source(buf, line)
  local info = M.buffer_info(buf)
  if not info then
    return nil
  end
  local chapter = M.chapter_of(info)
  if not chapter then
    return nil
  end
  return M.rune_of_line(M.chapter_map(info.book_id, chapter), line - 1)
end

---Rendered line (1-based) a source rune offset lands on, in a chapter that is
---already rendered.
---(某个源 rune 偏移落在已渲染章节的哪一行（1 基）)
---@param book_id string
---@param chapter table
---@param rune integer
---@return integer|nil
function M.line_of_source(book_id, chapter, rune)
  local meta = M.chapter_map(book_id, chapter)
  if type(meta) ~= "table" or not rune then
    return nil
  end
  local from = xhtml.resolve(meta, rune, rune + 1)
  if from and from.line then
    return from.line + 1
  end
  -- past the last text run (an offset at the closing tags): the last text line
  -- (超出最后一个文本段（偏移落在结束标签上）：取最后一行正文)
  local last = nil
  for _, segment in ipairs(meta.map or {}) do
    if segment.src_from and segment.src_from <= rune and (not last or segment.line > last) then
      last = segment.line
    end
  end
  return last and (last + 1) or nil
end

---Footnotes of the chapter in a buffer, from its map.
---(某个 buffer 里章节的脚注，取自它的 map)
---@param buf integer|nil
---@return table[]
function M.footnotes(buf)
  local info = M.buffer_info(buf)
  if not info then
    return {}
  end
  local chapter = M.chapter_of(info)
  local meta = chapter and M.chapter_map(info.book_id, chapter)
  return (type(meta) == "table" and type(meta.footnotes) == "table") and meta.footnotes or {}
end

-- ------------------------------------------------------------------ position

---What this process last wrote (or confirmed) per book, with the identity of
---positions.json at that moment. While the file is still the one we left, the
---record is trusted instead of re-read and re-parsed.
---(本进程最近一次写入（或确认）的位置记录，按书记，连同当时 positions.json 的身份。
--- 文件还是我们离开时的那个，就直接信这份记录，不再读盘解析)
---@type table<string, { stamp: string, record: table }>
local saved_positions = {}

---@return string|nil nil when the file does not exist(文件不存在时为 nil)
local function positions_stamp()
  local stat = vim.uv.fs_stat(config.path("positions.json"))
  if not stat then
    return nil
  end
  -- the inode joins the size and time: a write that goes through a temporary
  -- file lands on a new one, which a clock tick shorter than the write cannot hide
  -- (inode 也算进去：经临时文件的写入会落在新 inode 上，写入快过时钟刻度也藏不住)
  return string.format("%d.%09d:%d:%s", stat.mtime.sec, stat.mtime.nsec or 0, stat.size, tostring(stat.ino))
end

---The record on file for a book: ours when the file is untouched since, else
---read from disk. An unreadable file reads as empty, as it always has.
---(某本书当前记在盘上的记录：文件自那以后没动过就用我们自己的，否则读盘。读不出来的文件
--- 按空处理，这一点一直如此)
---@param book_id string
---@return table|nil
local function recorded_position(book_id)
  local memo = saved_positions[book_id]
  local stamp = positions_stamp()
  if memo and stamp and memo.stamp == stamp then
    return memo.record
  end
  return cache.read_position(book_id)
end

---Is `current` the very place `previous` records? The time stamp is left out on
---purpose: it says when the reader moved, not where they are.
---(`current` 与 `previous` 记的是不是同一个位置？时间戳有意不比：它说的是读者何时动过，
--- 而不是读者在哪)
---@param previous table
---@param current table
---@return boolean
local function same_place(previous, current)
  return previous.chapter_key == current.chapter_key
    and tonumber(previous.chapter_index) == tonumber(current.chapter_index)
    and tostring(previous.chapter_uid) == tostring(current.chapter_uid)
    and tonumber(previous.line) == tonumber(current.line)
    and tonumber(previous.src_from) == tonumber(current.src_from)
    and tonumber(previous.total_lines) == tonumber(current.total_lines)
end

---Persist the reading position of a chapter buffer.
---(保存章节 buffer 的阅读位置)
---
---Called on every window switch, buffer leave, focus loss and checkpoint, mostly
---with the reader exactly where they were: a place that has not changed is not
---written again, so those events cost a stat instead of a parse and a rewrite of
---the file that holds every book's position.
---(每次切窗口、离开 buffer、失焦、定期检查点都会调用，而多数时候读者就在原地：没变的位置
--- 不再写盘，这些事件因此只花一次 stat，而不是把存着所有书位置的那个文件解析再重写一遍)
---@param buf_override integer|nil
---@return boolean written false when there was nothing to save or nothing changed(没有要存的或没有变化时为 false)
function M.save_position(buf_override)
  -- Autocmd callbacks receive the event args table as their first positional
  -- argument, so anything that is not a number means "the current buffer".
  -- Reading a table as a buffer number silently made this function return early
  -- — which is how the reading position ended up frozen at the top of the
  -- chapter.
  -- (autocmd 回调会把事件参数表当作第一个位置参数传进来，因此非数字一律视为「当前
  --   buffer」。把表当 buffer 号会让本函数静默提前返回——阅读位置因此一直停在章节
  --   开头)
  local buf = (type(buf_override) == "number" and buf_override) or vim.api.nvim_get_current_buf()
  local info = M.buffer_info(buf)
  if not info then
    return false
  end
  local win = vim.fn.bufwinid(buf)
  local line = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or vim.fn.line(".")
  local chapter = M.chapter_of(info)
  local src_from = chapter and M.rune_of_line(M.chapter_map(info.book_id, chapter), line - 1) or nil
  local record = {
    chapter_key = info.chapter_key,
    chapter_index = info.chapter_index,
    chapter_uid = info.chapter_uid,
    line = line,
    -- where this line starts in the source, so a re-render does not lose the
    -- reader's place(该行在源文中的起点，重排后不会丢失阅读位置)
    src_from = src_from,
    total_lines = vim.api.nvim_buf_line_count(buf),
  }

  local book_id = tostring(info.book_id)
  local previous = recorded_position(book_id)
  if previous and previous.updated_at and same_place(previous, record) then
    return false
  end

  -- The time stamp says when the reader last *moved*, not when this function
  -- last ran: it runs on every window switch, and a fresh stamp on an unmoved
  -- place made the phone's newer progress look older than ours.
  -- (时间戳表示读者最后一次**移动**的时刻，而不是本函数最后一次运行的时刻：每次切窗口
  --  都会运行它，给没动过的位置盖新戳，会让手机上更新的进度看起来比我们的旧)
  local moved = not previous
    or previous.chapter_key ~= record.chapter_key
    or tonumber(previous.src_from) ~= src_from
    or (src_from == nil and tonumber(previous.line) ~= line)
  record.updated_at = (moved or not previous.updated_at) and os.time() or previous.updated_at

  local called, ok, err = pcall(cache.write_position, book_id, record)
  if not called or ok == false then
    log.warn("could not save the reading position of %s: %s", book_id, tostring(called and err or ok))
    saved_positions[book_id] = nil
    return false
  end
  local stamp = positions_stamp()
  saved_positions[book_id] = stamp and { stamp = stamp, record = record } or nil
  return true
end

return M
