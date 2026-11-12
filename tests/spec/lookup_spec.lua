--[[
Tests for `K` translation: the lookup engine (cache, provider chain, deadlines,
the LLM answering first with a fast fallback) against a mock server standing in for every service, the
local ECDICT dictionary through a real sqlite3, and the popup/menu behaviour of
`K` on a page.
(K 翻译的测试：查询引擎（缓存、服务链、时限、大模型润色）对着冒充所有服务的 mock 服务器跑；
 本地 ECDICT 词典用真实的 sqlite3；以及书页上 K 的弹窗与菜单行为)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

local llm_auth = nil

-- A gateway that accepts the connection and never answers: a listening socket
-- nobody reads from. (接受连接却永不回应的网关：一个没人读的监听套接字)
local stuck = vim.uv.new_tcp()
stuck:bind("127.0.0.1", 0)
stuck:listen(16, function() end)
local STUCK_URL = "http://127.0.0.1:" .. stuck:getsockname().port .. "/v1"
local server = mock_lib.start({
  {
    path = "/api/imt",
    handler = function(_, _, body)
      local request = vim.json.decode(body)
      local text = request.source.text_list[1]
      if text:find("fail", 1, true) then
        return { status = 500, ctype = "application/json", body = '{"header":{"ret_code":"error"}}' }
      end
      return {
        status = 200,
        ctype = "application/json",
        body = vim.json.encode({ header = { ret_code = "succ" }, auto_translation = { "译:" .. text } }),
      }
    end,
  },
  {
    path = "/jsonapi",
    handler = function(_, path)
      return {
        status = 200,
        ctype = "application/json",
        body = vim.json.encode({
          ec = {
            word = {
              {
                usphone = "ˈwɜːrd",
                trs = { { tr = { { l = { i = { "n. 在线释义" } } } } } },
                ["return-phrase"] = { l = { i = "online" } },
              },
            },
          },
        }),
      }
    end,
  },
  {
    path = "/v1/chat/completions",
    handler = function(_, _, body, head)
      llm_auth = head:match("[Aa]uthorization:%s*([^\r\n]+)")
      local request = vim.json.decode(body)
      local text = request.messages[#request.messages].content
      return {
        status = 200,
        ctype = "application/json",
        body = vim.json.encode({ choices = { { message = { content = "润色:" .. text } } } }),
      }
    end,
  },
})

local config = require("weread.config")
local http = require("weread.http")
local lookup = require("weread.lookup")

-- The machine running the specs may well have a real Claude Code gateway in its
-- environment and settings; no spec may reach it.
-- (跑 spec 的机器很可能在环境变量与设置里有真实的 Claude Code 网关；任何 spec 都不能碰到它)
vim.env.ANTHROPIC_BASE_URL = nil
vim.env.ANTHROPIC_AUTH_TOKEN = nil
lookup.CLAUDE_SETTINGS = tmpdir .. "/no-claude-settings.json"

local function setup(lookup_opts)
  lookup_opts = vim.deepcopy(lookup_opts or {})
  config.setup({ data_dir = tmpdir, proxy = "direct", sync_interval = 0, lookup = lookup_opts })
  config.ensure_dirs()
  http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 5, retries = 0, proxy = "direct" })
  lookup.TRANSMART_URL = server.url .. "/api/imt"
  lookup.YOUDAO_URL = server.url .. "/jsonapi"
  lookup._reset()
  os.remove(config.path("lookup.json"))
  server.reset()
end

---Run a translation to completion.
---(把一次翻译跑完)
---@param text string
---@param count integer|nil results to wait for(要等几个结果)
---@return table[] results
---@return string|nil error
local function run(text, count)
  local results, failure = {}, nil
  lookup.translate(text, {
    on_result = function(result)
      results[#results + 1] = result
    end,
    on_error = function(message)
      failure = message
    end,
  })
  vim.wait(5000, function()
    return failure ~= nil or #results >= (count or 1)
  end, 10)
  return results, failure
end

describe("lookup text", function()
  it("tells dictionary entries from passages", function()
    truthy(lookup.is_word("serendipity"))
    truthy(lookup.is_word("well-known"))
    truthy(lookup.is_word("give up"))
    falsy(lookup.is_word("Adding manpower makes it later."), "a sentence")
    falsy(lookup.is_word("one two three four"), "four words")
    eq(lookup.normalize("  hello \n world "), "hello world")
    eq(lookup.normalize("全是中文"), nil, "nothing foreign")
    eq(lookup.word_forms("Frodo's"), { "Frodo's", "Frodo", "frodo's", "frodo" })
  end)
end)

describe("lookup engine", function()
  it("translates a sentence, then serves it from the cache", function()
    setup({ word = { "youdao" }, sentence = { "transmart" } })
    local results = run("It was the best of times.")
    eq(results[1].text, "译:It was the best of times.")
    eq(results[1].source, "transmart")
    falsy(results[1].cached)
    local count = #server.requests
    local again = run("it was   the best of times.")
    truthy(again[1].cached, "same text, different spacing and case: a cache hit")
    eq(#server.requests, count, "and no request")
    lookup.flush()
    truthy(require("weread.cache").read_json(config.path("lookup.json"))["sentence:it was the best of times."], "written to disk")
    lookup._reset()
    local cold = run("It was the best of times.")
    truthy(cold[1].cached, "a new session reads the cache file")
  end)

  it("looks a word up in the dictionary and sends nothing WeRead-specific", function()
    setup({ word = { "youdao" }, sentence = { "transmart" } })
    local results = run("online")
    eq(results[1].kind, "word")
    eq(results[1].phonetic, "ˈwɜːrd")
    eq(results[1].lines, { "n. 在线释义" })
    local head = server.requests[#server.requests].headers
    falsy(head:find("[Cc]ookie:%s*%S"), "no cookies")
    falsy(head:find("[Rr]eferer:"), "no referer")
    falsy(head:find("[Oo]rigin:"), "no origin")
  end)

  it("falls back to the next service, and to the sentence translators for an unknown word", function()
    setup({ word = { "nothing", "youdao" }, sentence = { "transmart" } })
    lookup._provider("nothing", {
      available = function()
        return true
      end,
      word = function(_, _, done)
        done(nil, nil)
      end,
    })
    local results = run("online")
    eq(results[1].source, "youdao", "a dictionary without the word hands over")
    setup({ word = { "nothing" }, sentence = { "transmart" } })
    local unknown = run("Gandalf")
    eq(unknown[1].source, "transmart", "no dictionary knows it: translated as a phrase")
    eq(unknown[1].kind, "sentence")
    lookup._provider("nothing", nil)
  end)

  it("gives up on a slow service at the deadline and says why when all fail", function()
    setup({ word = { "slow" }, sentence = { "transmart" }, timeout = 0.3 })
    local finished = false
    lookup._provider("slow", {
      available = function()
        return true
      end,
      word = function(_, _, done)
        vim.defer_fn(function()
          finished = true
          done({ word = "late", lines = { "太晚了" } })
        end, 1500)
        return { kill = function() end }
      end,
    })
    local started = vim.uv.hrtime()
    local results = run("online")
    local elapsed = (vim.uv.hrtime() - started) / 1e6
    eq(results[1].source, "transmart", "the deadline handed over to the sentence translator")
    truthy(elapsed < 1200, "within the deadline, not the slow answer: " .. elapsed)
    vim.wait(1600, function()
      return finished
    end)
    lookup._provider("slow", nil)

    setup({ word = { "youdao" }, sentence = { "transmart" } })
    local _, failure = run("please fail this one now.")
    matches(failure, "腾讯交互翻译")
  end)

  it("shares one request between identical lookups in flight", function()
    setup({ word = { "youdao" }, sentence = { "transmart" } })
    local seen = 0
    for _ = 1, 3 do
      lookup.translate("Shared sentence here.", {
        on_result = function()
          seen = seen + 1
        end,
        on_error = function() end,
      })
    end
    vim.wait(3000, function()
      return seen == 3
    end, 10)
    eq(seen, 3)
    local posts = 0
    for _, request in ipairs(server.requests) do
      if request.path == "/api/imt" then
        posts = posts + 1
      end
    end
    eq(posts, 1, "three callers, one request")
  end)

  local GATEWAY = nil

  ---Point the LLM at the mock server, keyed from the environment.
  ---(把大模型指向 mock 服务器，key 来自环境变量)
  local function with_llm(extra)
    vim.env.WEREAD_TEST_LLM_KEY = "sk-test-secret"
    GATEWAY = server.url .. "/v1"
    return vim.tbl_deep_extend("force", {
      word = { "youdao" },
      sentence = { "llm", "transmart" },
      llm = { base_url = GATEWAY, model = "test-model", api_key_env = "WEREAD_TEST_LLM_KEY", timeout = 2 },
    }, extra or {})
  end

  ---@param path string
  ---@return integer
  local function posts(path)
    local count = 0
    for _, request in ipairs(server.requests) do
      if request.path == path then
        count = count + 1
      end
    end
    return count
  end

  it("answers a sentence with the LLM alone, and asks no fast translator", function()
    setup(with_llm())
    local results = run("A sentence for the model.")
    vim.wait(300, function()
      return false
    end)
    eq(#results, 1, "one answer, not a fast one and then a better one")
    eq(results[1].source, "llm")
    eq(results[1].model, "test-model")
    eq(results[1].text, "润色:A sentence for the model.")
    falsy(results[1].fallback)
    eq(posts("/api/imt"), 0, "TranSmart was never asked")
    eq(llm_auth, "Bearer sk-test-secret", "the key from the environment")
    local cached = run("A sentence for the model.")
    truthy(cached[1].cached)
    eq(cached[1].source, "llm")
    vim.env.WEREAD_TEST_LLM_KEY = nil
    eq(lookup.llm_key(), nil, "no key without the variable")
  end)

  it("falls back to the fast translator when the LLM times out, says so, and does not cache it", function()
    setup(with_llm({ llm = { timeout = 0.5, base_url = STUCK_URL } }))
    local started = vim.uv.hrtime()
    local results = run("A sentence the gateway sits on.")
    local elapsed = (vim.uv.hrtime() - started) / 1e6
    eq(#results, 1)
    eq(results[1].source, "transmart")
    truthy(results[1].fallback, "marked as the fallback")
    matches(results[1].fallback_reasons[1], "大模型：超时")
    truthy(elapsed < 1400, "the fallback came at the LLM's deadline: " .. elapsed)
    falsy(require("weread.lookup")._cached("sentence", "A sentence the gateway sits on."), "a fallback is not cached")

    -- within the back-off the LLM is not waited on again
    -- (冷却期内不会再等大模型)
    local before = posts("/v1/chat/completions")
    local again = run("Another sentence, right after.")
    eq(again[1].source, "transmart")
    truthy(again[1].fallback)
    matches(again[1].fallback_reasons[1], "刚才失败过")
    eq(posts("/v1/chat/completions"), before, "no LLM request during the back-off")
    falsy(lookup.llm_first(), "the popup will not promise the LLM either")
    vim.env.WEREAD_TEST_LLM_KEY = nil
  end)

  it("drops a fast-translator answer cached before, once the LLM answers first", function()
    setup({ word = { "youdao" }, sentence = { "transmart" } })
    eq(run("Cached by the fast one.")[1].source, "transmart")
    lookup.flush()
    config.setup({ data_dir = tmpdir, proxy = "direct", sync_interval = 0, lookup = with_llm() })
    local results = run("Cached by the fast one.")
    eq(results[1].source, "llm", "the old fast answer is not shown")
    falsy(results[1].cached)
    vim.env.WEREAD_TEST_LLM_KEY = nil
  end)

  it("uses the Claude Code gateway by default, from the environment or its settings file", function()
    setup()
    eq(config.get().lookup.llm.model, "deepseek-v4-flash", "the gateway's fast DeepSeek by default")
    eq(config.get().lookup.sentence, { "llm", "transmart" }, "the LLM first, TranSmart as the fallback")
    eq(lookup.llm_endpoint().url, nil, "no gateway anywhere: no LLM")
    falsy(lookup.llm_first())
    local plain = run("No gateway here.")
    eq(plain[1].source, "transmart", "without an LLM the fast translator is the answer")
    falsy(plain[1].fallback, "and an LLM that is not configured is no failure")

    -- the settings file, as when nvim was started from a desktop launcher
    -- (设置文件：比如从桌面启动器打开的 nvim)
    vim.fn.writefile({
      vim.json.encode({ env = { ANTHROPIC_BASE_URL = server.url .. "/", ANTHROPIC_AUTH_TOKEN = "sk-from-settings" } }),
    }, lookup.CLAUDE_SETTINGS)
    lookup._forget_claude_settings()
    local endpoint = lookup.llm_endpoint()
    eq(endpoint.url, server.url .. "/v1", "an Anthropic-style base gets /v1")
    eq(endpoint.key, "sk-from-settings")
    truthy(lookup.llm_first())
    local results = run("Through the gateway.")
    eq(#results, 1)
    eq(results[1].source, "llm")
    eq(results[1].model, "deepseek-v4-flash")
    eq(llm_auth, "Bearer sk-from-settings")

    -- the environment wins over the file (环境变量优先于文件)
    vim.env.ANTHROPIC_BASE_URL = server.url
    vim.env.ANTHROPIC_AUTH_TOKEN = "sk-from-env"
    eq(lookup.llm_endpoint().key, "sk-from-env")
    vim.env.ANTHROPIC_BASE_URL = nil
    vim.env.ANTHROPIC_AUTH_TOKEN = nil
    os.remove(lookup.CLAUDE_SETTINGS)
    lookup._forget_claude_settings()
  end)

  it("keeps one LLM request for popups waiting together", function()
    setup(with_llm())
    local seen = 0
    for _ = 1, 3 do
      lookup.translate("Wait for it together.", {
        on_result = function()
          seen = seen + 1
        end,
        on_error = function() end,
      })
    end
    vim.wait(3000, function()
      return seen == 3
    end, 10)
    eq(seen, 3)
    eq(posts("/v1/chat/completions"), 1, "three popups, one request")
    vim.env.WEREAD_TEST_LLM_KEY = nil
  end)

  it("says the translators are switched off when an unknown word has nowhere to go", function()
    setup({ word = { "nothing" }, sentence = {} })
    lookup._provider("nothing", {
      available = function()
        return true
      end,
      word = function(_, _, done)
        done(nil, nil)
      end,
    })
    local _, failure = run("Gandalf")
    matches(failure, "lookup.sentence 为空")
    lookup._provider("nothing", nil)
  end)
end)

describe("ecdict", function()
  local ecdict = require("weread.ecdict")
  if vim.fn.executable("sqlite3") ~= 1 then
    it("needs sqlite3 (skipped)", function() end)
    return
  end

  it("builds a dictionary from a CSV and finds words and their lemmas", function()
    setup({ word = { "ecdict" }, sentence = { "transmart" } })
    local csv = tmpdir .. "/mini ecdict.csv"
    vim.fn.writefile({
      "word,phonetic,definition,translation,pos,collins,oxford,tag,bnc,frq,exchange,detail,audio",
      'perceive,pə\'siːv,,"vt. 察觉，感知\\nvt. 理解，认为",,,,,,,"d:perceived/p:perceived/3:perceives/i:perceiving",,',
      'perceived,,,,,,,,,,"0:perceive/1:pd",,',
      "Paris,'pæris,,n. 巴黎,,,,,,,,,",
      'tooth,tuːθ,,"n. 牙齿\nvt. 装齿",,,,,,,"s:teeth",,',
      'teeth,tiːθ,,n. 牙齿（复数）,,,,,,,"0:tooth/1:s",,',
    }, csv)
    local built, message = nil, nil
    ecdict.build(csv, function(ok, text)
      built, message = ok, text
    end)
    vim.wait(5000, function()
      return built ~= nil
    end, 10)
    eq(built, true, tostring(message))
    matches(message, "5 个词条")
    truthy(ecdict.available())

    local found = nil
    ecdict.lookup("Perceive", function(result)
      found = result or false
    end)
    vim.wait(3000, function()
      return found ~= nil
    end, 10)
    eq(found.word, "perceive", "case folded")
    eq(found.lines, { "vt. 察觉，感知", "vt. 理解，认为" })

    local inflected = run("perceived")
    eq(inflected[1].source, "ecdict")
    eq(inflected[1].lemma, "perceive", "an inflected form leads to its lemma")
    eq(inflected[1].lines[1], "vt. 察觉，感知", "an empty entry takes the lemma's meanings")

    local own = run("teeth")
    eq(own[1].lemma, "tooth")
    eq(own[1].lines, { "n. 牙齿（复数）" }, "a form with meanings of its own keeps only those: one set, not two")

    local missing = nil
    ecdict.lookup("x'); DROP TABLE stardict; --", function(result)
      missing = result or false
    end)
    vim.wait(2000, function()
      return missing ~= nil
    end, 10)
    eq(missing, false, "anything but a plain word is refused")
    local still = nil
    ecdict.lookup("Paris", function(result)
      still = result or false
    end)
    vim.wait(2000, function()
      return still ~= nil
    end, 10)
    eq(still.lines, { "n. 巴黎" })
    os.remove(ecdict.path())
  end)
end)

describe("K on a page", function()
  local reader_lookup = require("weread.reader_lookup")

  it("finds the English word at a column", function()
    local line = "　　他说 don't-stop，然后 well-known words."
    local col = line:find("stop", 1, true) - 1
    eq((reader_lookup.word_at(line, col)), "don't-stop")
    eq((reader_lookup.word_at(line, line:find("words", 1, true) + 1)), "words")
    eq(reader_lookup.word_at(line, 0), nil, "on Chinese text")
  end)

  it("joins wrapped lines without the markdown", function()
    eq(reader_lookup.join({ "　　It was **the best**", "of times." }), "It was the best of times.")
    eq(reader_lookup.join({ "中文", "接着" }), "中文接着")
  end)

  ---A chapter buffer with one highlight over `highlighted`.
  ---(一个章节 buffer，`highlighted` 上有一条划线)
  local function page(lines, highlighted)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.b[buf].weread = { book_id = "B", chapter_index = 1, chapter_key = "0001", chapter_uid = "1" }
    if highlighted then
      local from = lines[1]:find(highlighted, 1, true) - 1
      vim.b[buf].weread_annotations = {
        { annotation = { range = "1-2" }, line = 0, finish_line = 0, from_col = from, to_col = from + #highlighted },
      }
    end
    vim.api.nvim_win_set_buf(0, buf)
    return buf
  end

  it("translates the word under the cursor in a popup next to it", function()
    setup({ word = { "youdao" }, sentence = { "transmart" } })
    local buf = page({ "　　An online page." })
    vim.api.nvim_win_set_cursor(0, { 1, (vim.fn.getline(1):find("online", 1, true)) })
    reader_lookup.hover()
    local win = reader_lookup.window()
    truthy(win, "the popup opens at once")
    eq(vim.api.nvim_win_get_config(win).relative, "win", "anchored to the cursor's window")
    vim.wait(3000, function()
      return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, 1, false)[1] ~= "翻译中…"
    end, 10)
    local shown = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    matches(shown[1], "online")
    eq(shown[2], "n. 在线释义")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    falsy(reader_lookup.window(), "moving the cursor closes it")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("shows one translation of a sentence: the LLM's, or the fallback marked as such", function()
    vim.env.WEREAD_TEST_LLM_KEY = "sk-test-secret"
    local function popup_lines()
      local win = reader_lookup.window()
      return win and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false) or {}, win
    end
    local function footer(win)
      local config_ = vim.api.nvim_win_get_config(win)
      return config_.footer and config_.footer[1] and config_.footer[1][1] or ""
    end
    local buf = page({ "　　Adding manpower makes it later." })
    setup({
      word = { "youdao" },
      sentence = { "llm", "transmart" },
      llm = { base_url = server.url .. "/v1", model = "test-model", api_key_env = "WEREAD_TEST_LLM_KEY" },
    })
    reader_lookup.translate("Adding manpower makes it later.")
    local lines = popup_lines()
    eq(lines, { "翻译中…（test-model）" }, "waiting says who is asked, and shows no early translation")
    vim.wait(3000, function()
      return popup_lines()[1] ~= "翻译中…（test-model）"
    end, 10)
    local shown, win = popup_lines()
    eq(shown, { "润色:Adding manpower makes it later." }, "exactly one translation")
    matches(footer(win), "test%-model")
    reader_lookup.close()

    setup({
      word = { "youdao" },
      sentence = { "llm", "transmart" },
      llm = { base_url = STUCK_URL, model = "test-model", api_key_env = "WEREAD_TEST_LLM_KEY", timeout = 0.4 },
    })
    reader_lookup.translate("Adding manpower makes it later.")
    vim.wait(3000, function()
      return not popup_lines()[1]:find("翻译中", 1, true)
    end, 10)
    shown, win = popup_lines()
    eq(shown[1], "译:Adding manpower makes it later.", "the fallback's translation, once")
    matches(shown[2], "兜底结果")
    matches(footer(win), "兜底：腾讯交互翻译")
    eq(#shown, 2, "and nothing else")
    reader_lookup.close()
    vim.env.WEREAD_TEST_LLM_KEY = nil
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("asks what to do on a highlight with foreign text, and goes straight to the thoughts otherwise", function()
    setup({ word = { "youdao" }, sentence = { "transmart" } })
    local annotations = require("weread.annotations")
    local thoughts = require("weread.thoughts")
    local original_show = thoughts.show_thoughts_at_cursor
    local shown = 0
    thoughts.show_thoughts_at_cursor = function()
      shown = shown + 1
    end
    local select = vim.ui.select
    local offered = nil
    vim.ui.select = function(items, opts, choose)
      offered = {}
      for _, item in ipairs(items) do
        offered[#offered + 1] = opts.format_item(item)
      end
      choose(items[2])
    end
    local ok, err = pcall(function()
      local buf = page({ "　　他写道 a quiet mind 很好。" }, "a quiet mind")
      vim.api.nvim_win_set_cursor(0, { 1, (vim.fn.getline(1):find("quiet", 1, true)) })
      reader_lookup.hover()
      truthy(offered, "a menu on a highlight")
      matches(offered[1], "翻译「quiet」")
      eq(offered[2], "查看划线的想法")
      eq(shown, 1, "the thoughts, as chosen")

      offered = nil
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "　　他写道很安静的心很好。" })
      local from = vim.fn.getline(1):find("很安静", 1, true) - 1
      vim.b[buf].weread_annotations = { { annotation = { range = "1-2" }, line = 0, finish_line = 0, from_col = from, to_col = from + 9 } }
      vim.api.nvim_win_set_cursor(0, { 1, from + 3 })
      reader_lookup.hover()
      falsy(offered, "nothing foreign to translate: no menu")
      eq(shown, 2, "straight to the thoughts")
      truthy(require("weread.annotations_render").entry_covering(buf, 0, from), "covering checks the exact span")
      falsy(require("weread.annotations_render").entry_covering(buf, 0, 0), "not the start of the line")
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)
    vim.ui.select = select
    thoughts.show_thoughts_at_cursor = original_show
    reader_lookup.close()
    if not ok then
      error(err, 0)
    end
  end)
end)
