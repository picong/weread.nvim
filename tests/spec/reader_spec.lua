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
local xhtml = require("weread.xhtml")

-- Progress reporting is off here on purpose: this spec counts network traffic,
-- and reading-time reports are covered by progress_spec.
-- (本 spec 会统计网络请求数，因此关闭进度回传；阅读时长上报由 progress_spec 覆盖)
config.setup({
  data_dir = tmpdir,
  base_url = live.url,
  gateway_url = live.url,
  proxy = "direct",
  keymaps = false,
  sync_interval = 0,
  sync_pull = true,
})
config.ensure_dirs()
http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 8, retries = 0, proxy = "direct" })
http.set_cookies({
  { name = "wr_skey", value = "skey", domain = ".weread.qq.com", path = "/", expires = 0, include_subdomains = true },
})
log.setup({ debug = true, path = config.path("weread.log") })

-- Remote progress pulls go through the Agent API gateway, which needs an api
-- key on file.
-- (远端进度拉取走 Agent API 网关，需要档案里有一个 api key)
local auth = require("weread.auth")
auth.save_credentials({
  version = 1,
  login_method = "qr",
  account = { name = "测试账号", user_vid = "vid" },
  api_key = "wrk-test-key",
  cookies = { wr_vid = "vid", wr_skey = "skey", wr_ql = "0", wr_rt = "rt" },
})

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
    truthy(lines:find("汪淼把车停在楼下", 1, true), "body rendered")
    -- the title is set once, on the chapter's opening page; the book's own copy
    -- of it as the first heading is still dropped
    -- (标题只在章首页排一次；书里作为第一个标题的那份重复仍被丢弃)
    local _, titles = lines:gsub("第 3 章 宇宙闪烁", "")
    eq(titles, 1, "the title is on the opening page, and not repeated in the body")

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
    truthy(groups.WereadStrong, "a bold phrase really looks bold, in the page's ink")
    truthy(groups.WereadItalic, "and an italic one italic")
    truthy(groups.WereadUnderline, "underline, which markdown cannot express")
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
    truthy(saved.src_from, "and the source offset the line starts at")

    eq(reader.last_book_id(), BOOK_ID)
    eq(reader.start_index(), 2, "resumes the saved chapter")
  end)

  it("keeps the reader's place across a re-render at another page width", function()
    -- Line numbers move when the page is laid out differently; the sentence the
    -- reader stopped at does not, so the position is remembered by source
    -- offset and only falls back to the line number.
    -- (重新排版后行号会变，读者停下的句子不会；因此位置按源偏移记住，行号只作为退路)
    local buf = vim.api.nvim_get_current_buf()
    local info = reader.buffer_info(buf)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.api.nvim_exec_autocmds("BufLeave", { buffer = buf })
    local saved = cache.read_position(info.book_id)
    truthy(saved.src_from, "the offset is what the resume should use")
    local reported_before = reader.source_offset()
    truthy(reported_before, "the cursor has a source offset to report")

    -- another page width: the chapter has to be laid out again
    -- (换一个版心宽度：章节必须重新排版)
    reader.set_page_width(40)
    local chapter = reader.state.catalog.chapters[info.chapter_index]
    vim.fn.delete(cache.chapter_file(BOOK_ID, chapter, "md"))
    await_async(function(done)
      reader.open_index(info.chapter_index, { resume = true })
      vim.defer_fn(done, 400)
    end, 20000)

    local meta = cache.read_json(cache.chapter_file(BOOK_ID, chapter, "map.json"))
    eq(meta.page_width, 40, "re-laid out for the new page")
    local resolved = xhtml.resolve(meta, saved.src_from, saved.src_from + 1)
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    eq(cursor, resolved.line + 1, "the cursor is back on the line that offset belongs to")
    eq(reader.source_offset(), reported_before, "and reports the same source offset as before the re-render")
    eq(reader.line_of_source(BOOK_ID, chapter, reported_before), cursor, "an offset maps back to its line")

    reader.set_page_width(nil)
  end)

  it("turns the page into the neighbouring chapter", function()
    -- Walking past either end of a chapter is what a reader swiping at a page
    -- boundary does, so the reader follows: forward lands at the top of the next
    -- chapter, backward at the end of the previous one.
    -- (走到章节任一端之外，正是读者在页边滑动时做的事，因此跟着翻：往后落在下一章章首，
    --  往前落在上一章章末)
    reader.state.catalog = cache.read_catalog(BOOK_ID)
    local chapter = reader.state.catalog.chapters[2]
    await_async(function(done)
      reader.open_index(2, {})
      vim.defer_fn(done, 400)
    end, 20000)
    eq(reader.buffer_info().chapter_index, 2)

    truthy(reader.auto_next(), "turning the page is on by default")
    truthy(reader.turn(true), "turned forward")
    vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 3
    end, 50)
    eq(reader.buffer_info().chapter_index, 3, "now in the next chapter")

    truthy(reader.turn(false), "turned backward")
    vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 2
    end, 50)
    eq(reader.buffer_info().chapter_index, 2, "back in the previous chapter")
    local last_line = vim.api.nvim_buf_line_count(vim.api.nvim_get_current_buf())
    eq(vim.fn.line("."), last_line, "arriving from below lands on the chapter's last line")

    -- the first chapter has nowhere to go back to
    -- (第一章没有可回退的地方)
    vim.fn.delete(config.path("positions.json"))
    await_async(function(done)
      reader.open_index(2, {})
      vim.defer_fn(done, 400)
    end, 20000)
    falsy(reader.turn(false), "the first chapter does not turn")
    eq(chapter.chapterUid, reader.state.catalog.chapters[2].chapterUid)
  end)

  it("turns the page when a scroll cannot move any further", function()
    -- "Slide to the bottom and carry on" is how a reader asks for the next
    -- chapter; the same gesture at the top asks for the previous one. The
    -- scroll helpers are called directly: mouse events cannot be injected into
    -- a headless session, and the keymaps only forward to them.
    -- (「滑到底再接着滑」就是读者要下一章的方式；在顶部做同样的动作则要上一章。这里直接
    --  调用滚动函数：无界面会话无法注入鼠标事件，键位只是转发)
    reader.state.catalog = cache.read_catalog(BOOK_ID)
    reader.set_page_width(nil)
    await_async(function(done)
      reader.open_index(2, {})
      vim.defer_fn(done, 400)
    end, 20000)
    local buf = vim.api.nvim_get_current_buf()
    eq(reader.buffer_info().chapter_index, 2)

    -- park the cursor on the last line, with the window scrolled to the end
    -- (把光标停在最后一行，并把窗口滚到底)
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
    vim.cmd("normal! zb")
    truthy(reader.wheel_or_turn(true), "the wheel turns the page at the end")
    vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 3
    end, 50)
    eq(reader.buffer_info().chapter_index, 3, "carried on into the next chapter")

    -- and back up from the top of it
    -- (再从它的顶部往上滚)
    vim.cmd("normal! ggzt")
    truthy(reader.wheel_or_turn(false), "and back at the top")
    vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 2
    end, 50)
    eq(reader.buffer_info().chapter_index, 2, "back in the previous chapter")
  end)

  it("gives keymaps to a chapter buffer opened before they existed", function()
    -- The regression a reader actually hit: keymaps were registered only when a
    -- buffer was created, so a session that was already reading never got the
    -- keys an update added — the highlight could be drawn but not removed.
    -- (读者真实踩到的回归：键位只在 buffer 创建时注册，因此已经在读的会话拿不到更新新增的键位
    --  —— 划线能画，却删不掉)
    local config = require("weread.config")
    reader.state.catalog = cache.read_catalog(BOOK_ID)
    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
      if reader.buffer_info(candidate) then
        pcall(vim.api.nvim_buf_delete, candidate, { force = true })
      end
    end

    config.get().keymaps = false
    await_async(function(done)
      reader.open_index(2, {})
      vim.defer_fn(done, 400)
    end, 20000)
    local buf = vim.api.nvim_get_current_buf()
    eq(vim.fn.maparg("<leader>wd", "n", false, true).buffer, nil, "no keymaps while they are off")

    -- the reader turns them on (an update, a config change) and visits the buffer
    -- (阅读器把它们打开（更新、改配置），然后再次进入这个 buffer)
    config.get().keymaps = true
    eq(reader.install_keymaps(buf), true, "the installer reports that it ran")
    eq(vim.fn.maparg("<leader>wd", "n", false, true).buffer, 1, "now it is mapped")
    eq(vim.fn.maparg("<leader>wh", "x", false, true).buffer, 1, "and so is the visual one")
    eq(reader.install_keymaps(buf), false, "running it again changes nothing")
  end)

  it("scrolls within a chapter instead of turning it", function()
    reader.state.catalog = cache.read_catalog(BOOK_ID)
    await_async(function(done)
      reader.open_index(2, {})
      vim.defer_fn(done, 400)
    end, 20000)
    local before = vim.fn.line("w0")
    truthy(reader.scroll_or_turn("\5", true, 2), "the motion moved")
    truthy(vim.fn.line("w0") >= before, "the view scrolled, it did not turn the page")
    eq(reader.buffer_info().chapter_index, 2, "still in the same chapter")
    truthy(reader.wheel_lines() >= 1, "the wheel is worth at least one line")
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

  it("fetches a chapter again whose cached source is garbled", function()
    -- A source decoded from shards that did not fit together, cached before the
    -- decoder refused such results, must not be laid out again from disk.
    -- (由对不上的分片解出、且在解码器拒收这类结果之前就缓存了的源文，不能再从磁盘重排)
    local chapter = reader.state.catalog.chapters[2]
    local html_path = cache.chapter_file(BOOK_ID, chapter, "xhtml")
    local md_path = cache.chapter_file(BOOK_ID, chapter, "md")
    local good = cache.read(html_path)
    cache.write(html_path, (good:gsub('class="', 'clas{\219"', 1)))
    cache.write(md_path, "　　汪淼\219乱码")

    live.reset()
    reader.open_index(2, {})
    vim.wait(20000, function()
      return not (cache.read(md_path) or "\219"):find("\219", 1, true)
        and (cache.read(md_path) or ""):find("汪淼把车停在楼下", 1, true) ~= nil
    end, 50)

    local fetched = false
    for _, request in ipairs(live.requests) do
      fetched = fetched or request.path:find("/chapter/e_0", 1, true) ~= nil
    end
    truthy(fetched, "the chapter was fetched again")
    eq(cache.read(html_path), good, "the clean source replaced the garbled one")
    eq(require("weread.content").find_invalid_text(cache.read(md_path)), nil, "the page is clean UTF-8")
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

  it("opens the chapter picked in the shelf preview, over the saved position", function()
    -- the reader picked chapter 3 in the preview; the record says chapter 2
    -- (读者在预览里点了第 3 项；本机记录在第 2 项)
    cache.write_position(BOOK_ID, {
      chapter_key = "0002",
      chapter_index = 2,
      chapter_uid = "2",
      line = 1,
      updated_at = os.time(),
    })
    reader.open_book(BOOK_ID, { chapter_uid = 119 })
    vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 3
    end, 100)
    eq(reader.buffer_info().chapter_index, 3, "landed on the picked chapter")
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
  it("hands a reading window's options back when it shows another buffer", function()
    local global_conceal = vim.go.conceallevel
    local global_winbar = vim.go.winbar
    reader.open_index(2, {})
    vim.wait(20000, function()
      return reader.buffer_info() ~= nil
    end, 50)
    local win = vim.api.nvim_get_current_win()
    eq(vim.wo[win].number, false, "the page hides line numbers")
    eq(vim.go.conceallevel, global_conceal, "the global value stays the user's")
    eq(vim.go.winbar, global_winbar, "and so does the global winbar")
    local other = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_win_set_buf(win, other)
    require("weread.reader_window").restore_stale()
    eq(vim.wo[win].winbar, global_winbar, "the winbar is gone")
    eq(vim.wo[win].statuscolumn, vim.go.statuscolumn, "and so is the margin")
    eq(vim.wo[win].conceallevel, global_conceal)
    vim.api.nvim_buf_delete(other, { force = true })
  end)
end)

describe("bookmarks, search and quick hide", function()
  local bookmarks = require("weread.bookmarks")

  local function open_chapter(index)
    reader.open_index(index, {})
    vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == index
    end, 50)
    return vim.api.nvim_get_current_buf()
  end

  local function text_line(buf)
    for line, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if text:find("汪淼", 1, true) then
        return line
      end
    end
  end

  it("adds a bookmark at the cursor, by source offset, and removes it again", function()
    vim.fn.delete(cache.book_file(BOOK_ID, "bookmarks.json"))
    local buf = open_chapter(2)
    local line = text_line(buf)
    truthy(line, "the chapter has text")
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    eq(bookmarks.toggle(buf), "added")
    local list = bookmarks.list(BOOK_ID)
    eq(#list, 1)
    eq(list[1].chapter_uid, "2")
    truthy(list[1].offset, "stored by source offset")
    matches(list[1].excerpt, "汪淼")
    eq(vim.api.nvim_win_get_cursor(0)[1], line, "the cursor did not move")
    local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("weread.bookmarks"), 0, -1, {})
    eq(#marks, 1, "the bookmark is drawn")
    eq(marks[1][2], line - 1)

    eq(bookmarks.toggle(buf), "removed", "the same line toggles it off")
    eq(#bookmarks.list(BOOK_ID), 0)
  end)

  it("jumps back to a bookmark from another chapter", function()
    local buf = open_chapter(2)
    local line = text_line(buf)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    bookmarks.toggle(buf)
    open_chapter(3)
    bookmarks.jump(bookmarks.list(BOOK_ID)[1])
    vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 2
    end, 50)
    eq(reader.buffer_info().chapter_index, 2)
    eq(vim.api.nvim_win_get_cursor(0)[1], line, "landed on the bookmarked line")
    vim.fn.delete(cache.book_file(BOOK_ID, "bookmarks.json"))
  end)

  it("finds text in the cached chapters only", function()
    open_chapter(2)
    local chapters = reader.state.catalog.chapters
    local found, searched, missing = bookmarks.search(BOOK_ID, chapters, "汪淼")
    truthy(#found > 0)
    eq(found[1].index, 2)
    truthy(found[1].text:find("汪淼", 1, true))
    truthy(searched >= 1)
    eq(searched + missing, 2, "the cover is not counted")
    local none = bookmarks.search(BOOK_ID, chapters, "不可能出现的词组")
    eq(#none, 0)
  end)

  it("hides the chapter behind an ordinary buffer and brings it back", function()
    local code = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(code, 0, -1, false, { "local x = 1" })
    vim.api.nvim_set_current_buf(code)
    local chapter = open_chapter(2)
    eq(reader.hide(), true)
    eq(vim.api.nvim_get_current_buf(), code, "the previous ordinary buffer covers the book")
    falsy(reader.buffer_info(), "no chapter on screen")
    eq(reader.hide(), false)
    eq(vim.api.nvim_get_current_buf(), chapter, "the same chapter comes back")
  end)
end)

describe("reader remote progress", function()
  local progress = require("weread.progress")

  local function reset()
    ref.progress = nil
    vim.fn.delete(config.path("positions.json"))
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  it("jumps to a position another device left later", function()
    reset()
    -- nothing read here; the phone is 10 minutes ahead
    -- (本机没读过；手机上领先了 10 分钟)
    local future = os.time() + 600
    ref.progress = {
      chapterUid = 119,
      chapterOffset = 100,
      progress = 42,
      updateTime = future,
      summary = "史强说",
    }

    reader.open_book(BOOK_ID, {})
    local landed = vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 3
    end, 50)
    truthy(landed, "landed on the remote chapter (uid 119)")

    -- the offset put the cursor on the sentence it names, not on line 1
    -- (偏移把光标放在它指的那一句上，而不是第 1 行)
    local chapter = reader.state.catalog.chapters[3]
    local line = reader.line_of_source(BOOK_ID, chapter, 100)
    truthy(line and line > 1, "offset 100 is past the chapter head")
    eq(vim.api.nvim_win_get_cursor(0)[1], line, "the cursor sits at the remote sentence")
  end)

  it("keeps the local position when the remote one is older", function()
    reset()
    local past = os.time() - 3600
    ref.progress = {
      chapterUid = 119,
      chapterOffset = 200,
      progress = 60,
      updateTime = past,
      summary = "old",
    }
    cache.write_position(BOOK_ID, {
      chapter_key = "0002",
      chapter_index = 2,
      chapter_uid = "2",
      line = 1,
      src_from = 60,
      updated_at = os.time(),
    })

    reader.open_book(BOOK_ID, {})
    local landed = vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 2
    end, 50)
    truthy(landed, "the local chapter wins")
    eq(reader.buffer_info().chapter_index, 2)
  end)

  it("falls back to the local position when the pull fails", function()
    reset()
    -- the gateway answers with an error (ref.progress is nil)
    -- (网关返回错误（ref.progress 为 nil）)
    cache.write_position(BOOK_ID, {
      chapter_key = "0002",
      chapter_index = 2,
      chapter_uid = "2",
      line = 1,
      src_from = 60,
      updated_at = os.time(),
    })

    reader.open_book(BOOK_ID, {})
    local landed = vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 2
    end, 50)
    truthy(landed, "a failed pull does not block the resume")
  end)

  it("pulls on FocusGained and jumps to the newer remote position", function()
    reset()
    reader.open_index(2, {})
    vim.wait(20000, function()
      return reader.buffer_info() ~= nil
    end, 50)
    eq(reader.buffer_info().chapter_index, 2, "reading chapter 2 locally")

    ref.progress = {
      chapterUid = 119,
      chapterOffset = 150,
      progress = 42,
      updateTime = os.time() + 600,
      summary = "从手机",
    }
    vim.api.nvim_exec_autocmds("FocusGained", {})

    local jumped = vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 3
    end, 50)
    truthy(jumped, "the window followed the phone")

    -- and the jump banked the place locally
    -- (跳转还把位置落到了本地)
    local saved = cache.read_position(BOOK_ID)
    truthy(saved, "position written")
    eq(tostring(saved.chapter_uid), "119")
  end)

  it("ignores its own recent report when pulling", function()
    reset()
    -- A position we uploaded a minute ago must not read as foreign news.
    -- (一分钟前自己上传的位置不能被当成别的设备带来的消息)
    reader.open_index(2, {})
    vim.wait(20000, function()
      return reader.buffer_info() ~= nil
    end, 50)
    local info = reader.buffer_info()

    ref.progress = {
      chapterUid = info.chapter_uid,
      chapterOffset = reader.source_offset(),
      progress = 10,
      updateTime = os.time(),
      summary = "same",
    }
    eq(progress.remote_is_newer(BOOK_ID, {
      chapter_uid = tostring(info.chapter_uid),
      chapter_offset = reader.source_offset(),
      update_time = os.time(),
    }), false, "the position we are sitting on is not news")
  end)

  it("keeps the stamp of a place that did not move", function()
    reset()
    reader.open_index(2, {})
    vim.wait(20000, function()
      return reader.buffer_info() ~= nil
    end, 50)
    local saved = cache.read_position(BOOK_ID)
    local stamp = saved.updated_at - 100
    saved.updated_at = stamp
    cache.write_position(BOOK_ID, saved)
    -- switching windows saves the position again, without moving
    -- (切窗口会再存一次位置，但没有移动)
    vim.api.nvim_exec_autocmds("WinLeave", {})
    eq(cache.read_position(BOOK_ID).updated_at, stamp, "an unmoved place keeps its time")
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
    vim.api.nvim_exec_autocmds("WinLeave", {})
    truthy(cache.read_position(BOOK_ID).updated_at > stamp, "a moved one gets a new one")
  end)

  it("waits for the reader to come back before following another device", function()
    reset()
    reader.open_index(2, {})
    vim.wait(20000, function()
      return reader.buffer_info() ~= nil
    end, 50)
    local chapter_buf = vim.api.nvim_get_current_buf()
    local code = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code)
    falsy(reader.follow_remote({ chapter_uid = "119", chapter_offset = 100, summary = "", update_time = os.time() + 600 }))
    eq(vim.api.nvim_get_current_buf(), code, "a code buffer is never replaced by a chapter")

    vim.api.nvim_win_set_buf(0, chapter_buf)
    local jumped = vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 3
    end, 50)
    truthy(jumped, "back in the book, the waiting position lands")
    pcall(vim.api.nvim_buf_delete, code, { force = true })
  end)

  it("opens the local place when the remote chapter is unknown", function()
    reset()
    ref.progress = {
      chapterUid = 999999,
      chapterOffset = 10,
      progress = 50,
      updateTime = os.time() + 600,
      summary = "?",
    }
    cache.write_position(BOOK_ID, {
      chapter_key = "0002",
      chapter_index = 2,
      chapter_uid = "2",
      line = 1,
      src_from = 60,
      updated_at = os.time() - 3600,
    })
    reader.open_book(BOOK_ID, {})
    local landed = vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 2
    end, 50)
    truthy(landed, "something opens instead of nothing")
  end)

  it("polls the service while a chapter is open and follows it", function()
    reset()
    reader.open_index(2, {})
    vim.wait(20000, function()
      return reader.buffer_info() ~= nil
    end, 50)
    ref.progress = {
      chapterUid = 119,
      chapterOffset = 150,
      progress = 42,
      updateTime = os.time() + 900,
      summary = "从手机",
    }
    progress.poll({ force = true })
    local jumped = vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 3
    end, 50)
    truthy(jumped, "the poll followed the phone without any focus event")
  end)

  it("never applies another book's remote position", function()
    reset()
    reader.open_index(2, {})
    vim.wait(20000, function()
      return reader.buffer_info() ~= nil
    end, 50)
    falsy(reader.follow_remote({ book_id = "some-other-book", chapter_uid = "119", chapter_offset = 10, update_time = os.time() + 600 }))
    falsy(reader.jump_to_remote({ book_id = "some-other-book", chapter_uid = "119", chapter_offset = 10 }))
    vim.wait(300)
    eq(reader.buffer_info().chapter_index, 2, "still where the reader was")
  end)

  it("keeps a remote position the busy reader has not followed, and reports nothing over it", function()
    reset()
    reader.open_index(2, {})
    vim.wait(20000, function()
      return reader.buffer_info() ~= nil
    end, 50)
    ref.progress = {
      chapterUid = 119,
      chapterOffset = 150,
      progress = 42,
      updateTime = os.time() + 900,
      summary = "从手机",
    }
    -- a key press lands while the question is out
    -- (问题发出去时正好有一次按键)
    progress.poll({ force = true })
    progress.touch()
    vim.wait(3000, function()
      return progress.status().deferred ~= nil
    end, 50)
    truthy(progress.deferred(BOOK_ID), "the answer is kept, not dropped")
    eq(reader.buffer_info().chapter_index, 2, "and the reader was not pulled away")
    falsy(progress.flush_sync(), "leaving does not push this machine's place over the phone's")
  end)

  it("follows a held remote position at the next quiet moment, even after local checkpoints", function()
    reset()
    config.setup(vim.tbl_extend("force", config.get(), { sync_debounce = 0.1, sync_interval = 60 }))
    reader.open_index(2, {})
    vim.wait(20000, function()
      return reader.buffer_info() ~= nil
    end, 50)
    progress.defer({
      book_id = BOOK_ID,
      chapter_uid = "119",
      chapter_offset = 150,
      summary = "从手机",
      update_time = os.time() - 30,
    })
    -- the reader keeps reading here: a checkpoint makes the local stamp newer
    -- (读者在这里继续读：一次存档让本地时间戳更新了)
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
    vim.api.nvim_exec_autocmds("WinLeave", {})
    truthy(progress.deferred(BOOK_ID), "the held position survives the checkpoint")
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
    local followed = vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 3
    end, 50)
    truthy(followed, "the settled cursor follows the phone instead of reporting over it")
    falsy(progress.deferred(BOOK_ID), "and the hold is released once the chapter is on screen")
    config.setup(vim.tbl_extend("force", config.get(), { sync_debounce = 5 }))
  end)

  it("opens the local place and lets go when the remote chapter cannot be fetched", function()
    reset()
    cache.write_position(BOOK_ID, {
      chapter_key = "0002",
      chapter_index = 2,
      chapter_uid = "2",
      line = 1,
      src_from = 60,
      updated_at = os.time() - 3600,
    })
    ref.progress = {
      chapterUid = 119,
      chapterOffset = 100,
      progress = 42,
      updateTime = os.time() + 600,
      summary = "史强说",
    }
    -- the remote chapter is not cached and its download fails
    -- (远端章节没有缓存，下载又失败了)
    for _, kind in ipairs({ "md", "map.json", "xhtml", "css" }) do
      vim.fn.delete(cache.chapter_file(BOOK_ID, reader.state.catalog.chapters[3], kind))
    end
    local saved_url = config.get().base_url
    local original_open = reader.open_index
    reader.open_index = function(index, opts)
      if opts and opts.remote then
        config.setup(vim.tbl_extend("force", config.get(), { base_url = "http://127.0.0.1:9" }))
        local done = opts.on_fail
        opts.on_fail = function(...)
          config.setup(vim.tbl_extend("force", config.get(), { base_url = saved_url }))
          if done then
            done(...)
          end
        end
      end
      return original_open(index, opts)
    end
    local messages = {}
    local notify = vim.notify
    vim.notify = function(message)
      messages[#messages + 1] = message
    end
    local ok, err = pcall(function()
      reader.open_book(BOOK_ID, {})
      vim.wait(30000, function()
        local info = reader.buffer_info()
        return info ~= nil and info.chapter_index == 2
      end, 50)
    end)
    vim.notify = notify
    reader.open_index = original_open
    config.setup(vim.tbl_extend("force", config.get(), { base_url = saved_url }))
    truthy(ok, tostring(err))
    eq((reader.buffer_info() or {}).chapter_index, 2, "the local place opens instead of nothing")
    falsy(progress.deferred(BOOK_ID), "and nothing keeps holding this book's reports")
  end)
end)

