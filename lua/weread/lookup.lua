--[[
Translation of foreign text in a book: a word through the dictionaries, a phrase
or a sentence through the sentence translators.
(书里外文的翻译：单词走词典，短语与句子走句子翻译)

Speed comes first, so every lookup is built the same way:
(速度第一，因此每次查询都是同一个结构：)

* cache first — memory, then `data_dir/lookup.json` — so a word met again costs
  nothing (先查缓存——内存，然后 data_dir/lookup.json——再遇到的词不花任何时间)
* then the services in the configured order, one at a time, each with a deadline;
  a service that fails or runs out of time hands over to the next
  (然后按配置顺序逐个问服务，每个都有时限；失败或超时就交给下一个)
* a word no dictionary knows (a name, a coinage) is sent to the sentence
  translators, so `K` always answers something
  (哪本词典都不认识的词（人名、新造词）交给句子翻译，所以 K 总能给出点什么)
* one answer per lookup: a sentence goes to the LLM first and only falls back to
  a fast translator when the LLM fails or runs out of time, and that answer is
  marked as the fallback it is
  (每次查询只给一份答案：句子先问大模型，大模型失败或超时才回退到快速翻译，并标明这是兜底结果)

Everything is asynchronous: curl and sqlite3 run as child processes, and the
callbacks come back on the main loop. Identical lookups in flight share one
request.
(全部异步：curl 与 sqlite3 都是子进程，回调回到主循环。同样的查询在途时共用一个请求)

Third-party services get the text and nothing else: no cookies, no Referer, no
Origin. The API key of the LLM comes from the environment (or the config) and
reaches curl through a 0600 header file, never its command line.
(第三方服务只拿到文本：不带 cookie、Referer、Origin。大模型的 API key 来自环境变量（或配置），
 经 0600 的头文件交给 curl，从不出现在命令行上)
]]

local M = {}

M.TRANSMART_URL = "https://transmart.qq.com/api/imt"
M.YOUDAO_URL = "https://dict.youdao.com/jsonapi"

---Most entries kept in the cache file.
---(缓存文件最多保留多少条)
M.CACHE_LIMIT = 3000

local PROVIDER_NAMES = {
  ecdict = "ECDICT",
  youdao = "有道",
  transmart = "腾讯交互翻译",
  llm = "大模型",
}

---@return table
local function settings()
  return require("weread.config").get().lookup or {}
end

-- ------------------------------------------------------------------ cache

---{ path, data = { [key] = { text..., at } }, dirty }
local store = { path = nil, data = nil }

---@return string
local function cache_path()
  return require("weread.config").path("lookup.json")
end

---@return table
local function cache()
  local path = cache_path()
  if store.data == nil or store.path ~= path then
    store.path = path
    store.data = require("weread.cache").read_json(path) or {}
  end
  return store.data
end

local function write_cache()
  local data = cache()
  local keys = vim.tbl_keys(data)
  if #keys > M.CACHE_LIMIT then
    table.sort(keys, function(a, b)
      return (data[a].at or 0) < (data[b].at or 0)
    end)
    for index = 1, #keys - M.CACHE_LIMIT do
      data[keys[index]] = nil
    end
  end
  local ok, err = require("weread.cache").write_json(store.path, data)
  if ok == false then
    require("weread.log").warn("lookup: cache write failed: %s", tostring(err))
  end
end

local save_later = nil

local function schedule_save()
  if not save_later then
    save_later = require("weread.timer").debounce(write_cache, 2000)
  end
  save_later.call()
end

---Write pending cache entries now (on exit).
---(把没写盘的缓存立刻写出（退出时用）)
function M.flush()
  if save_later then
    save_later.cancel()
  end
  if store.data then
    write_cache()
  end
end

