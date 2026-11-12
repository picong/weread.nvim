--[[
Session tests: the parsed-map cache (LRU, invalidation) the reader modules share.
(会话测试：各阅读器模块共用的已解析 map 缓存——LRU 与失效)
]]

local cache = require("weread.cache")
local chapter_pipeline = require("weread.chapter_pipeline")
local config = require("weread.config")
local session = require("weread.session")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
config.setup({ data_dir = tmpdir, base_url = "http://127.0.0.1:9", proxy = "direct", keymaps = false, sync_interval = 0 })
config.ensure_dirs()

local BOOK_ID = "900"

---@param index integer
---@return table
local function chapter_at(index)
  return { chapterUid = 1000 + index, chapterIdx = index, title = "第 " .. index .. " 章", wordCount = 100 }
end

---@param index integer
---@param marker string stored in the map so a read can be told apart(写进 map 里，用来区分是哪次读到的)
local function write_map(index, marker)
  cache.ensure_book_dirs(BOOK_ID)
  local ok = cache.write_json(cache.chapter_file(BOOK_ID, chapter_at(index), "map.json"), { marker = marker, map = {} })
  truthy(ok, "map written")
end

---Count how many times map.json files are parsed while `fn` runs.
---(统计 fn 运行期间解析了多少次 map.json)
---@param fn fun()
---@return integer
local function count_reads(fn)
  local original = cache.read_json
  local reads = 0
  cache.read_json = function(path, ...)
    if tostring(path):match("%.map%.json$") then
      reads = reads + 1
    end
    return original(path, ...)
  end
  local ok, err = pcall(fn)
  cache.read_json = original
  if not ok then
    error(err, 0)
  end
  return reads
end

describe("session chapter_map cache", function()
  it("parses a map once while the file does not change", function()
    write_map(1, "a")
    local reads = count_reads(function()
      for _ = 1, 5 do
        eq(session.chapter_map(BOOK_ID, chapter_at(1)).marker, "a")
      end
    end)
    eq(reads, 1, "five lookups, one parse")
  end)

  it("keeps only the three most recent chapters", function()
    eq(session.MAP_CACHE_LIMIT, 3)
    for index = 1, 4 do
      write_map(index, "m" .. index)
    end
    -- start from a clean slate: drop whatever earlier cases left behind
    -- (从干净状态开始：丢掉之前用例留下的)
    for index = 1, 4 do
      session.invalidate_chapter_map(BOOK_ID, chapter_at(index))
    end

    local first = count_reads(function()
      for index = 1, 3 do
        session.chapter_map(BOOK_ID, chapter_at(index))
      end
    end)
    eq(first, 3, "three chapters, three parses")

    local again = count_reads(function()
      for index = 1, 3 do
        session.chapter_map(BOOK_ID, chapter_at(index))
      end
    end)
    eq(again, 0, "all three are kept")

    -- chapter 1 is used again, so chapter 2 is now the least recently used
    -- (第 1 章又被用了一次，于是第 2 章成了最久没用的)
    session.chapter_map(BOOK_ID, chapter_at(1))
    eq(count_reads(function()
      session.chapter_map(BOOK_ID, chapter_at(4))
    end), 1, "a fourth chapter is parsed")

    eq(count_reads(function()
      session.chapter_map(BOOK_ID, chapter_at(1))
      session.chapter_map(BOOK_ID, chapter_at(3))
      session.chapter_map(BOOK_ID, chapter_at(4))
    end), 0, "1, 3 and 4 are the ones kept")
    eq(count_reads(function()
      eq(session.chapter_map(BOOK_ID, chapter_at(2)).marker, "m2")
    end), 1, "2 was evicted and is parsed again")
  end)

  it("parses again when the file is rewritten with a different size", function()
    write_map(5, "short")
    eq(session.chapter_map(BOOK_ID, chapter_at(5)).marker, "short")
    write_map(5, "a much longer marker than the first one")
    eq(session.chapter_map(BOOK_ID, chapter_at(5)).marker, "a much longer marker than the first one")
  end)

  it("forgets a map on invalidation even though the file is untouched", function()
    write_map(6, "x")
    session.chapter_map(BOOK_ID, chapter_at(6))
    eq(count_reads(function()
      session.chapter_map(BOOK_ID, chapter_at(6))
    end), 0, "cached")
    session.invalidate_chapter_map(BOOK_ID, chapter_at(6))
    eq(count_reads(function()
      session.chapter_map(BOOK_ID, chapter_at(6))
    end), 1, "parsed again after the invalidation")
  end)

  it("answers nil for a missing file and does not hold a slot for it", function()
    local chapter = chapter_at(7)
    vim.fn.delete(cache.chapter_file(BOOK_ID, chapter, "map.json"))
    eq(session.chapter_map(BOOK_ID, chapter), nil)
    write_map(7, "now there")
    eq(session.chapter_map(BOOK_ID, chapter).marker, "now there", "appears as soon as it is written")
    vim.fn.delete(cache.chapter_file(BOOK_ID, chapter, "map.json"))
    eq(session.chapter_map(BOOK_ID, chapter), nil, "and goes away when deleted")
  end)

  it("drops the map when the pipeline deletes a chapter's files", function()
    local chapter = chapter_at(8)
    write_map(8, "old")
    session.chapter_map(BOOK_ID, chapter)
    chapter_pipeline.drop_cache(BOOK_ID, chapter, { "md", "map.json" })
    eq(session.chapter_map(BOOK_ID, chapter), nil, "nothing stale survives the deletion")
  end)
end)

describe("chapter_pipeline cache writes", function()
  local chapter = chapter_at(9)
  local book = { book_id = BOOK_ID, title = "测试书" }

  it("lays a cached source out again at the page width in use, and shows the new map", function()
    cache.ensure_book_dirs(BOOK_ID)
    cache.write(cache.chapter_file(BOOK_ID, chapter, "xhtml"), "<p>第一段。</p><p>第二段。</p>")

    session.set_page_width(30)
    local done = false
    chapter_pipeline.ensure_cached(book, chapter, function(ok)
      truthy(ok)
      done = true
    end)
    truthy(done, "a cached source is laid out without waiting for the network")
    eq(session.chapter_map(BOOK_ID, chapter).page_width, 30)

    -- the same chapter at another width: the rewritten map must be the one read
    -- back, however close the two writes are in time
    -- (同一章换一个宽度：读回来的必须是重写后的 map，不管两次写入在时间上靠得多近)
    session.set_page_width(44)
    chapter_pipeline.ensure_cached(book, chapter, function(ok)
      truthy(ok)
    end)
    eq(session.chapter_map(BOOK_ID, chapter).page_width, 44, "not the map of the previous render")
    session.set_page_width(nil)
  end)

  it("invalidates the parsed map when it writes the chapter", function()
    session.set_page_width(30)
    local invalidated = 0
    local original = session.invalidate_chapter_map
    session.invalidate_chapter_map = function(...)
      invalidated = invalidated + 1
      return original(...)
    end
    local wide = 60
    session.set_page_width(wide)
    local ok, err = pcall(chapter_pipeline.ensure_cached, book, chapter, function() end)
    session.invalidate_chapter_map = original
    session.set_page_width(nil)
    truthy(ok, tostring(err))
    truthy(invalidated >= 1, "the cache was told the file changed")
  end)
end)
