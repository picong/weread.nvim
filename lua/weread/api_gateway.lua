--[[
Official WeRead "Skill" Agent API client.

This is the stable, documented surface: shelf, search, metadata, progress,
notes and reviews. It is keyed by the long lived API key (`wrk-*`) that the QR
login stores, and it authenticates with a Bearer header.
(官方 Agent API 客户端：书架/搜索/元信息/进度/笔记书评。使用扫码登录存下的长期
 API Key，走 Bearer 头认证)

It deliberately does NOT provide chapter bodies: those only exist behind the web
reader pipeline in weread.content.
(它刻意不提供正文：正文只能走 weread.content 里的网页阅读器链路)
]]

local P = require("weread.protocol")
local config = require("weread.config")
local http = require("weread.http")
local log = require("weread.log")

local M = {}

local DEFAULT_ORIGIN = "https://i.weread.qq.com"
local DEFAULT_PATH = "/api/agent/gateway"

---Resolve the gateway endpoint.
---(解析 gateway 端点地址)
---Accepts either an origin (`https://i.weread.qq.com`) or a full endpoint url.
---A bare origin used to be posted verbatim, so the request silently landed on
---"/" and surfaced as a JSON parse error much later; normalising here turns
---that into a working request.
---(既接受 origin 也接受完整端点 URL。以前只给 origin 时会原样 POST 到 "/"，
--- 最后表现为一个很难定位的 JSON 解析错误；在这里归一化掉)
---@return string
function M.gateway_url()
  local configured = config.get().gateway_url
  if not configured or configured == "" then
    return DEFAULT_ORIGIN .. DEFAULT_PATH
  end
  if configured:match("^https?://[^/]+/?$") then
    return (configured:gsub("/$", "")) .. DEFAULT_PATH
  end
  return configured
end

---Call one gateway endpoint.
---(调用一个 gateway 接口)
---@param api_name string e.g. "/store/search"
---@param params table|nil
---@param opts table|nil
---@param callback fun(ok: boolean, result: table|string)
function M.call(api_name, params, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  opts = opts or {}

  local auth = require("weread.auth")
  local key = auth.api_key()
  if not key then
    callback(false, "缺少官方 API Key，请执行 :WeReadLogin 重新扫码登录")
    return
  end

  local body = vim.tbl_extend("keep", vim.deepcopy(params or {}), {
    api_name = api_name,
    skill_version = P.SKILL_VERSION,
  })

  http.request({
    url = M.gateway_url(),
    method = "POST",
    json = true,
    body = body,
    timeout = opts.timeout or 20,
    headers = { Authorization = "Bearer " .. key },
    referer = false,
    origin = false,
  }, function(res)
    local data, err = http.decode_json(res)
    if not data then
      callback(false, err or "接口请求失败")
      return
    end
    -- The service asks clients to stop and follow the upgrade instruction.
    -- (服务端若返回 upgrade_info，要求客户端停止并按其指示升级)
    if data.upgrade_info then
      log.warn("gateway %s asks for an upgrade: %s", api_name, vim.json.encode(data.upgrade_info))
      callback(false, "微信读书 Agent API 要求升级 skill_version，请更新 weread.nvim")
      return
    end
    if not auth.check(data) then
      callback(false, auth.describe_error(data) or "接口返回错误")
      return
    end
    callback(true, data)
  end)
end

---@param callback fun(ok: boolean, books: table[]|string)
function M.shelf(callback)
  M.call("/shelf/sync", {}, function(ok, data)
    if not ok then
      callback(false, data)
      return
    end
    local books = {}
    for _, book in ipairs(data.books or {}) do
      books[#books + 1] = {
        book_id = tostring(book.bookId),
        title = book.title or "(无标题)",
        author = book.author or "",
        cover = P.normalize_cover_url(book.cover),
        category = book.category or "",
        finish_reading = tool_truthy(book.finishReading),
        read_update_time = tonumber(book.readUpdateTime) or 0,
        kind = "book",
      }
    end
    callback(true, books)
  end)
end

---@param book_id string
---@param callback fun(ok: boolean, result: table|string)
function M.book_info(book_id, callback)
  M.call("/book/info", { bookId = tostring(book_id) }, callback)
end

---@param book_id string
---@param callback fun(ok: boolean, result: table|string)
function M.progress(book_id, callback)
  M.call("/book/getprogress", { bookId = tostring(book_id) }, callback)
end

---@param keyword string
---@param opts table|nil { scope = 10, count = 20 }
---@param callback fun(ok: boolean, books: table[]|string)
function M.search(keyword, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  opts = opts or {}
  M.call("/store/search", {
    keyword = keyword,
    scope = opts.scope or 10,
    count = opts.count or 20,
    maxIdx = opts.max_idx or 0,
  }, function(ok, data)
    if not ok then
      callback(false, data)
      return
    end
    local books = {}
    for _, group in ipairs(data.results or {}) do
      for _, hit in ipairs(group.books or {}) do
        local info = hit.bookInfo or {}
        if info.bookId then
          books[#books + 1] = {
            book_id = tostring(info.bookId),
            title = info.title or "(无标题)",
            author = info.author or "",
            cover = P.normalize_cover_url(info.cover),
            rating = hit.newRating and string.format("%.1f%%", hit.newRating) or nil,
            reading_count = hit.readingCount,
            kind = "book",
          }
        end
      end
    end
    callback(true, books)
  end)
end

---WeRead uses 0/1 for booleans in several payloads.
---(微信读书有些字段用 0/1 表示布尔)
---@param value any
---@return boolean
function tool_truthy(value)
  return value == true or tonumber(value) == 1
end

return M
