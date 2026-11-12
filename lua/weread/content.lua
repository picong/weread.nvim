--[[
Copyright (C) 2026 finlater and contributors (weread.koplugin, AGPL-3.0)
Copyright (C) 2026 weread.nvim contributors

The decode chain (checked_body / base64_decode / swap_positions / reverse_swaps
/ decode_encoded_body) is ported from
https://github.com/QiuYukang/weread.koplugin (weread/lib/content.lua).
The request pipeline around it is weread.nvim specific.

weread.nvim is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.
]]

--[[
Chapter content: the only way to get readable text out of WeRead.
(章节正文：从微信读书拿到可读文本的唯一途径)

Pipeline per chapter:
(单章流程)

1. GET  /web/reader/<_e(bookId)>      -> reader HTML, carrying `psvts`
2. POST /web/book/chapterInfos        -> catalog + the resource `tar` url
3. POST /web/book/chapter/e_0|e_1|e_3 -> encoded XHTML shards (EPUB books)
   POST /web/book/chapter/t_0|t_1     -> encoded plain text  (TXT books)
   POST /web/book/chapter/e_2         -> encoded CSS, `st=1`
4. GET  <tar url>                     -> images, sniffed by magic bytes
5. decode, rewrite image urls, cache
]]

local P = require("weread.protocol")
local config = require("weread.config")
local http = require("weread.http")
local log = require("weread.log")
local reader_state = require("weread.reader_state")
local tar = require("weread.tar")

local M = {}

-- =========================================================================
-- Decoding
-- =========================================================================

---Verify the leading MD5 and return the payload.
---(校验前置 MD5 并返回载荷)
---@param response_text string
---@return string
local function checked_body(response_text)
  if not response_text or #response_text <= 32 then
    return ""
  end
  local expected = response_text:sub(1, 32)
  local body = response_text:sub(33)
  local actual = require("weread.crypto").md5_hex(body):upper()
  if actual ~= expected then
    error("Shard MD5 mismatch")
  end
  return body
end

---Decode a (possibly URL-safe, possibly unpadded) base64 string.
---(解码 base64，允许 URL-safe 字符集与缺失的 padding)
---
---Raises on input that is not base64. That is deliberate: callers wrap the
---decode chain in `pcall`, and an empty string would sail through the later
---UTF-8 check and get cached as a blank chapter.
---(遇到非 base64 输入会抛错：调用方都用 pcall 包着解码链，而返回空串会骗过后面的
--- UTF-8 检查，让一个空白章节被缓存下来)
---@param data string
---@return string
local function base64_decode(data)
  -- The old decoder dropped every byte outside the alphabet, whitespace included;
  -- keep that tolerance for line breaks (the shard MD5 already vouches for the
  -- payload, so this cannot hide corruption).
  -- (旧解码器会丢弃字母表外的所有字节，包括空白；换行这一类继续容忍：分片的 MD5 已经
  --  担保过内容完整，所以这里不会掩盖损坏)
  data = (data:gsub("%s+", ""):gsub("%-", "+"):gsub("_", "/"))
  local pad = #data % 4
  if pad > 0 then
    data = data .. string.rep("=", 4 - pad)
  end
  local ok, decoded = pcall(vim.base64.decode, data)
  if not ok then
    error("Shard is not valid base64: " .. tostring(decoded), 0)
  end
  return decoded
end

