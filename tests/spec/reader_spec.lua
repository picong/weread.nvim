--[[
Reader integration test: loads a book, opens chapters into real buffers and
checks the position memory, all against the local mock server.
(阅读器集成测试：加载书籍、把章节开进真实 buffer、检查位置记忆，全程打本地 mock)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

-- A fixed data dir (wiped on every run) instead of a random tempdir: when a
-- test fails, the cache and the debug log are still there to inspect.
-- (固定数据目录并在每次运行时清空，而不是随机临时目录：测试失败后缓存与日志仍在，
--  可以直接取证)
local tmpdir = "/tmp/weread-test-reader"
vim.fn.delete(tmpdir, "rf")
vim.fn.mkdir(tmpdir, "p")

-- The catalog fixture carries a {{BASE}} placeholder; the routes read it from
-- this ref, which is filled in once the server knows its port.
-- (目录夹具里的 {{BASE}} 由这个 ref 提供，端口只有服务启动后才知道)
local ref = {}
local live = mock_lib.start(mock_lib.weread_routes(ref))
ref.url = live.url

local config = require("weread.config")
local http = require("weread.http")
local cache = require("weread.cache")
local reader = require("weread.reader")
local log = require("weread.log")

-- Progress reporting is off here on purpose: this spec counts network traffic,
-- and reading-time reports are covered by progress_spec.
-- (本 spec 会统计网络请求数，因此关闭进度回传；阅读时长上报由 progress_spec 覆盖)
config.setup({
  data_dir = tmpdir,
  base_url = live.url,
  proxy = "direct",
  keymaps = false,
  sync_interval = 0,
})
config.ensure_dirs()
http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 8, retries = 0, proxy = "direct" })
http.set_cookies({
  { name = "wr_skey", value = "skey", domain = ".weread.qq.com", path = "/", expires = 0, include_subdomains = true },
})
log.setup({ debug = true, path = config.path("weread.log") })

local BOOK_ID = "43208843"

local unpack_values = table.unpack or unpack

---@param runner fun(callback: function)
local function await_async(runner, timeout)
  local captured
  local done = false
  runner(function(...)
    captured = { n = select("#", ...), ... }
    done = true
  end)
  vim.wait(timeout or 20000, function()
    return done
  end, 20)
  if not captured then
    error("timed out waiting for the callback")
  end
  return unpack_values(captured, 1, captured.n)
end

describe("reader catalog helpers", function()
  it("skips the zero-word cover entry", function()
    reader.state.catalog = {
      chapters = {
        { chapterUid = 1, chapterIdx = 1, title = "封面", wordCount = 0 },
        { chapterUid = 2, chapterIdx = 2, title = "第 3 章", wordCount = 151 },
        { chapterUid = 119, chapterIdx = 3, title = "第 4 章", wordCount = 200 },
        { chapterUid = 120, chapterIdx = 4, title = "分隔页", wordCount = 0 },
      },
    }
    eq(reader.is_readable({ wordCount = 0 }), false)
    eq(reader.is_readable({ wordCount = 5 }), true)
    eq(reader.is_readable({}), true, "missing wordCount is treated as readable")
    eq(reader.readable_indices(), { 2, 3 })
    eq(reader.next_readable(1), 2, "jumps over the cover")
    eq(reader.next_readable(3), 3, "stops at the last readable chapter")
    eq(reader.prev_readable(4), 3)
    eq(reader.prev_readable(2), 2)
    local position, total = reader.position_of(3)
    eq(position, 2)
    eq(total, 2)
  end)
end)

