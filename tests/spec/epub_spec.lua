--[[
Tests for the EPUB export (weread.epub): the translation replaces or follows
each translated block, WeRead's own translation never gets in, every file is
well-formed XML, and the zip opens with `mimetype` first and stored.
(EPUB 导出 weread.epub 的测试：译文替换或跟在每个译过的块后面、微信读书自己的译文不会混进来、
 每个文件都是合式 XML，以及压缩包以未压缩的 mimetype 打头)
]]

local cache = require("weread.cache")
local config = require("weread.config")
local epub = require("weread.epub")
local llm = require("weread.llm_translate")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
config.setup({ data_dir = tmpdir, proxy = "direct", sync_interval = 0, keymaps = false })
config.ensure_dirs()

local BOOK = { book_id = "CB_epub_test", title = "Getting Started", author = "A & B" }
local CHAPTERS = {
  { chapterUid = 1, chapterIdx = 1, title = "One", translateTitle = "第一章", wordCount = 10 },
  { chapterUid = 2, chapterIdx = 2, title = "Two", wordCount = 10 },
  { chapterUid = 3, chapterIdx = 3, title = "Cover", wordCount = 0 },
  { chapterUid = 4, chapterIdx = 4, title = "Not downloaded", wordCount = 10 },
}

local ONE = table.concat({
  "<?xml version='1.0' encoding='utf-8'?>",
  '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head>',
  '<body><h1 id="one">Getting Started</h1>',
  "<p>We set up a <em>project</em> directory&nbsp;&amp; a server.<br>Done.</p>",
  '<p><img src="https://res.weread.qq.com/wrepub/fig_1.png" alt="figure"></p>',
  '<p><img src="https://res.weread.qq.com/wrepub/gone.png" alt="lost figure"></p>',
  "<pre><code>go run ./cmd/api</code></pre>",
  "</body></html>",
}, "\n")
-- cached the old way, with WeRead's translation in it(按旧方式缓存，里面带着微信读书的译文)
local TWO = '<html><body><p>Second chapter text.</p>\n<p class="wr-translation">微信读书的译文。</p></body></html>'

cache.ensure_book_dirs(BOOK.book_id)
cache.write(cache.chapter_file(BOOK.book_id, CHAPTERS[1], "xhtml"), ONE)
cache.write(cache.chapter_file(BOOK.book_id, CHAPTERS[1], "css"), "p { margin: 0 }")
cache.write(cache.chapter_file(BOOK.book_id, CHAPTERS[2], "xhtml"), TWO)
cache.write(cache.chapter_file(BOOK.book_id, CHAPTERS[2], "css"), "p { margin: 0 }")
cache.write(cache.assets_dir(BOOK.book_id) .. "/url-fig_1.png.png", "\137PNG fake")
cache.write_json(cache.chapter_file(BOOK.book_id, CHAPTERS[1], "llm.json"), {
  model = "m",
  complete = true,
  items = {
    ["Getting Started"] = "入门",
    ["We set up a project directory & a server.Done."] = "我们建立项目目录 & 服务器。",
  },
})

---@param result table
---@param name string
---@return string|nil
local function file(result, name)
  for _, entry in ipairs(result.files) do
    if entry.name == name then
      return entry.data
    end
  end
  return nil
end

