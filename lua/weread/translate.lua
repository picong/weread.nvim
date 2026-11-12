--[[
Full-text translation, the way the web reader's 译文 button does it.
(全文翻译：做法与 Web 阅读器的「译文」按钮一致)

The service translates a chapter on request and from then on returns it with a
translated block after every block of the original. Three calls make up the
feature:
(服务端按请求翻译一章，之后返回的正文在原文每个块后面跟一个译文块。整个功能由三个调用组成：)

* `POST /web/book/enRead`             asks for the chapter and the next one to be
                                      translated, and reports how far it got;
                                      polled until `stopPoll`
                                      (请求翻译本章与下一章，并报告进度；轮询到 `stopPoll` 为止)
* `POST /web/reader/toggleTranslate`  the book's translation switch in the account,
                                      kept in step so the app agrees
                                      (账号里这本书的翻译开关，保持一致，App 才会同意)
* the chapter shards                  unchanged: a translated chapter simply comes
                                      back bilingual (see `xhtml.split_translation`)
                                      (正文分片不变：翻译过的章节直接以双语返回)

Translation is a member feature of the service; a refusal is reported as it is.
(翻译是服务端的会员功能；被拒时如实提示)

Whether the page shows the translation is a reading choice of this editor,
remembered per book, so the original stays one key away.
(页面是否显示译文是这里的阅读选择，按书记住，原文始终一键可回)
]]

local log = require("weread.log")

local M = {}

local POLL_INTERVAL_MS = 3000
local POLL_LIMIT = 40

---Books whose translation switch is on, remembered across sessions.
---(开启了译文的书，跨会话记住)
---@return table<string, boolean>
local function switches()
  local value = require("weread.prefs").get("translate")
  return type(value) == "table" and value or {}
end

---@param book_id string
---@return boolean
function M.enabled(book_id)
  return switches()[tostring(book_id)] == true
end

---@param book_id string
---@param on boolean
function M.set_enabled(book_id, on)
  local value = switches()
  value[tostring(book_id)] = on or nil
  require("weread.prefs").set("translate", value)
end

---Books read as the translation alone, the original hidden under it.
---(只看译文、把原文藏起来的书)
---@return table<string, boolean>
local function only_switches()
  local value = require("weread.prefs").get("translate_only")
  return type(value) == "table" and value or {}
end

---@param book_id string
---@return boolean
function M.only(book_id)
  return only_switches()[tostring(book_id)] == true
end

---@param book_id string
---@param on boolean
function M.set_only(book_id, on)
  local value = only_switches()
  value[tostring(book_id)] = on or nil
  require("weread.prefs").set("translate_only", value)
end

---Who translates a book's chapters, as the reader picked it: a model's name, or
---"weread" for the service's own translation. nil until the reader picks.
---(这本书的章节由谁来译，读者选的：模型名，或者 "weread" 表示服务端自己的译文；没选过为 nil)
---@param book_id string
---@return string|nil
function M.engine(book_id)
  local value = require("weread.prefs").get("translate_engine")
  local engine = type(value) == "table" and value[tostring(book_id)] or nil
  return type(engine) == "string" and engine ~= "" and engine or nil
end

---@param book_id string
---@param engine string|nil
function M.set_engine(book_id, engine)
  local value = require("weread.prefs").get("translate_engine")
  value = type(value) == "table" and value or {}
  value[tostring(book_id)] = engine
  require("weread.prefs").set("translate_engine", value)
end

---@param path string
---@param body table
---@param callback fun(ok: boolean, data: table|string)
local function post(path, body, callback)
  local http = require("weread.http")
  -- Read per call, so a later `setup{ base_url = ... }` is honoured
  -- (每次调用时读取，之后再 setup 改 base_url 也能生效)
  local origin = require("weread.config").web_origin()
  http.request({
    url = origin .. path,
    method = "POST",
    json = true,
    body = body,
    referer = origin .. "/web/reader/",
    timeout = 20,
  }, function(res)
    local data, err = http.decode_json(res)
    if type(data) ~= "table" then
      callback(false, tostring(err or ("HTTP " .. tostring(res and res.code))))
      return
    end
    if data.errCode or data.errcode then
      callback(false, tostring(data.errMsg or data.errmsg or data.errCode or data.errcode))
      return
    end
    callback(true, data)
  end)
end