describe("reader against a mock server", function()
  it("loads the book and caches metadata + catalog", function()
    local ok, book = await_async(function(cb)
      reader.load_book(BOOK_ID, cb)
    end)
    truthy(ok, tostring(book))
    eq(book.title, "持续交付2.0")
    eq(book.author, "乔梁")
    truthy(book.psvts, "psvts captured for later content requests")

    truthy(cache.read_meta(BOOK_ID), "meta cached")
    local catalog = cache.read_catalog(BOOK_ID)
    eq(#catalog.chapters, 3)
  end)

  it("starts at the first readable chapter", function()
    reader.state.book.remote_chapter_uid = nil
    vim.fn.delete(config.path("positions.json"))
    eq(reader.start_index(), 2, "chapter 1 is the cover")
  end)

  it("renders a chapter into a real buffer", function()
    local before = vim.api.nvim_get_current_buf()
    reader.open_index(2, {})
    vim.wait(20000, function()
      return reader.buffer_info() ~= nil
    end, 50)

    local buf = vim.api.nvim_get_current_buf()
    local info = reader.buffer_info(buf)
    truthy(info, "the buffer carries the weread marker")
    eq(info.book_id, BOOK_ID)
    eq(info.chapter_index, 2)
    eq(vim.bo[buf].filetype, "markdown")
    eq(vim.bo[buf].modifiable, false, "reading is not editing")
    truthy(buf ~= before, "the chapter replaced the scratch buffer")

    local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    truthy(lines:find("第 3 章 宇宙闪烁", 1, true), "heading rendered")
    truthy(lines:find("汪淼把车停在楼下", 1, true), "body rendered")

    -- window options that make it a reader
    -- (让它成为阅读器的窗口选项)
    eq(vim.wo.wrap, true)
    eq(vim.wo.number, false)
    eq(vim.wo.colorcolumn, "", "no vertical guide line through the text by default")
    eq(vim.wo.cursorline, false, "a highlighted line across Chinese text is heavy")
    eq(vim.wo.conceallevel, 2, "needed to hide markdown syntax")
    eq(vim.bo[buf].modifiable, false)
    truthy(vim.wo.winbar:find("第 3 章", 1, true), "winbar shows the chapter")

    -- cache artefacts
    -- (缓存产物)
    local chapter = reader.state.catalog.chapters[2]
    eq(vim.fn.filereadable(cache.chapter_file(BOOK_ID, chapter, "md")), 1)
    eq(vim.fn.filereadable(cache.chapter_file(BOOK_ID, chapter, "map.json")), 1)
    eq(vim.fn.filereadable(cache.chapter_file(BOOK_ID, chapter, "xhtml")), 1)
    eq(vim.fn.filereadable(cache.chapter_file(BOOK_ID, chapter, "css")), 1, "stylesheet cached")
  end)

  it("applies inline styling as attributes instead of visible markdown", function()
    -- end to end: book stylesheet -> converter -> map.json -> extmarks
    -- (端到端：书籍样式表 → 转换器 → map.json → extmark)
    local chapter = reader.state.catalog.chapters[2]
    local meta = cache.read_json(cache.chapter_file(BOOK_ID, chapter, "map.json"))
    eq(meta.renderer, require("weread.xhtml").VERSION)
    truthy(#meta.styles >= 6, "style spans were cached: " .. #(meta.styles or {}))

    local namespace = vim.api.nvim_create_namespace("weread.inline")
    local marks = vim.api.nvim_buf_get_extmarks(vim.api.nvim_get_current_buf(), namespace, 0, -1, { details = true })
    truthy(#marks > 0, "styles were drawn")

    local groups = {}
    local concealed = 0
    for _, mark in ipairs(marks) do
      if mark[4].hl_group then
        groups[mark[4].hl_group] = true
      end
      if mark[4].conceal ~= nil then
        concealed = concealed + 1
      end
    end
    truthy(groups.Bold, "a bold phrase really looks bold")
    truthy(groups.Italic, "and an italic one italic")
    truthy(groups.Underline, "underline, which markdown cannot express")
    truthy(concealed > 0, "the markdown markers are hidden")
  end)

  it("rewrites chapter images to cached local files", function()
    local chapter = reader.state.catalog.chapters[2]
    local md = cache.read(cache.chapter_file(BOOK_ID, chapter, "md"))
    truthy(md:find(tmpdir, 1, true), "the markdown points into the cache dir")
    falsy(md:find("res.weread.qq.com", 1, true), "no remote image urls left")
    truthy(vim.fn.filereadable(tmpdir .. "/books/" .. BOOK_ID .. "/assets/epub_43208843_44.png") == 1)
  end)

  it("serves a cached chapter without touching the network", function()
    -- Cache the *next* chapter too: opening a chapter schedules a background
    -- prefetch, and that prefetch legitimately makes requests. Without this the
    -- assertion would be measuring the prefetch instead of the cache hit.
    -- (把下一章也先缓存：打开章节会触发后台预取，而预取合理地会发请求；否则这个
    --  断言测到的其实是预取，而不是命中缓存)
    local next_chapter = reader.state.catalog.chapters[3]
    reader.prefetch(reader.state.book, 3)
    vim.wait(20000, function()
      return vim.fn.filereadable(cache.chapter_file(BOOK_ID, next_chapter, "md")) == 1
    end, 100)

    live.reset()
    reader.open_index(2, {})
    -- let the deferred prefetch fire before counting
    -- (先让延迟的预取触发，再计数)
    vim.wait(1500, function()
      return false
    end, 50)
    eq(#live.requests, 0, "a fully cached chapter and its prefetch make no request")
  end)

  it("remembers the reading position", function()
    local buf = vim.api.nvim_get_current_buf()
    local info = reader.buffer_info(buf)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.api.nvim_exec_autocmds("BufLeave", { buffer = buf })

    local saved = cache.read_position(info.book_id)
    truthy(saved, "position written")
    eq(saved.chapter_key, info.chapter_key)
    eq(saved.line, 3)

    eq(reader.last_book_id(), BOOK_ID)
    eq(reader.start_index(), 2, "resumes the saved chapter")
  end)

  it("prefetches the next chapter in the background", function()
    vim.fn.delete(config.path("positions.json"))
    reader.state.catalog = cache.read_catalog(BOOK_ID)
    local chapter = reader.state.catalog.chapters[3]
    vim.fn.delete(cache.chapter_file(BOOK_ID, chapter, "md"))

    reader.prefetch(reader.state.book, 3)
    vim.wait(20000, function()
      return vim.fn.filereadable(cache.chapter_file(BOOK_ID, chapter, "md")) == 1
    end, 100)
    eq(vim.fn.filereadable(cache.chapter_file(BOOK_ID, chapter, "md")), 1, "prefetched")
  end)

  it("jumps between chapters", function()
    reader.open_index(2, {})
    vim.wait(5000, function()
      return reader.buffer_info() ~= nil and reader.buffer_info().chapter_index == 2
    end, 50)
    reader.next_chapter()
    vim.wait(5000, function()
      return reader.buffer_info() and reader.buffer_info().chapter_index == 3
    end, 50)
    eq(reader.buffer_info().chapter_index, 3)

    reader.prev_chapter()
    vim.wait(5000, function()
      return reader.buffer_info() and reader.buffer_info().chapter_index == 2
    end, 50)
    eq(reader.buffer_info().chapter_index, 2)
  end)

  it("re-renders a chapter cached by an older renderer without the network", function()
    local chapter = reader.state.catalog.chapters[2]
    local map_path = cache.chapter_file(BOOK_ID, chapter, "map.json")
    local md_path = cache.chapter_file(BOOK_ID, chapter, "md")

    -- simulate a cache produced by the previous typography
    -- (模拟由上一版排版产出的缓存)
    local meta = cache.read_json(map_path)
    meta.renderer = 1
    cache.write_json(map_path, meta)
    cache.write(md_path, "　　旧的排版")

    live.reset()
    reader.open_index(2, {})
    vim.wait(5000, function()
      return (cache.read(md_path) or ""):find("汪淼把车停在楼下", 1, true) ~= nil
    end, 50)

    eq(#live.requests, 0, "the re-render used the cached source XHTML")
    eq(cache.read_json(map_path).renderer, require("weread.xhtml").VERSION)
    local fresh = cache.read(md_path)
    truthy(fresh:find("　　汪淼把车停在楼下", 1, true), "re-rendered with the indented layout")
    falsy(fresh:find("旧的排版", 1, true), "the stale body is gone")
  end)

  it("resumes the recorded chapter instead of the table of contents", function()
    local ui = require("weread.ui")
    local real_select = ui.select
    local picked = false
    ui.select = function()
      picked = true
    end

    -- chapter index 3 of the fixture catalog
    -- (夹具目录里的第 3 项)
    cache.write_position(BOOK_ID, {
      chapter_key = "0003",
      chapter_index = 3,
      chapter_uid = "119",
      line = 1,
      updated_at = os.time(),
    })

    local ok, err = pcall(function()
      reader.open_book(BOOK_ID, {})
      vim.wait(20000, function()
        local info = reader.buffer_info()
        return info ~= nil and info.chapter_index == 3
      end, 100)
    end)
    ui.select = real_select
    truthy(ok, tostring(err))

    falsy(picked, "the index must not be shown when there is a position to resume")
    eq(reader.buffer_info().chapter_index, 3, "landed on the recorded chapter")
    eq(reader.saved_position(BOOK_ID), 3)
  end)

  it("shows the table of contents for a book with no history at all", function()
    local ui = require("weread.ui")
    local real_select = ui.select
    local picked = false
    ui.select = function()
      picked = true
    end

    vim.fn.delete(config.path("positions.json"))
    -- No local record, and the service reports the opening chapter: that is what
    -- a book you have never opened looks like. It must not be treated as
    -- "resume here".
    -- (既无本地记录，服务端报的又是开篇章节——正是从未打开过的书的样子，不能当成
    --  「续读到这」)
    reader.state.book.remote_chapter_uid = reader.state.catalog.chapters[2].chapterUid
    reader.open_book(BOOK_ID, {})
    vim.wait(20000, function()
      return picked
    end, 100)
    ui.select = real_select
    truthy(picked, "a fresh book opens the index")
  end)

  it("refuses to open a chapter that has no text", function()
    local notifications = {}
    local original = vim.notify
    vim.notify = function(message)
      notifications[#notifications + 1] = message
    end
    reader.open_index(1, {})
    vim.notify = original
    local found = false
    for _, message in ipairs(notifications) do
      if message:find("没有正文", 1, true) then
        found = true
      end
    end
    truthy(found, "told the user why nothing happened")
  end)
end)