---When the LLM last failed, so a broken key or an unreachable gateway does not
---cost a full timeout on every `K`: for a while sentences go straight to the
---fast translators (still marked as the fallback).
---(大模型上次失败的时刻：key 不对或网关不通时，不必每按一次 K 都白等一个超时；这段时间里句子
--- 直接走快速翻译（仍标明是兜底）)
local llm_failed_at = nil
M.LLM_RETRY_SECONDS = 120

---Forget the in-memory cache and requests in flight. For tests.
---(丢掉内存缓存与在途请求；供测试使用)
function M._reset()
  store.path, store.data = nil, nil
  llm_failed_at = nil
  if save_later then
    save_later.cancel()
  end
end

---@param kind "word"|"sentence"
---@param text string
---@return string
local function key_of(kind, text)
  return kind .. ":" .. text:lower()
end

---The cached entry for a text, for tests.
---(某段文字的缓存条目，供测试)
---@param kind "word"|"sentence"
---@param text string
---@return table|nil
function M._cached(kind, text)
  return cache()[key_of(kind, M.normalize(text) or text)]
end

-- ------------------------------------------------------------------ text

---Collapse whitespace; nil when no Latin letter is left to translate.
---(折叠空白；没有拉丁字母可翻译时返回 nil)
---@param text string|nil
---@return string|nil
function M.normalize(text)
  local flat = vim.trim((tostring(text or ""):gsub("%s+", " ")))
  if flat == "" or not flat:find("%a") then
    return nil
  end
  return flat
end

---Is this something a dictionary lists: a word, or a short set phrase such as
---"give up" (three words at most, no sentence punctuation)? Everything else is
---a passage for the sentence translators.
---(这是词典会收的东西吗：一个词，或者 "give up" 这样的短词组（最多三个词、没有句子标点）？
--- 其余都是交给句子翻译的段落)
---@param text string
---@return boolean
function M.is_word(text)
  if #text > 40 then
    return false
  end
  local count = 0
  for token in text:gmatch("%S+") do
    if not token:match("^[%a][%a'%-]*$") then
      return false
    end
    count = count + 1
  end
  return count >= 1 and count <= 3
end

