--[[
Chapter requests may finish in a different order from the reader's choices.
(章节请求的完成顺序可能与读者选择章节的顺序不同)
]]

local config = require("weread.config")
config.setup({ data_dir = vim.fn.tempname(), sync_interval = 0, sync_pull = false, keymaps = false,
  animations = { enabled = false } })
config.ensure_dirs()

local cache = require("weread.cache")
local pipeline = require("weread.chapter_pipeline")
local reader = require("weread.reader")
local session = require("weread.session")
local window = require("weread.reader_window")

---@param run fun(requests: table[], shown: table[], released: table[], adopted: table[])
local function with_requests(run)
  local saved = {
    ensure = pipeline.ensure_cached,
    prefetch = pipeline.schedule_prefetch,
    display = window.display_chapter,
    translate = reader.auto_translate,
    progress = package.loaded["weread.progress"],
    notify = vim.notify,
  }
  local requests, shown, released, adopted = {}, {}, {}, {}
  pipeline.ensure_cached = function(book, chapter, callback)
    requests[#requests + 1] = { book = book, chapter = chapter, finish = callback }
  end
  pipeline.schedule_prefetch = function() end
  window.display_chapter = function(book, chapter, index, opts)
    shown[#shown + 1] = { win = vim.api.nvim_get_current_win(), index = index, opts = opts }
  end
  reader.auto_translate = function() end
  package.loaded["weread.progress"] = {
    undefer = function(remote) released[#released + 1] = remote end,
    adopted = function(remote) adopted[#adopted + 1] = remote end,
  }
  vim.notify = function() end
  session.state.book = { book_id = "async-book", title = "测试书" }
  session.state.catalog = { chapters = {
    { chapterUid = 1, chapterIdx = 1, title = "第一章", wordCount = 50 },
    { chapterUid = 2, chapterIdx = 2, title = "第二章", wordCount = 50 },
    { chapterUid = 3, chapterIdx = 3, title = "第三章", wordCount = 50 },
  } }
  session.set_page_width(40)
  vim.cmd("only")
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
  local ok, err = pcall(run, requests, shown, released, adopted)
  pipeline.ensure_cached = saved.ensure
  pipeline.schedule_prefetch = saved.prefetch
  window.display_chapter = saved.display
  reader.auto_translate = saved.translate
  package.loaded["weread.progress"] = saved.progress
  vim.notify = saved.notify
  vim.cmd("only")
  if not ok then error(err, 0) end
end

describe("reader asynchronous chapter choices", function()
  it("keeps the latest choice when the first request finishes last", function()
    with_requests(function(requests, shown)
      reader.open_index(1)
      reader.open_index(2)
      requests[2].finish(true)
      requests[1].finish(true)
      eq(#shown, 1, "only the latest choice is displayed")
      eq(shown[1].index, 2)
    end)
  end)

  it("does not display an older request even while the latest is still loading", function()
    with_requests(function(requests, shown)
      reader.open_index(1)
      reader.open_index(2)
      requests[1].finish(true)
      eq(#shown, 0, "the old chapter cannot flash or save an obsolete position")
      requests[2].finish(true)
      eq(shown[1].index, 2)
    end)
  end)

  it("keeps a normal buffer opened while the chapter was downloading", function()
    with_requests(function(requests, shown)
      reader.open_index(1)
      local scratch = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_win_set_buf(0, scratch)
      requests[1].finish(true)
      eq(#shown, 0)
      eq(vim.api.nvim_get_current_buf(), scratch)
    end)
  end)

  it("keeps requests in separate windows independent", function()
    with_requests(function(requests, shown)
      local first = vim.api.nvim_get_current_win()
      reader.open_index(1)
      vim.cmd("vsplit")
      local second = vim.api.nvim_get_current_win()
      reader.open_index(2)
      requests[2].finish(true)
      requests[1].finish(true)
      eq(#shown, 2)
      eq(shown[1].win, second)
      eq(shown[2].win, first)
    end)
  end)

  it("releases an obsolete remote jump without adopting or falling back from it", function()
    with_requests(function(requests, shown, released, adopted)
      local remote = { book_id = "async-book", chapter_uid = "1", chapter_offset = 10 }
      local fallbacks = 0
      reader.open_index(1, { remote = remote, on_fail = function() fallbacks = fallbacks + 1 end })
      reader.open_index(2)
      requests[1].finish(false, "old request failed")
      requests[2].finish(true)
      eq(fallbacks, 0, "an old failure cannot start another navigation")
      eq(released, { remote })
      eq(#adopted, 0)
      eq(#shown, 1)
      eq(shown[1].index, 2)
    end)
  end)
end)

describe("reader refresh", function()
  it("reloads an existing buffer even when renderer and page width did not change", function()
    local chapter = { chapterUid = 1, chapterIdx = 1, title = "第一章" }
    local path = cache.chapter_file("refresh-book", chapter, "md")
    truthy(cache.write(path, "old text\n"))
    local meta = { renderer = require("weread.xhtml").VERSION, page_width = 40, map = {} }
    truthy(cache.write_json(cache.chapter_file("refresh-book", chapter, "map.json"), meta))
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    truthy(cache.write(path, "new text\n"))
    window.reload_if_stale(buf, meta, "refresh-book", chapter, true)
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "new text" })
  end)
end)
