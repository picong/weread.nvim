--[[
Full-text translation of a chapter by the LLM (the Claude Code gateway, see
`weread.lookup`), shown the way WeRead shows its own: a translated block under
every block of the original.
(由大模型（Claude Code 网关，见 weread.lookup）做的整章翻译，呈现方式与微信读书自己的一样：
 原文每个块下面一个译文块)

The service's bilingual chapters have a simple shape — after each block of the
original, on a new line, a block of the same tag with `class="wr-translation"`
— and the renderer already knows how to lay that out without moving a single
offset of the original. So the LLM's translations are spliced into the cached
original in exactly that shape, and everything downstream (layout, highlights,
progress) stays as it is.
(服务端的双语章节形状很简单——原文每个块之后另起一行，跟一个同标签、class="wr-translation"
 的块——渲染器早就会把它排出来，而且不挪动原文的任何偏移。所以把大模型的译文按同样的形状拼进
 缓存的原文里，下游的一切（排版、划线、进度）都不用改)

Translations are kept per block, keyed by the block's text, in
`chapters/NNNN.llm.json`: a chapter translated halfway goes on from where it
stopped, and a re-fetched chapter keeps every block whose text did not change.
(译文按块保存，以块的文字为键，存在 chapters/NNNN.llm.json：翻到一半的章节从停下的地方继续，
 重新抓取的章节保留文字没变的每一块)

A chapter is sent in batches of paragraphs, several at once, starting at the
reader's place: the screen being read is translated first, and the page is
laid out again as batches arrive.
(一章按段落分批发送、几批并行，从读者所在的位置开始：先翻正在读的那一屏，每到一批就重排一次页面)
]]

local cache = require("weread.cache")
local log = require("weread.log")

local M = {}

---Batches in flight at once, and how big a batch gets. Measured on the gateway:
---a 2 400-character batch takes 6-15 s, four at a time a 42 000-character
---chapter in about 48 s, a short chapter in 7 s.
---(同时在途的批数，以及一批多大。网关上实测：2400 字的一批要 6–15 秒，四批并行时 42000 字的章节
--- 约 48 秒，短章节 7 秒)
M.WORKERS = 4
M.BATCH_CHARS = 2400
M.BATCH_ITEMS = 14
M.BATCH_TIMEOUT = 90
---A chapter with no request started and no reply for this long is given up:
---something below lost it, and a translation nobody hears about again would
---hold up an export for good.
---(一章这么久既没有请求发出、也没有回复，就放弃：底下某处把它弄丢了，而一个再也没有下文的翻译会让导出永远
--- 卡住)
M.STALL_MS = M.BATCH_TIMEOUT * 3 * 1000
M.WATCH_MS = 15000
---The first batch is about one screen of text, from the top of the page, so
---the screen being read is translated first and as a whole.
---(第一批大约一屏的文字，从页顶开始：正在读的那一屏最先、而且整屏一起译出来)
M.FIRST_BATCH_CHARS = 1200
---A batch the gateway turned away for being over its limit per user waits
---this long times how often it was turned away, and gives up after so many.
---(因超出网关单用户并发上限而被拒的一批，等待「本值 × 被拒次数」后再发，被拒这么多次就放弃)
M.BUSY_DELAY_MS = 5000
M.BUSY_RETRIES = 12

---Is this the gateway saying it has too many requests from us right now?
---(这是不是网关在说我们此刻的请求太多了)
---@param err string|nil
---@return boolean
function M.is_busy(err)
  local text = tostring(err or ""):lower()
  return text:find("concurrency", 1, true) ~= nil
    or text:find("rate limit", 1, true) ~= nil
    or text:find("too many requests", 1, true) ~= nil
    or text:find("http 429", 1, true) ~= nil
end