---Forms a word may be listed under: as written, without a possessive, lower case.
---(一个词可能的词头写法：原样、去掉所有格、小写)
---@param word string
---@return string[]
function M.word_forms(word)
  local forms = {}
  local function add(form)
    if form ~= "" and not vim.tbl_contains(forms, form) then
      forms[#forms + 1] = form
    end
  end
  local bare = word:gsub("'s$", ""):gsub("'$", "")
  add(word)
  add(bare)
  add(word:lower())
  add(bare:lower())
  return forms
end

-- ------------------------------------------------------------------ requests

---Request options every third-party call shares: no WeRead cookies or headers.
---(所有第三方请求共用的选项：不带微信读书的 cookie 与头)
---@param extra table
---@return table
local function third_party(extra)
  return vim.tbl_extend("force", {
    no_cookies = true,
    referer = false,
    origin = false,
    retries = 0,
  }, extra)
end

---@param res table
---@return table|nil data
---@return string|nil err
local function decode(res)
  if res.code ~= 200 then
    return nil, res.error or ("HTTP " .. tostring(res.code))
  end
  local ok, data = pcall(vim.json.decode, res.body or "")
  if not ok or type(data) ~= "table" then
    return nil, "无法解析的响应"
  end
  return data, nil
end

---Claude Code's settings file. `$WEREAD_CLAUDE_SETTINGS` points it elsewhere:
---the test runner does, so no spec can reach a real gateway.
---(Claude Code 的设置文件。$WEREAD_CLAUDE_SETTINGS 可以指向别处：测试入口就这么做，任何 spec
--- 都碰不到真实网关)
M.CLAUDE_SETTINGS = vim.env.WEREAD_CLAUDE_SETTINGS or "~/.claude/settings.json"

---`env` of Claude Code's settings file, read again only when the file changes.
---(Claude Code 设置文件里的 env 段；文件变了才重新读)
local claude_settings = { stamp = nil, env = {} }

---@return table<string, string>
local function claude_env()
  local path = vim.fn.expand(M.CLAUDE_SETTINGS)
  local stat = vim.uv.fs_stat(path)
  local stamp = stat and (path .. ":" .. stat.mtime.sec .. ":" .. stat.size) or nil
  if stamp ~= claude_settings.stamp then
    claude_settings.stamp = stamp
    claude_settings.env = {}
    local data = stat and require("weread.cache").read_json(path)
    if type(data) == "table" and type(data.env) == "table" then
      claude_settings.env = data.env
    end
  end
  return claude_settings.env
end

---A variable from the environment, else from Claude Code's settings.
---(先看环境变量，再看 Claude Code 的设置)
---@param name string
---@return string|nil
local function claude_value(name)
  local value = vim.env[name]
  if type(value) ~= "string" or value == "" then
    value = claude_env()[name]
  end
  return type(value) == "string" and value ~= "" and value or nil
end

---Where the LLM is and how to get in: the configured endpoint, or the gateway
---Claude Code uses. An Anthropic-style base ("http://host:3200") speaks the
---OpenAI dialect under `/v1`.
---(大模型在哪、凭什么进去：配置的地址，或者 Claude Code 用的网关。Anthropic 风格的根地址
--- （"http://host:3200"）在 /v1 下也说 OpenAI 的协议)
---@return { url: string|nil, key: string|nil, via: string }
function M.llm_endpoint()
  local llm = settings().llm or {}
  local explicit = type(llm.api_key) == "string" and llm.api_key ~= "" and llm.api_key or nil
  if type(llm.base_url) == "string" and llm.base_url ~= "" then
    local name = llm.api_key_env or "OPENAI_API_KEY"
    local key = explicit or (vim.env[name] ~= "" and vim.env[name] or nil)
    return { url = llm.base_url:gsub("/+$", ""), key = key, via = "lookup.llm.base_url" }
  end
  local base = claude_value("ANTHROPIC_BASE_URL")
  local key = explicit
  if not key then
    key = llm.api_key_env and claude_value(llm.api_key_env) or claude_value("ANTHROPIC_AUTH_TOKEN")
  end
  if not base then
    return { url = nil, key = key, via = "Claude Code 网关（未找到 ANTHROPIC_BASE_URL）" }
  end
  base = base:gsub("/+$", "")
  if not base:find("/v%d+$") then
    base = base .. "/v1"
  end
  return { url = base, key = key, via = "Claude Code 网关" }
end

---The API key of the LLM, wherever it comes from.
---(大模型的 API key，不管来自哪里)
---@return string|nil
function M.llm_key()
  return M.llm_endpoint().key
end

---For tests: forget what was read from Claude Code's settings.
---(供测试：忘掉从 Claude Code 设置里读到的东西)
function M._forget_claude_settings()
  claude_settings.stamp, claude_settings.env = nil, {}
end

---@type table<string, { available: fun(): boolean, word: fun(text: string, timeout: number, done: fun(result: table|nil, err: string|nil)): table|nil, sentence: fun(text: string, timeout: number, done: fun(result: table|nil, err: string|nil)): table|nil }>
local providers = {}

providers.ecdict = {
  available = function()
    return require("weread.ecdict").available()
  end,
  word = function(text, _, done)
    local ecdict = require("weread.ecdict")
    local forms = M.word_forms(text)
    local running = nil
    local function try(index)
      if index > #forms then
        done(nil, nil)
        return
      end
      running = ecdict.lookup(forms[index], function(result, err)
        if err then
          done(nil, err)
        elseif result then
          done({ word = result.word, phonetic = result.phonetic, lines = result.lines, lemma = result.lemma })
        else
          try(index + 1)
        end
      end)
    end
    try(1)
    return {
      kill = function()
        if running then
          running.kill()
        end
      end,
    }
  end,
}

providers.youdao = {
  available = function()
    return true
  end,
  word = function(text, timeout, done)
    local dicts = vim.uri_encode('{"count":99,"dicts":[["ec"]]}', "rfc3986")
    local url = M.YOUDAO_URL .. "?q=" .. vim.uri_encode(text, "rfc3986") .. "&dicts=" .. dicts
    return require("weread.http").request(third_party({ url = url, timeout = timeout }), function(res)
      local data, err = decode(res)
      if not data then
        done(nil, err)
        return
      end
      local words = ((data.ec or {}).word)
      local entry = type(words) == "table" and (words[1] or words) or nil
      if type(entry) ~= "table" or type(entry.trs) ~= "table" then
        done(nil, nil)
        return
      end
      local lines = {}
      for _, tr in ipairs(entry.trs) do
        for _, item in ipairs(tr.tr or {}) do
          for _, line in ipairs(((item.l or {}).i) or {}) do
            if type(line) == "string" and vim.trim(line) ~= "" then
              lines[#lines + 1] = vim.trim(line)
            end
          end
        end
      end
      if #lines == 0 then
        done(nil, nil)
        return
      end
      local phrase = (((entry["return-phrase"] or {}).l or {}).i)
      local phonetic = entry.usphone or entry.ukphone
      done({
        word = type(phrase) == "string" and phrase or text,
        phonetic = type(phonetic) == "string" and phonetic ~= "" and phonetic or nil,
        lines = lines,
        lemma = type(entry.prototype) == "string" and entry.prototype or nil,
      })
    end)
  end,
}

providers.transmart = {
  available = function()
    return true
  end,
  sentence = function(text, timeout, done)
    return require("weread.http").request(
      third_party({
        url = M.TRANSMART_URL,
        method = "POST",
        json = true,
        timeout = timeout,
        body = {
          header = { fn = "auto_translation", client_key = "browser-chrome-135.0.0-weread.nvim" },
          type = "plain",
          model_category = "normal",
          source = { lang = "en", text_list = { text } },
          target = { lang = "zh" },
        },
      }),
      function(res)
        local data, err = decode(res)
        if not data then
          done(nil, err)
          return
        end
        local out = data.auto_translation
        if type(out) ~= "table" or type(out[1]) ~= "string" or out[1] == "" then
          local code = ((data.header or {}).ret_code)
          done(nil, code and ("服务返回 " .. tostring(code)) or "没有译文")
          return
        end
        done({ text = table.concat(out, "\n") })
      end
    )
  end,
}

providers.llm = {
  available = function()
    local llm = settings().llm or {}
    local endpoint = M.llm_endpoint()
    return type(llm.model) == "string" and llm.model ~= "" and endpoint.url ~= nil and endpoint.key ~= nil
  end,
  sentence = function(text, timeout, done)
    return M.llm_chat({
      {
        role = "system",
        content = "You translate passages from books into fluent, natural Simplified Chinese. "
          .. "Reply with the translation only: no quotes, no notes, no romanization.",
      },
      { role = "user", content = text },
    }, { timeout = timeout, priority = "interactive" }, function(content, err)
      if not content then
        done(nil, err)
        return
      end
      done({ text = content, model = (settings().llm or {}).model })
    end)
  end,
}

---Is an LLM configured and reachable in principle (a model, an endpoint, a key)?
---(有没有配好的大模型：模型、地址、key 都在)
---@return boolean
function M.llm_available()
  return providers.llm.available()
end

-- ------------------------------------------------------------------ gate

---Requests to the LLM in flight and waiting. The gateway takes so many at once
---per user (`lookup.llm.max_concurrency`, four on the Claude Code gateway) and
---answers the rest "Concurrency limit exceeded"; every caller in the plugin —
---`K`, the 译文 key, a whole-book export, several of them at once — goes
---through here, so the limit holds for all of them together. A lookup the reader
---is waiting on (`priority = "interactive"`) goes ahead of every batch.
---(在途与排队的大模型请求。网关对每个用户同时只放行这么多个（lookup.llm.max_concurrency，Claude Code
--- 网关是 4 个），其余的回「Concurrency limit exceeded」；插件里所有调用方——K、译文键、整本导出，哪怕
--- 同时好几个——都经过这里，于是上限对它们合在一起成立。读者正在等的查询（priority = "interactive"）
--- 排在所有批量请求前面)
local gate = { active = 0, queue = {}, peak = 0, moved = 0 }

---@return integer
local function gate_limit()
  return math.max(1, math.floor(tonumber((settings().llm or {}).max_concurrency) or 4))
end

---Start what the gate lets through.
---(放行闸门允许的请求)
local function gate_pump()
  while gate.active < gate_limit() and #gate.queue > 0 do
    local ticket = table.remove(gate.queue, 1)
    gate.active = gate.active + 1
    gate.peak = math.max(gate.peak, gate.active)
    gate.moved = vim.uv.now()
    ticket.started = true
    ticket.start()
  end
end

---Run `start` when a slot is free. It is handed `release`, to be called once
---when the request is over; calling it again does nothing.
---(有空位时运行 start；它拿到 release，请求结束时调用一次，再调用无效)
---@param priority string|nil "interactive" goes first(“interactive” 优先)
---@param start fun(release: fun())
---@param cancelled fun() called instead of `start` when the ticket is cancelled while it waits(排队期间被取消时，代替 start 调用)
---@return table ticket with `cancel`(带 cancel 的票据)
local function gate_enter(priority, start, cancelled)
  local ticket = { started = false, done = false, priority = priority }
  local function release()
    if ticket.done then
      return
    end
    ticket.done = true
    if ticket.started then
      gate.active = math.max(0, gate.active - 1)
      gate.moved = vim.uv.now()
    end
    vim.schedule(gate_pump)
  end
  ticket.start = function()
    start(release)
  end
  function ticket.cancel()
    if ticket.started or ticket.done then
      return false
    end
    for index, waiting in ipairs(gate.queue) do
      if waiting == ticket then
        table.remove(gate.queue, index)
        break
      end
    end
    ticket.done = true
    cancelled()
    return true
  end
  if priority == "interactive" then
    -- behind the interactive ones already waiting, ahead of every batch
    -- (排在已在等的交互请求之后、所有批量请求之前)
    local at = #gate.queue + 1
    for index, waiting in ipairs(gate.queue) do
      if waiting.priority ~= "interactive" then
        at = index
        break
      end
    end
    table.insert(gate.queue, at, ticket)
  else
    gate.queue[#gate.queue + 1] = ticket
  end
  gate_pump()
  return ticket
end

---How busy the gate is: requests in flight, waiting, and the most ever in flight.
---(闸门的忙碌程度：在途数、排队数、历史最高在途数)
---`moved` is when a request last started or ended: a queue behind a gate that
---still moves is waiting its turn, not stuck.
---(moved 是最近一次有请求开始或结束的时刻：闸门还在动，排在后面的请求就是在等号，而不是卡住了)
---@return { active: integer, waiting: integer, peak: integer, limit: integer, moved: integer }
function M.llm_gate()
  return { active = gate.active, waiting = #gate.queue, peak = gate.peak, limit = gate_limit(), moved = gate.moved }
end

---For tests: an empty gate.(测试用：清空闸门)
function M._reset_gate()
  gate.active, gate.queue, gate.peak, gate.moved = 0, {}, 0, 0
end

---One chat completion from the LLM: the reply text, or why there is none.
---(向大模型要一次对话补全：回复文本，或者为什么没有)
---@param messages table[] { role, content }
---Waits for a slot of the gate first (see above); `kill` on the handle takes a
---waiting request out of the queue, and `done` hears "已取消" either way, so no
---caller is left waiting.
---(先在闸门排队等空位（见上）；句柄的 kill 会把排队中的请求移出队列。无论哪种情况 done 都会收到「已取消」，
--- 不会让任何调用方一直等下去)
---@param opts { timeout: number, json: boolean|nil, model: string|nil, priority: string|nil, on_start: fun()|nil }|nil json asks for a JSON object reply; model overrides `lookup.llm.model`; priority "interactive" for a lookup the reader waits on(json 要求以 JSON 对象回复；model 覆盖 lookup.llm.model；读者在等的查询用 priority = "interactive")
---@param done fun(content: string|nil, err: string|nil)
---@return table handle with `kill`(可 kill 的句柄)
function M.llm_chat(messages, opts, done)
  opts = opts or {}
  local llm = settings().llm or {}
  local endpoint = M.llm_endpoint()
  local model = opts.model or llm.model
  if not endpoint.url or not endpoint.key or type(model) ~= "string" then
    vim.schedule(function()
      done(nil, "没有可用的大模型（" .. endpoint.via .. "）")
    end)
    return { kill = function() end }
  end
  local body = { model = model, temperature = 0.2, messages = messages }
  if opts.json then
    body.response_format = { type = "json_object" }
  end
  local settled = false
  local function answer(content, err)
    if settled then
      return
    end
    settled = true
    done(content, err)
  end
  local request = nil
  local killed = false
  local handle = {}
  local free = nil
  local ticket
  ticket = gate_enter(opts.priority, function(release)
    free = release
    if killed then
      release()
      answer(nil, M.CANCELLED)
      return
    end
    if opts.on_start then
      pcall(opts.on_start)
    end
    request = M._send(endpoint, body, opts, llm, function(content, err)
      release()
      answer(content, err)
    end)
  end, function()
    vim.schedule(function()
      answer(nil, M.CANCELLED)
    end)
  end)
  function handle.kill()
    if killed then
      return
    end
    killed = true
    if ticket.cancel() then
      return
    end
    if request and request.kill then
      pcall(request.kill)
    end
    -- The slot is given back and the caller told now, not when curl gets round
    -- to exiting: a request whose answer never comes must not hold a slot.
    -- (现在就交还空位、告诉调用方，而不是等 curl 退出：一个永远等不到回复的请求不能一直占着空位)
    if free then
      free()
    end
    vim.schedule(function()
      answer(nil, M.CANCELLED)
    end)
  end
  return handle
end

---What a cancelled request answers with.(被取消的请求的回答)
M.CANCELLED = "已取消"

---Send one chat request, past the gate.
---(越过闸门之后，发出一次对话请求)
---@param endpoint table
---@param body table
---@param opts table
---@param llm table
---@param done fun(content: string|nil, err: string|nil)
---@return table handle
function M._send(endpoint, body, opts, llm, done)
  return require("weread.http").request(
    third_party({
      url = endpoint.url .. "/chat/completions",
      method = "POST",
      json = true,
      timeout = math.max(1, math.ceil(opts.timeout or tonumber(llm.timeout) or 8)),
      headers = { Authorization = "Bearer " .. endpoint.key },
      body = body,
    }),
    function(res)
      if res.cancelled then
        done(nil, M.CANCELLED)
        return
      end
      local data, err = decode(res)
      if not data then
        -- the service's own words are clearer than a bare status code
        -- (服务自己的说法比一个光秃秃的状态码清楚)
        local message = type(res.body) == "string" and res.body:match('"message"%s*:%s*"([^"]+)"')
        done(nil, message or err)
        return
      end
      local choice = (data.choices or {})[1]
      local content = choice and choice.message and choice.message.content
      if type(content) ~= "string" or vim.trim(content) == "" then
        done(nil, "没有译文")
        return
      end
      done(vim.trim(content), nil)
    end
  )
end

---Test hook: replace a provider.
---(测试钩子：替换某个服务)
---@param name string
---@param provider table|nil
function M._provider(name, provider)
  providers[name] = provider
end

---Call one provider with a deadline. `done` fires exactly once.
---(带时限地调用一个服务；done 恰好触发一次)
---@param name string
---@param kind "word"|"sentence"
---@param text string
---@param done fun(result: table|nil, err: string|nil)
local function call(name, kind, text, done)
  local provider = providers[name]
  if not provider or not provider[kind] then
    done(nil, "不支持")
    return
  end
  local timeout = tonumber(settings().timeout) or 3
  if name == "llm" then
    timeout = tonumber((settings().llm or {}).timeout) or 8
  end
  local settled = false
  local handle = nil
  local deadline = nil
  local function finish(result, err)
    if settled then
      return
    end
    settled = true
    require("weread.timer").stop(deadline)
    done(result, err)
  end
  -- curl's --max-time is whole seconds; the deadline is the real limit
  -- (curl 的 --max-time 只能是整秒；真正的时限是这个定时器)
  deadline = require("weread.timer").defer(function()
    if handle and handle.kill then
      pcall(handle.kill)
    end
    finish(nil, string.format("超时（%.1f 秒）", timeout))
  end, math.floor(timeout * 1000))
  local ok, returned = pcall(provider[kind], text, math.max(1, math.ceil(timeout)), finish)
  if not ok then
    finish(nil, tostring(returned))
    return
  end
  handle = returned
end

---Ask the providers of a list in turn until one answers.
---(按列表逐个问服务，直到有一个答出来)
---@param names string[]
---@param kind "word"|"sentence"
---@param text string
---@param done fun(result: table|nil, source: string|nil, errors: string[])
local function chain(names, kind, text, done)
  local errors = {}
  local function step(index)
    local name = names[index]
    if not name then
      done(nil, nil, errors)
      return
    end
    local provider = providers[name]
    if not provider or not provider[kind] or not provider.available() then
      step(index + 1)
      return
    end
    if name == "llm" and not M.llm_ready() then
      errors[#errors + 1] = string.format("%s：刚才失败过，%d 秒内先用快速翻译", PROVIDER_NAMES.llm, M.LLM_RETRY_SECONDS)
      step(index + 1)
      return
    end
    call(name, kind, text, function(result, err)
      if name == "llm" then
        llm_failed_at = not result and os.time() or nil
        if not result then
          require("weread.log").warn("lookup: LLM failed: %s", tostring(err))
        end
      end
      if result then
        done(result, name, errors)
        return
      end
      if err then
        errors[#errors + 1] = (PROVIDER_NAMES[name] or name) .. "：" .. err
      end
      step(index + 1)
    end)
  end
  step(1)
end

---Display name of a provider.
---(服务的显示名)
---@param name string|nil
---@return string
function M.provider_name(name)
  return PROVIDER_NAMES[name] or tostring(name or "")
end

---Is the LLM outside its back-off after a failure?
---(大模型是否已过了失败后的冷却期？)
---@return boolean
function M.llm_ready()
  return not (llm_failed_at and os.time() - llm_failed_at < M.LLM_RETRY_SECONDS)
end

---Will a sentence be asked of the LLM first? Then the popup waits for it.
---(句子会先问大模型吗？是的话弹窗就等它)
---@return boolean
function M.llm_first()
  local list = settings().sentence or {}
  return list[1] == "llm" and providers.llm ~= nil and providers.llm.available() and M.llm_ready()
end

---Callbacks waiting on a lookup in flight, by cache key.
---(按缓存键等待在途查询的回调)
local waiting = {}

---@param key string
---@param result table
local function remember(key, result)
  local entry = vim.deepcopy(result)
  entry.at = os.time()
  entry.ms, entry.cached = nil, nil
  cache()[key] = entry
  schedule_save()
end

---Translate a word or a passage. Exactly one of the handlers fires, once.
---(翻译一个词或一段文字。两个回调里恰好有一个触发，且只触发一次)
---
---A result answered by a service further down its list than the first one
---that could have answered carries `fallback = true` and the reasons
---(`fallback_reasons`): the popup labels it, and it is not cached, so the next
---`K` asks the better service again.
---(由列表中靠后的服务答出的结果（前面本可以答的服务失败了）带 fallback = true 与原因
--- fallback_reasons：弹窗会标明它，而且不缓存，下一次 K 会重新问更好的服务)
---@param raw string
---@param handlers { on_result: fun(result: table), on_error: fun(message: string) }
---@return boolean started false when there is nothing foreign to translate(没有外文可翻译时为 false)
function M.translate(raw, handlers)
  local text = M.normalize(raw)
  if not text then
    return false
  end
  local opts = settings()
  local kind = M.is_word(text) and "word" or "sentence"
  local key = key_of(kind, text)
  local sentence_list = opts.sentence or { "llm", "transmart" }
  local hit = cache()[key]
  -- a sentence cached from a fast translator (an older version, or a time the
  -- LLM was off) is asked again now that the LLM answers first
  -- (快速翻译缓存下来的句子（旧版本留下的，或当时没开大模型）在大模型优先时重新问一次)
  if hit and hit.kind == "sentence" and hit.source ~= "llm" and M.llm_first() then
    hit = nil
  end
  if hit then
    hit.at = os.time()
    local result = vim.deepcopy(hit)
    result.cached, result.ms = true, 0
    handlers.on_result(result)
    return true
  end
  if waiting[key] then
    table.insert(waiting[key], handlers)
    return true
  end
  waiting[key] = { handlers }
  local started = vim.uv.hrtime()
  local function deliver(result, source, errors)
    local listeners = waiting[key] or {}
    waiting[key] = nil
    if not result then
      local message = #errors > 0 and table.concat(errors, "；") or "没有找到释义"
      for _, listener in ipairs(listeners) do
        listener.on_error(message)
      end
      return
    end
    result.kind = result.kind or kind
    result.source = source
    result.original = text
    if #errors > 0 then
      result.fallback = true
      result.fallback_reasons = errors
    else
      remember(key, result)
    end
    result.ms = math.floor((vim.uv.hrtime() - started) / 1e6)
    for _, listener in ipairs(listeners) do
      listener.on_result(vim.deepcopy(result))
    end
  end
  local function none_left(errors)
    -- every service is switched off in the config: say so, not "not found"
    -- (配置里把服务全关了：要这么说，而不是「没找到」)
    if #errors == 0 and #sentence_list == 0 then
      errors[1] = "lookup.sentence 为空，没有可用的翻译服务"
    end
    return errors
  end
  if kind == "word" then
    chain(opts.word or { "ecdict", "youdao" }, "word", text, function(result, source, errors)
      if result then
        -- a dictionary that does not have the word is no failure: the next
        -- one answering is not a fallback unless one actually broke
        -- (词典里没有这个词不算失败：后面的词典答出来，除非前面真坏了，否则不算兜底)
        deliver(result, source, errors)
        return
      end
      -- no dictionary knows it: translate it like a phrase. The dictionaries
      -- missing it is not why the answer is what it is, so their errors are
      -- only reported if nothing answers at all.
      -- (没有词典认识它：当成短语来翻译。词典没收录不是答案如此的原因，所以它们的错误只在
      --  什么都没答出来时才报告)
      chain(sentence_list, "sentence", text, function(translated, sentence_source, more)
        if translated then
          translated.kind = "sentence"
          deliver(translated, sentence_source, more)
          return
        end
        vim.list_extend(errors, more)
        deliver(nil, nil, none_left(errors))
      end)
    end)
  else
    chain(sentence_list, "sentence", text, function(result, source, errors)
      deliver(result, source, result and errors or none_left(errors))
    end)
  end
  return true
end

return M