describe("epub.build", function()
  it("puts the translation in place of each translated block", function()
    local result = epub.build(BOOK, CHAPTERS, { mode = "only" })
    eq(result.chapters, 2, "the cover has no text, the missing chapter is not there")
    eq(result.translated, 1)
    eq(result.missing, { "Not downloaded" })
    eq(result.untranslated, { "Two" })
    local one = file(result, "OEBPS/c0001.xhtml")
    truthy(one:find("<h1 id=\"one\">入门</h1>", 1, true), "the heading keeps its tag and id")
    truthy(one:find("我们建立项目目录 &amp; 服务器。", 1, true), "the translation, escaped")
    falsy(one:find("Getting Started</h1>", 1, true), "the original is gone")
    truthy(one:find("go run ./cmd/api", 1, true), "code stays")
    truthy(one:find("<title>第一章</title>", 1, true), "the translated chapter title")
    truthy(file(result, "OEBPS/content.opf"):find("<dc:language>zh-CN</dc:language>", 1, true))
    truthy(file(result, "OEBPS/content.opf"):find("A &amp; B", 1, true), "metadata escaped")
  end)

  it("puts it under the original when bilingual, and never WeRead's", function()
    local result = epub.build(BOOK, CHAPTERS, { mode = "bilingual" })
    local one = file(result, "OEBPS/c0001.xhtml")
    truthy(one:find("Getting Started</h1>", 1, true), "the original stays")
    truthy(one:find('<h1 class="wr-translation">入门</h1>', 1, true), "the translation follows")
    local two = file(result, "OEBPS/c0002.xhtml")
    falsy(two:find("微信读书的译文", 1, true), "WeRead's translation is taken out")
    truthy(two:find("Second chapter text.", 1, true))
  end)

  it("carries the cached illustrations and drops the others", function()
    local result = epub.build(BOOK, CHAPTERS, { mode = "only" })
    local one = file(result, "OEBPS/c0001.xhtml")
    truthy(one:find('<img src="images/img0001.png" alt="figure"/>', 1, true), "pointed at the copy in the book")
    falsy(one:find("res.weread.qq.com", 1, true), "no remote image left")
    truthy(one:find('<span class="wr-missing-figure">lost figure</span>', 1, true), "a figure not cached leaves its alt text")
    truthy(file(result, "OEBPS/content.opf"):find('href="images/img0001.png" media-type="image/png"', 1, true))
    local kept = epub.build(BOOK, CHAPTERS, { mode = "only", restyle = false })
    eq(vim.tbl_count(vim.tbl_filter(function(entry)
      return entry.name:find("^OEBPS/styles/book") ~= nil
    end, kept.files)), 1, "one stylesheet shared by both chapters")
  end)

  it("typesets the whole book with one stylesheet, the book's own left out", function()
    local style = require("weread.epub_style")
    local result = epub.build(BOOK, CHAPTERS, { mode = "only" })
    eq(vim.tbl_count(vim.tbl_filter(function(entry)
      return entry.name:find("^OEBPS/styles/book") ~= nil
    end, result.files)), 0, "no stylesheet of the book")
    eq(file(result, "OEBPS/styles/weread.css"), style.CSS)
    local one = file(result, "OEBPS/c0001.xhtml")
    truthy(one:find('href="styles/weread.css"', 1, true))
    falsy(one:find("styles/book", 1, true), "the chapter links only ours")
    truthy(style.CSS:find("text-indent: 2em", 1, true), "one first-line indent for the body")
    truthy(style.CSS:find(".wr-translation", 1, true), "the translation still in muted ink")
  end)

  it("takes out what would beat the stylesheet", function()
    local style = require("weread.epub_style")
    eq(
      style.body('<div class="sidebar" style="background:#F7F7F7"><p bgcolor="#fff">a <font color="red">b</font></p></div>'),
      '<div class="sidebar"><p>a b</p></div>'
    )
    eq(style.body("<p style='color:red' id=\"x\">c</p>"), '<p id="x">c</p>')
  end)

  it("lets the config keep the book's own stylesheets", function()
    config.setup({ data_dir = tmpdir, proxy = "direct", sync_interval = 0, keymaps = false, epub = { restyle = false } })
    local ok, result = pcall(epub.build, BOOK, CHAPTERS, { mode = "only" })
    config.setup({ data_dir = tmpdir, proxy = "direct", sync_interval = 0, keymaps = false })
    truthy(ok, tostring(result))
    truthy(file(result, "OEBPS/c0001.xhtml"):find("styles/book1.css", 1, true))
    falsy(epub.restyle({ restyle = false }))
    truthy(epub.restyle({}))
  end)

  it("keeps the first of an attribute written twice", function()
    eq(
      epub.unique_attributes('<img src="a.png" data-w="1px" alt="x" data-w="1px"/><p class="c">t</p>'),
      '<img src="a.png" data-w="1px" alt="x"/><p class="c">t</p>'
    )
  end)

  it("renames an id met again in the same page", function()
    eq(epub.unique_ids('<div id="a"></div><div id="b"></div><div id="a"></div>'), '<div id="a"></div><div id="b"></div><div id="a-2"></div>')
  end)

  it("puts list items outside any list into one", function()
    eq(epub.wrap_stray_items("<div><li>a</li><li>b</li></div>"), "<div><ul><li>a</li><li>b</li></ul></div>")
    eq(epub.wrap_stray_items("<ul><li>a<br/></li></ul>"), "<ul><li>a<br/></li></ul>", "a list left alone")
    eq(epub.wrap_stray_items("<li>a</li><p>b</p>"), "<ul><li>a</li></ul><p>b</p>")
  end)

  it("points a link at the page when the place it names is not there", function()
    local files = {
      { name = "OEBPS/c0001.xhtml", data = '<p id="here"></p><a href="c0002.xhtml#gone">x</a><a href="#here">y</a><a href="#nope">z</a>' },
      { name = "OEBPS/c0002.xhtml", data = '<p id="there"></p><a href="c0001.xhtml#here">w</a>' },
    }
    epub.drop_dead_fragments(files)
    eq(files[1].data, '<p id="here"></p><a href="c0002.xhtml">x</a><a href="#here">y</a><a href="c0001.xhtml">z</a>')
    eq(files[2].data, '<p id="there"></p><a href="c0001.xhtml#here">w</a>')
  end)

  it("says a page with formulas has MathML", function()
    local uid = 9
    local chapter = { chapterUid = uid, chapterIdx = uid, title = "Maths", wordCount = 10 }
    cache.write(
      cache.chapter_file(BOOK.book_id, chapter, "xhtml"),
      '<html><body><p>x</p><math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math></body></html>'
    )
    local opf = file(epub.build(BOOK, { chapter }, { mode = "bilingual" }), "OEBPS/content.opf")
    truthy(opf:find('href="c0001.xhtml" media%-type="application/xhtml%+xml" properties="mathml"'), opf)
  end)

  it("writes well-formed XML", function()
    if vim.fn.executable("xmllint") ~= 1 then
      return
    end
    for _, mode in ipairs({ "only", "bilingual" }) do
      for _, entry in ipairs(epub.build(BOOK, CHAPTERS, { mode = mode }).files) do
        if entry.data and entry.name:match("%.x?ht?ml$") or (entry.name:match("%.opf$") or entry.name:match("%.ncx$")) then
          local check = vim.system({ "xmllint", "--noout", "-" }, { stdin = entry.data }):wait()
          eq(check.code, 0, mode .. " " .. entry.name .. ": " .. tostring(check.stderr))
        end
      end
    end
  end)
end)

