--[[
Writing highlights and thoughts to the account, through the web reader's own
endpoints, and keeping the local highlights in step with it.
(把划线与想法写进账号——走 Web 阅读器自己的端点——并让本地划线与账号保持同步)

The Agent API is read-only; the write path authenticates with the reader's
cookie session. Every request here goes to `config.web_origin()`, read at call
time, so the config (and therefore the test suite) decides where a write goes.
(Agent API 只读；写路径认的是阅读器的 cookie 会话。这里每个请求都发往 `config.web_origin()`，
 调用时读取：由配置（因此也由测试）决定写请求发到哪里)

Depends on model, store and render; nothing above it.
(依赖 model、store、render，不依赖更上层的模块)
]]

local config = require("weread.config")
local log = require("weread.log")
local model = require("weread.annotations_model")
local render = require("weread.annotations_render")
local store = require("weread.annotations_store")

local M = {}

---The Referer the reader's own pages send, so the service sees a request that
---looks like the page's.
---(阅读器自己的页面发送的 Referer，让服务端看到的请求和页面发的一样)
---@return string
local function reader_referer()
  return config.web_origin() .. "/web/reader/"
end

---Why a write was refused, in one line.
---(写请求被拒的原因，一行说完)
---@param res table|nil
---@param data table|nil
---@return string
function M.write_error(res, data)
  return tostring(data and (data.errMsg or data.errCode) or (res and res.error) or ("HTTP " .. tostring(res and res.code)))
end

---Line style a highlight made here is synced with (0 straight, 1 marker, 2 wavy).
---(在这里画的划线同步时用的线型：0 直线、1 马克笔、2 波浪线)
---@return integer
function M.sync_style()
  local style = tonumber(((config.get().annotations or {}).style))
  if style == 0 or style == 1 or style == 2 then
    return style
  end
  return 2
end

---Add a highlight to the account, through the web reader's own endpoint.
---(把一条划线加到账号里，走 Web 阅读器自己的端点)
---
---Same session and origin as `/web/review/add`. What made the endpoint refuse
---every earlier probe (HTTP 400, empty body) is that the reader sends
---`markText` Base64 encoded; with that, `/book/bookmarklist` reads the
---highlight back with the `style` it was given, and the phone draws it so.
---(会话与源都与 `/web/review/add` 相同。早先所有探测都被拒（HTTP 400、空响应），原因是阅读器
--- 发送的 `markText` 是 Base64 编码的；照做之后 `/book/bookmarklist` 能按给定的 `style`
--- 读回这条划线，手机上也就按这个线型显示)
---@param params table { book_id, chapter_uid, chapter_idx, range, text, style, book_version }
---@param callback fun(ok: boolean, result: string) bookmark id, or the error(bookmark id 或错误)
function M.post_highlight(params, callback)
  local http = require("weread.http")
  local body = {
    bookId = tostring(params.book_id),
    chapterUid = tonumber(params.chapter_uid) or 0,
    type = 1,
    style = tonumber(params.style) or M.sync_style(),
    range = tostring(params.range),
    markText = vim.base64.encode(params.text or ""),
  }
  if params.chapter_idx then
    body.chapterIdx = tonumber(params.chapter_idx)
  end
  if params.book_version then
    body.bookVersion = tonumber(params.book_version)
  end
  http.request({
    url = config.web_origin() .. "/web/book/addBookmark",
    write = true,
    method = "POST",
    json = true,
    body = body,
    referer = reader_referer(),
    timeout = 20,
  }, function(res)
    local data = http.decode_json(res)
    if type(data) ~= "table" or type(data.bookmarkId) ~= "string" or data.bookmarkId == "" then
      callback(false, "划线同步失败：" .. M.write_error(res, data))
      return
    end
    callback(true, data.bookmarkId)
  end)
end

---Take a highlight off the account.
---(从账号里删掉一条划线)
---@param bookmark_id string
---@param callback fun(ok: boolean, result: string|nil)
function M.delete_highlight(bookmark_id, callback)
  local http = require("weread.http")
  http.request({
    url = config.web_origin() .. "/web/book/removeBookmark",
    method = "POST",
    json = true,
    body = { bookmarkId = tostring(bookmark_id) },
    referer = reader_referer(),
    timeout = 20,
  }, function(res)
    local data = http.decode_json(res)
    if type(data) ~= "table" or data.succ ~= 1 then
      callback(false, "删除划线失败：" .. M.write_error(res, data))
      return
    end
    callback(true, nil)
  end)
end