local SYSTEM_PROMPT = table.concat({
  "You translate paragraphs of a book into fluent, natural Simplified Chinese.",
  "The user sends a JSON object mapping ids to paragraphs, in reading order.",
  "Reply with one JSON object mapping the same ids to their translations, and nothing else.",
  "Keep code, identifiers, API names, URLs and numbers as they are.",
}, " ")

---Elements whose text is a block a reader reads as one piece. Table cells and
---code listings are left alone, as the service leaves them.
---(读者当作一整块来读的元素。表格单元格与代码清单不动，服务端也不动它们)
local BLOCKS = {
  p = true,
  h1 = true,
  h2 = true,
  h3 = true,
  h4 = true,
  h5 = true,
  h6 = true,
  li = true,
  dt = true,
  dd = true,
  figcaption = true,
  blockquote = true,
}

---Containers whose blocks are not translated.
---(其中的块不翻译的容器)
local SKIPPED = { table = true, pre = true, head = true, style = true, script = true, svg = true, math = true }

---Running translations by chapter: { cancelled, handles, done }
---(按章节记录的进行中的翻译)
local running = {}

---@param book_id string|number
---@param chapter table
---@return string
local function key_of(book_id, chapter)
  return tostring(book_id) .. ":" .. cache.chapter_key(chapter)
end

---@param text string
---@return string
local function escape(text)
  return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

---Text of a block as a reader sees it: tags gone, entities decoded, whitespace
---collapsed.
---(读者看到的块文字：去掉标签、解码实体、折叠空白)
---@param inner string
---@return string
local function plain(inner)
  local text = require("weread.xhtml").decode_entities((inner:gsub("<[^>]*>", "")))
  return vim.trim((text:gsub("%s+", " ")))
end

