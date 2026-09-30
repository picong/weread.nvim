--[[
Tests for weread.annotations.

The interesting parts are the range -> markdown mapping (a highlight is only a
pair of rune offsets over the raw XHTML) and the merging of the three sources:
my highlights, community highlights and the thoughts attached to either.
(annotations 单测重点：range → markdown 的定位映射，以及三个数据源（我的划线、
 热门划线、划线下的想法）的归并)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

local tmpdir = "/tmp/weread-test-annotations"
vim.fn.delete(tmpdir, "rf")
vim.fn.mkdir(tmpdir, "p")

local CHAPTER_XHTML = mock_lib.shards().xhtml.plain

---Rune offset of a needle in the raw chapter, via nvim's own UTF machinery.
---(用 nvim 自身的 UTF 工具算子串的 rune 偏移)
---@param needle string
---@return string range "from-to"
local function range_of(needle)
  local byte_start = assert(CHAPTER_XHTML:find(needle, 1, true), "needle not found: " .. needle)
  local from = select(1, vim.str_utfindex(CHAPTER_XHTML, byte_start - 1))
  local runes = select(1, vim.str_utfindex(needle))
  return string.format("%d-%d", from, from + runes)
end

local MINE_TEXT = "汪淼把车停在楼下，抬头看天。"
local POPULAR_TEXT = "他想起叶文洁说过的那句话："
local MINE_RANGE = range_of(MINE_TEXT)
local POPULAR_RANGE = range_of(POPULAR_TEXT)

local THOUGHTS = {
  [MINE_RANGE] = {
    { content = "这段让我想起第一次读三体的晚上", author = { name = "李明" } },
    { content = "很克制的白描", author = { name = "王芳" } },
  },
  [POPULAR_RANGE] = {
    { content = "全书的题眼", author = { name = "张三" } },
  },
}

local gateway_calls = {}
local gateway_ref = {}
local gateway_server = mock_lib.start({
  {
    path = "/api/agent/gateway",
    handler = function(_, _, body, headers)
      local request = vim.json.decode(body)
      gateway_calls[#gateway_calls + 1] = request
      if not headers:find("Bearer wrk%-test") then
        return { status = 401, ctype = "application/json", body = '{"errcode":-2010,"errmsg":"用户不存在"}' }
      end
      if request.api_name == "/book/bookmarklist" then
        local updated = {
          { bookmarkId = "b1", chapterUid = 2, range = MINE_RANGE, markText = MINE_TEXT, createTime = 1780000000, type = 1 },
          -- a highlight from another chapter must not leak into this one
          -- (别的章节的划线不能混进来)
          { bookmarkId = "b2", chapterUid = 119, range = "10-20", markText = "别的章" },
        }
        return { status = 200, ctype = "application/json", body = vim.json.encode({ updated = updated }) }
      end
      if request.api_name == "/book/bestbookmarks" then
        local items = {
          -- same range as my highlight: must merge, not duplicate
          -- (与我的划线同 range：应合并而不是重复)
          { bookmarkId = "p1", chapterUid = 2, range = MINE_RANGE, markText = MINE_TEXT, totalCount = 5 },
          { bookmarkId = "p2", chapterUid = 2, range = POPULAR_RANGE, markText = POPULAR_TEXT, totalCount = 3 },
        }
        return { status = 200, ctype = "application/json", body = vim.json.encode({ items = items }) }
      end
      if request.api_name == "/book/readreviews" then
        local reviews = {}
        for _, asked in ipairs(request.reviews or {}) do
          reviews[#reviews + 1] = {
            range = asked.range,
            totalCount = #(THOUGHTS[asked.range] or {}),
            pageReviews = (function()
              local pages = {}
              for _, thought in ipairs(THOUGHTS[asked.range] or {}) do
                pages[#pages + 1] = { review = { content = thought.content, author = thought.author, range = asked.range } }
              end
              return pages
            end)(),
          }
        end
        return { status = 200, ctype = "application/json", body = vim.json.encode({ reviews = reviews }) }
      end
      return { status = 404, ctype = "text/plain", body = "unknown " .. tostring(request.api_name) }
    end,
  },
})
gateway_ref.url = gateway_server.url

local reader_ref = {}
local reader_server = mock_lib.start(mock_lib.weread_routes(reader_ref))
reader_ref.url = reader_server.url

local config = require("weread.config")
local http = require("weread.http")
local cache = require("weread.cache")
local auth = require("weread.auth")
local reader = require("weread.reader")
local annotations = require("weread.annotations")
local log = require("weread.log")

config.setup({
  data_dir = tmpdir,
  base_url = reader_server.url,
  gateway_url = gateway_server.url,
  proxy = "direct",
  keymaps = false,
  sync_interval = 0,
})
config.ensure_dirs()
http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 8, retries = 0, proxy = "direct" })
log.setup({ debug = true, path = config.path("weread.log") })
auth.save_credentials({
  version = 1,
  account = { name = "测试账号", user_vid = "vid" },
  api_key = "wrk-test-key",
  cookies = { wr_vid = "vid", wr_skey = "skey", wr_ql = "0", wr_rt = "rt" },
})

local BOOK_ID = "43208843"
local unpack_values = table.unpack or unpack

local function await_async(runner, timeout)
  local captured
  local done = false
  runner(function(...)
    captured = { n = select("#", ...), ... }
    done = true
  end)
  vim.wait(timeout or 20000, function()
    return done
  end, 20)
  if not captured then
    error("timed out waiting for the callback")
  end
  return unpack_values(captured, 1, captured.n)
end

---@return integer buf
local function open_chapter()
  await_async(function(cb)
    reader.load_book(BOOK_ID, cb)
  end)
  reader.open_index(2, {})
  vim.wait(20000, function()
    return reader.buffer_info() ~= nil
  end, 50)
  local buf = vim.api.nvim_get_current_buf()
  vim.wait(20000, function()
    return #(vim.b[buf].weread_annotations or {}) > 0
  end, 100)
  return buf
end

---@return table|nil win
local function current_float()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      return win
    end
  end
  return nil
end

---@return string[]
local function float_lines()
  local win = current_float()
  if not win then
    return {}
  end
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end


---Line number (1-based) holding a needle, so layout changes cannot break a test.
---(包含某段文字的行号，1 基；避免版式调整把测试弄坏)
---@param buf integer
---@param needle string
---@return integer
local function line_of(buf, needle)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for index, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return index
    end
  end
  error("needle not found: " .. needle)
end

local function close_float()
  local win = current_float()
  if win then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

describe("annotations.parse_range", function()
  it("parses the documented range format", function()
    local from, to = annotations.parse_range("383-415")
    eq(from, 383)
    eq(to, 415)
    eq(annotations.parse_range("nonsense"), nil)
    eq(annotations.parse_range(nil), nil)
  end)
end)

describe("annotations.load", function()
  it("merges my highlights, community highlights and thoughts", function()
    local chapter = { chapterUid = 2, chapterIdx = 2, title = "第 3 章" }
    local ok, loaded = await_async(function(cb)
      annotations.load(BOOK_ID, chapter, "0002", cb)
    end)
    truthy(ok, tostring(loaded))
    eq(#loaded, 2, "one merged entry plus one community-only entry")

    local by_range = {}
    for _, entry in ipairs(loaded) do
      by_range[entry.range] = entry
    end

    local merged = by_range[MINE_RANGE]
    truthy(merged, "the overlapping highlight merged")
    eq(merged.mine, true)
    eq(merged.popular, true)
    eq(merged.count, 5, "the community count survives the merge")
    eq(#merged.thoughts, 2, "thoughts attached")
    eq(merged.thoughts[1].author, "李明")

    local popular = by_range[POPULAR_RANGE]
    eq(popular.mine, false)
    eq(popular.count, 3)
    eq(#popular.thoughts, 1)

    -- ordering follows the reading order
    -- (顺序按阅读顺序)
    truthy(loaded[1].range == MINE_RANGE)
    truthy(loaded[2].range == POPULAR_RANGE)
  end)

  it("caches the result and reads it back", function()
    local annotations_path = string.format("%s/0002.json", cache.annotations_dir(BOOK_ID))
    eq(vim.fn.filereadable(annotations_path), 1, "cached to disk")
    local cached = cache.read_json(annotations_path)
    eq(#cached, 2)
  end)

  it("batches the thought requests instead of sending one per range", function()
    gateway_calls = {}
    local chapter = { chapterUid = 2, chapterIdx = 2, title = "第 3 章" }
    await_async(function(cb)
      annotations.load(BOOK_ID, chapter, "0002", cb)
    end)
    local thought_calls = 0
    for _, call in ipairs(gateway_calls) do
      if call.api_name == "/book/readreviews" then
        thought_calls = thought_calls + 1
        truthy(#call.reviews <= 10, "at most ten ranges per request")
      end
    end
    eq(thought_calls, 1, "two ranges fit in one batch")
  end)
end)

describe("annotations.label", function()
  it("describes each highlight kind", function()
    eq(annotations.label({ mine = true, count = 0, thoughts = {} }), "▎我的划线")
    eq(annotations.label({ mine = true, count = 0, thoughts = { {} } }), "▎我的划线 · 1想法")
    eq(annotations.label({ popular = true, count = 3, thoughts = {} }), "▎3人划线")
    eq(annotations.label({ mine = true, popular = true, count = 5, thoughts = {} }), "▎我的划线 · 5人")
  end)
end)

describe("annotations rendering", function()
  it("marks the right lines in the chapter buffer", function()
    local buf = open_chapter()
    local resolved = vim.b[buf].weread_annotations
    eq(#resolved, 2, "both highlights resolved")

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- The contract is "the highlighted text lives on that line", not "the line
    -- is exactly the highlighted text": a range that ends mid paragraph snaps
    -- outward to the text run that contains it.
    -- (约定是「划线文本落在那一行」，而不是「该行恰好等于划线文本」：段落中间的
    --  range 会向外收敛到包含它的文本段)
    for _, case in ipairs({
      { resolved[1], MINE_TEXT },
      { resolved[2], POPULAR_TEXT },
    }) do
      local line = lines[case[1].line + 1]
      truthy(
        line and line:find(case[2], 1, true),
        string.format("line %d should contain %q, got %q", case[1].line, case[2], tostring(line))
      )
    end

    local namespace = vim.api.nvim_create_namespace("weread.annotations")
    local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
    eq(#marks, 2, "two line-end markers")
    local labels = {}
    for _, mark in ipairs(marks) do
      labels[#labels + 1] = mark[4].virt_text[1][1]
    end
    table.sort(labels)
    truthy(labels[1]:find("▎", 1, true), "got: " .. table.concat(labels, " | "))
  end)

  it("renders from cache without hitting the gateway again", function()
    gateway_calls = {}
    local buf = open_chapter()
    vim.wait(1000, function()
      return false
    end, 50)
    eq(#gateway_calls, 0, "no gateway traffic for a cached chapter")
    eq(#(vim.b[buf].weread_annotations or {}), 2)
  end)
end)

describe("annotations popups", function()
  it("shows the thoughts under the cursor", function()
    local buf = open_chapter()
    local resolved = vim.b[buf].weread_annotations
    vim.api.nvim_win_set_cursor(0, { resolved[1].line + 1, 0 })

    annotations.show_thoughts_at_cursor()
    local lines = float_lines()
    truthy(#lines > 0, "the popup opened")
    local text = table.concat(lines, "\n")
    truthy(text:find("李明", 1, true), "first author")
    truthy(text:find("这段让我想起第一次读三体的晚上", 1, true), "first thought")
    truthy(text:find("王芳", 1, true), "second author")
    close_float()
  end)

  it("says so when there is no highlight nearby", function()
    local buf = open_chapter()
    -- the last line is far from any highlight in the fixture
    -- (夹具里最后一行离任何划线都远)
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
    local captured = {}
    local original = vim.notify
    vim.notify = function(message)
      captured[#captured + 1] = message
    end
    annotations.show_thoughts_at_cursor()
    vim.notify = original
    truthy(#captured > 0)
    truthy(captured[1]:find("没有划线", 1, true) ~= nil, "got: " .. tostring(captured[1]))
  end)

  it("summarizes the chapter", function()
    open_chapter()
    annotations.show_chapter_summary()
    local lines = float_lines()
    local text = table.concat(lines, "\n")
    truthy(text:find("共 2 条", 1, true), "the counts line: " .. (lines[1] or ""))
    truthy(text:find("我的 1", 1, true), "one of mine")
    truthy(text:find("热门 2", 1, true), "two community highlights")
    truthy(text:find("想法 3", 1, true), "three thoughts in total")
    truthy(text:find(POPULAR_TEXT, 1, true), "the popular text is listed")
    close_float()
  end)
end)

describe("annotations.refresh", function()
  it("refetches when asked", function()
    open_chapter()
    gateway_calls = {}
    annotations.refresh(true)
    vim.wait(20000, function()
      return #gateway_calls >= 3
    end, 100)
    truthy(#gateway_calls >= 3, "bookmarklist + bestbookmarks + readreviews")
  end)
end)
