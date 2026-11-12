--[[
Reading highlights and thoughts from the official Agent API:

* `/book/bookmarklist`   my highlights for a whole book (one request)
* `/book/bestbookmarks`  community highlights for one chapter, with a reader count
* `/book/readreviews`    the thoughts attached to a set of ranges, batched
(从官方 Agent API 读取划线与想法：我的划线（整本一次请求）、本章热门划线（带人数）、
 一批 range 下的想法（分批）)

Depends on `annotations_model` and `annotations_store` only.
(只依赖 `annotations_model` 与 `annotations_store`)
]]

local gateway = require("weread.api_gateway")
local log = require("weread.log")
local model = require("weread.annotations_model")
local store = require("weread.annotations_store")

local M = {}

local MAX_RANGES_PER_BATCH = 10

---@param book_id string
---@param callback fun(ok: boolean, data: table|string)
local function fetch_book_highlights(book_id, callback)
  gateway.call("/book/bookmarklist", { bookId = book_id }, callback)
end

---@param book_id string
---@param chapter_uid string
---@param callback fun(ok: boolean, data: table|string)
local function fetch_chapter_popular(book_id, chapter_uid, callback)
  gateway.call("/book/bestbookmarks", {
    bookId = book_id,
    chapterUid = tonumber(chapter_uid) or 0,
    synckey = 0,
  }, callback)
end

