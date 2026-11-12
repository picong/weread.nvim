--[[
Where the annotation data lives on disk, and the operations on it: the
per-chapter cache of the account's list, the offset map of a chapter, and the
highlights made in the editor (`highlights.json`). Also the "which chapter is
this buffer" context the write paths need.
(划线数据在磁盘上的位置及其读写：每章账号列表的缓存、章节偏移表，以及在编辑器里画的划线
 （`highlights.json`）；还有写路径需要的「这个 buffer 是哪一章」的上下文)

Depends on `annotations_model` (plus cache and xhtml) only, so fetch, render and
sync can all sit on top of it without a load-time loop.
(只依赖 `annotations_model`（加 cache 与 xhtml），因此 fetch、render、sync 都能建在它上面，
 加载期不成环)
]]

local cache = require("weread.cache")
local log = require("weread.log")
local model = require("weread.annotations_model")
local xhtml = require("weread.xhtml")

local M = {}

-- ------------------------------------------------------------------ paths

---@param book_id string
---@param chapter_key string
---@return string
function M.annotations_path(book_id, chapter_key)
  return string.format("%s/%s.json", cache.annotations_dir(book_id), chapter_key)
end

---@param book_id string
---@param chapter_key string
---@return string
function M.map_path(book_id, chapter_key)
  return string.format("%s/%s.map.json", cache.chapters_dir(book_id), chapter_key)
end

---Parsed offset map (`NNNN.map.json`) of a chapter, or nil when there is none.
---(章节的偏移表（NNNN.map.json）；没有则 nil)
---
---The one place the annotation modules get a map from. It goes through the
---reader session's cache, which parses the file once and reuses it until the
---file changes. A chapter key is `%04d` of the chapter's index, so the chapter
---table the session wants can be rebuilt from it: no catalog needs to be loaded.
---(annotation 各模块取偏移表的唯一入口。走阅读会话的缓存：文件只解析一次，直到文件变化。
--- 章节 key 就是章节序号的 `%04d`，所以会话要的 chapter 表可以由它还原，不需要已加载目录)
---@param book_id string
---@param chapter_key string
---@return table|nil
function M.chapter_map(book_id, chapter_key)
  local index = tonumber(chapter_key)
  if index then
    return require("weread.session").chapter_map(book_id, { chapterIdx = index })
  end
  return cache.read_json(M.map_path(book_id, chapter_key))
end

---The cached map and account list of a chapter.
---(某章缓存的偏移表与账号划线列表)
---@param book_id string
---@param chapter_key string
---@return table|nil map
---@return table|nil annotations
function M.cached(book_id, chapter_key)
  local map = M.chapter_map(book_id, chapter_key)
  local path = M.annotations_path(book_id, chapter_key)
  local partial = vim.uv.fs_stat(path .. ".partial")
  if partial and os.time() - partial.mtime.sec > M.PARTIAL_TTL then
    -- fetched while part of the service was failing: ask again
    -- (拉取时有接口失败：再问一次)
    return map, nil
  end
  return map, cache.read_json(path)
end

---Seconds a partially fetched list is trusted before it is fetched again.
---(残缺的列表在重新拉取之前可以信任多少秒)
M.PARTIAL_TTL = 600

---Cache a chapter's fetched list; `complete = false` marks it for a refetch
---after PARTIAL_TTL.
---(缓存一章拉到的列表；`complete = false` 时做标记，PARTIAL_TTL 之后重新拉)
---@param path string
---@param annotations table[]
---@param complete boolean
function M.write_cached(path, annotations, complete)
  local ok, err = cache.write_json(path, annotations)
  if ok == false then
    require("weread.log").warn("annotations: cache write failed: %s", tostring(err))
    return
  end
  if complete then
    os.remove(path .. ".partial")
  else
    cache.write(path .. ".partial", "")
  end
end

-- ------------------------------------------------------------------ local highlights