---Post a thought on a passage.
---(在某段文字上写想法)
---
---Verified against the live service: a thought posted this way comes back out of
---`/book/readreviews` under that range.
---(已对线上服务验证：这样发出的想法能从 `/book/readreviews` 按该 range 读回来)
---@param params table { book_id, chapter_uid, chapter_idx, range, content, abstract, book_version }
---@param callback fun(ok: boolean, result: table|string)
function M.post_thought(params, callback)
  local http = require("weread.http")
  local body = {
    bookId = tostring(params.book_id),
    chapterUid = tonumber(params.chapter_uid) or 0,
    range = tostring(params.range),
    content = params.content,
    -- `abstract` is the text the thought hangs on; without it the service files
    -- the thought against the chapter rather than the passage.
    -- (`abstract` 是想法挂靠的原文；缺了它服务端会把想法记在章节上而不是这一段)
    abstract = params.abstract or "",
    isPrivate = params.is_private == true,
    type = 1,
  }
  if params.chapter_idx then
    body.chapterIdx = tonumber(params.chapter_idx)
  end
  if params.book_version then
    body.bookVersion = tonumber(params.book_version)
  end
  http.request({
    url = config.web_origin() .. "/web/review/add",
    write = true,
    method = "POST",
    json = true,
    body = body,
    referer = reader_referer(),
    timeout = 20,
  }, function(res)
    local data = http.decode_json(res)
    if type(data) ~= "table" or not data.reviewId then
      callback(false, "写想法失败：" .. M.write_error(res, data))
      return
    end
    callback(true, data)
  end)
end

---Delete one of my thoughts.
---(删除我的一条想法)
---@param review_id string
---@param opts table|nil { book_id, chapter_uid, range, book_version }
---@param callback fun(ok: boolean, result: table|string)
function M.delete_thought(review_id, opts, callback)
  local http = require("weread.http")
  opts = opts or {}
  local body = { reviewId = review_id }
  if opts.book_id then
    body.bookId = tostring(opts.book_id)
  end
  if opts.chapter_uid then
    body.chapterUid = tonumber(opts.chapter_uid) or 0
  end
  if opts.range then
    body.range = tostring(opts.range)
  end
  if opts.book_version then
    body.bookVersion = tonumber(opts.book_version)
  end
  http.request({
    url = config.web_origin() .. "/web/review/delete",
    write = true,
    method = "POST",
    json = true,
    body = body,
    referer = reader_referer(),
    timeout = 20,
  }, function(res)
    local data = http.decode_json(res)
    if type(data) ~= "table" or data.succ ~= 1 then
      callback(false, "删除想法失败：" .. M.write_error(res, data))
      return
    end
    callback(true, data)
  end)
end

---Find my thought under one range through the web reader's own "my notes"
---list (`/web/review/list`, `listType = 4`).
---(通过 Web 阅读器自己的「我的想法」列表查找某个 range 下我写的那条)
---
---The Agent API's `/book/readreviews` answers `-2020` for an uploaded book,
---so this cookie-authenticated list is the only read path that can recover the
---review id of a note written before ids were stored locally.
---(Agent API 的 /book/readreviews 对上传的书回 -2020；这个走 cookie 的列表是唯一能
--- 找回「开始存 id 之前写的备注」的 review id 的读路径)
---@param book_id string
---@param chapter_uid string|nil
---@param range string
---@param callback fun(ok: boolean, thought: table|nil, error: string|nil)
function M.find_my_thought_web(book_id, chapter_uid, range, callback)
  local http = require("weread.http")
  local credentials = require("weread.auth").load_credentials()
  local vid = tostring((credentials and credentials.account or {}).user_vid or "")
  local page_size = 50
  local max_pages = 10
  local pages = 0
  local seen = {}

  local function fetch(offset)
    pages = pages + 1
    local query = table.concat({
      "bookId=" .. tostring(book_id),
      -- 4 is the web reader's ReviewListTypeNote (4 = 我的想法)
      "listType=4",
      "maxIdx=" .. tostring(offset),
      "count=" .. tostring(page_size),
      "listMode=2",
      "synckey=0",
      "mine=1",
      "userVid=" .. vid,
    }, "&")
    if chapter_uid then
      query = query .. "&chapterUid=" .. tostring(chapter_uid)
    end
    http.request({
      url = config.web_origin() .. "/web/review/list?" .. query,
      method = "GET",
      referer = reader_referer(),
      timeout = 20,
    }, function(res)
      local data = http.decode_json(res)
      if type(data) ~= "table" then
        callback(false, nil, "读取我的想法失败：" .. M.write_error(res, data))
        return
      end
      if data.errCode ~= nil and tonumber(data.errCode) ~= 0 then
        callback(false, nil, tostring(data.errMsg or data.errCode))
        return
      end

      local reviews = data.reviews or {}
      local fresh = 0
      for _, entry in ipairs(reviews) do
        local review = entry.review or entry
        local entry_id = tostring(review.reviewId or entry.reviewId or "")
        if entry_id ~= "" and not seen[entry_id] then
          seen[entry_id] = true
          fresh = fresh + 1
        end
        if tostring(review.range) == tostring(range) and (not chapter_uid or tostring(review.chapterUid) == tostring(chapter_uid)) then
          local review_id = review.reviewId or entry.reviewId
          if review_id ~= nil and tostring(review_id) ~= "" then
            local content = (review.content or ""):gsub("\226\128[\139-\141]", ""):gsub("\239\187\191", "")
            callback(true, {
              content = content,
              author = (review.author or {}).name,
              id = tostring(review_id),
              author_vid = tostring((review.author or {}).userVid or review.userVid or ""),
              time = review.createTime,
              is_private = review.isPrivate,
              likes = 0,
              range = review.range,
            })
            return
          end
        end
      end

      -- A server that ignores `maxIdx` would otherwise repeat the same page.
      -- (服务端若忽略 maxIdx，就会一直重复同一页)
      if #reviews >= page_size and fresh > 0 and pages < max_pages then
        fetch(offset + page_size)
        return
      end
      callback(true, nil)
    end)
  end

  fetch(0)