---The innermost blocks of a chapter that hold foreign text, in order.
---(章节里含外文的最内层块，按顺序)
---@param source string
---@return { tag: string, from: integer, open_end: integer, to: integer, text: string }[] from/to: bytes of the whole element, open_end: of its opening tag(from/to：整个元素的字节区间；open_end：开始标签的结尾)
function M.blocks(source)
  local found = {}
  local stack = {}
  local skipped = 0
  local pos = 1
  while true do
    local lt = source:find("<", pos, true)
    if not lt then
      break
    end
    if source:sub(lt, lt + 3) == "<!--" then
      local close = source:find("-->", lt + 4, true)
      pos = close and close + 3 or #source + 1
    else
      local finish = source:find(">", lt, true)
      if not finish then
        break
      end
      local slash, name = source:sub(lt, finish):match("^<(/?)([%a][%w]*)")
      name = name and name:lower()
      local self_closing = source:sub(finish - 1, finish) == "/>"
      if name and SKIPPED[name] and not self_closing then
        skipped = skipped + (slash == "/" and -1 or 1)
        skipped = math.max(0, skipped)
      elseif name and BLOCKS[name] and not self_closing then
        if slash == "" then
          stack[#stack + 1] = { tag = name, from = lt, open_end = finish, has_child = false, skipped = skipped > 0 }
          if #stack > 1 then
            stack[#stack - 1].has_child = true
          end
        else
          -- close the innermost open block of that name, and what is left open inside it
          -- (关闭最内层的同名块，以及它里面还开着的东西)
          for depth = #stack, 1, -1 do
            if stack[depth].tag == name then
              local open = stack[depth]
              for _ = depth, #stack do
                table.remove(stack)
              end
              if not open.has_child and not open.skipped then
                local text = plain(source:sub(open.open_end + 1, lt - 1))
                local _, letters = text:gsub("%a", "")
                if letters >= 2 then
                  found[#found + 1] = { tag = name, from = open.from, open_end = open.open_end, to = finish, text = text }
                end
              end
              break
            end
          end
        end
      end
      pos = finish + 1
    end
  end
  table.sort(found, function(a, b)
    return a.from < b.from
  end)
  return found
end

---@param book_id string|number
---@param chapter table
---@return string
local function store_path(book_id, chapter)
  return cache.chapter_file(book_id, chapter, "llm.json")
end

---The translations stored for a chapter.
---(某章已存的译文)
---@param book_id string|number
---@param chapter table
---@return { model: string|nil, items: table<string, string>, complete: boolean }
function M.load(book_id, chapter)
  local data = cache.read_json(store_path(book_id, chapter))
  if type(data) ~= "table" or type(data.items) ~= "table" then
    return { items = {}, complete = false }
  end
  data.complete = data.complete == true
  return data
end

---@param book_id string|number
---@param chapter table
---@param data table
local function save(book_id, chapter, data)
  local ok, err = cache.write_json(store_path(book_id, chapter), data)
  if not ok then
    log.warn("llm_translate: could not save %s: %s", store_path(book_id, chapter), tostring(err))
  end
end

---The original with the stored translations spliced in, WeRead-style.
---(把已存的译文按微信读书的形状拼进原文)
---@param source string the chapter without translations(不含译文的章节)
---@param items table<string, string> block text -> translation(块文字 → 译文)
---@return string bilingual
---@return integer count blocks translated(译出的块数)
---@return integer total blocks that can be(可翻译的块数)
function M.bilingual(source, items)
  local blocks = M.blocks(source)
  local parts, pos, count = {}, 1, 0
  for _, block in ipairs(blocks) do
    local translation = items[block.text]
    if type(translation) == "string" and translation ~= "" then
      local attrs = ' class="wr-translation"'
      if block.tag == "li" then
        attrs = attrs .. ' style="list-style-type:none;"'
      end
      parts[#parts + 1] = source:sub(pos, block.to)
      parts[#parts + 1] = "\n<" .. block.tag .. attrs .. ">" .. escape(translation) .. "</" .. block.tag .. ">"
      pos = block.to + 1
      count = count + 1
    end
  end
  parts[#parts + 1] = source:sub(pos)
  return table.concat(parts), count, #blocks
end

---The original with every translated block's text replaced by its translation:
---the chapter as a Chinese book. The block keeps its own tag and attributes, so
---the book's stylesheet still applies.
---(把原文里每个译过的块的文字换成译文：整章就是一本中文书。块保留自己的标签和属性，书的样式表照样生效)
---@param source string the chapter without translations(不含译文的章节)
---@param items table<string, string> block text -> translation(块文字 → 译文)
---@return string translated
---@return integer count blocks replaced(替换的块数)
function M.translated_only(source, items)
  local parts, pos, count = {}, 1, 0
  for _, block in ipairs(M.blocks(source)) do
    local translation = items[block.text]
    if type(translation) == "string" and translation ~= "" then
      parts[#parts + 1] = source:sub(pos, block.open_end)
      parts[#parts + 1] = escape(translation) .. "</" .. block.tag .. ">"
      pos = block.to + 1
      count = count + 1
    end
  end
  parts[#parts + 1] = source:sub(pos)
  return table.concat(parts), count
end

---Is the LLM translating this chapter right now?
---(大模型此刻是否正在翻译这一章)
---@param book_id string|number
---@param chapter table
---@return boolean
function M.running(book_id, chapter)
  local job = running[key_of(book_id, chapter)]
  return job ~= nil and not job.cancelled
end

---Stop a job: its requests killed, its watchdog stopped, every caller still
---waiting on it told why.
---(停掉一个任务：杀掉它的请求、停掉看门狗，并告诉每个还在等它的调用方原因)
---@param key string
---@param job table
---@param reason string
local function stop_job(key, job, reason)
  job.cancelled = true
  require("weread.timer").stop(job.watchdog)
  job.watchdog = nil
  for _, handle in pairs(job.handles) do
    pcall(handle.kill)
  end
  if running[key] == job then
    running[key] = nil
  end
  if job.save then
    job.save()
  end
  local waiters = job.waiters
  job.waiters = {}
  local stats = job.stats and job.stats() or {}
  for _, waiter in ipairs(waiters) do
    vim.schedule(function()
      pcall(waiter.on_done, false, reason, stats)
    end)
  end
end

---What a cancelled translation reports.(被取消的翻译报告的原因)
M.CANCELLED = "已取消"

---Stop translations, but only for the callers that asked: `owner` names who
---("reader" for the page, "epub" for an export), `book_id` narrows it to one
---book. A job other callers still wait on goes on for them; the ones taken
---off hear `M.CANCELLED`.
---(停掉翻译，但只针对提出要求的调用方：owner 指明是谁（"reader" 是页面，"epub" 是导出），book_id
--- 把范围收窄到一本书。还有别的调用方在等的任务继续为它们跑；被摘下的调用方收到 M.CANCELLED)
---@param filter { owner: string|nil, book_id: string|nil }|nil nil stops everything(nil 表示全部停掉)
---@return integer cancelled callers told(被告知取消的调用方数)
function M.cancel(filter)
  filter = filter or {}
  local told = 0
  for key, job in pairs(running) do
    if filter.book_id == nil or job.book_id == tostring(filter.book_id) then
      local keep, drop = {}, {}
      for _, waiter in ipairs(job.waiters) do
        if filter.owner == nil or waiter.owner == filter.owner then
          drop[#drop + 1] = waiter
        else
          keep[#keep + 1] = waiter
        end
      end
      if #drop > 0 then
        told = told + #drop
        log.info("llm_translate: cancelling %s for %d caller(s) (%s)", key, #drop, tostring(filter.owner or "all"))
        if #keep == 0 then
          stop_job(key, job, M.CANCELLED)
        else
          job.waiters = keep
          local stats = job.stats and job.stats() or {}
          for _, waiter in ipairs(drop) do
            vim.schedule(function()
              pcall(waiter.on_done, false, M.CANCELLED, stats)
            end)
          end
        end
      end
    end
  end
  return told
end

---Stop every translation in flight.(停掉所有在途的翻译)
function M.cancel_all()
  return M.cancel(nil)
end

---Parse a model reply: a JSON object, possibly inside a code fence.
---(解析模型的回复：一个 JSON 对象，可能包在代码围栏里)
---@param content string
---@return table|nil
local function parse_reply(content)
  local body = vim.trim(content):gsub("^```%w*%s*", ""):gsub("%s*```$", "")
  local ok, data = pcall(vim.json.decode, body)
  if ok and type(data) == "table" then
    return data
  end
  local object = body:match("%b{}")
  ok, data = pcall(vim.json.decode, object or "")
  return ok and type(data) == "table" and data or nil
end

---Batches of blocks in the order a reader needs them: the screen first (from
---the top of the page), then outward — two blocks ahead for every block behind,
---since a reader mostly reads on but does glance back.
---(按读者需要的顺序分批：先是这一屏（从页顶开始），然后向两边扩展——往后两块配往前一块，
--- 因为读者大多往下读，但也会回头看)
---@param blocks table[]
---@param from_byte integer|nil byte the page starts at(页面起始的字节)
---@return table[][]
local function batches_of(blocks, from_byte)
  local start = 1
  if from_byte then
    start = #blocks + 1
    for index, block in ipairs(blocks) do
      if block.to >= from_byte then
        start = index
        break
      end
    end
  end
  local order = {}
  local ahead, behind = start, start - 1
  local first_size = 0
  -- the page itself, forward from its top (这一页本身，从页顶往下)
  while ahead <= #blocks and first_size < M.FIRST_BATCH_CHARS do
    order[#order + 1] = blocks[ahead]
    first_size = first_size + #blocks[ahead].text
    ahead = ahead + 1
  end
  local first_count = #order
  while ahead <= #blocks or behind >= 1 do
    for _ = 1, 2 do
      if ahead <= #blocks then
        order[#order + 1] = blocks[ahead]
        ahead = ahead + 1
      end
    end
    if behind >= 1 then
      order[#order + 1] = blocks[behind]
      behind = behind - 1
    end
  end
  local out = { {} }
  for index = 1, first_count do
    table.insert(out[1], order[index])
  end
  if #out[1] == 0 then
    out = {}
  end
  local current, size = {}, 0
  for index = first_count + 1, #order do
    local block = order[index]
    if #current > 0 and (size + #block.text > M.BATCH_CHARS or #current >= M.BATCH_ITEMS) then
      out[#out + 1] = current
      current, size = {}, 0
    end
    current[#current + 1] = block
    size = size + #block.text
  end
  if #current > 0 then
    out[#out + 1] = current
  end
  return out
end

---Translate a chapter with the LLM. The chapter's original must be cached.
---(用大模型翻译一章；章节原文必须已经缓存)
---
---`on_progress` fires after each batch that added translations; `on_done`
---fires once: ok when every block is translated, otherwise with the reason.
---(每一批带来新译文后触发 on_progress；on_done 只触发一次：全部译完为 ok，否则带上原因)
---@param book_id string|number
---@param chapter table
---@param opts { from_rune: integer|nil, model: string|nil, workers: integer|nil, on_progress: fun(count: integer, total: integer)|nil, on_done: fun(ok: boolean, err: string|nil, stats: table) } model: instead of the book's(代替这本书所用的模型)
function M.run(book_id, chapter, opts)
  local lookup = require("weread.lookup")
  local key = key_of(book_id, chapter)
  local model = opts.model or M.model(book_id)
  local source = cache.read(cache.chapter_file(book_id, chapter, "xhtml"))
  local function finish_now(ok, err, stats)
    vim.schedule(function()
      opts.on_done(ok, err, stats or {})
    end)
  end
  if not model then
    finish_now(false, "这本书没有选大模型翻译")
    return
  end
  if not source or source == "" then
    finish_now(false, "本章原文还没缓存")
    return
  end
  if running[key] then
    -- already under way: this caller hears about the same end
    -- (已经在翻了：这个调用方等同一个结果)
    table.insert(running[key].waiters, opts)
    return
  end
  local data = M.load(book_id, chapter)
  if data.model ~= model then
    -- another model's translations are not this one's: start over
    -- (别的模型的译文不算这个模型的：重新开始)
    data = { model = model, items = {}, complete = false }
  end
  -- a new try: the page shows this run's translations, not the fallback
  -- (重新试一次：页面显示这一次的译文，而不是兜底)
  data.failed = nil
  save(book_id, chapter, data)
  local blocks = M.blocks(source)
  if #blocks == 0 then
    finish_now(false, "本章没有可翻译的外文")
    return
  end
  local todo = {}
  for _, block in ipairs(blocks) do
    if not data.items[block.text] then
      todo[#todo + 1] = block
    end
  end
  local total = #blocks
  local started = vim.uv.hrtime()
  if #todo == 0 then
    data.complete = true
    save(book_id, chapter, data)
    finish_now(true, nil, { count = total, total = total, ms = 0 })
    return
  end
  local from_byte = nil
  if opts.from_rune then
    local ok, byte = pcall(vim.fn.byteidx, source, opts.from_rune)
    from_byte = ok and byte >= 0 and byte + 1 or nil
  end
  local job = {
    cancelled = false,
    handles = {},
    waiters = { opts },
    failures = {},
    workers = opts.workers,
    book_id = tostring(book_id),
    last_activity = vim.uv.now(),
  }
  running[key] = job
  local queue = batches_of(todo, from_byte)
  for _, batch in ipairs(queue) do
    batch.attempt = 1
  end
  local in_flight = 0
  local next_id = 0

  local function count_done()
    local count = 0
    for _, block in ipairs(blocks) do
      if data.items[block.text] then
        count = count + 1
      end
    end
    return count
  end

  job.save = function()
    data.complete = count_done() == total
    save(book_id, chapter, data)
  end
  job.stats = function()
    return { count = count_done(), total = total, ms = math.floor((vim.uv.hrtime() - started) / 1e6) }
  end

  local function finish()
    if job.cancelled then
      return
    end
    job.cancelled = true
    require("weread.timer").stop(job.watchdog)
    job.watchdog = nil
    if running[key] == job then
      running[key] = nil
    end
    local count = count_done()
    data.complete = count == total
    save(book_id, chapter, data)
    local stats = { count = count, total = total, ms = math.floor((vim.uv.hrtime() - started) / 1e6) }
    local err = nil
    if not data.complete then
      err = job.failures[1] or string.format("只译出 %d / %d 段", count, total)
    end
    local waiters = job.waiters
    job.waiters = {}
    for _, waiter in ipairs(waiters) do
      pcall(waiter.on_done, data.complete, err, stats)
    end
  end

  local pump

  ---@param batch table[]
  local function send(batch)
    in_flight = in_flight + 1
    next_id = next_id + 1
    local id = next_id
    local request = {}
    for index, block in ipairs(batch) do
      request[tostring(index)] = block.text
    end
    job.handles[id] = lookup.llm_chat({
      { role = "system", content = SYSTEM_PROMPT },
      { role = "user", content = vim.json.encode(request) },
    }, {
      timeout = M.BATCH_TIMEOUT,
      json = true,
      model = model,
      on_start = function()
        job.last_activity = vim.uv.now()
      end,
    }, function(content, err)
      job.handles[id] = nil
      in_flight = in_flight - 1
      if job.cancelled then
        return
      end
      job.last_activity = vim.uv.now()
      -- The gateway turns away requests past its limit per user: not a failure
      -- of the batch, so it goes back in the queue after a pause, without using
      -- up its tries. Only so many times, or a gateway that always says so would
      -- be asked forever.
      -- (网关对每个用户有并发上限，超出的请求会被拒绝：这不是这一批失败了，所以停一会儿再放回队列，
      --  不占重试次数。但次数有限，否则一个总是这么回答的网关会被无限地问下去)
      if not content and M.is_busy(err) and (batch.busy or 0) < M.BUSY_RETRIES then
        batch.busy = (batch.busy or 0) + 1
        job.busy_until = vim.uv.now() + M.BUSY_DELAY_MS * batch.busy
        table.insert(queue, 1, batch)
        require("weread.timer").defer(pump, M.BUSY_DELAY_MS * batch.busy)
        return
      end
      local reply = content and parse_reply(content)
      local missing = {}
      local added = 0
      for index, block in ipairs(batch) do
        local translation = reply and reply[tostring(index)]
        if type(translation) == "string" and vim.trim(translation) ~= "" then
          data.items[block.text] = vim.trim(translation)
          added = added + 1
        else
          missing[#missing + 1] = block
        end
      end
      if #missing > 0 then
        if batch.attempt < 2 then
          -- once more, on their own: a long batch is the usual reason a reply comes back short
          -- (单独再试一次：回复缺段，通常是因为这批太长)
          missing.attempt = batch.attempt + 1
          table.insert(queue, 1, missing)
        else
          job.failures[#job.failures + 1] = err or "回复里缺少部分段落"
          log.warn("llm_translate: %d blocks of %s failed: %s", #missing, key, tostring(err or "missing ids"))
        end
      end
      if added > 0 then
        save(book_id, chapter, data)
        local count = count_done()
        for _, waiter in ipairs(job.waiters) do
          if waiter.on_progress then
            pcall(waiter.on_progress, count, total)
          end
        end
      end
      pump()
    end)
  end

  -- the watchdog: a chapter that goes quiet for too long is given up
  -- (看门狗：沉寂太久的章节就放弃)
  job.watchdog = require("weread.timer").every(function()
    if job.cancelled then
      require("weread.timer").stop(job.watchdog)
      return
    end
    -- requests waiting behind a gate that still moves are only waiting their turn
    -- (排在仍在流动的闸门后面的请求只是在等号)
    local last = job.last_activity
    if next(job.handles) ~= nil then
      last = math.max(last, lookup.llm_gate().moved or 0)
    end
    local quiet = vim.uv.now() - last
    if quiet > M.STALL_MS then
      local reason = string.format("超过 %d 秒没有进展，放弃这一章", math.floor(quiet / 1000))
      log.warn("llm_translate: %s stalled (%d ms quiet, %d in flight, %d queued)", key, quiet, in_flight, #queue)
      job.failures[#job.failures + 1] = reason
      job.save()
      stop_job(key, job, reason)
    end
  end, M.WATCH_MS)

  pump = function()
    if job.cancelled then
      return
    end
    -- a broken gateway fails every batch: stop at the first batch that failed twice
    -- (网关坏了每一批都会失败：有一批失败两次就停)
    if #job.failures > 0 then
      queue = {}
    end
    if job.busy_until and vim.uv.now() < job.busy_until then
      -- the gateway asked to wait: the timer set when it said so comes back here
      -- (网关让等一下：它这么说的时候设下的定时器会回到这里)
      if in_flight == 0 and #queue == 0 then
        finish()
      end
      return
    end
    while in_flight < (job.workers or M.WORKERS) and #queue > 0 do
      send(table.remove(queue, 1))
    end
    if in_flight == 0 and #queue == 0 then
      finish()
    end
  end

  pump()
end

---The model that translates a book's chapters, nil when WeRead's own
---translation does. The reader's pick for the book comes first (see
---`translate.engine`); a book never picked for follows `lookup.chapter` and
---`lookup.llm.model`. A model counts only when the LLM is set up at all (an
---endpoint and a key).
---(翻译这本书章节的模型；用微信读书自己的译文时为 nil。读者给这本书选的优先（见
--- translate.engine）；没选过的书按 lookup.chapter 与 lookup.llm.model。大模型配好了（有地址和 key）
--- 模型才算数)
---@param book_id string|number
---@return string|nil
function M.model(book_id)
  local lookup = require("weread.lookup")
  local engine = require("weread.translate").engine(book_id)
  if engine == "weread" then
    return nil
  end
  if engine then
    return lookup.llm_available() and engine or nil
  end
  local opts = require("weread.config").get().lookup or {}
  if opts.chapter == "llm" and lookup.llm_available() then
    return (opts.llm or {}).model
  end
  return nil
end

---Is a model the one that translates this book's chapters?
---(这本书的章节由大模型来译吗)
---@param book_id string|number
---@return boolean
function M.enabled(book_id)
  return M.model(book_id) ~= nil
end

---Are a chapter's stored translations by the model in use for its book?
---(某章存下的译文是不是这本书当前所用的模型译的)
---@param book_id string|number
---@param chapter table
---@return boolean
function M.usable(book_id, chapter)
  local model = M.model(book_id)
  return model ~= nil and M.load(book_id, chapter).model == model
end

---Is a chapter's LLM translation complete, by the model in use, and not given up on?
---(某章的大模型译文是否完整、是当前模型译的、且没有被放弃)
---@param book_id string|number
---@param chapter table
---@return boolean
function M.preferred(book_id, chapter)
  local data = M.load(book_id, chapter)
  return data.complete and not data.failed and M.usable(book_id, chapter)
end

---Drop a chapter's LLM translations (it failed and the fallback takes over).
---What was translated is kept for a later try; only the page stops preferring it.
---(放弃某章的大模型译文（失败了，由兜底接手）。已译出的部分留着下次再试，只是页面不再优先用它)
---@param book_id string|number
---@param chapter table
function M.discard(book_id, chapter)
  local data = M.load(book_id, chapter)
  data.complete = false
  data.failed = true
  save(book_id, chapter, data)
end

---For tests: forget running jobs without killing anything.
---(供测试：忘掉进行中的任务，不终止任何东西)
function M._reset()
  running = {}
end

return M