local function swap_positions(encoded)
  local length = #encoded
  if length < 4 then
    return {}
  end
  if length < 11 then
    return { 0, 2 }
  end

  local n = math.min(4, math.floor((length + 9) / 10))
  local tmp = {}
  for i = length, length - n + 1, -1 do
    local byte = encoded:byte(i)
    local bin = {}
    repeat
      table.insert(bin, 1, tostring(byte % 2))
      byte = math.floor(byte / 2)
    until byte == 0
    local value = tonumber(table.concat(bin), 4) or 0
    table.insert(tmp, tostring(value))
  end
  tmp = table.concat(tmp)

  local result = {}
  local m = length - n - 2
  local step = #tostring(m)
  local i = 1
  while #result < 10 and i + step - 1 < #tmp do
    table.insert(result, (tonumber(tmp:sub(i, i + step - 1)) or 0) % m)
    local end2 = math.min(i + step, #tmp)
    if i + 1 <= #tmp then
      table.insert(result, (tonumber(tmp:sub(i + 1, end2)) or 0) % m)
    end
    i = i + step
  end
  return result
end

local function reverse_swaps(encoded, positions)
  local chars = {}
  for i = 1, #encoded do
    chars[i] = encoded:sub(i, i)
  end
  for i = #positions, 1, -2 do
    for k = 1, 0, -1 do
      local left = positions[i] + k + 1
      local right = positions[i - 1] + k + 1
      chars[left], chars[right] = chars[right], chars[left]
    end
  end
  return table.concat(chars)
end

local function decode_encoded_body(body)
  if #body == 0 then
    return ""
  end
  local encoded = body:sub(2)
  local restored = reverse_swaps(encoded, swap_positions(encoded))
  return base64_decode(restored)
end

---Decode one shard response.
---(解码单个分片)
---@param shard string
---@return string
function M.decode_shard(shard)
  return decode_encoded_body(checked_body(shard))
end

---Decode the EPUB content shards, which are concatenated before decoding.
---(解码 EPUB 正文分片：先拼接再解码)
---@param shards string[]
---@return string
function M.decode_shards(shards)
  local body = ""
  for _, shard in ipairs(shards or {}) do
    body = body .. checked_body(shard)
  end
  return decode_encoded_body(body)
end

---Find the first byte that keeps `text` from being well-formed UTF-8, or, with
---`opts.xml`, a C0 control character XML forbids (everything below 0x20 except
---tab, newline and carriage return).
---(找出让 text 不是合法 UTF-8 的第一个字节；带 opts.xml 时也找 XML 不允许的 C0
--- 控制字符，即 0x20 以下除制表、换行、回车之外的字符)
---
---A shard spliced from two versions of a chapter, or decoded with one shard
---missing, still passes every per-shard MD5, but the swap positions are taken
---from the wrong total length: each swap leaves two garbage bytes behind. This
---check is what catches that before anything is cached or shown.
---(由两个版本拼成、或缺了一片的分片组合，每片 MD5 都校验通过，但 swap 位置是按错误的
--- 总长度算的：每处 swap 都留下两个垃圾字节。这个检查负责在缓存或显示前把它拦下)
---@param text string
---@param opts table|nil { xml = boolean }
---@return integer|nil position 1-based byte position of the first bad byte, nil when clean(首个坏字节的位置，干净时为 nil)
function M.find_invalid_text(text, opts)
  if type(text) ~= "string" then
    return 1
  end
  local xml = opts and opts.xml
  if xml then
    local control = text:find("[%z\1-\8\11\12\14-\31]")
    if control then
      -- still report an earlier invalid byte, if there is one
      -- (若前面还有非法字节，仍报更靠前的那个)
      local before = M.find_invalid_text(text:sub(1, control - 1))
      return before or control
    end
  end
  -- fast path: pure ASCII (快速路径：纯 ASCII)
  local i = text:find("[\128-\255]")
  if not i then
    return nil
  end
  local byte = string.byte
  local length = #text
  while i <= length do
    local first = byte(text, i)
    if first < 0x80 then
      -- skip the ASCII run in one step (一次跳过整段 ASCII)
      local next_high = text:find("[\128-\255]", i)
      if not next_high then
        return nil
      end
      i = next_high
    else
      local second = byte(text, i + 1)
      local width
      if first >= 0xc2 and first <= 0xdf then
        width = 2
      elseif first == 0xe0 then
        width = (second and second >= 0xa0 and second <= 0xbf) and 3 or nil
      elseif (first >= 0xe1 and first <= 0xec) or first == 0xee or first == 0xef then
        width = 3
      elseif first == 0xed then
        -- no UTF-16 surrogates (不允许 UTF-16 代理项)
        width = (second and second >= 0x80 and second <= 0x9f) and 3 or nil
      elseif first == 0xf0 then
        width = (second and second >= 0x90 and second <= 0xbf) and 4 or nil
      elseif first >= 0xf1 and first <= 0xf3 then
        width = 4
      elseif first == 0xf4 then
        width = (second and second >= 0x80 and second <= 0x8f) and 4 or nil
      end
      if not width then
        return i
      end
      for offset = 1, width - 1 do
        local continuation = byte(text, i + offset)
        if not continuation or continuation < 0x80 or continuation > 0xbf then
          return i
        end
      end
      i = i + width
    end
  end
  return nil
end

---Are the EPUB content shards three slices of one and the same payload? The
---service cuts a chapter into near-equal thirds, so their lengths differ by the
---remainder at most; a slice taken from another version of the chapter (one
---the service was translating at that moment) has a clearly different length.
---(EPUB 正文三片是否是同一份载荷切出来的？服务端把一章切成近似等长的三份，长度最多
--- 差一个余数；若某片取自这一章的另一个版本（服务端那一刻正在翻译它），长度会明显不同)
---@param shards string[]
---@return boolean
function M.shards_consistent(shards)
  local shortest, longest = math.huge, 0
  for _, shard in ipairs(shards) do
    local length = #shard - 32
    shortest = math.min(shortest, length)
    longest = math.max(longest, length)
  end
  return longest - shortest <= 2
end

---Wrap decoded TXT content into paragraph XHTML.
---(把解码后的 TXT 正文包成段落 XHTML)
---@param text string
---@return string
function M.txt_to_xhtml(text)
  local parts = { '<div class="readerChapterContent">' }
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = line:gsub("\r$", "")
    if vim.trim(trimmed) ~= "" then
      parts[#parts + 1] = "<p>" .. vim.trim(trimmed) .. "</p>"
    end
  end
  parts[#parts + 1] = "</div>"
  return table.concat(parts, "\n")
end

-- =========================================================================
-- URLs and request shapes
-- =========================================================================

---Kept as a thin wrapper: progress.lua calls it, and config owns the origin.
---(保留为薄封装：progress.lua 在调用它，origin 由 config 统一提供)
---@return string
function M.base_url()
  return config.web_origin()
end

---@param book_id string|number
---@param chapter_uid string|number|nil
---@return string
function M.reader_url(book_id, chapter_uid)
  -- Kept in lockstep with protocol.reader_url; a test asserts they agree so
  -- the ported function stays the reference implementation.
  -- (与 protocol.reader_url 保持一致，并有测试断言两者相同，从而让移植来的函数
  --  继续充当参考实现)
  local url = M.base_url() .. "/web/reader/" .. P.e(book_id)
  if chapter_uid then
    url = url .. "k" .. P.e(chapter_uid)
  end
  return url
end

---@return string
function M.chapter_infos_url()
  return M.base_url() .. "/web/book/chapterInfos"
end

---@param endpoint string e.g. "/web/book/chapter/e_0"
---@return string
function M.shard_url(endpoint)
  return M.base_url() .. endpoint
end

---Fetch the reader HTML and extract psvts/pclts/token/bookInfo.
---(抓阅读器 HTML 并提取 psvts/pclts/token/bookInfo)
---@param book_id string|number
---@param chapter_uid string|number|nil
---@param opts table|nil
---@param callback fun(ok: boolean, result: table|string)
function M.fetch_reader_state(book_id, chapter_uid, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  opts = opts or {}

  http.request({
    url = M.reader_url(book_id, chapter_uid or opts.chapter_uid),
    accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    referer = M.base_url() .. "/",
    persist = true,
    timeout = opts.timeout or 20,
  }, function(res)
    if res.code ~= 200 or not res.body then
      callback(false, string.format("读取阅读器页面失败（HTTP %s）", tostring(res.status or res.error)))
      return
    end
    local state = reader_state.extract(res.body, vim.json.decode)
    if not state.psvts then
      callback(false, "阅读器页面缺少 psvts，可能登录已过期或接口已变更")
      return
    end
    callback(true, state)
  end)
end

---Fetch the catalog and normalize it.
---(抓目录并归一化)
---@param book_id string|number
---@param opts table|nil
---@param callback fun(ok: boolean, result: table|string)
function M.fetch_catalog(book_id, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  opts = opts or {}
  http.request({
    url = M.chapter_infos_url(),
    method = "POST",
    json = true,
    body = { bookIds = { tostring(book_id) }, synckeys = { 0 } },
    timeout = opts.timeout or 20,
  }, function(res)
    local data, err = http.decode_json(res)
    if not data then
      callback(false, err or "目录请求失败")
      return
    end
    if not M.check_response(data, callback) then
      return
    end
    local record = M.normalize_catalog(data, book_id)
    if not record or #record.chapters == 0 then
      callback(false, "目录为空（该书可能无法在网页端阅读）")
      return
    end
    callback(true, record)
  end)
end

---Report a WeRead error payload through the callback.
---(把微信读书错误负载通过回调报出)
---@param data table
---@param callback fun(ok: boolean, result: any)
---@return boolean ok
function M.check_response(data, callback)
  local message = require("weread.auth").describe_error(data)
  if message then
    callback(false, message)
    return false
  end
  return true
end

---@param payload table
---@param book_id string|number
---@return table|nil
function M.normalize_catalog(payload, book_id)
  local records = payload
  if type(payload) == "table" and payload.data then
    records = payload.data
  end
  if type(records) ~= "table" then
    return nil
  end
  if records.bookId or records.updated then
    records = { records }
  end

  for _, record in ipairs(records) do
    if tostring(record.bookId or "") == tostring(book_id) then
      local chapters = {}
      for _, chapter in ipairs(record.updated or record.chapterInfos or record.chapters or {}) do
        chapters[#chapters + 1] = chapter
      end
      return {
        book_id = tostring(book_id),
        format = record.format,
        synckey = record.synckey,
        title = (record.book or {}).title,
        author = (record.book or {}).author,
        chapters = chapters,
      }
    end
  end
  return nil
end

---Fetch one encoded shard.
---@param book table needs book_id, chapter_uid, psvts
---@param endpoint string
---@param opts table|nil { style = true for the CSS shard }
---@param callback fun(ok: boolean, result: string)
function M.fetch_shard(book, endpoint, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  opts = opts or {}
  local params = P.make_content_params(book.book_id, book.chapter_uid, book.psvts, {
    style = opts.style,
    sc = opts.sc,
  })
  http.request({
    url = M.shard_url(endpoint),
    method = "POST",
    json = true,
    body = params,
    referer = M.reader_url(book.book_id, book.chapter_uid),
    timeout = opts.timeout or 20,
    -- Shards carry no Set-Cookie, and concurrent prefetching must not race on
    -- the jar (分片不带 Set-Cookie，且并发预取不应争抢 jar)
    persist = false,
  }, function(res)
    local body = res.body
    if res.code ~= 200 or not body or body == "" then
      callback(false, string.format("%s 无响应（HTTP %s）", endpoint, tostring(res.status or res.error)))
      return
    end
    callback(true, body)
  end)
end

---Classify a shard response.
---(判别分片响应类型)
---@param body string
---@return string kind "shard"|"txt_metadata"|"error"
---@return table|nil payload
local function classify_shard(body)
  if body:sub(1, 1) ~= "{" then
    return "shard", nil
  end
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= "table" then
    log.debug("shard response starts with '{' but is not a JSON object: %s", tostring(body:sub(1, 80)))
    return "error", nil
  end
  if data.errCode then
    return "error", data
  end
  -- EPUB endpoints answer with chapter metadata JSON for TXT-format books.
  -- (对 TXT 型书籍，EPUB 端点会返回章节元数据 JSON)
  if data.bookId or data.chapterUid or data.title then
    return "txt_metadata", data
  end
  return "error", data
end

---Why a shard response is not usable as a shard, or nil when it is.
---(分片响应为什么不能当分片用；能用时返回 nil)
---@param endpoint string
---@param ok boolean
---@param body string|nil
---@return string|nil
local function shard_problem(endpoint, ok, body)
  if not ok then
    return tostring(body)
  end
  if type(body) ~= "string" or body == "" then
    return endpoint .. " 返回空内容"
  end
  if body:sub(1, 1) == "{" then
    local decoded_ok, data = pcall(vim.json.decode, body)
    local message = decoded_ok and require("weread.auth").describe_error(data) or nil
    return endpoint .. " 返回错误：" .. (message or body:sub(1, 80))
  end
  return nil
end

---Decode a set of shards and refuse the result unless it is clean text.
---(解码一组分片，结果不是干净文本就拒收)
---@param shards string[]
---@param opts table|nil { xml = boolean }
---@return boolean ok
---@return string text_or_error
local function decode_checked(shards, opts)
  local ok, text = pcall(M.decode_shards, shards)
  if not ok then
    return false, "章节解码失败：" .. tostring(text)
  end
  local bad = M.find_invalid_text(text, opts)
  if bad then
    return false, string.format("章节解码结果含非法字节（位置 %d），分片可能不完整或来自不同版本", bad)
  end
  return true, text
end

---Fetch shards in parallel and hand them back in order once all have answered.
---(并行抓取多个分片，全部返回后按顺序交回)
---@param book table
---@param requests table[] { endpoint, opts }
---@param callback fun(shards: string[]|nil, err: string|nil)
local function fetch_all(book, requests, callback)
  local results, problem = {}, nil
  local pending = #requests
  for index, request in ipairs(requests) do
    M.fetch_shard(book, request[1], request[2], function(ok, body)
      local issue = shard_problem(request[1], ok, body)
      if issue then
        problem = problem or issue
      else
        results[index] = body
      end
      pending = pending - 1
      if pending == 0 then
        if problem then
          callback(nil, problem)
        else
          callback(results, nil)
        end
      end
    end)
  end
end

---How many times a chapter whose shards did not fit together is fetched again.
---(分片对不上的章节最多重取几次)
M.CHAPTER_RETRIES = 3

---Fetch and decode one chapter's XHTML and stylesheet.
---(抓取并解码一章的 XHTML 与样式表)
---
---Every shard has to arrive, and the decoded text has to be valid UTF-8 with no
---control characters, or nothing is returned: a chapter is cached once and then
---read from disk, so a garbled one would stay garbled. The usual cause is the
---service re-cutting the chapter between two shard requests (while it
---translates it), so the whole set is fetched again a few times before giving
---up.
---(所有分片都必须到齐，解码后必须是不含控制字符的合法 UTF-8，否则什么都不返回：章节
--- 缓存一次之后就从磁盘读，一旦乱码就会一直乱码。常见原因是服务端在两次分片请求之间
--- 重新切了这一章（正在翻译它），所以放弃前会整组重取几次)
---@param book table needs book_id, chapter_uid, psvts
---@param opts table|nil { timeout, retries, retry_delay = ms }
---@param callback fun(ok: boolean, result: table|string)
function M.fetch_chapter(book, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  opts = opts or {}
  local timeout = opts.timeout or 25
  local retries = opts.retries or M.CHAPTER_RETRIES
  local retry_delay = opts.retry_delay or 1500
  local attempt = 0

  local function fetch_css(result)
    M.fetch_shard(book, "/web/book/chapter/e_2", { timeout = timeout, style = true }, function(css_ok, css_shard)
      if not shard_problem("/web/book/chapter/e_2", css_ok, css_shard) then
        local ok_css, decoded = pcall(M.decode_shard, css_shard)
        -- a damaged stylesheet only costs the styling (样式表坏了只损失样式)
        if not ok_css then
          log.warn("chapter %s: stylesheet shard did not decode, rendering without it: %s", tostring(book.chapter_uid), tostring(decoded))
        elseif M.find_invalid_text(decoded) then
          log.warn("chapter %s: stylesheet decoded to invalid text, rendering without it", tostring(book.chapter_uid))
        else
          result.css = decoded
        end
      end
      callback(true, result)
    end)
  end

  local run

  ---Try again after a pause, or give up with the last reason.
  ---(稍等再试，或带着最后的原因放弃)
  local function retry(reason)
    if attempt > retries then
      log.warn("chapter %s/%s: giving up after %d attempts: %s", tostring(book.book_id), tostring(book.chapter_uid), attempt, reason)
      callback(false, reason)
      return
    end
    log.info("chapter %s/%s: %s; fetching again", tostring(book.book_id), tostring(book.chapter_uid), reason)
    require("weread.timer").defer(run, retry_delay * attempt)
  end

  run = function()
    attempt = attempt + 1
    M.fetch_shard(book, "/web/book/chapter/e_0", { timeout = timeout }, function(ok, first)
      if not ok then
        callback(false, first)
        return
      end

      local kind, payload = classify_shard(first)
      if kind == "error" then
        local message = require("weread.auth").describe_error(payload) or "章节请求被拒绝"
        callback(false, message)
        return
      end

      -- TXT-format book: t_0/t_1 carry the plain text.
      -- (TXT 型书籍：正文在 t_0/t_1)
      if kind == "txt_metadata" then
        fetch_all(book, {
          { "/web/book/chapter/t_0", { timeout = timeout } },
        }, function(shards, err)
          if not shards then
            retry(err)
            return
          end
          -- t_1 may legitimately be empty (`{}`) for a short chapter, as
          -- upstream allows; a transport failure or an error payload is not.
          -- (短章节的 t_1 可以合法地为空（`{}`），上游也允许；但传输失败或错误负载不行)
          M.fetch_shard(book, "/web/book/chapter/t_1", { timeout = timeout, sc = 0 }, function(t1_ok, t1)
            if not t1_ok then
              retry(tostring(t1))
              return
            end
            if t1:sub(1, 1) == "{" then
              local decoded_ok, data = pcall(vim.json.decode, t1)
              local message = decoded_ok and require("weread.auth").describe_error(data) or nil
              if message or not decoded_ok then
                retry("/web/book/chapter/t_1 返回错误：" .. (message or t1:sub(1, 80)))
                return
              end
            else
              shards[2] = t1
            end
            local decode_ok, text = decode_checked(shards)
            if not decode_ok then
              retry(text)
              return
            end
            callback(true, { format = "txt", xhtml = M.txt_to_xhtml(text), css = nil })
          end)
        end)
        return
      end

      -- EPUB-format book: e_0 + e_1 + e_3 carry the XHTML, e_2 the stylesheet.
      -- (EPUB 型书籍：正文在 e_0+e_1+e_3，样式表在 e_2)
      fetch_all(book, {
        { "/web/book/chapter/e_1", { timeout = timeout } },
        { "/web/book/chapter/e_3", { timeout = timeout, sc = 0 } },
      }, function(rest, err)
        if not rest then
          retry(err)
          return
        end
        local shards = { first, rest[1], rest[2] }
        if not M.shards_consistent(shards) then
          retry(string.format(
            "章节分片长度不一致（%d/%d/%d），服务端可能正在更新本章",
            #first - 32,
            #rest[1] - 32,
            #rest[2] - 32
          ))
          return
        end
        local decode_ok, xhtml = decode_checked(shards, { xml = true })
        if not decode_ok then
          retry(xhtml)
          return
        end
        fetch_css({ format = "epub", xhtml = xhtml, css = nil })
      end)
    end)
  end

  run()
end

-- =========================================================================
-- Images
-- =========================================================================

---Last path segment of a WeRead resource url or tar entry name.
---(WeRead 资源 URL 或 tar 条目名的最后一段)
---@param value string
---@return string
function M.image_id(value)
  return (tostring(value):gsub("%?.*$", ""):match("([^/]+)$")) or tostring(value)
end

---Extract image entries from a decoded tar archive.
---(从解析后的 tar 归档中取出图片条目)
---@param entries table[]
---@return table[] images { id, ext, media, data }
function M.extract_images(entries)
  local images = {}
  for _, entry in ipairs(entries or {}) do
    local id = M.image_id(entry.name)
    if id ~= "" and not id:find("/$") then
      local ext, media = tar.detect_type(entry.data)
      if ext then
        images[#images + 1] = { id = id, ext = ext, media = media, data = entry.data, size = #entry.data }
      else
        log.debug("skipping non-image tar entry %s (%d bytes)", entry.name, #entry.data)
      end
    end
  end
  return images
end

---Resource tarballs downloaded so far, numbering their temporary files.
---(已下载的资源包数，用来给临时文件编号)
local tar_downloads = 0

---Download and unpack a chapter's resource tarball.
---(下载并解包章节资源包)
---@param book table
---@param chapter table needs .tar
---@param callback fun(ok: boolean, result: table|string)
function M.fetch_assets(book, chapter, callback)
  if not chapter.tar or chapter.tar == "" then
    callback(true, { images = {} })
    return
  end

  config.ensure_dirs()
  -- unique per download: a reload can start one while the last is still running
  -- (每次下载唯一：重载时上一次可能还在跑)
  tar_downloads = tar_downloads + 1
  local tar_path = string.format(
    "%s/tmp/chapter-%s-%s-%d-%d.tar",
    config.data_dir(),
    tostring(book.book_id),
    tostring(chapter.chapterUid),
    vim.uv.os_getpid(),
    tar_downloads
  )
  http.download(chapter.tar, tar_path, {
    referer = M.reader_url(book.book_id, book.chapter_uid),
    timeout = 60,
    retries = 2,
  }, function(res)
    -- the downloader keeps its header dump next to the body; drop it on every path
    -- (下载器会把响应头留在正文旁边；无论成败都删掉)
    os.remove(tar_path .. ".headers")
    if res.code ~= 200 and res.status ~= 200 then
      os.remove(tar_path)
      callback(false, string.format("资源包下载失败（HTTP %s）", tostring(res.status or res.error)))
      return
    end
    local data = tar.read_file(tar_path)
    os.remove(tar_path)
    if not data or #data < 512 then
      callback(true, { images = {} })
      return
    end
    local ok, entries = pcall(tar.parse, data)
    if not ok then
      callback(false, "资源包解析失败：" .. tostring(entries))
      return
    end
    callback(true, { images = M.extract_images(entries) })
  end)
end

---Rewrite remote image urls in a chapter to local files.
---(把章节里的远程图片 URL 改写为本地文件)
---@param xhtml string
---@param id_to_path table<string, string>
---@return string xhtml
---@return integer replaced
---@return integer missing
function M.rewrite_image_sources(xhtml, id_to_path)
  local replaced, missing = 0, 0

  local function rewrite(url)
    local id = M.image_id(url)
    local path = id_to_path[id]
    if path then
      replaced = replaced + 1
      return path
    end
    missing = missing + 1
    return url
  end

  local out = xhtml:gsub('(<img[^>]-src=)"([^"]+)"', function(prefix, url)
    return prefix .. '"' .. rewrite(url) .. '"'
  end)
  out = out:gsub("(<img[^>]-src=)'([^']+)'", function(prefix, url)
    return prefix .. "'" .. rewrite(url) .. "'"
  end)

  return out, replaced, missing
end

return M