end

---Ranges being uploaded right now, so a quick second call does not post twice.
---(正在上传的 range：短时间内再调一次也不会重复发)
local syncing = {}

---Upload the chapter's local highlights the account does not have yet.
---(把本章账号里还没有的本地划线传上去)
---
---Called right after a highlight is drawn and whenever a chapter opens, so a
---highlight made offline, or before syncing existed, reaches the phone the next
---time its chapter is read. A failure keeps the highlight here and says so once.
---(画完划线立刻调用，打开章节时也调用：离线时画的、或者有同步之前画的划线，下次读到这一章
--- 就会进手机。失败时划线仍留在本机，并提示一次)
---@param buf integer
---@param opts table|nil { quiet = boolean } no message on success(成功时不提示)
function M.sync_local(buf, opts)
  opts = opts or {}
  local context = store.write_context(buf)
  if not context then
    return
  end
  local server = {}
  for _, annotation in ipairs(vim.b[buf].weread_server_annotations or {}) do
    server[annotation.range] = annotation
  end
  for _, entry in ipairs(store.local_for(context.book_id, context.chapter_key)) do
    local known = server[entry.range]
    local key = table.concat({ context.book_id, context.chapter_key, entry.range }, ":")
    if entry.bookmark_id or syncing[key] then
      -- already in the account, or on its way
      -- (已经在账号里，或者正在上传)
    elseif known and known.mine and known.bookmark_id then
      -- the account already has this range: adopt its id instead of posting again
      -- (账号里已经有这个 range：直接用它的 id，不再重复上传)
      store.mark_synced(context.book_id, context.chapter_key, entry.range, known.bookmark_id)
    elseif not entry.local_only then
      syncing[key] = true
      M.post_highlight({
        book_id = context.book_id,
        chapter_uid = context.chapter_uid,
        chapter_idx = context.chapter_idx,
        range = entry.range,
        text = store.source_text(context.book_id, context.chapter_key, entry.range) or entry.text,
        book_version = context.book.version,
      }, function(ok, result)
        syncing[key] = nil
        if not ok then
          log.warn("highlight sync %s failed: %s", entry.range, tostring(result))
          if not opts.quiet then
            vim.notify("weread: " .. tostring(result) .. "（划线已留在本地，下次打开本章会再试）", vim.log.levels.WARN)
          end
          return
        end
        if not store.mark_synced(context.book_id, context.chapter_key, entry.range, result) then
          -- removed here while the upload was in flight: take it back off the account
          -- (上传途中在这里取消了：再从账号里删掉)
          M.delete_highlight(result, function(deleted, err)
            if not deleted then
              log.warn("highlight %s removed during sync, delete failed: %s", entry.range, tostring(err))
            end
          end)
          return
        end
        render.redraw(buf, context.book_id, context.chapter_key)
        require("weread.ui").notify("weread: 划线已同步到微信读书", vim.log.levels.INFO, { routine = opts.quiet })
      end)
    end
  end
end

---Remove a highlight: from the account when it is there, then from here.
---(删除一条划线：账号里有就先从账号删，再删本地)
---@param buf integer
---@param annotation table
---@param callback fun(ok: boolean, message: string)|nil
function M.remove_highlight(buf, annotation, callback)
  local info = require("weread.reader").buffer_info(buf)
  callback = callback or function(ok, message)
    vim.notify(message, ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end
  if not info then
    callback(false, "只在微信读书章节里取消划线")
    return
  end
  local function drop_local()
    store.remove_local(info.book_id, info.chapter_key, annotation.range)
    store.forget_server(buf, info.book_id, info.chapter_key, annotation.range)
    render.redraw(buf, info.book_id, info.chapter_key)
  end
  if not annotation.bookmark_id then
    drop_local()
    callback(true, "已取消这条本地划线")
    return
  end
  M.delete_highlight(annotation.bookmark_id, function(ok, err)
    if not ok then
      callback(false, tostring(err))
      return
    end
    drop_local()
    callback(true, "已取消划线（微信读书里同步删除）")
  end)
end

return M
