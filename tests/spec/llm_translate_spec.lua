--[[
Tests for the LLM's full-text translation (weread.llm_translate): which blocks
get translated, splicing the translations in without moving an offset of the
original, the batched run against a mock gateway, and the 译文 key preferring
the LLM with WeRead's own translation as the fallback.
(大模型整章翻译 weread.llm_translate 的测试：哪些块会被翻译、拼入译文而不挪动原文的任何偏移、
 对着 mock 网关分批运行，以及译文键优先用大模型、微信读书译文兜底)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

local ORIGINAL = table.concat({
  "<?xml version='1.0' encoding='utf-8'?>",
  '<html xmlns="http://www.w3.org/1999/xhtml" lang="en">',
  "<head><title>Getting Started</title><style>p { margin: 0 }</style></head>",
  '<body><h1 id="start">Getting Started</h1>',
  "<p>In this section we set up a <em>project</em> directory &amp; a server.</p>",
  "<ul>",
  "<li><p>Create a skeleton directory.</p></li>",
  "<li>Establish an HTTP server.</li>",
  "</ul>",
  "<table><tr><td>Cell text stays</td></tr></table>",
  "<pre><code>go run ./cmd/api</code></pre>",
  "<p>12345</p>",
  "<p>The end of the chapter.</p>",
  "</body></html>",
}, "\n")

local fail_all = false
local busy_left = 0
local short_reply = false
local requests = {}
local models = {}
local server = mock_lib.start({
  {
    path = "/v1/chat/completions",
    handler = function(_, _, body)
      local request = vim.json.decode(body)
      local paragraphs = vim.json.decode(request.messages[#request.messages].content)
      requests[#requests + 1] = paragraphs
      models[#models + 1] = request.model
      if busy_left > 0 then
        busy_left = busy_left - 1
        return { status = 429, ctype = "application/json", body = '{"error":{"message":"Concurrency limit exceeded for user, please retry later"}}' }
      end
      if fail_all then
        return { status = 500, ctype = "application/json", body = '{"error":{"message":"gateway down"}}' }
      end
      local out = {}
      for id, text in pairs(paragraphs) do
        if not (short_reply and id == "1") then
          out[id] = "译<" .. text .. ">"
        end
      end
      return {
        status = 200,
        ctype = "application/json",
        body = vim.json.encode({ choices = { { message = { content = vim.json.encode(out) } } } }),
      }
    end,
  },
})

local config = require("weread.config")
local http = require("weread.http")
local cache = require("weread.cache")
local xhtml = require("weread.xhtml")
local llm = require("weread.llm_translate")

local BOOK = "CB_llm_test"
local CHAPTER = { chapterUid = 7, chapterIdx = 3, title = "Getting Started" }

local function setup(lookup)
  vim.env.WEREAD_TEST_LLM_KEY = "sk-test"
  config.setup({
    data_dir = tmpdir,
    proxy = "direct",
    sync_interval = 0,
    keymaps = false,
    lookup = vim.tbl_deep_extend("force", {
      llm = { base_url = server.url .. "/v1", model = "test-model", api_key_env = "WEREAD_TEST_LLM_KEY" },
    }, lookup or {}),
  })
  config.ensure_dirs()
  http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 5, retries = 0, proxy = "direct" })
  cache.ensure_book_dirs(BOOK)
  cache.write(cache.chapter_file(BOOK, CHAPTER, "xhtml"), ORIGINAL)
  os.remove(cache.chapter_file(BOOK, CHAPTER, "llm.json"))
  llm._reset()
  fail_all, short_reply, busy_left = false, false, 0
  for index = #requests, 1, -1 do
    requests[index] = nil
  end
  for index = #models, 1, -1 do
    models[index] = nil
  end
  require("weread.translate").set_engine(BOOK, nil)
end

---Run a chapter translation to its end.
---(把一章的翻译跑完)
local function run(opts)
  local result = nil
  local progress = 0
  llm.run(BOOK, CHAPTER, vim.tbl_extend("force", {
    on_progress = function()
      progress = progress + 1
    end,
    on_done = function(ok, err, stats)
      result = { ok = ok, err = err, stats = stats }
    end,
  }, opts or {}))
  vim.wait(8000, function()
    return result ~= nil
  end, 10)
  return result, progress
end

describe("llm_translate blocks", function()
  it("finds the innermost blocks with foreign text, not table cells, code or numbers", function()
    local texts = {}
    for _, block in ipairs(llm.blocks(ORIGINAL)) do
      texts[#texts + 1] = block.tag .. ":" .. block.text
    end
    eq(texts, {
      "h1:Getting Started",
      "p:In this section we set up a project directory & a server.",
      "p:Create a skeleton directory.",
      "li:Establish an HTTP server.",
      "p:The end of the chapter.",
    })
  end)

  it("splices translations in the service's shape, keeping every offset of the original", function()
    local items = {
      ["Getting Started"] = "入门",
      ["In this section we set up a project directory & a server."] = "本节创建项目目录 & 服务器。",
      ["Establish an HTTP server."] = "搭建 HTTP 服务器。",
    }
    local bilingual, count, total = llm.bilingual(ORIGINAL, items)
    eq(count, 3)
    eq(total, 5)
    truthy(bilingual:find('\n<h1 class="wr-translation">入门</h1>', 1, true), "a heading's translation is a heading")
    truthy(bilingual:find("本节创建项目目录 &amp; 服务器。", 1, true), "escaped")
    truthy(bilingual:find('<li class="wr-translation" style="list-style-type:none;">', 1, true))
    local original = xhtml.split_translation(bilingual)
    eq(original, ORIGINAL, "taking the translations out gives the original back byte for byte")
    local plain = xhtml.convert(ORIGINAL, { page_width = 52 })
    local both = xhtml.convert(bilingual, { page_width = 52, translations = xhtml.translation_ranges(bilingual) })
    eq(both.source_runes, plain.source_runes, "no runes added")
    truthy(both.text:find("搭建 HTTP 服务器。", 1, true), "on the page")
  end)
end)

describe("llm_translate.run", function()
  it("translates every block in batches, from the reader's place, and keeps the result", function()
    setup()
    llm.FIRST_BATCH_CHARS = 40
    llm.BATCH_CHARS = 60
    -- one at a time, so the order the server sees is the order they were sent
    -- (一次一批，服务端看到的顺序就是发送顺序)
    llm.WORKERS = 1
    local from = ORIGINAL:find("Establish", 1, true)
    local result, progress = run({ from_rune = vim.fn.charidx(ORIGINAL, from - 1) })
    -- the page from that block on goes first, then outward: two ahead, one behind
    -- (从那一块开始的这一屏最先，然后向两边：往后两块、往前一块)
    llm.FIRST_BATCH_CHARS, llm.BATCH_CHARS, llm.WORKERS = 600, 2400, 4
    truthy(result.ok, tostring(result.err))
    eq(result.stats.count, 5)
    truthy(#requests >= 2, "more than one batch")
    eq(requests[1]["1"], "Establish an HTTP server.", "the reader's place goes first")
    truthy(progress >= 2, "progress after each batch")
    local stored = llm.load(BOOK, CHAPTER)
    truthy(stored.complete)
    eq(stored.model, "test-model")
    eq(stored.items["The end of the chapter."], "译<The end of the chapter.>")
    truthy(llm.preferred(BOOK, CHAPTER))

    local before = #requests
    truthy(run().ok)
    eq(#requests, before, "a translated chapter is not sent again")
  end)

  it("asks again for paragraphs a reply left out, and gives up on a broken gateway", function()
    setup()
    short_reply = true
    local result = run()
    -- id "1" is missing from every reply: retried once alone, then given up
    -- (每个回复都缺 id "1"：单独重试一次，然后放弃)
    falsy(result.ok)
    truthy(result.stats.count >= 3, "the rest is kept")
    falsy(llm.preferred(BOOK, CHAPTER), "an incomplete translation is not the one shown")

    setup()
    fail_all = true
    local broken = run()
    falsy(broken.ok)
    matches(broken.err, "gateway down")
    truthy(#requests <= 2 + llm.WORKERS, "stops instead of sending every batch: " .. #requests)
  end)

  it("uses the model picked for the book, and none when WeRead's was picked", function()
    local translate = require("weread.translate")
    setup()
    translate.set_engine(BOOK, "picked-model")
    eq(llm.model(BOOK), "picked-model")
    truthy(run().ok)
    eq(models[1], "picked-model", "the request names the picked model")
    eq(llm.load(BOOK, CHAPTER).model, "picked-model")
    truthy(llm.preferred(BOOK, CHAPTER))
    eq(llm.model("CB_other_book"), "test-model", "a book never picked for follows the config")

    translate.set_engine(BOOK, "weread")
    eq(llm.model(BOOK), nil)
    falsy(llm.enabled(BOOK), "WeRead's translation: no model")
    translate.set_engine(BOOK, nil)
  end)

  it("waits and tries again when the gateway is over its limit", function()
    setup()
    local saved = llm.BUSY_DELAY_MS
    llm.BUSY_DELAY_MS = 20
    busy_left = 3
    local result = run()
    llm.BUSY_DELAY_MS = saved
    truthy(result.ok, tostring(result.err))
    eq(result.stats.count, result.stats.total, "every block translated once the gateway let it through")
    truthy(llm.is_busy("Concurrency limit exceeded for user, please retry later"))
    falsy(llm.is_busy("gateway down"))
  end)

  it("starts over for another model", function()
    setup()
    truthy(run().ok)
    setup({ llm = { model = "other-model" } })
    falsy(llm.preferred(BOOK, CHAPTER), "translations by another model do not count")
  end)
end)

describe("the page with the LLM's translation", function()
  local pipeline = require("weread.chapter_pipeline")
  local translate = require("weread.translate")

  it("shows one translation at a time: the LLM's while it works, WeRead's only after it gave up", function()
    setup({ chapter = "llm" })
    translate.set_enabled(BOOK, true)
    local weread = ORIGINAL:gsub("<p>The end of the chapter.</p>", '<p>The end of the chapter.</p>\n<p class="wr-translation">微信读书的译文。</p>')
    cache.write(cache.chapter_file(BOOK, CHAPTER, "trans.xhtml"), weread)
    eq(pipeline.translation_state(BOOK, CHAPTER), nil, "nothing translated by the LLM yet: the plain original, not WeRead's")
    truthy(run().ok)
    eq(pipeline.translation_state(BOOK, CHAPTER), "llm:5", "complete: the LLM's")
    llm.discard(BOOK, CHAPTER)
    eq(pipeline.translation_state(BOOK, CHAPTER), "weread", "the LLM gave up: WeRead's")
    -- trying again: the page goes back to the LLM's, never a mix
    -- (再试一次：页面回到大模型的译文，绝不混排)
    truthy(run().ok)
    eq(pipeline.translation_state(BOOK, CHAPTER), "llm:5")

    setup({ chapter = "weread" })
    translate.set_enabled(BOOK, true)
    cache.write(cache.chapter_file(BOOK, CHAPTER, "trans.xhtml"), weread)
    eq(pipeline.translation_state(BOOK, CHAPTER), "weread", "WeRead's only")
    translate.set_enabled(BOOK, false)
    eq(pipeline.translation_state(BOOK, CHAPTER), nil, "switched off: none")
  end)
end)