---Where the highlights made in the editor are kept: source rune ranges, which
---is also how WeRead itself addresses them, so a local highlight and a server
---one are the same kind of thing (and survive a page re-layout).
---(在编辑器里画的划线存在哪：源 rune 区间——微信读书自己也是这么定位的，因此本地划线与
--- 服务端划线是同一种东西，也能扛过重新排版)
---@param book_id string
---@return string
function M.local_path(book_id)
  return cache.book_dir(book_id) .. "/highlights.json"
end

---Paths whose last read found a file that exists but could not be read. Saving
---over such a file would destroy the only copy, so `save_local` refuses.
---(上一次读取时发现「文件在但读不了」的路径。覆盖这样的文件会毁掉仅存的一份，
--- 所以 `save_local` 拒绝写)
---@type table<string, boolean>
local unreadable = {}

---Copy a file aside before something is dropped from it.
---(在丢掉其中内容之前，先把文件复制一份留底)
---@param path string
---@return string|nil backup
local function keep_copy(path)
  local raw = cache.read(path)
  if not raw then
    return nil
  end
  local stamp = os.date("%Y%m%d-%H%M%S")
  local backup = string.format("%s.corrupt-%s", path, stamp)
  local suffix = 0
  while vim.uv.fs_stat(backup) do
    suffix = suffix + 1
    backup = string.format("%s.corrupt-%s-%d", path, stamp, suffix)
  end
  if not cache.write(backup, raw) then
    return nil
  end
  return backup
end

