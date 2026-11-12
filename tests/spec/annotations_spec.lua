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
                pages[#pages + 1] = {
                  review = {
                    reviewId = thought.id,
                    content = thought.content,
                    author = thought.author,
                    range = asked.range,
                  },
                }
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

---Every write the reader makes, asserted by the tests below.
---(阅读器发出的每一次写请求，供下面的用例断言)
local review_calls = {}

local reader_ref = {}
local reader_routes = mock_lib.weread_routes(reader_ref)
-- the reader's own write endpoints, on the same origin as its read endpoints
-- (阅读器自己的写接口，与它的读接口同源)
reader_routes[#reader_routes + 1] = {
  path = "/web/review/add",
  handler = function(_, _, body)
    local payload = vim.json.decode(body or "{}")
    review_calls[#review_calls + 1] = { api_name = "/web/review/add", body = payload }
    return {
      status = 200,
      ctype = "application/json",
      body = vim.json.encode({ reviewId = "241667668_test1", createTime = 1791000000 }),
    }
  end,
}
reader_routes[#reader_routes + 1] = {
  path = "/web/review/delete",
  handler = function(_, _, body)
    review_calls[#review_calls + 1] = { api_name = "/web/review/delete", body = vim.json.decode(body or "{}") }
    return { status = 200, ctype = "application/json", body = '{"succ":1}' }
  end,
}
---Highlights the account holds, as the mock's write endpoints left them.
---(mock 写接口留下的账号划线)
local bookmark_calls = {}
local refuse_bookmarks = false
reader_routes[#reader_routes + 1] = {
  path = "/web/book/addBookmark",
  handler = function(_, _, body)
    local payload = vim.json.decode(body or "{}")
    bookmark_calls[#bookmark_calls + 1] = { api_name = "/web/book/addBookmark", body = payload }
    if refuse_bookmarks then
      return { status = 400, ctype = "text/plain", body = "" }
    end
    return {
      status = 200,
      ctype = "application/json",
      body = vim.json.encode({ bookmarkId = string.format("%s_%s_%s", payload.bookId, payload.chapterUid, payload.range) }),
    }
  end,
}
reader_routes[#reader_routes + 1] = {
  path = "/web/book/removeBookmark",
  handler = function(_, _, body)
    bookmark_calls[#bookmark_calls + 1] = { api_name = "/web/book/removeBookmark", body = vim.json.decode(body or "{}") }
    return { status = 200, ctype = "application/json", body = '{"succ":1}' }
  end,
}
---My notes as the web reader's own list returns them (used by the delete
---fallback for notes written before review ids were stored).
---(Web 阅读器自己的「我的想法」列表，用于删除「开始存 review id 之前」的备注)
local web_my_reviews = {}
reader_routes[#reader_routes + 1] = {
  path = "/web/review/list",
  handler = function()
    return {
      status = 200,
      ctype = "application/json",
      body = vim.json.encode({ reviews = web_my_reviews, totalCount = #web_my_reviews, synckey = 0 }),
    }
  end,
}
local reader_server = mock_lib.start(reader_routes)
reader_ref.url = reader_server.url

local config = require("weread.config")
local http = require("weread.http")
local cache = require("weread.cache")
local auth = require("weread.auth")
local reader = require("weread.reader")
local annotations = require("weread.annotations")
local xhtml = require("weread.xhtml")
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

describe("annotations editing", function()
  ---Find a short sentence of the chapter in the rendered buffer.
  ---(在渲染出的 buffer 里找一段较短的句子)
  ---@param buf integer
  ---@param needle string
  ---@return integer|nil line 1-based
  ---@return integer|nil col 0-based byte offset in the line
  local function locate_in_buffer(buf, needle)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for index, line in ipairs(lines) do
      local from = line:find(needle, 1, true)
      if from then
        return index, from - 1
      end
    end
    return nil, nil
  end

  it("turns a selection into the source range the server would use", function()
    -- The range is what the whole feature rests on: it must be the same
    -- coordinate system WeRead uses, or the highlight lands on the wrong
    -- sentence. The expectation is computed independently, from the raw source.
    -- (range 是整个功能的地基：它必须和微信读书用同一套坐标，否则划线会落到别的句子上。
    --  这里的期望值是用另一套算法从源文独立算出来的)
    local buf = open_chapter()
    -- a sentence the fixtures do not already highlight: a local highlight must be
    -- its own thing, not a merge into a server one
    -- (夹具里没有划线过的句子：本地划线必须是独立的一条，而不是并进服务端那条)
    local sentence = "小标题后的正文。"
    local line, col = locate_in_buffer(buf, sentence)
    truthy(line, "the sentence is on the page")

    local ok, message = annotations.highlight(buf, { line, col }, { line, col + #sentence })
    truthy(ok, message)
    local info = reader.buffer_info(buf)
    local local_list = annotations.local_for(info.book_id, info.chapter_key)
    eq(#local_list, 1, "one local highlight was stored")
    eq(local_list[1].range, range_of(sentence), "and it is the sentence's own range")
    eq(local_list[1].text, sentence, "with the sentence as its text")

    -- drawn like one of mine, and findable by `K`
    local found = annotations.annotations_on_line(buf, line - 1)
    eq(#found >= 1, true, "the highlight is resolved on its line")
    local mine = nil
    for _, entry in ipairs(found) do
      if entry.annotation.range == range_of(sentence) then
        mine = entry.annotation
      end
    end
    truthy(mine, "and it is the one we just drew")
    eq(mine.unsynced, true, "marked as made here")

    -- removing it puts the chapter back the way it was
    -- (取消之后本章回到原样)
    local removed, removed_message = annotations.unhighlight(buf, line - 1)
    truthy(removed, removed_message)
    eq(#annotations.local_for(info.book_id, info.chapter_key), 0, "the store is empty again")
    local groups = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("weread.annotations"), 0, -1, { details = true })) do
      groups[mark[4].hl_group] = true
    end
    eq(groups.WereadMineHighlight, true, "the server highlight is still drawn")
  end)

  it("highlights a whole line at once, indent excluded", function()
    -- `<leader>wh` in normal mode takes the line under the cursor; the
    -- paragraph indent is layout, so it must not end up inside the range.
    -- (普通模式的 `<leader>wh` 取光标所在整行；段落缩进属于排版，不能跑进 range 里)
    local buf = open_chapter()
    local info = reader.buffer_info(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- a plain sentence of the fixture that nothing else highlights, and that is
    -- not an image line (those carry no source runes to map)
    -- (夹具里一段没有被划过的普通文字，也不是图片行——图片行没有可映射的源 rune)
    local target = nil
    for index, line in ipairs(lines) do
      if line:find("小标题后的正文", 1, true) then
        target = { index = index, line = line }
        break
      end
    end
    truthy(target, "a plain prose line is on the page")

    local ok, message = annotations.highlight_line(buf, target.index)
    truthy(ok, message)
    local entry = annotations.local_for(info.book_id, info.chapter_key)[1]
    truthy(entry, "stored")
    local from = tonumber(entry.range:match("^(%d+)"))
    local located = xhtml.locate(cache.read_json(cache.chapter_file(info.book_id, reader.state.catalog.chapters[info.chapter_index], "map.json")), from)
    eq(located.line, target.index - 1, "the range starts on that line")
    local resolved_line = lines[located.line + 1]
    truthy(resolved_line:find("　", 1, true), "the page line is indented")
    falsy(entry.text:find("^　", 1, true), "the stored text is not indented")
    truthy(
      resolved_line:find(entry.text:sub(1, 9), 1, true),
      string.format("and it starts at the text, not the layout: %q in %q", entry.text, resolved_line)
    )
    local removed, removed_message = annotations.unhighlight(buf, target.index - 1)
    truthy(removed, removed_message)
    eq(#annotations.local_for(info.book_id, info.chapter_key), 0, "and the store is clean again")
  end)

  it("refuses a passage the account already highlighted", function()
    -- Highlighting something WeRead already knows about is not a new highlight;
    -- a local copy would be a mark the reader could not remove from here.
    -- (给微信读书已经划过的段落再画一次不是新划线；留一条本地副本会变成在这里删不掉的记号)
    local buf = open_chapter()
    local info = reader.buffer_info(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for index, line in ipairs(lines) do
      local from = line:find(MINE_TEXT, 1, true)
      if from then
        local ok, message = annotations.highlight(buf, { index, from - 1 }, { index, from - 1 + #MINE_TEXT })
        falsy(ok, "refused")
        truthy(message:find("已经划过", 1, true), "and it says why: " .. tostring(message))
        eq(#annotations.local_for(info.book_id, info.chapter_key), 0, "nothing was stored")
        return
      end
    end
    error("the fixture highlight is not on the page")
  end)

  it("refuses an empty selection", function()
    local buf = open_chapter()
    local info = reader.buffer_info(buf)
    local line = 1
    local ok, message = annotations.highlight(buf, { line, 0 }, { line, 0 })
    falsy(ok, "an empty selection cannot be highlighted")
    truthy(message:find("没有选中正文", 1, true), "and it says why: " .. tostring(message))
    eq(#annotations.local_for(info.book_id, info.chapter_key), 0)
  end)

  it("posts a thought through the reader's own write endpoint", function()
    -- Writing is the one thing the Agent API cannot do (it is read only), so
    -- thoughts go to the reader's endpoint with the reader's session. The mock
    -- asserts the payload shape, which is what the live service accepts.
    -- (写是 Agent API 唯一做不到的事（它只读），因此想法走阅读器的端点与阅读器的会话。mock
    --  断言请求体的形状——也就是线上服务接受的那套字段)
    local buf = open_chapter()
    local info = reader.buffer_info(buf)
    local chapter = reader.state.catalog.chapters[info.chapter_index]
    local posted = nil
    annotations.post_thought({
      book_id = info.book_id,
      chapter_uid = tostring(chapter.chapterUid),
      chapter_idx = chapter.chapterIdx,
      range = "503-511",
      content = "写想法测试",
      abstract = "小标题后的正文。",
    }, function(ok, result)
      posted = { ok = ok, result = result }
    end)
    vim.wait(15000, function()
      return posted ~= nil
    end, 50)
    truthy(posted.ok, tostring(posted.result))
    eq(posted.result.reviewId, "241667668_test1", "the review id comes back")

    local request = nil
    for _, call in ipairs(review_calls) do
      request = call
    end
    truthy(request, "the mock saw the write")
    eq(request.api_name, "/web/review/add")
    eq(request.body.range, "503-511", "the whole range, which is what the read side uses")
    eq(request.body.abstract, "小标题后的正文。", "and the passage it hangs on")
    eq(request.body.content, "写想法测试")
    eq(request.body.bookId, BOOK_ID)
    eq(request.body.isPrivate, false)

    -- deleting needs the id, which is why it is kept with the thought
    -- (删除需要 reviewId，因此要随想法一起留着)
    local deleted = nil
    annotations.delete_thought(posted.result.reviewId, { book_id = info.book_id }, function(ok)
      deleted = ok
    end)
    vim.wait(15000, function()
      return deleted ~= nil
    end, 50)
    truthy(deleted, "and the delete call succeeds")
    eq(review_calls[#review_calls].api_name, "/web/review/delete")
  end)

  it("keeps a thought locally when the service refuses it", function()
    -- Someone's writing must never be lost to a failed request.
    -- (写下的内容绝不能因为一次请求失败就丢掉)
    local buf = open_chapter()
    local info = reader.buffer_info(buf)
    -- a thought can be written on a highlight the account owns, so the note has
    -- to create the record it needs
    -- (想法可能写在账号自己的划线上，因此备注要能自己补一条记录)
    annotations.remember_note(buf, "503-511", "离线时写的话", "小标题后的正文。")
    local list = annotations.local_annotations(info.book_id, info.chapter_key)
    local found = nil
    for _, candidate in ipairs(list) do
      if candidate.range == "503-511" then
        found = candidate
      end
    end
    truthy(found, "the record was created")
    eq(found.note, "离线时写的话", "and it carries the note")
    eq(found.text, "小标题后的正文。", "with the passage it hangs on")

    -- and a note on a range the account also highlights survives the merge
    -- (与服务端同 range 时，备注在合并后仍在)
    local merged = annotations.merged(info.book_id, info.chapter_key, {
      { range = "503-511", text = "来自服务端", mine = true, count = 3, thoughts = {} },
    })
    local merged_entry = nil
    for _, candidate in ipairs(merged) do
      if candidate.range == "503-511" then
        merged_entry = candidate
      end
    end
    eq(#merged, 1, "the two entries merged into one")
    eq(merged_entry.note, "离线时写的话", "and the note came along")
    eq(merged_entry.count, 3, "while the account's own data stayed")
    annotations.remove_local(info.book_id, info.chapter_key, "503-511")
  end)

  it("syncs a highlight to the account as a wavy line", function()
    -- What the phone shows is what `/web/book/addBookmark` stored: the style is
    -- the line (2 = wavy) and the reader's own client sends `markText` Base64
    -- encoded — the live endpoint answers 400 to plain text.
    -- (手机上显示的就是 `/web/book/addBookmark` 存下的东西：style 是线型（2 = 波浪线），而
    --  阅读器自己的客户端把 `markText` 做了 Base64 编码——线上接口对明文直接回 400)
    local buf = open_chapter()
    local info = reader.buffer_info(buf)
    bookmark_calls = {}
    local sentence = "小标题后的正文。"
    local line, col = locate_in_buffer(buf, sentence)
    truthy(annotations.highlight(buf, { line, col }, { line, col + #sentence }))
    vim.wait(15000, function()
      return (annotations.local_for(info.book_id, info.chapter_key)[1] or {}).bookmark_id ~= nil
    end, 50)

    local request = bookmark_calls[1]
    truthy(request, "the mock saw the upload")
    eq(request.api_name, "/web/book/addBookmark")
    eq(request.body.style, 2, "wavy, like the app's 波浪线")
    eq(request.body.type, 1)
    eq(request.body.range, range_of(sentence), "the same range the read side uses")
    eq(request.body.bookId, BOOK_ID)
    eq(request.body.chapterUid, 2)
    eq(vim.base64.decode(request.body.markText), sentence, "the passage, Base64 encoded")

    local entry = annotations.local_for(info.book_id, info.chapter_key)[1]
    eq(entry.bookmark_id, BOOK_ID .. "_2_" .. range_of(sentence), "the account's id is kept")
    local synced = nil
    for _, candidate in ipairs(annotations.local_annotations(info.book_id, info.chapter_key)) do
      synced = candidate
    end
    falsy(synced.unsynced, "and it is no longer marked as local only")

    -- removing it here removes it from the account too
    -- (在这里取消，账号里也一起删掉)
    local done = nil
    annotations.unhighlight(buf, line - 1, function(ok, message)
      done = { ok = ok, message = message }
    end)
    vim.wait(15000, function()
      return done ~= nil
    end, 50)
    truthy(done.ok, done.message)
    eq(bookmark_calls[#bookmark_calls].api_name, "/web/book/removeBookmark")
    eq(bookmark_calls[#bookmark_calls].body.bookmarkId, entry.bookmark_id)
    eq(#annotations.local_for(info.book_id, info.chapter_key), 0, "and the local record is gone")
  end)

  it("keeps a highlight here when the account refuses it, and retries later", function()
    local buf = open_chapter()
    local info = reader.buffer_info(buf)
    bookmark_calls = {}
    refuse_bookmarks = true
    local sentence = "小标题后的正文。"
    local line, col = locate_in_buffer(buf, sentence)
    truthy(annotations.highlight(buf, { line, col }, { line, col + #sentence }))
    vim.wait(15000, function()
      return #bookmark_calls >= 1
    end, 50)
    vim.wait(300)
    local entry = annotations.local_for(info.book_id, info.chapter_key)[1]
    truthy(entry, "the highlight stays here")
    eq(entry.bookmark_id, nil, "not synced")

    -- the next time the chapter opens, it goes up
    -- (下次打开本章时补传)
    refuse_bookmarks = false
    annotations.sync_local(buf, { quiet = true })
    vim.wait(15000, function()
      return (annotations.local_for(info.book_id, info.chapter_key)[1] or {}).bookmark_id ~= nil
    end, 50)
    truthy(annotations.local_for(info.book_id, info.chapter_key)[1].bookmark_id, "synced on retry")
    vim.fn.delete(annotations.local_path(info.book_id))
  end)

  it("does not post a highlight the account already has", function()
    local buf = open_chapter()
    local info = reader.buffer_info(buf)
    bookmark_calls = {}
    -- e.g. a local record from before syncing existed, for a range the account
    -- also highlights: adopt the account's id
    -- (比如同步出现之前的本地记录，而账号里同 range 也划过：直接认领账号的 id)
    annotations.add_local(info.book_id, info.chapter_key, MINE_RANGE, MINE_TEXT)
    annotations.sync_local(buf, { quiet = true })
    vim.wait(300)
    eq(#bookmark_calls, 0, "nothing was posted")
    eq(annotations.local_for(info.book_id, info.chapter_key)[1].bookmark_id, "b1", "the account's id was adopted")

    -- and a note-only record (a thought on someone else's highlight) is not one of mine
    -- (只为挂想法补的记录（写在别人划线上）不是我的划线)
    annotations.remember_note(buf, POPULAR_RANGE, "别人的划线上写的", POPULAR_TEXT)
    annotations.sync_local(buf, { quiet = true })
    vim.wait(300)
    eq(#bookmark_calls, 0, "still nothing posted")
    vim.fn.delete(annotations.local_path(info.book_id))
  end)

  it("forgets a synced highlight removed on the phone", function()
    local info_book, key = BOOK_ID, "0002"
    vim.fn.delete(annotations.local_path(info_book))
    annotations.add_local(info_book, key, "10-20", "已同步")
    annotations.mark_synced(info_book, key, "10-20", "x_2_10-20")
    annotations.add_local(info_book, key, "30-40", "未同步")
    local removed = annotations.prune_synced(info_book, key, {}, os.time() + 1)
    eq(removed, 1, "the synced one the account no longer has")
    local left = annotations.local_for(info_book, key)
    eq(#left, 1)
    eq(left[1].range, "30-40", "the unsynced one stays to be uploaded")
    -- synced after the fetch started: the list cannot know it yet
    -- (拉取开始之后才同步的：那份列表还不可能有它)
    annotations.mark_synced(info_book, key, "30-40", "x_2_30-40")
    eq(annotations.prune_synced(info_book, key, {}, os.time() - 5), 0, "kept")
    vim.fn.delete(annotations.local_path(info_book))
  end)

  it("reads a highlight's text from the source, not the wrapped page", function()
    local buf = open_chapter()
    local info = reader.buffer_info(buf)
    eq(annotations.source_text(info.book_id, info.chapter_key, MINE_RANGE), MINE_TEXT)
  end)

  it("keeps local highlights across a re-render at another page width", function()
    local buf = open_chapter()
    local sentence = "一、小标题"
    local line, col = locate_in_buffer(buf, sentence)
    truthy(annotations.highlight(buf, { line, col }, { line, col + #sentence }))
    local info = reader.buffer_info(buf)

    -- another page width, laid out again from the cached source
    -- (换一个版心宽度，用缓存里的源重新排版)
    reader.set_page_width(40)
    local chapter = reader.state.catalog.chapters[info.chapter_index]
    vim.fn.delete(cache.chapter_file(info.book_id, chapter, "md"))
    await_async(function(done)
      reader.open_index(info.chapter_index, { line = line })
      vim.defer_fn(done, 400)
    end, 20000)

    local map = cache.read_json(cache.chapter_file(info.book_id, chapter, "map.json"))
    eq(map.page_width, 40, "re-laid out")
    eq(#annotations.local_for(info.book_id, info.chapter_key), 1, "the highlight is still remembered")
    local list = annotations.merged(info.book_id, info.chapter_key, {})
    local located = xhtml.locate(map, annotations.parse_range(list[1].range))
    truthy(located, "and it still resolves to a line of the new layout")
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    truthy(
      (lines[located.line + 1] or ""):find(sentence, 1, true),
      "on the line that still holds the sentence: " .. tostring(lines[located.line + 1])
    )
    reader.set_page_width(nil)
    vim.fn.delete(annotations.local_path(info.book_id))
  end)
end)

describe("annotations.compose_thought", function()
  ---The composer's window: the chapter has a pager cover float of its own, so
  ---"the first float" is not the composer.
  ---(输入框自己的窗口：章节本身有一个分页器遮罩浮窗，所以「第一个浮窗」并不是输入框)
  ---@return integer|nil win
  local function composer_win()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local candidate = vim.api.nvim_win_get_buf(win)
      if vim.bo[candidate].filetype == "weread-thought" then
        return win
      end
    end
    return nil
  end

  ---@return integer|nil buf the composer's buffer(输入框 buffer)
  local function composer_buf()
    local win = composer_win()
    return win and vim.api.nvim_win_get_buf(win) or nil
  end

  local function close_composer()
    local win = composer_win()
    if win then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  ---The Lua callback of a buffer-local mapping.
  ---(某个 buffer 局部映射的 Lua 回调)
  ---@param buf integer
  ---@param mode string
  ---@param lhs string
  ---@return function|nil
  local function mapped(buf, mode, lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
      if map.lhs == lhs then
        return map.callback
      end
    end
    return nil
  end

  it("publishes on Enter and reaches the reader's write endpoint", function()
    -- The reported bug: writing a thought and pressing Enter did nothing, so
    -- nothing ever reached the service. Enter is now the submit key.
    -- (实测反馈的问题：写完想法按回车没反应，于是什么都没发出去。现在回车就是发表键)
    local buf = open_chapter()
    local line = line_of(buf, MINE_TEXT)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    local entry = nil
    for _, candidate in ipairs(annotations.annotations_on_line(buf, line - 1)) do
      if candidate.annotation.range == MINE_RANGE then
        entry = candidate
      end
    end
    truthy(entry, "the fixture highlight is under the cursor")

    review_calls = {}
    -- The refetch that follows a successful post is another test's subject; here
    -- it would leak three gateway calls into the next case.
    -- (发表成功后的重新拉取是另一个用例的主题；留在这里会把三次网关调用漏给下一个用例)
    local refresh_after_write = annotations.refresh_after_write
    annotations.refresh_after_write = function() end
    annotations.compose_thought(buf, entry.annotation.range, entry.annotation.text)
    local compose = composer_buf()
    truthy(compose, "the composer opened")
    vim.api.nvim_buf_set_lines(compose, 0, -1, false, { "回车写下的想法" })

    local enter = mapped(compose, "i", "<CR>")
    truthy(enter, "insert mode maps Enter")
    truthy(mapped(compose, "n", "<CR>"), "normal mode maps Enter too")
    enter()

    -- Wait for the response to be processed, not just for the request to be
    -- sent: the local copy is written in the HTTP callback.
    -- (等响应处理完，而不是只等请求发出去：本地副本是在 HTTP 回调里写的)
    local info = reader.buffer_info(buf)
    local function local_note()
      for _, record in ipairs(annotations.local_for(info.book_id, info.chapter_key)) do
        if record.range == entry.annotation.range and record.note ~= nil then
          return record
        end
      end
      return nil
    end
    vim.wait(20000, function()
      return local_note() ~= nil
    end, 50)
    annotations.refresh_after_write = refresh_after_write
    truthy(#review_calls > 0, "the thought reached the service")
    eq(review_calls[1].api_name, "/web/review/add")
    eq(review_calls[1].body.content, "回车写下的想法")
    eq(review_calls[1].body.abstract, MINE_TEXT, "the passage comes from the source, not the laid-out page")
    eq(composer_win(), nil, "the composer closed after posting")

    local stored = local_note()
    truthy(stored, "a local copy is kept")
    eq(stored.note, "回车写下的想法")
    eq(stored.note_synced, true, "and it is marked as already on the server")
    eq(stored.note_review_id, "241667668_test1", "the review id is kept so it can be deleted")
    vim.fn.delete(annotations.local_path(info.book_id))
  end)

  it("keeps a newline key that does not submit", function()
    -- Multi-paragraph thoughts still need a line break; the newline key must be
    -- a literal <CR>, never another trip through the submit mapping.
    -- (多段想法仍然需要换行；换行键必须是字面的 <CR>，不能再走一遍发表映射)
    local buf = open_chapter()
    local line = line_of(buf, MINE_TEXT)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    local entry = annotations.entry_at(buf, line - 1)
    truthy(entry)
    annotations.compose_thought(buf, entry.annotation.range, entry.annotation.text)
    local compose = composer_buf()
    truthy(compose, "the composer opened")

    local newline = nil
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(compose, "i")) do
      if map.lhs == "<C-J>" then
        newline = map
      end
    end
    truthy(newline, "Ctrl-J is mapped")
    eq(newline.rhs, "<CR>")
    eq(newline.noremap, 1, "not remapped back into the submit mapping")
    close_composer()
  end)

  it("asks before throwing away unsent text", function()
    -- Closing must not silently drop what the reader typed; the prompt keeps
    -- "continue editing" as the default.
    -- (关闭时不能静默丢掉读者写下的内容；确认框把「继续编辑」设为默认)
    local buf = open_chapter()
    local line = line_of(buf, MINE_TEXT)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    local entry = annotations.entry_at(buf, line - 1)
    truthy(entry)
    annotations.compose_thought(buf, entry.annotation.range, entry.annotation.text)
    local compose = composer_buf()
    truthy(compose)
    local esc = mapped(compose, "n", "<Esc>")
    truthy(esc, "Esc is ours, not the float's silent close")

    local asked = nil
    local confirm = vim.fn.confirm
    vim.fn.confirm = function(message, choices, default)
      asked = { message = message, choices = choices, default = default }
      return 1 -- continue editing(继续编辑)
    end
    vim.api.nvim_buf_set_lines(compose, 0, -1, false, { "还没发表" })
    esc()
    vim.fn.confirm = confirm
    truthy(asked, "the reader was asked")
    truthy(asked.choices:find("继续编辑", 1, true) ~= nil)
    eq(asked.default, 1, "continue editing is the default")
    truthy(composer_win(), "the composer is still open")
    close_composer()
  end)
end)

describe("annotations.delete_thought_at", function()
  -- A book/chapter of their own: later tests open BOOK_ID chapter 0002 and must
  -- not inherit a hand-made buffer or cache from these cases.
  -- (用自己的书/章节：后面的用例会打开 BOOK_ID 的 0002 章，不能继承这里手搓的
  --  buffer 或缓存)
  local NOTE_BOOK = BOOK_ID .. "-notes"
  local NOTE_CHAPTER = "0099"

  ---A chapter buffer with just enough state for a write: no network, no map.
  ---(只带写操作所需状态、不联网也没有排版地图的章节 buffer)
  ---@return integer buf
  local function write_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "正文" })
    vim.api.nvim_win_set_buf(0, buf)
    vim.b[buf].weread = { book_id = NOTE_BOOK, chapter_key = NOTE_CHAPTER, chapter_index = 1 }
    reader.state.catalog = { chapters = { { chapterUid = 2, chapterIdx = 1 } } }
    reader.state.book = { book_id = NOTE_BOOK, version = 1 }
    return buf
  end

  local function clear_local()
    vim.fn.delete(annotations.local_path(NOTE_BOOK))
  end

  local function remove_buf(buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  it("deletes a synced thought using the id kept with the local note", function()
    -- A thought written moments ago is not in /book/readreviews yet; the local
    -- record carries the review id returned by /web/review/add, and that is
    -- enough to delete it.
    -- (刚写完的想法还不在 /book/readreviews 里；本地记录带着 /web/review/add 返回的
    --  review id，用它就足以删除)
    local buf = write_buf()
    clear_local()
    annotations.remember_note(buf, MINE_RANGE, "刚写完的想法", MINE_TEXT, true, "rv-local-1")
    truthy(annotations.my_thought_for(buf, MINE_RANGE), "the local record is visible to the delete path")

    review_calls = {}
    local done = nil
    annotations.delete_thought_at(buf, MINE_RANGE, function(ok, message)
      done = { ok = ok, message = message }
    end)
    vim.wait(20000, function()
      return done ~= nil
    end, 50)
    truthy(done and done.ok, done and done.message)
    eq(review_calls[1].api_name, "/web/review/delete")
    eq(review_calls[1].body.reviewId, "rv-local-1")
    eq(review_calls[1].body.bookId, NOTE_BOOK)

    falsy(annotations.my_thought_for(buf, MINE_RANGE), "and nothing is left to delete")
    eq(#annotations.local_for(NOTE_BOOK, NOTE_CHAPTER), 0, "the note-only local record is gone")
    clear_local()
    remove_buf(buf)
  end)

  it("deletes an unsynced local thought without calling the server", function()
    local buf = write_buf()
    clear_local()
    annotations.remember_note(buf, MINE_RANGE, "还没发出去的想法", MINE_TEXT, false, nil)
    review_calls = {}

    local done = nil
    annotations.delete_thought_at(buf, MINE_RANGE, function(ok, message)
      done = { ok = ok, message = message }
    end)
    vim.wait(1000, function()
      return done ~= nil
    end, 20)
    truthy(done and done.ok, done and done.message)
    eq(#review_calls, 0, "there is nothing on the server to delete")
    falsy(annotations.my_thought_for(buf, MINE_RANGE), "the local thought is gone")
    eq(#annotations.local_for(NOTE_BOOK, NOTE_CHAPTER), 0, "and its record went with it")
    clear_local()
    remove_buf(buf)
  end)

  it("finds the id of an older synced note from the web list", function()
    -- Notes written before the review id was stored carry none; the web
    -- reader's own "my notes" list still knows them, so look the id up there.
    -- (在开始存 review id 之前写的备注没有 id；Web 阅读器自己的「我的想法」列表
    --  还知道它，因此去那里查)
    local range = "900-920"
    web_my_reviews = {
      {
        review = {
          reviewId = "vid_old",
          content = "旧版本写的想法",
          range = range,
          chapterUid = 2,
          createTime = 1,
          author = { name = "我", userVid = "vid" },
        },
      },
    }
    local buf = write_buf()
    clear_local()
    annotations.remember_note(buf, range, "旧版本写的想法", "旧原文", true, nil)
    review_calls = {}
    local done = nil
    annotations.delete_thought_at(buf, range, function(ok, message)
      done = { ok = ok, message = message }
    end)
    vim.wait(20000, function()
      return done ~= nil
    end, 50)
    truthy(done and done.ok, done and done.message)
    local delete_call = review_calls[#review_calls]
    truthy(delete_call, "the service was asked to delete it")
    eq(delete_call.api_name, "/web/review/delete")
    eq(delete_call.body.reviewId, "vid_old", "the id came from the read-side lookup")
    falsy(annotations.my_thought_for(buf, range), "the local note is gone")
    clear_local()
    remove_buf(buf)
    web_my_reviews = {}
  end)

  it("removes the deleted thought from the chapter's lists", function()
    local buf = write_buf()
    clear_local()
    -- A server thought of mine, as a refetch would have returned it.
    -- (一次重新拉取会返回的那种「我的想法」)
    local annotation = {
      range = MINE_RANGE,
      text = MINE_TEXT,
      mine = true,
      count = 0,
      thought_total = 1,
      thoughts = { { id = "vid_r1", author_vid = "vid", content = "服务端里的想法", time = 1 } },
    }
    vim.b[buf].weread_server_annotations = { annotation }
    local path = string.format("%s/%s.json", cache.annotations_dir(NOTE_BOOK), NOTE_CHAPTER)
    cache.write_json(path, { annotation })
    annotations.remember_note(buf, MINE_RANGE, "服务端里的想法", MINE_TEXT, true, "vid_r1")

    review_calls = {}
    local done = nil
    annotations.delete_thought_at(buf, MINE_RANGE, function(ok, message)
      done = { ok = ok, message = message }
    end)
    vim.wait(20000, function()
      return done ~= nil
    end, 50)
    truthy(done and done.ok, done and done.message)
    -- Buffer variables come back as copies, so read the current list instead of
    -- the table this test put there.
    -- (buffer 变量读出来是副本，因此看当前列表，而不是测试放进去的那张表)
    local server_after = nil
    for _, candidate in ipairs(vim.b[buf].weread_server_annotations or {}) do
      if candidate.range == MINE_RANGE then
        server_after = candidate
      end
    end
    truthy(server_after, "the highlight is still in the chapter's list")
    eq(#(server_after.thoughts or {}), 0, "the card is gone from the buffer's list")
    eq(server_after.thought_total, 0, "and the count followed")

    local cached = cache.read_json(path)
    local cached_annotation = nil
    for _, candidate in ipairs(cached or {}) do
      if candidate.range == MINE_RANGE then
        cached_annotation = candidate
      end
    end
    truthy(cached_annotation, "the highlight is still cached")
    eq(#(cached_annotation.thoughts or {}), 0, "and the cached list lost the thought too")
    clear_local()
    vim.fn.delete(path)
    remove_buf(buf)
  end)
end)

describe("annotations rendering", function()
  it("underlines the highlighted text itself", function()
    local buf = open_chapter()
    local resolved = vim.b[buf].weread_annotations
    eq(#resolved, 2, "both highlights resolved")

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local namespace = vim.api.nvim_create_namespace("weread.annotations")
    local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
    truthy(#marks >= 2, "the underline is drawn per line of the range")

    -- The contract is that the highlighted text is *inside* the marked columns:
    -- the range is resolved through a paragraph-sized segment, so the mark can
    -- cover more than the highlight, never less.
    -- (约定是划线文本落在被标记的列区间**之内**：range 是通过段落级区间解析的，因此
    --  标记可能比划线宽，但绝不会更窄)
    for _, case in ipairs({
      { resolved[1], MINE_TEXT },
      { resolved[2], POPULAR_TEXT },
    }) do
      local entry, needle = case[1], case[2]
      local marked = {}
      for _, mark in ipairs(marks) do
        local row, col, details = mark[2], mark[3], mark[4]
        if row == entry.line and details.hl_group then
          local text = lines[row + 1] or ""
          marked[#marked + 1] = text:sub(col + 1, details.end_col or #text)
        end
      end
      local joined = table.concat(marked, "")
      truthy(
        joined:find(needle, 1, true),
        string.format("line %d should underline %q, got %q", entry.line, needle, joined)
      )
    end
  end)

  it("marks my highlights and popular ones differently", function()
    local buf = open_chapter()
    local namespace = vim.api.nvim_create_namespace("weread.annotations")
    local groups = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
      groups[mark[4].hl_group] = true
    end
    eq(groups.WereadMineHighlight, true)
    truthy(groups.WereadPopularHighlight or groups.WereadPopularWarm or groups.WereadPopularHot, "a popular highlight is drawn")
  end)

  it("grades popular highlights by heat within the chapter", function()
    local annotations = require("weread.annotations")
    eq(annotations.heat(100, 100), 3)
    eq(annotations.heat(40, 100), 2)
    eq(annotations.heat(10, 100), 1)
    eq(annotations.heat(0, 100), 1)
    eq(annotations.heat(5, 0), 1)
    eq(annotations.heat_group(3), "WereadPopularHot")
    eq(annotations.heat_group(2), "WereadPopularWarm")
    eq(annotations.heat_group(1), "WereadPopularHighlight")
  end)

  it("puts the marker back at the end of the line when labels are on", function()
    local config = require("weread.config")
    local opts = config.get()
    opts.annotations = opts.annotations or {}
    opts.annotations.label = true
    local buf = open_chapter()
    local namespace = vim.api.nvim_create_namespace("weread.annotations")
    local labels = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
      if mark[4].virt_text then
        labels[#labels + 1] = mark[4].virt_text[1][1]
      end
    end
    eq(#labels, 2, "one marker per highlight")
    truthy(labels[1]:find("▎", 1, true), "got: " .. table.concat(labels, " | "))
    opts.annotations.label = nil
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

describe("annotations popups with real shaped data", function()
  ---A thought exactly as the service returns it: several paragraphs in one
  ---string, plus an author that is a plain name.
  ---(与服务端返回完全一致的想法：一个字符串里含多个自然段，作者是普通名字)
  local MULTI_PARAGRAPH = "上次研究这个，还是2006年了。在机房度过的无数个日日夜夜。。。\n\n"
    .. "GNU=GNU's Not Unix，强调免费使用\n\nGNU工具链包括多个关键组件。"

  ---@param annotations table[]
  ---@return integer buf
  local function chapter_with(annotations)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "第一行", "第二行" })
    vim.b[buf].weread = { book_id = BOOK_ID, chapter_key = "0002", chapter_index = 2, chapter_uid = "2" }
    vim.api.nvim_win_set_buf(0, buf)
    vim.b[buf].weread_annotations = annotations
    return buf
  end

  it("lays out a multi paragraph thought in the summary", function()
    local buf = chapter_with({
      {
        line = 1,
        annotation = {
          range = "10-20",
          text = "Linux系统可划分为以下4部分。",
          mine = false,
          popular = true,
          count = 44,
          thoughts = { { author = "老鱼", time = 1749283552, content = MULTI_PARAGRAPH } },
        },
      },
    })

    local ok, err = pcall(annotations.show_chapter_summary)
    truthy(ok, "the summary must not raise: " .. tostring(err))

    local lines = float_lines()
    truthy(#lines > 0, "the popup opened")
    local text = table.concat(lines, "\n")
    truthy(text:find("44人划线", 1, true), "the highlight is listed")
    truthy(text:find("想法 1", 1, true), "the counts line accounts for the single thought")
    truthy(text:find("老鱼：上次研究这个", 1, true), "the first paragraph starts the entry")
    truthy(text:find("GNU工具链包括多个关键组件。", 1, true), "later paragraphs are kept")
    falsy(text:find("\n\nGNU工具链", 1, true), "and none of them arrive glued together")
    -- continuation lines are indented under their author
    -- (续行缩进在作者名下)
    local indented = false
    for _, line in ipairs(lines) do
      if line:find("^        GNU", 1) then
        indented = true
      end
    end
    truthy(indented, "continuation lines are indented")

    close_float()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("caps the thoughts per highlight and says how many are left", function()
    local many = {}
    for index = 1, 7 do
      many[#many + 1] = { author = "读者" .. index, content = "想法" .. index }
    end
    local buf = chapter_with({
      {
        line = 0,
        annotation = { range = "10-20", text = "被划得很多的一句", mine = false, popular = true, count = 30, thoughts = many },
      },
    })

    annotations.show_chapter_summary()
    local text = table.concat(float_lines(), "\n")
    truthy(text:find("读者1", 1, true), "the first thoughts are listed")
    truthy(text:find("读者3", 1, true))
    falsy(text:find("读者4", 1, true), "later ones are left to the K popup")
    truthy(text:find("另有 4 条想法", 1, true), "and the count is honest: " .. text:sub(1, 200))

    close_float()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("works on the chapter buffer even when a popup holds the focus", function()
    local buf = chapter_with({
      {
        line = 0,
        annotation = { range = "10-20", text = "第一行划线", mine = true, popular = false, count = 0, thoughts = {} },
      },
    })

    -- open a popup first: the current buffer is now the float
    -- (先打开一个弹窗：当前 buffer 变成浮窗)
    annotations.show_chapter_summary()
    truthy(current_float(), "a popup is open")
    eq(vim.api.nvim_get_current_buf() == buf, false, "the float holds the focus")

    -- the summary must still find the chapter, not the float
    -- (汇总仍应找到章节 buffer，而不是浮窗)
    local ok, err = pcall(annotations.show_chapter_summary)
    truthy(ok, tostring(err))
    truthy(table.concat(float_lines(), "\n"):find("我的划线", 1, true), "the chapter's highlights are shown")

    close_float()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("explains itself when used outside a chapter", function()
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, plain)

    local captured = {}
    local original = vim.notify
    vim.notify = function(message)
      captured[#captured + 1] = message
    end
    annotations.show_thoughts_at_cursor()
    vim.notify = original

    truthy(#captured > 0)
    truthy(captured[1]:find("章节 buffer", 1, true) ~= nil, "got: " .. tostring(captured[1]))
    vim.api.nvim_buf_delete(plain, { force = true })
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
