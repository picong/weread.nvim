--[[
Tests for translations that end without finishing: cancelled by the page, by
:WeReadEpub stop, or lost below and caught by the watchdog — every caller hears
about it, and an export never hangs. And for the gate in front of the gateway:
never more requests in flight than it allows, `K` ahead of the batches.
(没有译完就结束的翻译的测试：被页面取消、被 :WeReadEpub stop 取消，或者在底下丢失后被看门狗发现——每个调用
 方都会收到通知，导出绝不挂住。以及网关前的闸门：在途请求从不超过上限，K 排在批量请求前面)

The gateway is stubbed one level below the gate (`lookup._send`), so the gate
itself is what is tested.
(网关在闸门下一层（lookup._send）打桩，被测的就是闸门本身)
]]

local cache = require("weread.cache")
local config = require("weread.config")
local lookup = require("weread.lookup")
local llm = require("weread.llm_translate")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
vim.env.WEREAD_TEST_LLM_KEY = "sk-test"
config.setup({
  data_dir = tmpdir,
  proxy = "direct",
  sync_interval = 0,
  keymaps = false,
  lookup = { llm = { base_url = "http://127.0.0.1:9/v1", model = "m", api_key_env = "WEREAD_TEST_LLM_KEY", max_concurrency = 4 } },
})
config.ensure_dirs()

---A chapter of `n` paragraphs, cached.(缓存一章 n 段的章节)
local function chapter(book, uid, n)
  local paragraphs = {}
  for index = 1, n do
    paragraphs[index] = string.format("<p>Paragraph %d of chapter %d is here.</p>", index, uid)
  end
  local entry = { chapterUid = uid, chapterIdx = uid, title = "Chapter " .. uid, wordCount = 100 }
  cache.ensure_book_dirs(book)
  cache.write(cache.chapter_file(book, entry, "xhtml"), "<html><body>" .. table.concat(paragraphs, "\n") .. "</body></html>")
  os.remove(cache.chapter_file(book, entry, "llm.json"))
  return entry
end