---Flip the book's translation switch in the account.
---(翻转账号里这本书的翻译开关)
---@param book_id string
---@param on boolean
---@param callback fun(ok: boolean, err: string|nil)|nil
function M.toggle_remote(book_id, on, callback)
  post("/web/reader/toggleTranslate", { bookId = tostring(book_id), enabled = on == true }, function(ok, data)
    if callback then
      callback(ok and (data.succ == nil or data.succ == 1), ok and nil or tostring(data))
    end
  end)
end

---Ask the service to translate a chapter (and the one after it), and report
---how far it got.
---(请服务端翻译一章（以及下一章），并报告进度)
---@param book_id string
---@param chapters table[] { chapterUid, translateVersion }, the current chapter first(当前章在前)
---@param callback fun(ok: boolean, status: table|string) status: { done, progress, versions, tips }
function M.request(book_id, chapters, callback)
  local read = {}
  for _, chapter in ipairs(chapters) do
    read[#read + 1] = {
      uid = tonumber(chapter.chapterUid) or chapter.chapterUid,
      translateVersion = tonumber(chapter.translateVersion) or 0,
    }
  end
  if #read == 0 then
    callback(false, "没有可翻译的章节")
    return
  end
  post("/web/book/enRead", {
    bookId = tostring(book_id),
    reference = { uid = read[1].uid, texts = {} },
    read = read,
  }, function(ok, data)
    if not ok then
      callback(false, data)
      return
    end
    local versions = {}
    for _, status in ipairs(type(data.curStatus) == "table" and data.curStatus or {}) do
      if type(status) == "table" and status.uid then
        versions[tostring(status.uid)] = tonumber(status.translateVersion) or 0
      end
    end
    callback(true, {
      done = data.stopPoll == 1 or data.stopPoll == true,
      progress = tonumber(data.translationProgress) or 0,
      versions = versions,
      tips = data.tips,
    })
  end)
end

---Running polls, one per book and chapter.
---(进行中的轮询：每本书每章一个)
local polling = {}

---Translate a chapter and call back once the service has a translation of it
---newer than the one already shown.
---(翻译一章：服务端有了比已显示版本更新的译文时回调)
---@param book_id string
---@param chapters table[] see `request`; the first one is waited for(等待的是第一章)
---@param on_ready fun(ok: boolean, result: integer|string) the new translateVersion, or the error(新的 translateVersion 或错误)
---@param opts table|nil { interval = ms, limit = attempts }
function M.ensure(book_id, chapters, on_ready, opts)
  opts = opts or {}
  local first = chapters[1]
  if not first then
    on_ready(false, "没有可翻译的章节")
    return
  end
  local key = tostring(book_id) .. ":" .. tostring(first.chapterUid)
  if polling[key] then
    table.insert(polling[key], on_ready)
    return
  end
  polling[key] = { on_ready }
  local known = tonumber(first.translateVersion) or 0
  local attempts = 0
  local function finish(ok, result)
    local waiters = polling[key] or {}
    polling[key] = nil
    for _, waiter in ipairs(waiters) do
      waiter(ok, result)
    end
  end
  local function step()
    attempts = attempts + 1
    -- A synchronous throw from the request must not leave `polling[key]` set:
    -- every later call would queue behind a poll that never finishes.
    -- (请求同步抛错时不能留着 polling[key]：否则之后每次调用都会排在一个永远不结束的轮询后面)
    local started, start_err = pcall(M.request, book_id, chapters, function(ok, status)
      if not ok then
        log.warn("translate %s failed: %s", key, tostring(status))
        finish(false, status)
        return
      end
      local version = status.versions[tostring(first.chapterUid)] or 0
      if version > known and (status.done or status.progress >= 100) then
        finish(true, version)
        return
      end
      if status.done then
        if version > 0 then
          finish(true, version)
        else
          finish(false, status.tips or "服务端没有给出译文")
        end
        return
      end
      if attempts >= (opts.limit or POLL_LIMIT) then
        finish(false, "翻译超时，稍后再试")
        return
      end
      vim.defer_fn(step, opts.interval or POLL_INTERVAL_MS)
    end)
    if not started then
      log.warn("translate %s request raised: %s", key, tostring(start_err))
      finish(false, "翻译请求出错：" .. tostring(start_err))
    end
  end
  step()
end

return M