describe("epub.write", function()
  it("zips mimetype first and stored", function()
    if vim.fn.executable("zip") ~= 1 or vim.fn.executable("unzip") ~= 1 then
      return
    end
    local path = tmpdir .. "/out/book.epub"
    local ok, err = epub.write(path, epub.build(BOOK, CHAPTERS, { mode = "only" }).files)
    truthy(ok, tostring(err))
    local data = cache.read(path)
    eq(data:sub(31, 38), "mimetype", "the first entry is mimetype")
    eq(data:byte(9) + data:byte(10) * 256, 0, "stored, not deflated")
    local listing = vim.system({ "unzip", "-l", path }):wait().stdout
    truthy(listing:find("OEBPS/images/img0001.png", 1, true))
    truthy(listing:find("META-INF/container.xml", 1, true))
  end)
end)

describe("epub.run, the whole book", function()
  local reader = require("weread.reader")
  local pipeline = require("weread.chapter_pipeline")
  local lookup = require("weread.lookup")
  local translate = require("weread.translate")

  it("downloads and translates every chapter that is not yet, then writes the book", function()
    local fetched, sent = {}, {}
    local saved = {
      ensure = pipeline.ensure_cached,
      import = require("weread.upload").import,
      cover = epub.fetch_cover,
      available = lookup.llm_available,
      chat = lookup.llm_chat,
      notify = vim.notify,
      book = reader.state.book,
      catalog = reader.state.catalog,
    }
    local messages = {}
    vim.notify = function(message)
      messages[#messages + 1] = message
    end
    pipeline.ensure_cached = function(_, chapter, callback)
      fetched[#fetched + 1] = chapter.title
      if chapter.title == "Not downloaded" then
        cache.write(cache.chapter_file(BOOK.book_id, chapter, "xhtml"), "<html><body><p>Fourth chapter here.</p></body></html>")
      end
      vim.schedule(function()
        callback(true, nil)
      end)
    end
    lookup.llm_available = function()
      return true
    end
    lookup.llm_chat = function(chat, opts, done)
      sent[#sent + 1] = opts.model
      local out = {}
      for id, text in pairs(vim.json.decode(chat[#chat].content)) do
        out[id] = "译：" .. text
      end
      vim.schedule(function()
        done(vim.json.encode(out), nil)
      end)
      return { kill = function() end }
    end
    epub.fetch_cover = function(_, callback)
      callback(nil)
    end
    local imported = {}
    require("weread.upload").import = function(file, callback)
      imported[#imported + 1] = file
      vim.schedule(function()
        callback(true, "CB_uploaded")
      end)
    end
    reader.state.book = BOOK
    reader.state.catalog = { chapters = CHAPTERS }
    translate.set_engine(BOOK.book_id, "picked-model")
    local path = tmpdir .. "/whole.epub"
    local ok, err = pcall(function()
      epub.run(path)
      vim.wait(5000, function()
        return vim.fn.filereadable(path) == 1
      end, 20)
      eq(fetched, { "Not downloaded" }, "only the chapter not downloaded is fetched")
      truthy(#sent > 0 and sent[1] == "picked-model", "the book's model translates")
      eq(llm.load(BOOK.book_id, CHAPTERS[1]).model, "picked-model", "the chapter done by another model is done again")
      truthy(llm.load(BOOK.book_id, CHAPTERS[4]).complete, "the new chapter is translated")
      truthy(vim.fn.filereadable(path) == 1, "the book is written")
      local listing = vim.system({ "unzip", "-p", path, "OEBPS/c0003.xhtml" }):wait().stdout or ""
      truthy(listing:find("译：Fourth chapter here.", 1, true), "with the new chapter, translated")
      vim.wait(2000, function()
        return #imported > 0 and messages[#messages]:find("已传到", 1, true) ~= nil
      end, 20)
      eq(imported, { path }, "then put on the shelf")
      matches(messages[#messages], "已传到微信读书书架")
      eq(require("weread.prefs").get("epub_uploads")[BOOK.book_id].book_id, "CB_uploaded", "remembered")
      -- the same file again: not uploaded twice(同一个文件再来一次：不重复上传)
      epub.upload(BOOK, path)
      eq(#imported, 1)
      matches(messages[#messages], "没有重复上传")
    end)
    require("weread.upload").import = saved.import
    epub.fetch_cover = saved.cover
    pipeline.ensure_cached, lookup.llm_available, lookup.llm_chat, vim.notify = saved.ensure, saved.available, saved.chat, saved.notify
    reader.state.book, reader.state.catalog = saved.book, saved.catalog
    translate.set_engine(BOOK.book_id, nil)
    truthy(ok, tostring(err))
  end)
end)

describe("epub contents and check", function()
  it("nests the contents by the catalog's levels and the chapter's headings", function()
    local tree = epub.toc_tree({
      { name = "c1.xhtml", title = "前言", level = 1, anchors = { { id = "a", title = "约定", level = 2 } } },
      { name = "c2.xhtml", title = "I. 拆解", level = 1, anchors = {} },
      { name = "c3.xhtml", title = "2. 耦合", level = 2, anchors = { { id = "q", title = "量子", level = 3 }, { id = "d", title = "可部署", level = 4 } } },
      { name = "c4.xhtml", title = "_2", level = 2, anchors = {} },
      { name = "c5.xhtml", title = "索引", level = 1, anchors = {} },
    })
    eq(#tree, 3, "front matter, the part, the index; the placeholder is gone")
    eq(tree[1].children[1].href, "c1.xhtml#a")
    eq(tree[2].children[1].title, "2. 耦合", "the chapter under its part")
    eq(tree[2].children[1].children[1].children[1].title, "可部署", "four levels deep")
    eq(epub.depth(tree), 4)
    matches(epub.nav_list(tree), "^<ol><li><a href=\"c1.xhtml\">前言</a><ol>")
  end)

  it("reads the levels off the numbering when the catalog has none", function()
    eq(epub.derive_levels({ "6. SQL", "6.1. Overview", "6.2 Working", "7. CRUD", "Index" }, { 1, 1, 1, 1, 1 }), { 1, 2, 2, 1, 1 })
    -- parts hold the chapters after them, back matter steps out
    -- (部统领它后面的章，书后部分退出来)
    eq(
      epub.derive_levels({ "Preface", "I. Apart", "2. Coupling", "Saga", "II. Together", "8. Reuse", "A. Terms", "Index" }, { 1, 1, 1, 3, 1, 1, 1, 1 }),
      { 1, 1, 2, 4, 1, 2, 1, 1 }
    )
  end)

  it("points links between chapters at this book's files", function()
    local body = '<a href="ch07.xhtml#gran">Chapter 7</a> <a href="#fig">Figure</a> <a href="https://x.y/a.html">web</a> <a href="gone.xhtml#z">gone</a>'
    local out = epub.relink(body, { ["ch07.xhtml"] = "c0011.xhtml" })
    matches(out, 'href="c0011.xhtml#gran"')
    matches(out, 'href="#fig"', "same-page links stay")
    matches(out, 'href="https://x.y/a.html"', "web links stay")
    matches(out, 'href="#z"', "a chapter not in the book is no link out of it")
  end)

  it("joins a chapter made of several files and keeps one declaration", function()
    local two = "<?xml version='1.0'?><html><body><p>A</p></body></html>\n<?xml version='1.0'?><html><body><p>B</p></body></html>"
    eq(epub.body_of(two), "<p>A</p>\n<p>B</p>")
  end)

  it("puts the cover first and finds nothing wrong with a good book", function()
    local cover = tmpdir .. "/cover"
    cache.write(cover, "\137PNG\r\n\26\n fake")
    eq(epub.image_type(cover), "png")
    local result = epub.build(BOOK, CHAPTERS, { mode = "only", cover = cover })
    truthy(result.cover)
    local opf = file(result, "OEBPS/content.opf")
    matches(opf, 'properties="cover%-image"')
    matches(opf, '<meta name="cover" content="cover%-image"/>')
    truthy(opf:find('<itemref idref="cover"', 1, true) < opf:find('<itemref idref="c0001"', 1, true), "the cover page first")
    local errors = epub.check(result)
    eq(errors, {})
  end)

  it("stops a book with a broken page or a contents entry going nowhere", function()
    local result = epub.build(BOOK, CHAPTERS, { mode = "only" })
    for _, entry in ipairs(result.files) do
      if entry.name == "OEBPS/c0001.xhtml" then
        entry.data = entry.data .. "<p>unclosed"
      end
    end
    result.toc[#result.toc + 1] = { title = "x", href = "c0099.xhtml", level = 1, children = {} }
    local errors, warnings = epub.check(result)
    local text = table.concat(errors, "\n")
    if vim.fn.executable("xmllint") == 1 then
      matches(text, "c0001.xhtml 不是合式 XML")
    end
    matches(text, "目录里有 1 条指向不存在的位置")
    matches(table.concat(warnings, "\n"), "没有封面")
  end)
end)

local holds = 0

describe("epub.run, when translations end early", function()
  local reader = require("weread.reader")
  local lookup = require("weread.lookup")
  local translate = require("weread.translate")

  ---Run an export of BOOK with a gateway that answers only when told to.
  ---(在一个叫它答才答的网关上导出 BOOK)
  local function hold(body)
    local pending = {}
    local saved = {
      available = lookup.llm_available,
      chat = lookup.llm_chat,
      notify = vim.notify,
      book = reader.state.book,
      catalog = reader.state.catalog,
      cover = epub.fetch_cover,
      import = require("weread.upload").import,
    }
    local messages = {}
    vim.notify = function(message)
      messages[#messages + 1] = message
    end
    lookup.llm_available = function()
      return true
    end
    lookup._reset_gate()
    -- the real llm_chat answers a killed request with 已取消; so does this one
    -- (真正的 llm_chat 对被 kill 的请求回答「已取消」；这里也一样)
    lookup.llm_chat = function(chat, _, done)
      local request = { body = { messages = chat }, done = done, live = true }
      pending[#pending + 1] = request
      return { kill = function()
        if request.live then
          request.live = false
          vim.schedule(function()
            done(nil, lookup.CANCELLED)
          end)
        end
      end }
    end
    epub.fetch_cover = function(_, callback)
      callback(nil)
    end
    require("weread.upload").import = function(_, callback)
      callback(true, "CB_x")
    end
    reader.state.book = BOOK
    reader.state.catalog = { chapters = { CHAPTERS[1], CHAPTERS[2] } }
    for _, entry in ipairs({ CHAPTERS[1], CHAPTERS[2] }) do
      os.remove(cache.chapter_file(BOOK.book_id, entry, "llm.json"))
    end
    -- a model of its own each time, so nothing is translated yet
    -- (每次一个新模型，于是还什么都没译)
    holds = (holds or 0) + 1
    translate.set_engine(BOOK.book_id, "hold-model-" .. holds)
    local function answer()
      local now = pending
      pending = {}
      for _, request in ipairs(now) do
        if request.live then
          local out = {}
          for id, text in pairs(vim.json.decode(request.body.messages[#request.body.messages].content)) do
            out[id] = "译：" .. text
          end
          request.live = false
          request.done(vim.json.encode(out), nil)
        end
      end
    end
    local ok, err = pcall(body, { messages = messages, pending = function()
      return #pending
    end, answer = answer })
    if epub.status_text() then
      epub.stop()
    end
    lookup.llm_available, lookup.llm_chat, vim.notify = saved.available, saved.chat, saved.notify
    reader.state.book, reader.state.catalog = saved.book, saved.catalog
    epub.fetch_cover, require("weread.upload").import = saved.cover, saved.import
    lookup._reset_gate()
    translate.set_engine(BOOK.book_id, nil)
    truthy(ok, tostring(err))
  end

  it("goes on when the page cancels its own translations", function()
    hold(function(gateway)
      local path = tmpdir .. "/early1.epub"
      os.remove(path)
      epub.run("local " .. path)
      vim.wait(1000, function()
        return gateway.pending() > 0
      end, 10)
      -- the reader turns the translation of this very book off on its page
      -- (读者在页面上关掉了这本书的译文)
      llm.cancel({ owner = "reader", book_id = BOOK.book_id })
      for _ = 1, 50 do
        gateway.answer()
        vim.wait(30)
        if vim.fn.filereadable(path) == 1 then
          break
        end
      end
      truthy(vim.fn.filereadable(path) == 1, "the export got to the end")
      eq(epub.status_text(), nil, "and is no longer under way")
    end)
  end)

  it("stops for sure, and starts again where it stopped", function()
    hold(function(gateway)
      local path = tmpdir .. "/early2.epub"
      os.remove(path)
      epub.run("local " .. path)
      vim.wait(1000, function()
        return gateway.pending() > 0
      end, 10)
      truthy(epub.status_text(), "under way")
      -- even an export cancelled from below first, as at 19:05, stops at once
      -- (即使导出先在底下被取消——就像 19:05 那次——也能立刻停下)
      llm.cancel_all()
      vim.wait(50)
      truthy(epub.stop() or true)
      eq(epub.status_text(), nil, "the job is cleared")
      matches(table.concat(gateway.messages, "\n"), "已停止导出")
      epub.run("local " .. path)
      truthy(epub.status_text(), "a new export starts")
      for _ = 1, 50 do
        gateway.answer()
        vim.wait(30)
        if vim.fn.filereadable(path) == 1 then
          break
        end
      end
      truthy(vim.fn.filereadable(path) == 1, "and finishes")
    end)
  end)

  it("says when it may be stuck instead of a wild estimate", function()
    hold(function(gateway)
      epub.run("local " .. tmpdir .. "/early3.epub")
      vim.wait(1000, function()
        return gateway.pending() > 0
      end, 10)
      local saved = epub.QUIET_WARN_S
      epub.QUIET_WARN_S = -1
      matches(epub.status_text(), "可能卡住了")
      epub.QUIET_WARN_S = saved
      epub.stop()
    end)
  end)
end)

describe("epub contents of a book WeRead never translated", function()
  -- DDIA 2nd edition: no translateTitle anywhere in the catalog, every section
  -- an <h1>, chapters split into several files named after the book.
  -- (DDIA 第二版：目录里没有任何 translateTitle，每一节都是 <h1>，章节拆成几个以书名命名的文件)
  local DDIA = { book_id = "CB_epub_ddia", title = "Designing Data-Intensive Applications (for . .)", author = "M" }
  local catalog = {
    {
      chapterUid = 1,
      chapterIdx = 1,
      level = 1,
      title = "1. Trade-Offs",
      wordCount = 10,
      files = { "ch01__split__0.html" },
      -- the chapter's own anchor points at its first section, as in the real book
      -- (本章自己的 anchor 指向它的第一节，与真书一致)
      anchors = {
        { level = 1, title = "1. Trade-Offs", anchor = "sec_first" },
        { level = 2, title = "Cloud Versus Self-Hosting", anchor = "sec_cloud" },
        { level = 3, title = "Pros and Cons", anchor = "sec_pros" },
      },
    },
    {
      chapterUid = 2,
      chapterIdx = 2,
      level = 3,
      title = "Column compression",
      wordCount = 10,
      files = { "ch01__split__1.html" },
      anchors = {
        { level = 3, title = "Column compression", anchor = "sec_col" },
        { level = 2, title = "Summary", anchor = "sec_sum" },
      },
    },
    { chapterUid = 3, chapterIdx = 3, level = 2, title = "Designing Data-Intensive Applications, 2nd Edition_2", wordCount = 10, files = { "ch01__split__2.html" }, anchors = {} },
    { chapterUid = 4, chapterIdx = 4, level = 2, title = "Index", wordCount = 10, files = { "ix01__split__0.html" }, anchors = {} },
    { chapterUid = 5, chapterIdx = 5, level = 2, title = "Designing Data-Intensive Applications, 2nd Edition_5", wordCount = 10, files = { "ix01__split__1.html" }, anchors = {} },
    { chapterUid = 6, chapterIdx = 6, level = 2, title = "Designing Data-Intensive Applications, 2nd Edition", wordCount = 10, files = { "colophon01.html" }, anchors = {} },
  }
  local pages = {
    '<div class="chapter" id="ch_one"><h1>1. Trade-Offs</h1><div class="sect1" id="sec_first"><h1>Operational Versus Analytical</h1></div>'
      .. '<div class="sect1" id="sec_cloud"><h1>Cloud Versus Self-Hosting</h1><div id="sec_pros"><h2>Pros and Cons</h2></div></div></div>',
    '<div id="sec_col"><h4>Column compression</h4></div><div id="sec_sum"><h1>Summary</h1></div>',
    "<p>More of the chapter.</p>",
    "<h1>Index</h1><h3>A</h3>",
    "<h3>D</h3><h3>E</h3>",
    "<h1>About the Authors</h1><p>Martin.</p>",
  }
  local items = {
    ["1. Trade-Offs"] = "第1章 权衡",
    ["Operational Versus Analytical"] = "操作型与分析型",
    ["Cloud Versus Self-Hosting"] = "云服务与自托管",
    ["Pros and Cons"] = "优缺点",
    ["Column compression"] = "列压缩",
    ["Summary"] = "小结",
    ["More of the chapter."] = "本章的其余部分。",
    ["Index"] = "索引",
    ["About the Authors"] = "关于作者",
    ["Martin."] = "马丁。",
  }
  cache.ensure_book_dirs(DDIA.book_id)
  for index, entry in ipairs(catalog) do
    cache.write(cache.chapter_file(DDIA.book_id, entry, "xhtml"), "<html><body>" .. pages[index] .. "</body></html>")
    cache.write_json(cache.chapter_file(DDIA.book_id, entry, "llm.json"), { model = "m", complete = true, items = items })
  end

  ---@param nodes table[]
  ---@param depth integer|nil
  ---@return string[]
  local function outline(nodes, depth)
    local out = {}
    for _, node in ipairs(nodes) do
      out[#out + 1] = string.rep("  ", depth or 0) .. node.title
      vim.list_extend(out, outline(node.children, (depth or 0) + 1))
    end
    return out
  end

  it("uses the translated headings, nests split chapters, drops the placeholders", function()
    local result = epub.build(DDIA, catalog, { mode = "only" })
    eq(outline(result.toc), {
      "第1章 权衡",
      "  云服务与自托管",
      "    优缺点",
      "    列压缩",
      "  小结",
      "索引",
      "关于作者",
    })
    eq(epub.check(result), {}, "and every entry lands")
  end)

  it("knows a placeholder from a title", function()
    truthy(epub.is_placeholder("Designing Data-Intensive Applications, 2nd Edition_5", DDIA.title))
    truthy(epub.is_placeholder("Designing Data-Intensive Applications, 2nd Edition", DDIA.title))
    truthy(epub.is_placeholder("_2"))
    falsy(epub.is_placeholder("Summary", DDIA.title))
    falsy(epub.is_placeholder("6. Replication", DDIA.title))
  end)

  it("says why there is no cover", function()
    local api = require("weread.api_gateway")
    local http = require("weread.http")
    local saved_info, saved_request = api.book_info, http.request
    api.book_info = function(_, callback)
      callback(false, "没有 API Key")
    end
    http.request = function(_, callback)
      vim.schedule(function()
        callback({ code = 200, status = 200, body = '{"errCode":-2012,"errMsg":"登录超时"}' })
      end)
      return { kill = function() end }
    end
    local got, reason = "pending", nil
    epub.fetch_cover({ book_id = "CB_epub_nocover" }, function(path, why)
      got, reason = path, why
    end)
    vim.wait(1000, function()
      return got ~= "pending"
    end, 10)
    api.book_info, http.request = saved_info, saved_request
    eq(got, nil)
    matches(reason, "没有 API Key")
    matches(reason, "登录超时")
    local result = epub.build(BOOK, CHAPTERS, { mode = "only" })
    result.cover_reason = reason
    local _, warnings = epub.check(result)
    matches(table.concat(warnings, "\n"), "没有封面：.*登录超时")
  end)
end)

describe("epub figures", function()
  it("downloads the figures the reader never drew, and puts each where the page has it", function()
    local image = require("weread.image")
    local saved = image.ensure_local
    local BOOK3 = { book_id = "CB_epub_figs", title = "Figures", author = "A" }
    local entry = { chapterUid = 1, chapterIdx = 1, title = "One", wordCount = 10 }
    cache.ensure_book_dirs(BOOK3.book_id)
    cache.write(cache.chapter_file(BOOK3.book_id, entry, "xhtml"), table.concat({
      "<html><body><p>Before the figure.</p>",
      '<figure><div class="figure" id="fig-1"><img alt="One" src="https://res.weread.qq.com/wrepub/x_0101.png"/><h6>Figure 1</h6></div></figure>',
      '<p>Between.</p><img alt="Two" src="https://res.weread.qq.com/wrepub/x_0102.png"/>',
      '<img alt="Gone" src="https://res.weread.qq.com/wrepub/x_0199.png"/>',
      "</body></html>",
    }, "\n"))
    local asked = {}
    image.ensure_local = function(src, dir, callback)
      asked[#asked + 1] = src
      if src:find("0199", 1, true) then
        vim.schedule(function()
          callback(nil, "插图下载失败（HTTP 404）")
        end)
        return
      end
      local path = dir .. "/url-" .. src:match("([^/]+)$") .. ".png"
      cache.write(path, "\137PNG\r\n\26\n fake")
      vim.schedule(function()
        callback(path, nil)
      end)
    end
    local stats = nil
    epub.fetch_images(BOOK3, { entry }, function(result)
      stats = result
    end)
    vim.wait(2000, function()
      return stats ~= nil
    end, 10)
    image.ensure_local = saved
    eq(#asked, 3, "every figure not on disk is asked for")
    eq(stats.fetched, 2)
    eq(#stats.failed, 1)
    local result = epub.build(BOOK3, { entry }, { mode = "only" })
    local page = file(result, "OEBPS/c0001.xhtml")
    truthy(page:find('<p>Before the figure.</p>\n<figure><div class="figure" id="fig-1"><img src="images/img0001.png" alt="One"/>', 1, true), "in place, inside its figure")
    truthy(page:find('<p>Between.</p><img src="images/img0002.png" alt="Two"/>', 1, true), "the second one too")
    truthy(file(result, "OEBPS/content.opf"):find('href="images/img0002.png"', 1, true), "both in the manifest")
    local _, warnings = epub.check(result)
    matches(table.concat(warnings, "\n"), "有 1 张插图下载不下来")
    -- figures already on disk are not asked for again(磁盘上已有的插图不再请求)
    asked = {}
    image.ensure_local = function(src, _, callback)
      asked[#asked + 1] = src
      callback(nil, "no")
    end
    epub.fetch_images(BOOK3, { entry }, function() end)
    image.ensure_local = saved
    eq(asked, { "https://res.weread.qq.com/wrepub/x_0199.png" })
  end)
end)