---The gateway below the gate: answers when told to, counts what is in flight.
---(闸门下面的网关：叫它答才答，并记下在途数)
local gateway = { pending = {}, in_flight = 0, peak = 0, order = {}, hang = false }
local saved_send = lookup._send
local function install()
  gateway.pending, gateway.in_flight, gateway.peak, gateway.order, gateway.hang = {}, 0, 0, {}, false
  lookup._reset_gate()
  llm._reset()
  lookup._send = function(_, body, opts, _, done)
    gateway.in_flight = gateway.in_flight + 1
    gateway.peak = math.max(gateway.peak, gateway.in_flight)
    gateway.order[#gateway.order + 1] = opts.priority or "batch"
    local request = { body = body, done = done, live = true }
    gateway.pending[#gateway.pending + 1] = request
    return {
      kill = function()
        if request.live then
          request.live = false
          gateway.in_flight = gateway.in_flight - 1
        end
      end,
    }
  end
end

---Answer every request in flight, translating each paragraph.
---(回答所有在途请求，把每一段都译出来)
local function answer_all()
  local pending = gateway.pending
  gateway.pending = {}
  for _, request in ipairs(pending) do
    if request.live then
      request.live = false
      gateway.in_flight = gateway.in_flight - 1
      local content = request.body.messages[#request.body.messages].content
      local ok, paragraphs = pcall(vim.json.decode, content)
      local out = {}
      if ok and type(paragraphs) == "table" then
        for id, text in pairs(paragraphs) do
          out[id] = "译：" .. text
        end
        request.done(vim.json.encode(out), nil)
      else
        request.done("句子的译文", nil)
      end
    end
  end
end

local function settle()
  vim.wait(50)
end

describe("cancelling a translation", function()
  it("tells every caller, and only the callers it was asked for", function()
    install()
    local entry = chapter("CB_c1", 1, 6)
    local heard = {}
    llm.run("CB_c1", entry, { owner = "epub", model = "m", on_done = function(ok, err)
      heard.epub = { ok = ok, err = err }
    end })
    llm.run("CB_c1", entry, { owner = "reader", model = "m", on_done = function(ok, err)
      heard.reader = { ok = ok, err = err }
    end })
    settle()
    -- the page turns its translation off: the export goes on
    -- (页面关掉了译文：导出照常进行)
    llm.cancel({ owner = "reader", book_id = "CB_c1" })
    settle()
    eq(heard.reader, { ok = false, err = llm.CANCELLED }, "the page is told")
    eq(heard.epub, nil, "the export is not")
    truthy(llm.running("CB_c1", entry), "and its translation goes on")
    answer_all()
    vim.wait(2000, function()
      return heard.epub ~= nil
    end, 10)
    truthy(heard.epub and heard.epub.ok, "the export's chapter is finished")
  end)

  it("never leaves an export waiting on a cancelled chapter (the 19:05 hang)", function()
    -- What happened: the page's 译文 key turned translation off while an export
    -- was translating; cancel_all() took the job away without a word to the
    -- export, which waited for that chapter for good.
    -- (当时发生的事：导出正在翻译时，页面的译文键关掉了译文；cancel_all() 把任务拿走，却没告诉导出，导出就
    --  永远等着那一章)
    install()
    local entry = chapter("CB_c2", 1, 4)
    local heard = nil
    llm.run("CB_c2", entry, { owner = "epub", model = "m", on_done = function(ok, err)
      heard = { ok = ok, err = err }
    end })
    settle()
    llm.cancel_all()
    vim.wait(1000, function()
      return heard ~= nil
    end, 10)
    eq(heard, { ok = false, err = llm.CANCELLED }, "cancel_all tells the export too")
    eq(gateway.in_flight, 0, "and its requests are gone")
    eq(lookup.llm_gate().active, 0, "and their slots given back")
  end)

  it("gives up a chapter that goes quiet, so the export moves on", function()
    install()
    local saved_stall, saved_watch = llm.STALL_MS, llm.WATCH_MS
    llm.STALL_MS, llm.WATCH_MS = 150, 30
    local entry = chapter("CB_c3", 1, 3)
    local heard = nil
    llm.run("CB_c3", entry, { owner = "epub", model = "m", on_done = function(ok, err)
      heard = { ok = ok, err = err }
    end })
    -- the gateway never answers(网关始终不回答)
    vim.wait(2000, function()
      return heard ~= nil
    end, 10)
    llm.STALL_MS, llm.WATCH_MS = saved_stall, saved_watch
    truthy(heard and not heard.ok, "the chapter is given up")
    matches(heard.err, "没有进展")
    falsy(llm.running("CB_c3", entry))
    eq(lookup.llm_gate().active, 0, "its slots are free again")
  end)
end)

describe("the gate in front of the gateway", function()
  it("never has more than four in flight, and K goes first", function()
    install()
    local done = { export_a = false, export_b = false, page = false }
    local a = chapter("CB_ga", 1, 60)
    local b = chapter("CB_gb", 1, 60)
    local p = chapter("CB_gp", 1, 60)
    local saved_chars = llm.BATCH_CHARS
    llm.BATCH_CHARS = 80
    llm.run("CB_ga", a, { owner = "epub", model = "m", workers = 2, on_done = function()
      done.export_a = true
    end })
    llm.run("CB_gb", b, { owner = "epub", model = "m", workers = 2, on_done = function()
      done.export_b = true
    end })
    llm.run("CB_gp", p, { owner = "reader", model = "m", on_done = function()
      done.page = true
    end })
    settle()
    eq(gateway.in_flight, 4, "four in flight")
    truthy(lookup.llm_gate().waiting > 0, "the rest waits at the gate")
    -- the reader presses K while all of it is going on
    -- (这一切进行中，读者按下 K)
    local k_answer = nil
    lookup.llm_chat({ { role = "user", content = "a sentence" } }, { priority = "interactive", model = "m" }, function(content)
      k_answer = content
    end)
    local before = #gateway.order
    answer_all()
    settle()
    eq(gateway.order[before + 1], "interactive", "K takes the first slot that frees up")
    local rounds = 0
    while not (done.export_a and done.export_b and done.page and k_answer) and rounds < 200 do
      truthy(gateway.in_flight <= 4, "never more than four: " .. gateway.in_flight)
      answer_all()
      settle()
      rounds = rounds + 1
    end
    llm.BATCH_CHARS = saved_chars
    truthy(done.export_a and done.export_b and done.page, "everything gets done")
    eq(k_answer, "句子的译文")
    eq(gateway.peak, 4, "the most ever in flight is the limit")
    eq(lookup.llm_gate().peak, 4)
  end)

  it("tells a request cancelled while it waits, and frees the slot of one cancelled in flight", function()
    install()
    local answers = {}
    local handles = {}
    for index = 1, 6 do
      handles[index] = lookup.llm_chat({ { role = "user", content = "x" } }, { model = "m" }, function(content, err)
        answers[index] = err or content
      end)
    end
    settle()
    eq(lookup.llm_gate().active, 4)
    eq(lookup.llm_gate().waiting, 2)
    handles[6].kill()
    handles[1].kill()
    settle()
    eq(answers[6], lookup.CANCELLED, "the waiting one is told")
    eq(answers[1], lookup.CANCELLED, "and so is the one in flight")
    eq(lookup.llm_gate().active, 4, "its slot went to the next in line")
    eq(lookup.llm_gate().waiting, 0)
    answer_all()
    settle()
    eq(answers[5], "句子的译文")
  end)

  it("restores the gateway", function()
    lookup._send = saved_send
    lookup._reset_gate()
  end)
end)
