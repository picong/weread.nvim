--[[
Cache failures and out-of-order downloads must reach every chapter waiter.
(缓存失败与乱序下载都必须通知每个章节等待者)
]]

local cache = require("weread.cache")
local config = require("weread.config")
local content = require("weread.content")
local pipeline = require("weread.chapter_pipeline")
local session = require("weread.session")
local timer = require("weread.timer")

config.setup({ data_dir = vim.fn.tempname(), sync_interval = 0, sync_pull = false })
config.ensure_dirs()
local book = { book_id = "pipeline-book", title = "测试书" }
local chapter = { chapterUid = 1, chapterIdx = 1, title = "第一章", wordCount = 100 }
session.state.book = book
session.state.catalog = { chapters = { chapter } }
session.set_page_width(40)

---@param run fun(requests: table[])
local function with_downloads(run)
  local saved = { state = content.fetch_reader_state, chapter = content.fetch_chapter,
    assets = content.fetch_assets, write = cache.write }
  pipeline.drop_cache(book.book_id, chapter, { "md", "map.json", "xhtml", "trans.xhtml", "css" })
  session.state.inflight = {}
  local requests = {}
  content.fetch_reader_state = function(_, _, callback)
    callback(true, { psvts = "test-token" })
  end
  content.fetch_chapter = function(_, callback)
    requests[#requests + 1] = callback
  end
  content.fetch_assets = function(_, _, callback)
    callback(true, { images = {} })
  end
  local ok, err = pcall(run, requests)
  content.fetch_reader_state, content.fetch_chapter, content.fetch_assets = saved.state, saved.chapter, saved.assets
  cache.write = saved.write
  if not ok then error(err, 0) end
end

---@param kind string
local function fail_write(kind)
  local original = cache.write
  local path = cache.chapter_file(book.book_id, chapter, kind)
  cache.write = function(target, ...)
    if target == path then return false, "ENOSPC: " .. kind end
    return original(target, ...)
  end
end

describe("chapter pipeline cache failures", function()
  for _, kind in ipairs({ "md", "map.json" }) do
    it("reports a local " .. kind .. " write failure without downloading again", function()
      with_downloads(function(requests)
        truthy(cache.write(cache.chapter_file(book.book_id, chapter, "xhtml"), "<p>缓存的正文。</p>"))
        fail_write(kind)
        local result
        pipeline.ensure_cached(book, chapter, function(ok, err) result = { ok, err } end)
        truthy(result, "local render finished")
        eq(result[1], false)
        matches(result[2], "ENOSPC")
        eq(#requests, 0, "a network retry cannot fix a disk failure")
      end)
    end)
  end

  for _, kind in ipairs({ "xhtml", "md", "map.json", "css", "trans.xhtml" }) do
    it("reports a downloaded " .. kind .. " write failure to all waiters", function()
      with_downloads(function(requests)
        fail_write(kind)
        local results = {}
        local function done(ok, err) results[#results + 1] = { ok, err } end
        pipeline.ensure_cached(book, chapter, done)
        pipeline.ensure_cached(book, chapter, done)
        eq(#requests, 1, "concurrent readers share the download")
        local source = kind == "trans.xhtml"
          and '<p>Hello.</p><p class="wr-translation">你好。</p>' or "<p>下载的正文。</p>"
        requests[1](true, { xhtml = source, css = "p { color: red; }" })
        eq(#results, 2)
        for _, result in ipairs(results) do
          eq(result[1], false, "a failed write must not be reported as a cached chapter")
          matches(result[2], "ENOSPC")
        end
        eq(next(session.state.inflight), nil, "a failed download can be retried")
      end)
    end)
  end

  it("does not reuse the old map after new markdown was written without its map", function()
    with_downloads(function()
      local source_path = cache.chapter_file(book.book_id, chapter, "xhtml")
      truthy(cache.write(source_path, "<p>旧的正文。</p>"))
      pipeline.ensure_cached(book, chapter, function(ok) truthy(ok) end)
      session.set_page_width(30)
      fail_write("map.json")
      pipeline.ensure_cached(book, chapter, function() end)
      session.set_page_width(40)
      falsy(pipeline.chapter_cache_is_fresh(book.book_id, chapter), "old metadata cannot validate new text")
    end)
  end)
end)

describe("chapter pipeline superseded downloads", function()
  it("keeps the refreshed source when an older download finishes afterwards", function()
    with_downloads(function(requests)
      local results = {}
      pipeline.ensure_cached(book, chapter, function(ok) results.old = ok end)
      session.state.inflight[book.book_id .. ":" .. cache.chapter_key(chapter)] = nil
      pipeline.ensure_cached(book, chapter, function(ok) results.new = ok end)
      requests[2](true, { xhtml = "<p>刷新后的正文。</p>" })
      requests[1](true, { xhtml = "<p>过期的正文。</p>" })
      eq(cache.read(cache.chapter_file(book.book_id, chapter, "xhtml")), "<p>刷新后的正文。</p>")
      eq(results.new, true)
      eq(results.old, false, "the obsolete request still answers its waiters")
      eq(next(session.state.inflight), nil)
    end)
  end)
end)

---@param run fun(calls: integer[], fire: fun(index: integer), timers: table[])
local function with_prefetch_timers(run)
  local saved = { defer = timer.defer, stop = timer.stop, vim_defer = vim.defer_fn,
    prefetch = pipeline.prefetch, input = require("weread.progress_state").last_input }
  local timers, calls = {}, {}
  local function defer(fn)
    local handle = { fn = fn }
    timers[#timers + 1] = handle
    return handle
  end
  timer.defer, vim.defer_fn = defer, defer
  timer.stop = function(handle) if handle then handle.cancelled = true end end
  pipeline.prefetch = function(_, index) calls[#calls + 1] = index end
  local function fire(index)
    local handle = timers[index]
    if not handle.cancelled then handle.fn() end
  end
  require("weread.progress_state").last_input = vim.uv.now() - 10000
  local ok, err = pcall(run, calls, fire, timers)
  if pipeline.cancel_prefetch then pipeline.cancel_prefetch() end
  timer.defer, timer.stop, vim.defer_fn, pipeline.prefetch = saved.defer, saved.stop, saved.vim_defer, saved.prefetch
  require("weread.progress_state").last_input = saved.input
  if not ok then error(err, 0) end
end

describe("chapter pipeline prefetch scheduling", function()
  it("prefetches only the final target after several quick chapter changes", function()
    with_prefetch_timers(function(calls, fire)
      pipeline.schedule_prefetch(book, 2)
      pipeline.schedule_prefetch(book, 3)
      pipeline.schedule_prefetch(book, 4)
      fire(1)
      fire(2)
      fire(3)
      eq(calls, { 4 })
    end)
  end)

  it("cancels a deferred retry when a new target is scheduled", function()
    with_prefetch_timers(function(calls, fire)
      require("weread.progress_state").last_input = vim.uv.now()
      pipeline.schedule_prefetch(book, 2)
      fire(1)
      pipeline.schedule_prefetch(book, 3)
      require("weread.progress_state").last_input = vim.uv.now() - 10000
      fire(2)
      fire(3)
      eq(calls, { 3 })
    end)
  end)
end)