---Keep only what the rest of the module can iterate: chapter key -> list of
---entries that are tables with a string range. Returns how many were dropped.
---(只留下本模块其余部分能遍历的东西：章节 key → 条目列表，条目是带字符串 range 的 table。
--- 同时返回丢掉了几项)
---@param store table
---@return table clean
---@return integer dropped
local function sanitize(store)
  local clean, dropped = {}, 0
  for key, list in pairs(store) do
    if type(key) == "string" and type(list) == "table" then
      local kept = {}
      for _, entry in ipairs(list) do
        if type(entry) == "table" and type(entry.range) == "string" then
          kept[#kept + 1] = entry
        else
          dropped = dropped + 1
        end
      end
      clean[key] = kept
    else
      dropped = dropped + 1
    end
  end
  return clean, dropped
end

---@param book_id string
---@return table<string, table[]> keyed by chapter key(按章节 key 分组)
function M.local_store(book_id)
  local path = M.local_path(book_id)
  unreadable[path] = nil
  local data = cache.read_json(path)
  if type(data) ~= "table" then
    -- Nothing came back. "No file" and "a corrupt file the cache moved aside"
    -- are safe to start over from; a file that is still there but unreadable
    -- is not: the next save would replace the only copy of it.
    -- (什么都没读到。「没有文件」和「cache 已挪走的损坏文件」可以放心重新开始；而文件还在
    --  却读不了就不行：下一次保存会把仅存的那份换掉)
    local stat = vim.uv.fs_stat(path)
    if stat and stat.size > 0 then
      unreadable[path] = true
      log.warn("%s exists but could not be read; local highlights are not saved until it can", path)
    end
    return {}
  end
  local clean, dropped = sanitize(data)
  if dropped > 0 then
    local backup = keep_copy(path)
    log.warn("%s: dropped %d malformed entries (original kept at %s)", path, dropped, tostring(backup))
    -- write the clean store back once the original is kept, or every read
    -- (and they are frequent) makes another backup
    -- (原件留底后把清理过的写回去，否则每次读取（读得很频繁）都会再备份一份)
    if backup then
      cache.write_json(path, clean)
    end
  end
  return clean
end

---@param book_id string
---@param store table
---@return boolean saved
function M.save_local(book_id, store)
  local path = M.local_path(book_id)
  if unreadable[path] then
    log.warn("not saving %s: its current content could not be read", path)
    return false
  end
  local ok, err = cache.write_json(path, store)
  if not ok then
    log.warn("could not save %s: %s", path, tostring(err))
    return false
  end
  return true
end

---@param book_id string
---@param chapter_key string
---@return table[]
function M.local_for(book_id, chapter_key)
  local store = M.local_store(book_id)
  return store[chapter_key] or {}
end

---@param book_id string
---@param chapter_key string
---@param range string
---@param text string
---@return table entry
function M.add_local(book_id, chapter_key, range, text)
  local store = M.local_store(book_id)
  store[chapter_key] = store[chapter_key] or {}
  for _, existing in ipairs(store[chapter_key]) do
    if existing.range == range then
      existing.text = text ~= "" and text or existing.text
      -- highlighted on purpose now, so it is synced like any other
      -- (现在是有意划的线了，和其它划线一样同步)
      existing.local_only = nil
      M.save_local(book_id, store)
      return existing
    end
  end
  local entry = { range = range, text = text, created_at = os.time() }
  store[chapter_key][#store[chapter_key] + 1] = entry
  table.sort(store[chapter_key], function(left, right)
    return (tonumber(left.range:match("^(%d+)")) or 0) < (tonumber(right.range:match("^(%d+)")) or 0)
  end)
  M.save_local(book_id, store)
  return entry
end

---@param book_id string
---@param chapter_key string
---@param range string
---@return boolean removed
function M.remove_local(book_id, chapter_key, range)
  local store = M.local_store(book_id)
  local list = store[chapter_key]
  if type(list) ~= "table" then
    return false
  end
  for index, entry in ipairs(list) do
    if entry.range == range then
      table.remove(list, index)
      M.save_local(book_id, store)
      return true
    end
  end
  return false
end

---The local highlights of a chapter, in the shape the renderer and the popups
---already understand.
---(某章的本地划线，形式与渲染器和弹窗已经认识的那种一致)
---@param book_id string
---@param chapter_key string
---@return table[]
function M.local_annotations(book_id, chapter_key)
  local annotations = {}
  for _, entry in ipairs(M.local_for(book_id, chapter_key)) do
    annotations[#annotations + 1] = {
      range = entry.range,
      text = entry.text or "",
      note = entry.note,
      note_synced = entry.note_synced,
      mine = true,
      -- a record that carries a bookmark id has been synced to the account
      -- (带 bookmark id 的记录已经同步到了账号)
      unsynced = entry.bookmark_id == nil or nil,
      bookmark_id = entry.bookmark_id,
      count = 0,
      thoughts = {},
    }
  end
  return annotations
end

---Server annotations plus the local ones; a local highlight on a range the
---server also knows about merges into it (and keeps the server's thoughts).
---(服务端划线加上本地划线；本地与服务端同 range 时合并到服务端那条，并保留其想法)
---@param book_id string
---@param chapter_key string
---@param list table[]|nil
---@return table[]
function M.merged(book_id, chapter_key, list)
  local merged = {}
  for _, annotation in ipairs(list or {}) do
    model.upsert(merged, annotation)
  end
  for _, annotation in ipairs(M.local_annotations(book_id, chapter_key)) do
    model.upsert(merged, annotation)
  end
  model.sort(merged)
  return merged
end

---Record that a local highlight now lives in the account too.
---(记下某条本地划线已经进了账号)
---@param book_id string
---@param chapter_key string
---@param range string
---@param bookmark_id string
---@return boolean found the record is still here(记录还在)
function M.mark_synced(book_id, chapter_key, range, bookmark_id)
  local store = M.local_store(book_id)
  local found = false
  for _, entry in ipairs(store[chapter_key] or {}) do
    if entry.range == range then
      entry.bookmark_id = bookmark_id
      entry.synced_at = os.time()
      found = true
    end
  end
  if found then
    M.save_local(book_id, store)
  end
  return found
end

---Forget the synced highlights the account no longer has: removed on the
---phone, so they go here too instead of lingering as marks nobody owns.
---(忘掉账号里已经没有的已同步划线：手机上删掉了，这里也跟着删，而不是留下一条谁都不认的记号)
---@param book_id string
---@param chapter_key string
---@param server table[] the account's list for the chapter, freshly fetched(刚拉到的本章账号列表)
---@param since integer only records synced before this fetch started(只处理这次拉取开始前就已同步的记录)
---@return integer removed
function M.prune_synced(book_id, chapter_key, server, since)
  local present = {}
  for _, annotation in ipairs(server or {}) do
    if annotation.mine then
      present[annotation.range] = true
    end
  end
  local store = M.local_store(book_id)
  local kept, removed = {}, 0
  for _, entry in ipairs(store[chapter_key] or {}) do
    if entry.bookmark_id and not present[entry.range] and (tonumber(entry.synced_at) or 0) < since then
      removed = removed + 1
    else
      kept[#kept + 1] = entry
    end
  end
  if removed > 0 then
    store[chapter_key] = kept
    M.save_local(book_id, store)
  end
  return removed
end

---Keep a note on the local record of a highlight, making the record when the
---range has none. Works from ids alone, so it does not need the chapter buffer
---to still exist.
---(把一段备注存到划线的本地记录上，该 range 还没有记录就补一条。只靠 id 工作，
--- 因此不要求章节 buffer 还在)
---@param book_id string
---@param chapter_key string
---@param range string
---@param content string
---@param text string|nil the passage, when the range has no local record yet
---@param synced boolean|nil the service accepted it(服务端已接受)
---@param review_id string|nil the service's id for it(服务端给它的 id)
function M.set_note(book_id, chapter_key, range, content, text, synced, review_id)
  -- A thought can be written on a highlight the account owns, which has no local
  -- record: make one, so `K` has somewhere to show it.
  -- (想法可能写在账号自己的划线上，那条没有本地记录：补一条，K 才有地方显示它)
  local found = false
  for _, entry in ipairs(M.local_for(book_id, chapter_key)) do
    if entry.range == range then
      found = true
    end
  end
  if not found then
    M.add_local(book_id, chapter_key, range, text or "")
    -- A record made only to hold a note is not a highlight of mine: a thought on
    -- someone else's highlight must not turn into one in the account.
    -- (只为挂备注补的记录不算我的划线：写在别人划线上的想法，不能在账号里变成我的划线)
    local records = M.local_store(book_id)
    for _, entry in ipairs(records[chapter_key] or {}) do
      if entry.range == range then
        entry.local_only = true
      end
    end
    M.save_local(book_id, records)
  end
  local records = M.local_store(book_id)
  records[chapter_key] = records[chapter_key] or {}
  for _, entry in ipairs(records[chapter_key]) do
    if entry.range == range then
      entry.note = content
      -- Keep the cloud state with the note: K says whether it is already on
      -- the server instead of calling every local copy "local only".
      -- (把云端状态跟备注一起存：K 能说清它是否已经在服务端，而不是把本地副本一律
      --  标成「仅本地」)
      entry.note_synced = synced == true
      entry.note_review_id = review_id ~= nil and tostring(review_id) or nil
      entry.note_at = os.time()
    end
  end
  M.save_local(book_id, records)
end

---Run `change` over the cached account list of a chapter and write it back,
---when there is a cached list to change.
---(对某章缓存的账号列表做一次修改并写回；没有缓存列表就什么都不做)
---@param book_id string
---@param chapter_key string
---@param change fun(list: table[]): table[]
local function update_cached(book_id, chapter_key, change)
  local path = M.annotations_path(book_id, chapter_key)
  local cached = cache.read_json(path)
  if type(cached) == "table" then
    cache.write_json(path, change(cached))
  end
end

---Drop a highlight from the chapter's copy of the account's list, both the
---buffer's and the cached one, so it does not come back before a refetch.
---(把一条划线从本章那份账号列表里去掉——buffer 里的与缓存里的都去掉，免得重新拉取前它又出现)
---@param buf integer
---@param book_id string
---@param chapter_key string
---@param range string
function M.forget_server(buf, book_id, chapter_key, range)
  local function without(list)
    local kept = {}
    for _, annotation in ipairs(list or {}) do
      if annotation.range ~= range then
        kept[#kept + 1] = annotation
      end
    end
    return kept
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.b[buf].weread_server_annotations = without(vim.b[buf].weread_server_annotations)
  end
  update_cached(book_id, chapter_key, without)
end

---Drop one of my thoughts from the chapter's copy of the account's list, both
---the buffer's and the cached one, so it disappears before a refetch.
---(把一条我的想法从本章那份账号列表里去掉——buffer 与缓存都去掉，免得重新拉取前它又出现)
---@param buf integer
---@param book_id string
---@param chapter_key string
---@param range string
---@param review_id string|nil
function M.forget_thought(buf, book_id, chapter_key, range, review_id)
  if not review_id then
    return
  end
  local function without(list)
    for _, annotation in ipairs(list or {}) do
      if annotation.range == range then
        local kept, removed = {}, false
        for _, thought in ipairs(annotation.thoughts or {}) do
          if tostring(thought.id) == tostring(review_id) then
            removed = true
          else
            kept[#kept + 1] = thought
          end
        end
        annotation.thoughts = kept
        if removed and tonumber(annotation.thought_total) then
          annotation.thought_total = math.max(0, tonumber(annotation.thought_total) - 1)
        end
      end
    end
    return list
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.b[buf].weread_server_annotations = without(vim.b[buf].weread_server_annotations)
  end
  update_cached(book_id, chapter_key, without)
end

-- ------------------------------------------------------------------ chapter context

---The book's own text a range covers, read from the cached source: what the
---app shows under the highlight, without the spaces a wrapped page line adds.
---(某个 range 覆盖的原文，从缓存的源文读出：也就是 App 在划线下显示的文字，不带折行
--- 拼接出来的空格)
---@param book_id string
---@param chapter_key string
---@param range string
---@return string|nil
function M.source_text(book_id, chapter_key, range)
  local from, to = model.parse_range(range)
  local source = from and cache.read(string.format("%s/%s.xhtml", cache.chapters_dir(book_id), chapter_key))
  if not source then
    return nil
  end
  local ok_from, head = pcall(vim.str_byteindex, source, "utf-32", from, false)
  local ok_to, tail = pcall(vim.str_byteindex, source, "utf-32", to, false)
  if not ok_from or not ok_to or not head or not tail or tail <= head then
    return nil
  end
  local text = source:sub(head + 1, tail):gsub("<[^>]*>", ""):gsub("%s*\n%s*", "")
  text = vim.trim(xhtml.decode_entities(text))
  return text ~= "" and text or nil
end

---Chapter and book details a write needs.
---(写操作需要的章节与书籍信息)
---@param buf integer
---@return table|nil
function M.write_context(buf)
  local reader = require("weread.reader")
  local info = reader.buffer_info(buf)
  if not info then
    return nil
  end
  local chapter = ((reader.state.catalog or {}).chapters or {})[info.chapter_index]
  if not chapter then
    return nil
  end
  return {
    book_id = info.book_id,
    chapter_uid = tostring(chapter.chapterUid),
    chapter_idx = chapter.chapterIdx,
    chapter_key = info.chapter_key,
    chapter_index = info.chapter_index,
    book = reader.state.book or {},
  }
end

---The chapter buffer to operate on.
---(要操作的章节 buffer)
---Popups steal the "current buffer", so a command that looks at the current
---buffer right after a popup opened would silently work on the wrong one.
---(弹窗会抢走「当前 buffer」，因此弹窗打开后再看当前 buffer 会静默作用于错误的 buffer)
---@return integer|nil buf
---@return table|nil info
function M.chapter_buffer()
  local reader = require("weread.reader")
  local current = vim.api.nvim_get_current_buf()
  local info = reader.buffer_info(current)
  if info then
    return current, info
  end

  local best, best_info, best_used = nil, nil, -1
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local buf_info = reader.buffer_info(buf)
    if buf_info then
      local used = vim.fn.getbufinfo(buf)[1].lastused or 0
      if used > best_used then
        best, best_info, best_used = buf, buf_info, used
      end
    end
  end
  return best, best_info
end

return M
