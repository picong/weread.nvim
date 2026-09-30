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

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

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

local function base64_decode(data)
  data = data:gsub("-", "+"):gsub("_", "/")
  local pad = #data % 4
  if pad > 0 then
    data = data .. string.rep("=", 4 - pad)
  end
  data = data:gsub("[^" .. b64chars .. "=]", "")
  return (data:gsub(".", function(char)
    if char == "=" then
      return ""
    end
    local bits = ""
    local index = b64chars:find(char, 1, true) - 1
    for bit = 6, 1, -1 do
      bits = bits .. (index % 2 ^ bit - index % 2 ^ (bit - 1) > 0 and "1" or "0")
    end
    return bits
  end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(bits)
    if #bits ~= 8 then
      return ""
    end
    local byte = 0
    for i = 1, 8 do
      if bits:sub(i, i) == "1" then
        byte = byte + 2 ^ (8 - i)
      end
    end
    return string.char(byte)
  end))
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

---@return string
function M.base_url()
  return config.get().base_url or "https://weread.qq.com"
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

---Fetch and decode one chapter's XHTML and stylesheet.
---(抓取并解码一章的 XHTML 与样式表)
---@param book table needs book_id, chapter_uid, psvts
---@param opts table|nil
---@param callback fun(ok: boolean, result: table|string)
function M.fetch_chapter(book, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  opts = opts or {}
  local timeout = opts.timeout or 25

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
      M.fetch_shard(book, "/web/book/chapter/t_0", { timeout = timeout }, function(txt_ok, t0)
        if not txt_ok then
          callback(false, t0)
          return
        end
        M.fetch_shard(book, "/web/book/chapter/t_1", { timeout = timeout, sc = 0 }, function(t1_ok, t1)
          local shards = { t0 }
          if t1_ok and t1 then
            shards[#shards + 1] = t1
          end
          local decode_ok, text = pcall(M.decode_shards, shards)
          if not decode_ok then
            callback(false, "章节解码失败：" .. tostring(text))
            return
          end
          callback(true, { format = "txt", xhtml = M.txt_to_xhtml(text), css = nil })
        end)
      end)
      return
    end

    -- EPUB-format book: e_0 + e_1 + e_3 carry the XHTML, e_2 the stylesheet.
    -- (EPUB 型书籍：正文在 e_0+e_1+e_3，样式表在 e_2)
    local pending = 2
    local shards = { first, "", "" }
    local failed = nil

    local function done()
      pending = pending - 1
      if pending > 0 then
        return
      end
      if failed then
        callback(false, failed)
        return
      end
      local ok_decode, xhtml = pcall(M.decode_shards, shards)
      if not ok_decode then
        callback(false, "章节解码失败：" .. tostring(xhtml))
        return
      end

      M.fetch_shard(book, "/web/book/chapter/e_2", { timeout = timeout, style = true }, function(css_ok, css_shard)
        local css = nil
        if css_ok and css_shard and css_shard:sub(1, 1) ~= "{" then
          local ok_css, decoded = pcall(M.decode_shard, css_shard)
          css = ok_css and decoded or nil
        end
        callback(true, { format = "epub", xhtml = xhtml, css = css })
      end)
    end

    M.fetch_shard(book, "/web/book/chapter/e_1", { timeout = timeout }, function(ok1, shard1)
      if ok1 and shard1 and shard1:sub(1, 1) ~= "{" then
        shards[2] = shard1
      end
      done()
    end)

    M.fetch_shard(book, "/web/book/chapter/e_3", { timeout = timeout, sc = 0 }, function(ok3, shard3)
      if ok3 and shard3 and shard3:sub(1, 1) ~= "{" then
        shards[3] = shard3
      end
      done()
    end)
  end)
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
  local tar_path = string.format("%s/tmp/chapter-%s-%s.tar", config.data_dir(), tostring(book.book_id), tostring(chapter.chapterUid))
  http.download(chapter.tar, tar_path, {
    referer = M.reader_url(book.book_id, book.chapter_uid),
    timeout = 60,
    retries = 2,
  }, function(res)
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