describe("reader translation across chapters", function()
  local translate = require("weread.translate")

  ---Record every translation request instead of sending it; each one succeeds.
  ---(记下每次翻译请求而不真的发出；每次都成功)
  ---@return table calls, function restore
  local function stub_ensure()
    local calls = {}
    local original = translate.ensure
    translate.ensure = function(book_id, chapters, on_ready)
      calls[#calls + 1] = { book_id = book_id, uid = tostring(chapters[1].chapterUid), count = #chapters }
      on_ready(true, 1)
    end
    return calls, function()
      translate.ensure = original
    end
  end

  ---@param index integer
  local function open(index)
    reader.open_index(index, {})
    vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == index
    end, 50)
  end

  it("translates every chapter opened while the book's translation is on", function()
    await_async(function(cb)
      reader.load_book(BOOK_ID, cb)
    end)
    local chapters = reader.state.catalog.chapters
    -- the fixture is a Chinese book; pretend the service offers a translation
    -- (夹具是中文书；假装服务端提供译文)
    reader.state.book.translatable = true
    local calls, restore = stub_ensure()
    local messages = {}
    local notify = vim.notify
    vim.notify = function(message)
      messages[#messages + 1] = message
    end
    local ok, err = pcall(function()
      translate.set_enabled(BOOK_ID, false)
      open(2)
      vim.wait(300)
      eq(#calls, 0, "nothing is translated while the switch is off")

      translate.set_enabled(BOOK_ID, true)
      open(3)
      vim.wait(2000, function()
        return #calls > 0
      end, 20)
      eq(#calls, 1, "turning into a chapter translates it")
      eq(calls[1].uid, tostring(chapters[3].chapterUid))

      -- the service has not translated it after all: not asked again on every visit
      -- (服务端终究没有给译文：不会每次进来都再问)
      open(2)
      open(3)
      vim.wait(300)
      local asked = 0
      for _, call in ipairs(calls) do
        if call.uid == tostring(chapters[3].chapterUid) then
          asked = asked + 1
        end
      end
      eq(asked, 1, "a chapter is asked about once per session")
    end)
    vim.notify = notify
    restore()
    translate.set_enabled(BOOK_ID, false)
    translate.set_engine(BOOK_ID, nil)
    reader.state.book.translatable = nil
    truthy(ok, tostring(err))
  end)

  it("prepares the next chapter once this one is translated", function()
    local chapters = reader.state.catalog.chapters
    local here = chapters[2]
    local trans = cache.chapter_file(BOOK_ID, here, "trans.xhtml")
    cache.write(trans, cache.read(cache.chapter_file(BOOK_ID, here, "xhtml")) or "<p/>")
    reader.state.book.translatable = true
    local calls, restore = stub_ensure()
    local ok, err = pcall(function()
      translate.set_enabled(BOOK_ID, true)
      reader.auto_translate(2)
      local next_index = reader.next_readable(2)
      eq(#calls, 1, "the next chapter is asked for ahead of time")
      eq(calls[1].uid, tostring(chapters[next_index].chapterUid))
      reader.auto_translate(2)
      eq(#calls, 1, "and only once")
    end)
    restore()
    translate.set_enabled(BOOK_ID, false)
    translate.set_engine(BOOK_ID, nil)
    reader.state.book.translatable = nil
    vim.fn.delete(trans)
    truthy(ok, tostring(err))
  end)

  it("translates with the LLM first, and asks WeRead only when the LLM fails", function()
    local lookup = require("weread.lookup")
    local llm = require("weread.llm_translate")
    local chapters = reader.state.catalog.chapters
    reader.state.book.translatable = true
    local calls, restore = stub_ensure()
    local saved_available, saved_run = lookup.llm_available, llm.run
    local outcome = "ok"
    local ran = {}
    lookup.llm_available = function()
      return true
    end
    llm.run = function(book_id, chapter, opts)
      ran[#ran + 1] = tostring(chapter.chapterUid)
      vim.schedule(function()
        if outcome == "ok" then
          opts.on_done(true, nil, { count = 3, total = 3, ms = 10 })
        else
          opts.on_done(false, "网关超时", { count = 0, total = 3, ms = 10 })
        end
      end)
    end
    local messages = {}
    local notify = vim.notify
    vim.notify = function(message)
      messages[#messages + 1] = message
    end
    local ok, err = pcall(function()
      open(2)
      translate.set_enabled(BOOK_ID, false)
      reader.toggle_translation(true, { engine = "deepseek-v4-flash" })
      vim.wait(2000, function()
        return #ran > 0
      end, 20)
      eq(ran[1], tostring(chapters[2].chapterUid), "the LLM is asked for the chapter on screen")
      vim.wait(300)
      eq(#calls, 0, "WeRead is not asked while the LLM does it")

      outcome = "fail"
      reader.toggle_translation(false)
      open(3)
      reader.toggle_translation(true, { engine = "deepseek-v4-flash" })
      vim.wait(3000, function()
        return #calls > 0
      end, 20)
      eq(#calls, 1, "the LLM failed: WeRead's translation is asked for instead")
      eq(calls[1].uid, tostring(chapters[3].chapterUid))
      local said = table.concat(messages, "\n")
      matches(said, "翻译失败（网关超时），改用微信读书译文")
    end)
    vim.notify = notify
    lookup.llm_available, llm.run = saved_available, saved_run
    restore()
    translate.set_enabled(BOOK_ID, false)
    translate.set_engine(BOOK_ID, nil)
    reader.state.book.translatable = nil
    truthy(ok, tostring(err))
  end)

  it("keeps the reader's sentence on screen while the LLM's translation fills in", function()
    -- The jump that was reported: the chapter was laid out again with the
    -- service's translation behind the buffer, and the cursor's line number,
    -- read against that new map, pointed into an earlier part of the chapter.
    -- (报告的那次跳页：章节在 buffer 背后带着服务端译文被重排，光标的行号拿新 map 去读，指到了
    --  本章前面的地方)
    local lookup = require("weread.lookup")
    local llm = require("weread.llm_translate")
    local pager = require("weread.pager")
    local chapters = reader.state.catalog.chapters
    local target = reader.readable_indices()[2]
    local here = chapters[target]
    reader.state.book.translatable = true
    local calls, restore = stub_ensure()
    local saved_available, saved_chat = lookup.llm_available, lookup.llm_chat
    local saved_chapter = config.get().lookup.chapter
    local saved_interval = require("weread.reader_translate").REDRAW_INTERVAL_MS
    config.get().lookup.chapter = "llm"
    require("weread.reader_translate").REDRAW_INTERVAL_MS = 50
    lookup.llm_available = function()
      return true
    end
    lookup.llm_chat = function(messages, _, done)
      local out = {}
      for id, text in pairs(vim.json.decode(messages[#messages].content)) do
        out[id] = "【译】" .. text:sub(1, 12)
      end
      local timer = vim.defer_fn(function()
        done(vim.json.encode(out), nil)
      end, 250)
      return {
        kill = function()
          pcall(function()
            timer:stop()
          end)
        end,
      }
    end
    llm.FIRST_BATCH_CHARS, llm.BATCH_CHARS = 60, 120
    -- the service's translation is cached too: it must not show up next to the LLM's
    -- (服务端的译文也在缓存里：它不能出现在大模型的译文旁边)
    -- the fixture book is Chinese: this chapter is given English text to translate
    -- (夹具是中文书：给这一章换上要翻译的英文)
    local source_path = cache.chapter_file(BOOK_ID, here, "xhtml")
    local saved_source = cache.read(source_path)
    local paragraphs = {}
    for index = 1, 80 do
      paragraphs[#paragraphs + 1] = string.format(
        "<p>Paragraph %d tells how the architect weighs one trade-off against another before deciding.</p>",
        index
      )
    end
    local english = "<html><body><h1>Trade-offs</h1>\n" .. table.concat(paragraphs, "\n") .. "\n</body></html>"
    -- The service's translation of every paragraph, as a long one: if the page
    -- were ever laid out with it, every line below the top would move far down,
    -- and a line number read against that layout would point far up.
    -- (服务端对每段的译文，而且很长：页面一旦按它排版，页顶以下的每一行都会大幅下移，拿那份排版去读
    --  的行号就会指到很靠前的地方)
    local trans = cache.chapter_file(BOOK_ID, here, "trans.xhtml")
    local long = string.rep("微信读书译文", 30)
    -- the gateway answers slowly, so the page is redrawn while translations are partial
    -- (网关回得慢，页面在译文只到了一部分时就会重画)
    local notify = vim.notify
    vim.notify = function() end
    local ok, err = pcall(function()
      translate.set_enabled(BOOK_ID, false)
      os.remove(cache.chapter_file(BOOK_ID, here, "llm.json"))
      -- a buffer left by an earlier case would be reused as it is
      -- (前面用例留下的 buffer 会被原样复用)
      for _, old in ipairs(vim.api.nvim_list_bufs()) do
        if reader.buffer_info(old) then
          pcall(vim.api.nvim_buf_delete, old, { force = true })
        end
      end
      open(target)
      -- now that the chapter is cached, swap its source for the English one and
      -- lay it out again from cache (the mock serves the same Chinese text for
      -- every chapter, so this has to come after the fetch)
      -- (章节缓存好之后再把源文换成英文、从缓存重排——mock 对每章都给同一段中文，所以必须在抓取之后)
      vim.wait(300)
      cache.write(source_path, english)
      -- written after the fetch, which removes a translation the mock did not send
      -- (抓取之后再写：抓取会删掉 mock 没给的译文)
      cache.write(trans, (english:gsub("</p>", '</p>\n<p class="wr-translation">' .. long .. "</p>")))
      require("weread.chapter_pipeline").drop_cache(BOOK_ID, here, { "md", "map.json" })
      for _, old in ipairs(vim.api.nvim_list_bufs()) do
        if reader.buffer_info(old) then
          pcall(vim.api.nvim_buf_delete, old, { force = true })
        end
      end
      open(target)
      -- let the chapter settle (the pager measures the page once more after
      -- opening), then go two thirds of the way in
      -- (等章节落定（打开之后分页器还会再量一次页），再走到三分之二处)
      vim.wait(300)
      local win = vim.api.nvim_get_current_win()
      local last = vim.api.nvim_buf_line_count(0)
      vim.api.nvim_win_set_cursor(win, { math.floor(last * 2 / 3), 0 })
      pager.show_line(win, vim.fn.line("."))
      vim.wait(100)
      local anchor = reader.source_offset()
      truthy(anchor, "the cursor has a source offset")
      truthy((cache.read(source_path) or ""):find("Paragraph 40", 1, true), "the English source is the cached one")
      local opened = reader.buffer_info()
      eq(opened.chapter_index, target, "the chapter is on screen")
      truthy(last > 100, "the English chapter is the one laid out: " .. last .. " lines")
      reader.toggle_translation(true, { engine = "deepseek-v4-flash" })
      local left = 0
      vim.wait(8000, function()
        local now = reader.source_offset()
        if now and math.abs(now - anchor) > 400 then
          left = left + 1
        end
        return not llm.running(BOOK_ID, here) and llm.preferred(BOOK_ID, here)
      end, 30)
      vim.wait(400)
      truthy(llm.preferred(BOOK_ID, here), "the chapter got translated")
      eq(left, 0, "the place never moved away from the reader's sentence")
      local now = reader.source_offset()
      truthy(math.abs(now - anchor) <= 400, string.format("still at %d, was %d", now, anchor))
      local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      falsy(text:find("微信读书译文", 1, true), "no translation by the service mixed in")
      truthy(text:find("【译】", 1, true), "the LLM's translations are on the page")
      local top, bottom = vim.fn.line("w0"), pager.bottom(win)
      local _, on_screen = table.concat(vim.api.nvim_buf_get_lines(0, top - 1, bottom, false), "\n"):gsub("【译】", "")
      truthy(on_screen > 0, "and on the screen being read")
      eq(#calls, 0, "the service was never asked")
    end)
    vim.notify = notify
    lookup.llm_available, lookup.llm_chat = saved_available, saved_chat
    config.get().lookup.chapter = saved_chapter
    require("weread.reader_translate").REDRAW_INTERVAL_MS = saved_interval
    llm.FIRST_BATCH_CHARS, llm.BATCH_CHARS = 1200, 2400
    restore()
    translate.set_enabled(BOOK_ID, false)
    translate.set_engine(BOOK_ID, nil)
    reader.state.book.translatable = nil
    vim.fn.delete(trans)
    os.remove(cache.chapter_file(BOOK_ID, here, "llm.json"))
    if saved_source then
      cache.write(source_path, saved_source)
    end
    require("weread.chapter_pipeline").drop_cache(BOOK_ID, here, { "md", "map.json" })
    truthy(ok, tostring(err))
  end)

  it("asks who translates, and remembers the pick for the book", function()
    local lookup = require("weread.lookup")
    local ui = require("weread.ui")
    local llm = require("weread.llm_translate")
    reader.state.book.translatable = true
    local saved_available, saved_select, saved_run = lookup.llm_available, ui.select, llm.run
    local saved_models = config.get().lookup.chapter_models
    config.get().lookup.chapter_models = { "claude-opus-5-5", "deepseek-v4-flash" }
    lookup.llm_available = function()
      return true
    end
    local offered, ran = nil, {}
    ui.select = function(opts)
      offered = opts.items
      opts.on_choice(opts.items[1])
    end
    llm.run = function(book_id, chapter, opts)
      ran[#ran + 1] = llm.model(book_id)
      vim.schedule(function()
        opts.on_done(true, nil, { count = 1, total = 1, ms = 1 })
      end)
    end
    local notify = vim.notify
    vim.notify = function() end
    local ok, err = pcall(function()
      translate.set_enabled(BOOK_ID, false)
      translate.set_engine(BOOK_ID, nil)
      open(2)
      reader.toggle_translation(true)
      eq(#offered, 3, "both models and WeRead's translation")
      eq(offered[1].engine, "claude-opus-5-5")
      eq(offered[3].engine, "weread")
      vim.wait(2000, function()
        return #ran > 0
      end, 20)
      eq(ran[1], "claude-opus-5-5", "the picked model translates")
      eq(translate.engine(BOOK_ID), "claude-opus-5-5", "remembered for the book")

      reader.toggle_translation(false)
      translate.set_engine(BOOK_ID, "deepseek-v4-flash")
      reader.toggle_translation(true)
      eq(offered[1].engine, "deepseek-v4-flash", "the last pick comes first")
      truthy(offered[1].text:find("上次", 1, true), "and says so")
    end)
    vim.notify = notify
    lookup.llm_available, ui.select, llm.run = saved_available, saved_select, saved_run
    config.get().lookup.chapter_models = saved_models
    translate.set_enabled(BOOK_ID, false)
    translate.set_engine(BOOK_ID, nil)
    reader.state.book.translatable = nil
    truthy(ok, tostring(err))
  end)

  it("shows the translation alone, then the original alone", function()
    local lookup = require("weread.lookup")
    local inline = require("weread.inline")
    local chapters = reader.state.catalog.chapters
    local target = reader.readable_indices()[2]
    local here = chapters[target]
    reader.state.book.translatable = true
    local calls, restore = stub_ensure()
    -- WeRead's translation, already cached: no LLM, no network
    -- (微信读书的译文已在缓存里：不走大模型，也不联网)
    local saved_available = lookup.llm_available
    lookup.llm_available = function()
      return false
    end
    local trans = cache.chapter_file(BOOK_ID, here, "trans.xhtml")
    local notify = vim.notify
    vim.notify = function() end
    local ok, err = pcall(function()
      translate.set_enabled(BOOK_ID, false)
      translate.set_only(BOOK_ID, false)
      open(target)
      vim.wait(300)
      local source = cache.read(cache.chapter_file(BOOK_ID, here, "xhtml"))
      cache.write(trans, (source:gsub("</p>", '</p>\n<p class="wr-translation">【译文】</p>')))
      local function hidden()
        return #(vim.b[vim.api.nvim_get_current_buf()].weread_hidden_originals or {})
      end
      local function page()
        return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      end
      local function settled(want)
        vim.wait(3000, function()
          local info = reader.buffer_info()
          return info ~= nil and info.translated == want
        end, 20)
        vim.wait(100)
      end

      reader.toggle_translation_only()
      settled("weread")
      truthy(translate.enabled(BOOK_ID) and translate.only(BOOK_ID), "translation on, alone")
      truthy(page():find("【译文】", 1, true), "the translation is on the page")
      truthy(hidden() > 0, "the originals above it are hidden")
      local buf = vim.api.nvim_get_current_buf()
      local line = vim.fn.line(".")
      eq(inline.shown_line(buf, line), line, "the cursor is on a line the page shows")
      truthy(reader.source_offset(), "the place is still read in the original's offsets")

      reader.toggle_translation_only()
      settled(nil)
      falsy(translate.enabled(BOOK_ID), "the second press turns the translation off")
      falsy(page():find("【译文】", 1, true), "the original alone")
      eq(hidden(), 0, "nothing hidden")

      -- bilingual first: the key only hides the originals, nothing is laid out again
      -- (先是双语：按键只藏原文，不重排)
      reader.toggle_translation(true, { engine = "weread" })
      settled("weread")
      eq(hidden(), 0, "bilingual hides nothing")
      local tick = vim.api.nvim_buf_get_changedtick(0)
      reader.toggle_translation_only()
      truthy(hidden() > 0, "the originals are hidden at once")
      eq(vim.api.nvim_buf_get_changedtick(0), tick, "the buffer is the same")
      eq(#calls, 0, "the cached translation needed no request")
    end)
    vim.notify = notify
    lookup.llm_available = saved_available
    restore()
    translate.set_enabled(BOOK_ID, false)
    translate.set_only(BOOK_ID, false)
    reader.state.book.translatable = nil
    vim.fn.delete(trans)
    require("weread.chapter_pipeline").drop_cache(BOOK_ID, here, { "md", "map.json" })
    truthy(ok, tostring(err))
  end)

  it("ignores floats resizing, which say nothing about the page", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local float = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 0, col = 0, width = 5, height = 2 })
    falsy(reader.resized_split({ float }), "a float alone")
    truthy(reader.resized_split({ float, vim.api.nvim_get_current_win() }), "a split among them")
    vim.api.nvim_win_close(float, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("reader position saving", function()
  local session = require("weread.session")

  local function open_chapter(index)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    vim.fn.delete(config.path("positions.json"))
    reader.open_index(index, {})
    vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == index
    end, 50)
  end

  ---Count the writes to positions.json made while `fn` runs.
  ---(统计 fn 运行期间对 positions.json 的写入次数)
  ---@param fn fun()
  ---@return integer
  local function count_writes(fn)
    local original = cache.write_position
    local writes = 0
    cache.write_position = function(...)
      writes = writes + 1
      return original(...)
    end
    local ok, err = pcall(fn)
    cache.write_position = original
    if not ok then
      error(err, 0)
    end
    return writes
  end

  it("does not write a place that has not changed", function()
    open_chapter(2)
    session.save_position()
    local writes = count_writes(function()
      -- the events that fire on every window switch and focus change
      -- (每次切窗口、焦点变化都会触发的事件)
      vim.api.nvim_exec_autocmds("WinLeave", {})
      vim.api.nvim_exec_autocmds("BufLeave", { buffer = vim.api.nvim_get_current_buf() })
      vim.api.nvim_exec_autocmds("FocusLost", {})
      session.save_position()
    end)
    eq(writes, 0, "an unmoved reader costs no write")
  end)

  it("writes again once the reader has moved", function()
    open_chapter(2)
    session.save_position()
    local last = vim.api.nvim_buf_line_count(0)
    local line = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_win_set_cursor(0, { line == last and 1 or last, 0 })
    local writes = count_writes(function()
      session.save_position()
      session.save_position()
    end)
    eq(writes, 1, "the move is written once, the repeat is skipped")
  end)

  it("writes again when positions.json was removed behind our back", function()
    open_chapter(2)
    session.save_position()
    vim.fn.delete(config.path("positions.json"))
    local writes = count_writes(function()
      session.save_position()
    end)
    eq(writes, 1, "the remembered record is not trusted over a missing file")
    truthy(cache.read_position(BOOK_ID), "and the place is on disk again")
  end)

  it("keeps the other books' places when it saves", function()
    open_chapter(2)
    cache.write_position("777", { chapter_key = "0001", chapter_index = 1, chapter_uid = "1", line = 9, updated_at = 1 })
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(2, last), 0 })
    session.save_position()
    eq((cache.read_position("777") or {}).line, 9, "the other book is still there")
    truthy(cache.read_position(BOOK_ID), "and this one was saved")
  end)

  ---Collect what `log.warn` is told while `fn` runs.
  ---(收集 fn 运行期间 log.warn 收到的内容)
  ---@param fn fun()
  ---@return string[]
  local function warnings_during(fn)
    local original = log.warn
    local seen = {}
    log.warn = function(format, ...)
      seen[#seen + 1] = select("#", ...) > 0 and string.format(format, ...) or format
    end
    local ok, err = pcall(fn)
    log.warn = original
    if not ok then
      error(err, 0)
    end
    return seen
  end

  it("says so when the position cannot be written", function()
    open_chapter(2)
    vim.fn.delete(config.path("positions.json"))
    local original = cache.write_position
    cache.write_position = function()
      return false, "disk full"
    end
    local seen = warnings_during(function()
      session.save_position()
    end)
    cache.write_position = original
    eq(#seen, 1)
    matches(seen[1], "disk full")
    -- a failed write is not remembered as saved: the next try writes again
    -- (写失败不能记成已保存：下一次要再写)
    local writes = count_writes(function()
      session.save_position()
    end)
    eq(writes, 1)
  end)

  it("says so when the final report at exit fails", function()
    open_chapter(2)
    local progress = require("weread.progress")
    local original = progress.flush_sync
    progress.flush_sync = function()
      error("exit report exploded")
    end
    local seen = warnings_during(function()
      vim.api.nvim_exec_autocmds("VimLeavePre", { group = "weread_reader" })
    end)
    progress.flush_sync = original
    local joined = table.concat(seen, "\n")
    matches(joined, "exit report exploded")
  end)

  it("reads the wheel step from the config, with no second default of its own", function()
    local layout_opts = config.get().layout
    local original = layout_opts.mousescroll
    layout_opts.mousescroll = "ver:4,hor:2"
    eq(reader.wheel_lines(), 4)
    layout_opts.mousescroll = "garbage"
    eq(reader.wheel_lines(), 1, "an unparsable value scrolls a single line")
    layout_opts.mousescroll = original
    eq(reader.wheel_lines(), tonumber(tostring(original):match("ver:(%d+)")), "the config default is what applies")
  end)
end)

describe("reader resize handling", function()
  local layout = require("weread.layout")
  local session = require("weread.session")
  local pager = require("weread.pager")

  local function open_chapter(index)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    reader.open_index(index, {})
    vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == index
    end, 50)
  end

  it("re-measures the page once for a burst of resize events at the same width", function()
    open_chapter(2)
    session.set_page_width(layout.page_width(vim.api.nvim_get_current_win()))
    local original = pager.refresh_all
    local refreshes = 0
    pager.refresh_all = function()
      refreshes = refreshes + 1
    end
    for _ = 1, 12 do
      vim.api.nvim_exec_autocmds("WinResized", { group = "weread_reader" })
      vim.api.nvim_exec_autocmds("VimResized", { group = "weread_reader" })
    end
    eq(refreshes, 0, "nothing runs while the events are still arriving")
    vim.wait(1000, function()
      return refreshes > 0
    end, 20)
    vim.wait(300, function()
      return false
    end, 20)
    pager.refresh_all = original
    eq(refreshes, 1, "24 events, one refresh")
  end)

  it("lays the chapter out once for a burst of events that change the page width", function()
    open_chapter(2)
    session.set_page_width(1)
    local original = reader.open_index
    local relayouts = 0
    reader.open_index = function(...)
      relayouts = relayouts + 1
      return original(...)
    end
    local refresh = pager.refresh_all
    pager.refresh_all = function() end
    for _ = 1, 12 do
      vim.api.nvim_exec_autocmds("WinResized", { group = "weread_reader" })
    end
    eq(relayouts, 0, "the layout waits for the width to settle")
    vim.wait(2000, function()
      return relayouts > 0
    end, 20)
    vim.wait(500, function()
      return false
    end, 20)
    reader.open_index = original
    pager.refresh_all = refresh
    eq(relayouts, 1, "12 events, one re-layout")
    eq(session.page_width(), layout.page_width(vim.api.nvim_get_current_win()), "at the width the window has now")
  end)

  it("lets a terminal resize through even though it names no windows", function()
    open_chapter(2)
    session.set_page_width(layout.page_width(vim.api.nvim_get_current_win()))
    local original = pager.refresh_all
    local refreshes = 0
    pager.refresh_all = function()
      refreshes = refreshes + 1
    end
    vim.api.nvim_exec_autocmds("VimResized", { group = "weread_reader" })
    vim.wait(1000, function()
      return refreshes > 0
    end, 20)
    pager.refresh_all = original
    eq(refreshes, 1)
  end)
end)

describe("reader chapters that arrive late", function()
  local session = require("weread.session")
  local pipeline = require("weread.chapter_pipeline")

  local function fresh_start()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    vim.cmd("only")
    reader.open_index(2, {})
    vim.wait(20000, function()
      local info = reader.buffer_info()
      return info ~= nil and info.chapter_index == 2
    end, 50)
  end

  ---Forget chapter 3 on disk, so opening it has to fetch.
  ---(把第 3 章的缓存删掉，打开它就得抓取)
  ---@return table chapter
  local function uncache_chapter_three()
    local chapter = reader.state.catalog.chapters[3]
    pipeline.drop_cache(BOOK_ID, chapter, { "md", "map.json", "xhtml", "trans.xhtml", "css" })
    return chapter
  end

  it("caches the chapter but leaves the reader alone when the window is gone", function()
    fresh_start()
    local home = vim.api.nvim_get_current_win()
    local home_buf = vim.api.nvim_get_current_buf()
    local chapter = uncache_chapter_three()

    vim.cmd("vsplit")
    local doomed = vim.api.nvim_get_current_win()
    reader.open_index(3, {})
    -- the window is closed while the chapter is still on its way
    -- (章节还在路上，窗口就被关掉了)
    vim.api.nvim_win_close(doomed, true)

    vim.wait(20000, function()
      return vim.fn.filereadable(cache.chapter_file(BOOK_ID, chapter, "md")) == 1
    end, 20)
    vim.wait(300, function()
      return false
    end, 20)

    truthy(vim.fn.filereadable(cache.chapter_file(BOOK_ID, chapter, "md")) == 1, "the work is kept")
    eq(vim.api.nvim_get_current_win(), home)
    eq(vim.api.nvim_win_get_buf(home), home_buf, "the surviving window still shows what it showed")
    eq((reader.buffer_info(home_buf) or {}).chapter_index, 2)
  end)

  it("shows the chapter in the window it was asked for, not wherever the cursor is by then", function()
    fresh_start()
    local home = vim.api.nvim_get_current_win()
    uncache_chapter_three()

    reader.open_index(3, {})
    vim.cmd("vsplit")
    local elsewhere = vim.api.nvim_get_current_win()
    vim.cmd("enew")
    local scratch = vim.api.nvim_get_current_buf()

    vim.wait(20000, function()
      local info = reader.buffer_info(vim.api.nvim_win_get_buf(home))
      return info ~= nil and info.chapter_index == 3
    end, 50)

    eq((reader.buffer_info(vim.api.nvim_win_get_buf(home)) or {}).chapter_index, 3, "it landed in the window that asked")
    eq(vim.api.nvim_win_get_buf(elsewhere), scratch, "and the window the reader moved to was left alone")
    vim.api.nvim_set_current_win(elsewhere)
    vim.cmd("only")
  end)

  it("does not apply a chapter to a book that replaced the one it was fetched for", function()
    fresh_start()
    local home_buf = vim.api.nvim_get_current_buf()
    local chapter = uncache_chapter_three()
    local original_book = reader.state.book

    reader.open_index(3, {})
    -- another book is opened while the chapter is on its way
    -- (章节在路上的时候，另一本书被打开了)
    reader.state.book = vim.tbl_extend("force", original_book, { book_id = "other-book" })
    vim.wait(20000, function()
      return vim.fn.filereadable(cache.chapter_file(BOOK_ID, chapter, "md")) == 1
    end, 20)
    vim.wait(300, function()
      return false
    end, 20)
    reader.state.book = original_book

    eq(vim.api.nvim_get_current_buf(), home_buf, "the buffer on screen was not replaced")
    eq((reader.buffer_info() or {}).chapter_index, 2)
  end)

  describe("prefetch", function()
    local progress_state = require("weread.progress_state")

    ---Run `fn` with a short prefetch delay and the pipeline's prefetch recorded.
    ---(把预取延迟缩短，并记录流水线的 prefetch 调用，然后运行 fn)
    ---@param fn fun(calls: table[])
    local function with_recording(fn)
      local delay, deferrals = pipeline.PREFETCH_DELAY_MS, pipeline.PREFETCH_MAX_DEFERRALS
      local original = pipeline.prefetch
      local last_input = progress_state.last_input
      local calls = {}
      pipeline.PREFETCH_DELAY_MS = 40
      pipeline.PREFETCH_MAX_DEFERRALS = 3
      pipeline.prefetch = function(book, index)
        calls[#calls + 1] = { book_id = tostring(book.book_id), index = index }
      end
      local ok, err = pcall(fn, calls)
      pipeline.PREFETCH_DELAY_MS, pipeline.PREFETCH_MAX_DEFERRALS = delay, deferrals
      pipeline.prefetch = original
      progress_state.last_input = last_input
      if not ok then
        error(err, 0)
      end
    end

    it("prefetches the next chapter once the reader is quiet", function()
      with_recording(function(calls)
        progress_state.last_input = vim.uv.now() - 10000
        pipeline.schedule_prefetch(reader.state.book, 3)
        vim.wait(1000, function()
          return #calls > 0
        end, 10)
        eq(calls, { { book_id = BOOK_ID, index = 3 } })
      end)
    end)

    it("gives up when the book changed while it waited", function()
      with_recording(function(calls)
        progress_state.last_input = vim.uv.now() - 10000
        local original_book = reader.state.book
        pipeline.schedule_prefetch(original_book, 3)
        reader.state.book = vim.tbl_extend("force", original_book, { book_id = "other-book" })
        vim.wait(300, function()
          return #calls > 0
        end, 10)
        reader.state.book = original_book
        eq(#calls, 0, "the old book's chapter index is not applied to the new book")
      end)
    end)

    it("waits for a reader who keeps turning pages, then gives up", function()
      with_recording(function(calls)
        -- input that never stops: always "just now"
        -- (按键从不停歇：永远是「刚刚」)
        local ticker = vim.uv.new_timer()
        ticker:start(0, 5, function()
          progress_state.last_input = vim.uv.now()
        end)
        pipeline.schedule_prefetch(reader.state.book, 3)
        vim.wait(600, function()
          return #calls > 0
        end, 10)
        ticker:stop()
        ticker:close()
        eq(#calls, 0, "no prefetch lands in the middle of a page turn")
      end)
    end)

    it("goes ahead as soon as the reader stops", function()
      with_recording(function(calls)
        progress_state.last_input = vim.uv.now()
        pipeline.schedule_prefetch(reader.state.book, 3)
        vim.wait(1000, function()
          return #calls > 0
        end, 10)
        eq(#calls, 1, "the input was recent at first, then it went quiet")
      end)
    end)
  end)
end)