---Fetch the thoughts under the given ranges, in batches the service accepts.
---(分批获取这些划线下的想法)
---@param book_id string
---@param chapter_uid string
---@param ranges string[]
---@param callback fun(ok: boolean, data: table[]|string)
local function fetch_thoughts(book_id, chapter_uid, ranges, callback)
  local batches = {}
  for index = 1, #ranges, MAX_RANGES_PER_BATCH do
    local batch = {}
    for offset = index, math.min(index + MAX_RANGES_PER_BATCH - 1, #ranges) do
      batch[#batch + 1] = { range = ranges[offset], maxIdx = 0, count = 20, synckey = 0 }
    end
    batches[#batches + 1] = batch
  end

  if #batches == 0 then
    callback(true, {})
    return
  end

  local responses = {}
  local pending = #batches
  local failed = nil

  for _, batch in ipairs(batches) do
    -- Silent: a chapter opening must not pop an error for thoughts it only
    -- fetches in the background.
    -- (静默：打开章节时后台顺带取想法，失败不应弹错误)
    gateway.call("/book/readreviews", {
      bookId = book_id,
      chapterUid = tonumber(chapter_uid) or 0,
      reviews = batch,
    }, { silent = true }, function(ok, data)
      if ok then
        responses[#responses + 1] = data
      elseif not failed then
        failed = data
      end
      pending = pending - 1
      if pending == 0 then
        if #responses == 0 and failed then
          callback(false, failed)
        else
          callback(true, responses)
        end
      end
    end)
  end
end

---Page size of the full thought list. The chapter load asks for 20 per range,
---which cuts off a hot passage; `K` walks `hasMore`/`maxIdx` to get them all.
---(全量想法的分页大小。加载章节时每个 range 只取 20 条，热门段落会被截断；K 按
--- `hasMore`/`maxIdx` 翻页取全)
local THOUGHT_PAGE = 50
local THOUGHT_PAGES_MAX = 20

---Every thought under one range, following the service's pagination.
---(某个 range 下的全部想法，按服务端分页翻完)
---
---Verified against the live service: `maxIdx` of the response is the offset of
---the next page, and `hasMore = 1` while there is one.
---(已对线上服务验证：响应里的 `maxIdx` 就是下一页的偏移，还有下一页时 `hasMore = 1`)
---@param book_id string
---@param chapter_uid string
---@param range string
---@param callback fun(ok: boolean, thoughts: table[]|string, total: integer|nil)
function M.fetch_all_thoughts(book_id, chapter_uid, range, callback)
  local thoughts, seen = {}, {}
  local pages, total = 0, nil
  local function page(offset)
    pages = pages + 1
    gateway.call("/book/readreviews", {
      bookId = book_id,
      chapterUid = tonumber(chapter_uid) or 0,
      reviews = { { range = range, maxIdx = offset, count = THOUGHT_PAGE, synckey = 0 } },
    }, { silent = true }, function(ok, data)
      if not ok then
        -- a later page failing still leaves the ones already read
        -- (后面某页失败时，已经取到的照样交出去)
        if #thoughts > 0 then
          callback(true, thoughts, total)
        else
          callback(false, data)
        end
        return
      end
      local group = nil
      for _, candidate in ipairs((data or {}).reviews or {}) do
        if candidate.range == range then
          group = candidate
        end
      end
      group = group or {}
      total = tonumber(group.totalCount) or total
      for _, entry in ipairs(group.pageReviews or {}) do
        local thought = model.thought_of(entry)
        if thought and not (thought.id and seen[thought.id]) then
          thoughts[#thoughts + 1] = thought
          if thought.id then
            seen[thought.id] = true
          end
        end
      end
      local next_offset = tonumber(group.maxIdx) or 0
      if tonumber(group.hasMore) == 1 and next_offset > offset and pages < THOUGHT_PAGES_MAX then
        page(next_offset)
      else
        callback(true, thoughts, total)
      end
    end)
  end
  page(0)
end

---Fetch every highlight and thought for one chapter and cache the result.
---(拉取一章的全部划线与想法并缓存)
---@param book_id string
---@param chapter table needs chapterUid
---@param chapter_key string
---@param callback fun(ok: boolean, result: table[]|string, meta: table|nil) meta.mine_ok: my own list was fetched(我的划线列表拉到了)
function M.load(book_id, chapter, chapter_key, callback)
  local chapter_uid = tostring(chapter.chapterUid)
  local path = store.annotations_path(book_id, chapter_key)

  fetch_book_highlights(book_id, function(mine_ok, mine)
    if not mine_ok then
      log.warn("bookmarklist failed: %s", tostring(mine))
    end

    fetch_chapter_popular(book_id, chapter_uid, function(popular_ok, popular)
      if not popular_ok then
        log.warn("bestbookmarks failed: %s", tostring(popular))
      end

      local annotations = {}
      if mine_ok then
        for _, annotation in ipairs(model.from_bookmarklist(mine, chapter_uid)) do
          model.upsert(annotations, annotation)
        end
      end
      if popular_ok then
        for _, annotation in ipairs(model.from_bestbookmarks(popular, chapter_uid)) do
          model.upsert(annotations, annotation)
        end
      end

      -- An uploaded book has no thoughts to fetch, and asking only earns `-2020`.
      -- (上传的书没有想法可取，去问只会换来 `-2020`)
      -- A partial answer is cached too (no request on every open), but marked,
      -- so it is fetched again once it is old: the cache is otherwise never
      -- refetched, and a list fetched offline would hide the highlights for good.
      -- (残缺的结果也缓存（不必每次打开都请求），但做上标记，过一阵就重新拉：否则缓存永不重拉，
      --  离线时拉到的列表会让这一章的划线永远看不见)
      local complete = mine_ok and popular_ok
      if #annotations == 0 or model.is_uploaded(book_id) then
        model.sort(annotations)
        store.write_cached(path, annotations, complete)
        callback(true, annotations, { mine_ok = mine_ok })
        return
      end

      local ranges = {}
      for _, annotation in ipairs(annotations) do
        ranges[#ranges + 1] = annotation.range
      end

      fetch_thoughts(book_id, chapter_uid, ranges, function(thoughts_ok, responses)
        if thoughts_ok then
          for _, response in ipairs(responses) do
            model.attach_thoughts(annotations, response)
          end
        else
          log.warn("readreviews failed: %s", tostring(responses))
        end

        -- Ordering matters for the summary popup and for the "closest marker"
        -- lookup, and rune order is the reading order.
        -- (顺序对汇总弹窗与「最近标记」查找都重要，rune 顺序即阅读顺序)
        model.sort(annotations)

        store.write_cached(path, annotations, complete and thoughts_ok)
        callback(true, annotations, { mine_ok = mine_ok })
      end)
    end)
  end)
end

return M
