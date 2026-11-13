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

local DEFAULT_PATH = "/api/agent/gateway"

---WeRead uses 0/1 for booleans in several payloads.
---(微信读书有些字段用 0/1 表示布尔)
---@param value any
---@return boolean
local function tool_truthy(value)
  return value == true or tonumber(value) == 1
end

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
    configured = config.defaults.gateway_url
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
    callback(false, "缺少官方 API Key：请在微信读书 App 开通微信读书 Skill 后重新执行 :WeReadLogin")
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
    -- A background pull must answer quickly or not at all: three attempts at a
    -- few seconds each is a reader left waiting for half a minute.
    -- (后台拉取要么快速回答，要么干脆不答：每次几秒、重试三次，读者就得等半分钟)
    retries = opts.retries,
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
    if not auth.check(data, { silent = opts.silent }) then
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

---Book metadata (rating, intro, ...). Silent by default: the shelf preview
---renders failures inline, so they must not pop a notify.
---(书籍元信息（评分、简介等）。默认静默：书架预览把失败内联渲染，不能再弹通知)
---@param book_id string
---@param opts table|nil { silent = boolean } default true(默认 true)
---@param callback fun(ok: boolean, result: table|string)
function M.book_info(book_id, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  opts = opts or {}
  M.call("/book/info", { bookId = tostring(book_id) }, { silent = opts.silent ~= false }, callback)
end

---@param book_id string
---@param opts table|nil { timeout = integer, retries = integer, silent = boolean }
---@param callback fun(ok: boolean, result: table|string)
function M.progress(book_id, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  M.call("/book/getprogress", { bookId = tostring(book_id) }, opts, callback)
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

---Public reviews written by other readers for one book.
---(一本书的公开点评——别的读者写的，不是我的笔记)
---Failures stay silent by default: the preview renders them inline.
---(默认静默失败：预览会把错误内联渲染)
---@param book_id string
---@param opts table|nil { count = integer, list_type = integer, max_idx = integer, silent = boolean } silent defaults to true(默认 true)
---@param callback fun(ok: boolean, result: table|string)
function M.review_list(book_id, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  opts = opts or {}
  M.call("/review/list", {
    bookId = tostring(book_id),
    reviewListType = opts.list_type or 0,
    count = opts.count or 20,
    maxIdx = opts.max_idx or 0,
    synckey = 0,
  }, { silent = opts.silent ~= false }, function(ok, data)
    if not ok then
      callback(false, data)
      return
    end
    -- The payload nests the text one level deeper than the id:
    -- entry.review.reviewId but entry.review.review.content.
    -- (负载里文本比 id 多包了一层：entry.review.reviewId 但 entry.review.review.content)
    local reviews = {}
    for _, entry in ipairs(data.reviews or {}) do
      local outer = type(entry.review) == "table" and entry.review or {}
      local inner = type(outer.review) == "table" and outer.review or outer
      local author = type(inner.author) == "table" and inner.author or {}
      reviews[#reviews + 1] = {
        name = type(author.name) == "string" and author.name or nil,
        star = tonumber(inner.star),
        content = type(inner.content) == "string" and inner.content
          or type(outer.content) == "string" and outer.content
          or "",
        create_time = tonumber(inner.createTime),
        is_finish = tool_truthy(inner.isFinish),
      }
    end
    callback(true, { total = tonumber(data.reviewsCnt), reviews = reviews })
  end)
end

---The chapter table of one book, from the official API (no reader pipeline).
---Silent: the preview falls back to the web catalog on failure and renders
---the outcome inline.
---(一本书的章节目录，走官方 API——不经网页阅读器链路。静默失败：预览失败时会回退到
--- 网页目录，并把结果内联渲染)
---@param book_id string
---@param callback fun(ok: boolean, result: table|string)
function M.chapter_info(book_id, callback)
  M.call("/book/chapterinfo", { bookId = tostring(book_id) }, { silent = true }, function(ok, data)
    if not ok then
      callback(false, data)
      return
    end
    local chapters = {}
    for _, chapter in ipairs(data.chapters or {}) do
      chapters[#chapters + 1] = {
        uid = chapter.chapterUid,
        idx = tonumber(chapter.chapterIdx),
        title = type(chapter.title) == "string" and chapter.title or "",
        level = tonumber(chapter.level) or 1,
        word_count = tonumber(chapter.wordCount),
      }
    end
    callback(true, { chapters = chapters })
  end)
end

---Reading statistics for one calendar period: total time, per-bucket times
---(days of a week/month, months of a year, years overall), reading days, the
---longest-read books and the reader's preferences.
---(一个自然周期的阅读统计：总时长、分桶时长（周/月按天，年按月，全部按年）、阅读天数、
--- 读得最久的书与阅读偏好)
---@param mode "weekly"|"monthly"|"annually"|"overall"
---@param base_time integer|nil start of the period (unix seconds), 0/nil = the current one(周期起点，0 或 nil 为当前周期)
---@param callback fun(ok: boolean, result: table|string)
function M.read_stats(mode, base_time, callback)
  M.call("/readdata/detail", { mode = mode, baseTime = base_time or 0 }, function(ok, data)
    if not ok then
      callback(false, data)
      return
    end
    -- readTimes is keyed by the bucket's start time as a string
    -- (readTimes 以分桶起点时间的字符串为键)
    local buckets = {}
    for key, seconds in pairs(type(data.readTimes) == "table" and data.readTimes or {}) do
      local at = tonumber(key)
      if at then
        buckets[#buckets + 1] = { at = at, seconds = tonumber(seconds) or 0 }
      end
    end
    table.sort(buckets, function(left, right)
      return left.at < right.at
    end)
    local longest = {}
    for _, entry in ipairs(type(data.readLongest) == "table" and data.readLongest or {}) do
      -- audiobook entries carry `albumInfo` instead of `book`, often empty
      -- (听书条目带的是 albumInfo 而不是 book，而且经常是空的)
      local book = type(entry.book) == "table" and entry.book
        or type(entry.albumInfo) == "table" and entry.albumInfo
        or {}
      longest[#longest + 1] = {
        title = type(book.title) == "string" and book.title or (type(book.name) == "string" and book.name or ""),
        audio = entry.book == nil and entry.albumInfo ~= nil,
        author = type(book.author) == "string" and book.author or "",
        seconds = tonumber(entry.readTime) or 0,
        tags = type(entry.tags) == "table" and entry.tags or {},
      }
    end
    local facts = {}
    for _, stat in ipairs(type(data.readStat) == "table" and data.readStat or {}) do
      if type(stat.stat) == "string" and type(stat.counts) == "string" then
        facts[#facts + 1] = { name = stat.stat, value = stat.counts }
      end
    end
    local categories = {}
    for _, category in ipairs(type(data.preferCategory) == "table" and data.preferCategory or {}) do
      categories[#categories + 1] = {
        title = category.categoryTitle or category.parentCategoryTitle or "",
        seconds = tonumber(category.readingTime) or 0,
        books = tonumber(category.readingCount) or 0,
      }
    end
    local prefer_time = nil
    if type(data.preferTime) == "table" and #data.preferTime == 24 then
      prefer_time = {}
      for index, seconds in ipairs(data.preferTime) do
        prefer_time[index] = tonumber(seconds) or 0
      end
    end
    callback(true, {
      mode = mode,
      base_time = tonumber(data.baseTime) or 0,
      total = tonumber(data.totalReadTime) or 0,
      day_average = tonumber(data.dayAverageReadTime),
      read_days = tonumber(data.readDays) or 0,
      compare = tonumber(data.compare),
      listen = tonumber(data.wrListenTime),
      buckets = buckets,
      longest = longest,
      facts = facts,
      categories = categories,
      prefer_time = prefer_time,
      prefer_time_word = type(data.preferTimeWord) == "string" and data.preferTimeWord or nil,
      prefer_category_word = type(data.preferCategoryWord) == "string" and data.preferCategoryWord or nil,
    })
  end)
end

return M
