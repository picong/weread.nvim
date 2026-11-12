--[[
Tests for full-text translation: telling the book's text apart from the
translation the service interleaves with it, laying out the bilingual page
without moving a single offset, and the request / poll loop.
(全文翻译单测：把书的原文与服务端穿插进来的译文分开、排出双语页面且不挪动任何偏移，以及请求/轮询循环)

The bilingual shape is the one the live service returns: a stylesheet and a meta
line added to <head>, `value` on every list item, and after each block of the
original a block of the same tag with `class="wr-translation"`, on its own line.
(双语形态与线上服务返回的一致：<head> 里多一张样式表和一行 meta，每个列表项带 `value`，原文
 每个块后面另起一行跟一个同标签、`class="wr-translation"` 的块)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")
local xhtml = require("weread.xhtml")

local ORIGINAL = table.concat({
  "<?xml version='1.0' encoding='utf-8'?>",
  '<html xmlns="http://www.w3.org/1999/xhtml" lang="en">',
  "  <head>",
  '    <meta charset="utf-8"/>',
  "\t<title>Getting Started</title>",
  "</head>",
  '  <body class="text"><div class="chapter">Chapter 2.</div>',
  '\t<h1 id="getting-started">Getting Started</h1>',
  "",
  "<p>In this first section we set up a <em>project</em> directory. We will:</p>",
  "",
  "<ul>",
  "<li><p>Create a skeleton directory structure.</p></li>",
  "",
  "<li><p>Establish a HTTP server.</p></li>",
  "</ul>",
  "",
  "</body>",
  "</html>",
}, "\n")

local BILINGUAL = table.concat({
  "<?xml version='1.0' encoding='utf-8'?>",
  '<html xmlns="http://www.w3.org/1999/xhtml" lang="en">',
  "  <head>",
  '<link href="wereadstyle/wrtranslation.css" rel="stylesheet" type="text/css"/>',
  '<meta content="text/html; charset=utf-8" http-equiv="content-type"/>',
  '    <meta charset="utf-8"/>',
  "\t<title>Getting Started</title>",
  "</head>",
  '  <body class="text"><div class="chapter">Chapter 2.</div>',
  '<div class="wr-translation chapter">第2章。</div>',
  '\t<h1 id="getting-started">Getting Started</h1>',
  '<h1 class="wr-translation" id="getting-started">入门指南</h1>',
  "",
  "<p>In this first section we set up a <em>project</em> directory. We will:</p>",
  '<p class="wr-translation">在这一节里我们创建项目目录。具体包括：</p>',
  "",
  "<ul>",
  '<li value="1"><p>Create a skeleton directory structure.</p>',
  '<p class="wr-translation">创建项目的骨架目录结构。</p></li>',
  "",
  '<li value="2"><p>Establish a HTTP server.</p>',
  '<p class="wr-translation">搭建一个 HTTP 服务器。</p></li>',
  "</ul>",
  "",
  "</body>",
  "</html>",
}, "\n")

---@param result table
---@return string
local function map_key(result)
  local parts = {}
  for _, segment in ipairs(result.map) do
    parts[#parts + 1] = string.format("%d-%d", segment.src_from, segment.src_to)
  end
  return table.concat(parts, ",")
end

describe("xhtml.split_translation", function()
  it("gives the original back byte for byte", function()
    -- highlight ranges and reading positions are runes over the original, so
    -- anything less than an exact match would move every one of them
    -- (划线 range 与阅读位置都是原文上的 rune，差一个字节就会全部错位)
    local original, bilingual, ranges = xhtml.split_translation(BILINGUAL)
    eq(original, ORIGINAL)
    truthy(bilingual, "the bilingual version is kept")
    eq(#ranges, 5, "one range per translated block")
    falsy(bilingual:find("wrtranslation.css", 1, true), "the added stylesheet is gone")
    falsy(bilingual:find('value="1"', 1, true), "and the list numbers")
    for _, range in ipairs(ranges) do
      truthy(bilingual:sub(range[1], range[2]):find('class="wr%-translation'), "each range is a translation block")
    end
  end)

  it("leaves a chapter without translations alone", function()
    local original, bilingual, ranges = xhtml.split_translation(ORIGINAL)
    eq(original, ORIGINAL)
    eq(bilingual, nil)
    eq(#ranges, 0)
  end)
end)

describe("xhtml.convert with translations", function()
  local original, bilingual, ranges = xhtml.split_translation(BILINGUAL)
  local plain = xhtml.convert(original, { page_width = 52 })
  local both = xhtml.convert(bilingual, { page_width = 52, translations = ranges })

  it("keeps every offset of the original", function()
    eq(both.source_runes, plain.source_runes, "the translation adds no runes")
    eq(map_key(both), map_key(plain), "and every map segment points where it did")
  end)

  it("puts each translation under its original, marked as such", function()
    local lines = vim.split(both.text, "\n", { plain = true })
    local function line_of(needle)
      for index, line in ipairs(lines) do
        if line:find(needle, 1, true) then
          return index - 1
        end
      end
      error("not on the page: " .. needle)
    end
    local english = line_of("Create a skeleton")
    local chinese = line_of("创建项目的骨架目录结构")
    eq(chinese, english + 1, "right under it")
    truthy((both.lines[chinese] or {}).translation, "drawn as a translation")
    falsy((both.lines[english] or {}).translation, "the original is not")
    truthy(both.text:find("# 入门指南", 1, true), "a heading's translation is a heading")
  end)

  it("shows the original page unchanged once the translations are taken out", function()
    local kept = {}
    for index, line in ipairs(vim.split(both.text, "\n", { plain = true })) do
      if not (both.lines[index - 1] or {}).translation and line ~= "" then
        kept[#kept + 1] = line
      end
    end
    local expected = {}
    for _, line in ipairs(vim.split(plain.text, "\n", { plain = true })) do
      if line ~= "" then
        expected[#expected + 1] = line
      end
    end
    eq(kept, expected)
  end)

  it("names the lines of the original a translation follows", function()
    local lines = vim.split(both.text, "\n", { plain = true })
    local hidden = {}
    for _, line in ipairs(both.originals) do
      hidden[line + 1] = true
    end
    local shown = {}
    for index, line in ipairs(lines) do
      if not hidden[index] and line ~= "" then
        shown[#shown + 1] = line
      end
      if hidden[index] then
        falsy((both.lines[index - 1] or {}).translation, "a translation is never hidden: " .. line)
      end
    end
    local page = table.concat(shown, "\n")
    falsy(page:find("Create a skeleton", 1, true), "an original with a translation is hidden")
    falsy(page:find("Getting Started", 1, true), "headings too")
    truthy(page:find("创建项目的骨架目录结构", 1, true), "its translation stays")
    truthy(page:find("# 入门指南", 1, true), "and a heading's translation")
    eq(#plain.originals, 0, "a page without translations hides nothing")
  end)

  it("keeps a figure and an untranslated block on the page", function()
    local source = table.concat({
      "<html><body>",
      '<p>First paragraph.</p>',
      '<p class="wr-translation">第一段。</p>',
      '<p>No translation here.</p>',
      '<p><img src="a.png" alt="fig"/>Caption text.</p>',
      '<p class="wr-translation">图注。</p>',
      "</body></html>",
    }, "\n")
    local _, bilingual_page, blocks = xhtml.split_translation(source)
    local result = xhtml.convert(bilingual_page, { page_width = 52, translations = blocks })
    local lines = vim.split(result.text, "\n", { plain = true })
    local hidden = {}
    for _, line in ipairs(result.originals) do
      hidden[#hidden + 1] = lines[line + 1]
    end
    local text = table.concat(hidden, "\n")
    truthy(text:find("First paragraph", 1, true), "the translated paragraph is hidden")
    truthy(text:find("Caption text", 1, true), "and the caption")
    falsy(text:find("No translation", 1, true), "an untranslated paragraph stays")
    falsy(text:find("a.png", 1, true), "the figure stays")
  end)

  it("drops a heading's translation along with a dropped title", function()
    local titled = xhtml.convert(bilingual, { page_width = 52, translations = ranges, skip_title = true })
    falsy(titled.text:find("Getting Started", 1, true), "the repeated title is gone")
    falsy(titled.text:find("入门指南", 1, true), "and so is its translation")
  end)
end)

describe("translate.ensure", function()
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  local calls = {}
  local versions = { 0, 0, 10130 }
  local server_ref = {}
  local server = mock_lib.start({
    {
      path = "/web/book/enRead",
      handler = function(_, _, body)
        local payload = vim.json.decode(body or "{}")
        calls[#calls + 1] = payload
        local version = versions[math.min(#calls, #versions)]
        local done = version > 0
        return {
          status = 200,
          ctype = "application/json",
          body = vim.json.encode({
            curStatus = { { uid = payload.read[1].uid, translateVersion = version } },
            translationProgress = done and 100 or 40,
            stopPoll = done and 1 or nil,
            tips = done and nil or "全文翻译中...",
          }),
        }
      end,
    },
    {
      path = "/web/reader/toggleTranslate",
      handler = function(_, _, body)
        calls[#calls + 1] = { toggle = vim.json.decode(body or "{}") }
        return { status = 200, ctype = "application/json", body = '{"succ":1}' }
      end,
    },
  })
  server_ref.url = server.url

  local config = require("weread.config")
  config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", keymaps = false, sync_interval = 0 })
  config.ensure_dirs()
  require("weread.http").setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 8, retries = 0, proxy = "direct" })
  local translate = require("weread.translate")

  it("asks for the chapter and the next one, and waits until it is done", function()
    local result = nil
    translate.ensure("CB_x", {
      { chapterUid = 3, translateVersion = 0 },
      { chapterUid = 4, translateVersion = 0 },
    }, function(ok, value)
      result = { ok = ok, value = value }
    end, { interval = 20 })
    vim.wait(15000, function()
      return result ~= nil
    end, 20)
    truthy(result and result.ok, result and tostring(result.value))
    eq(result.value, 10130, "the new translation version")
    eq(#calls, 3, "polled until the service said it was done")
    eq(calls[1].bookId, "CB_x")
    eq(calls[1].reference.uid, 3, "the chapter on screen is the reference")
    eq(#calls[1].read, 2, "and the next one is translated ahead")
  end)

  it("keeps the switch per book and tells the account", function()
    calls = {}
    eq(translate.enabled("CB_x"), false)
    translate.set_enabled("CB_x", true)
    eq(translate.enabled("CB_x"), true)
    eq(translate.enabled("CB_y"), false, "other books are not affected")
    local done = nil
    translate.toggle_remote("CB_x", true, function(ok)
      done = ok
    end)
    vim.wait(15000, function()
      return done ~= nil
    end, 20)
    truthy(done)
    eq(calls[1].toggle.enabled, true)
    eq(calls[1].toggle.bookId, "CB_x")
    translate.set_enabled("CB_x", false)
    eq(translate.enabled("CB_x"), false)
  end)

  it("builds the referer from the configured origin, read at call time", function()
    server.reset()
    local previous = config.get().base_url
    -- a trailing slash must not turn into "//web/..." (尾斜杠不能变成 "//web/...")
    config.setup({ data_dir = tmpdir, base_url = server.url .. "/", proxy = "direct", keymaps = false, sync_interval = 0 })
    local done = nil
    translate.toggle_remote("CB_x", true, function(ok)
      done = ok
    end)
    vim.wait(15000, function()
      return done ~= nil
    end, 20)
    config.setup({ data_dir = tmpdir, base_url = previous, proxy = "direct", keymaps = false, sync_interval = 0 })
    translate.set_enabled("CB_x", false)

    truthy(done)
    local request = server.requests[1]
    truthy(request, "the request reached the mock")
    eq(request.path, "/web/reader/toggleTranslate", "no doubled slash")
    matches(request.headers:lower(), "referer: " .. server.url:lower() .. "/web/reader/", "referer follows base_url")
  end)

  it("clears its poll when the request raises synchronously, so a retry works", function()
    local http = require("weread.http")
    local real_request = http.request
    http.request = function()
      error("boom")
    end
    local first = nil
    local ok_call, call_err = pcall(translate.ensure, "CB_throw", { { chapterUid = 9, translateVersion = 0 } }, function(ok, value)
      first = { ok = ok, value = value }
    end, { interval = 20 })
    http.request = real_request

    truthy(ok_call, "ensure itself does not raise: " .. tostring(call_err))
    truthy(first, "the waiter was told")
    falsy(first.ok)
    matches(first.value, "boom")

    -- the key is free again: a second call really polls (key 已释放，第二次调用真的会轮询)
    calls = {}
    local second = nil
    translate.ensure("CB_throw", { { chapterUid = 9, translateVersion = 0 } }, function(ok, value)
      second = { ok = ok, value = value }
    end, { interval = 20 })
    vim.wait(15000, function()
      return second ~= nil
    end, 20)
    truthy(second and second.ok, second and tostring(second.value))
    eq(second.value, 10130)
    truthy(#calls >= 1, "the service was asked this time")
  end)

  it("tells every queued waiter when the request raises", function()
    local http = require("weread.http")
    local real_request = http.request
    local queued = nil
    -- the first waiter queues a second one while the poll is "in flight"
    -- (第一个等待者在轮询「进行中」时再排一个)
    http.request = function()
      translate.ensure("CB_queue", { { chapterUid = 5, translateVersion = 0 } }, function(ok, value)
        queued = { ok = ok, value = value }
      end)
      error("boom")
    end
    local first = nil
    translate.ensure("CB_queue", { { chapterUid = 5, translateVersion = 0 } }, function(ok, value)
      first = { ok = ok, value = value }
    end, { interval = 20 })
    http.request = real_request

    truthy(first and not first.ok, "the first waiter failed")
    truthy(queued and not queued.ok, "and so did the one queued behind it")
  end)
end)
