--[[
Tests for weread.annotations_sync: the web reader's write endpoints and what
happens when the service refuses them, plus callbacks that arrive after the
buffer they were started for is gone.
(annotations_sync 的测试：Web 阅读器的写接口，服务端拒绝时会怎样，以及回调到来时
 当初发起请求的 buffer 已经不在了)

The mock is switchable per endpoint, so each case picks the answer it needs:
a normal reply, an `errCode`, a bare HTTP 400, or text that is not JSON.
(mock 按端点可切换，每个用例选自己需要的回答：正常、`errCode`、纯 HTTP 400，或不是 JSON 的文本)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

---How each endpoint answers next: "ok", "err", "http400", "garbage" or "empty".
---(各端点接下来怎么回答)
local mode = {}
local seen = {}

local function answer(endpoint, ok_body)
  return function(_, _, body, headers)
    seen[#seen + 1] = { endpoint = endpoint, body = vim.json.decode(body ~= "" and body or "{}"), headers = headers }
    local how = mode[endpoint] or "ok"
    if how == "ok" then
      return { status = 200, ctype = "application/json", body = type(ok_body) == "function" and ok_body() or ok_body }
    elseif how == "err" then
      return { status = 200, ctype = "application/json", body = '{"errCode":-2012,"errMsg":"登录超时"}' }
    elseif how == "code_only" then
      return { status = 200, ctype = "application/json", body = '{"errCode":-1}' }
    elseif how == "http400" then
      return { status = 400, ctype = "text/plain", body = "" }
    elseif how == "garbage" then
      return { status = 200, ctype = "text/plain", body = "<html>nope</html>" }
    end
    return { status = 200, ctype = "application/json", body = "{}" }
  end
end

local function route(path, ok_body)
  return { path = path, handler = answer(path, ok_body) }
end

---What `/web/review/list` answers with, read per request so a case can restage it.
---(`/web/review/list` 的回复，按请求读取，用例可以随时换)
local list_reply = '{"reviews":[]}'

local server = mock_lib.start({
  route("/web/book/addBookmark", '{"bookmarkId":"bm_1"}'),
  route("/web/book/removeBookmark", '{"succ":1}'),
  route("/web/review/add", '{"reviewId":"vid_rev1"}'),
  route("/web/review/delete", '{"succ":1}'),
  route("/web/review/list", function()
    return list_reply
  end),
})

local config = require("weread.config")
local http = require("weread.http")
local auth = require("weread.auth")
local log = require("weread.log")

config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", keymaps = false, sync_interval = 0 })
config.ensure_dirs()
http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 8, retries = 0, proxy = "direct" })
log.setup({ debug = true, path = config.path("weread.log") })
auth.save_credentials({
  version = 1,
  account = { name = "测试账号", user_vid = "vid" },
  api_key = "wrk-test-key",
  cookies = { wr_vid = "vid", wr_skey = "skey", wr_ql = "0", wr_rt = "rt" },
})

local sync = require("weread.annotations_sync")

---Run an async call and wait for its callback.
---(跑一个异步调用并等它的回调)
local function await(runner)
  local captured, done = nil, false
  runner(function(...)
    captured = { n = select("#", ...), ... }
    done = true
  end)
  vim.wait(20000, function()
    return done
  end, 10)
  assert(captured, "timed out waiting for the callback")
  return (table.unpack or unpack)(captured, 1, captured.n)
end

local function reset()
  list_reply = '{"reviews":[]}'
  mode = {}
  for index = #seen, 1, -1 do
    seen[index] = nil
  end
end

describe("annotations_sync.write_error", function()
  it("prefers the service's message, then its code, then the transport error, then the status", function()
    eq(sync.write_error({ code = 200 }, { errMsg = "太快了", errCode = -5 }), "太快了")
    eq(sync.write_error({ code = 200 }, { errCode = -5 }), "-5")
    eq(sync.write_error({ code = 0, error = "could not connect" }, nil), "could not connect")
    eq(sync.write_error({ code = 400 }, nil), "HTTP 400")
  end)

  it("copes with a missing response altogether", function()
    eq(sync.write_error(nil, nil), "HTTP nil")
  end)
end)

describe("annotations_sync.post_highlight", function()
  it("sends the text Base64 encoded, with the reader's referer, to the configured origin", function()
    reset()
    local ok, id = await(function(done)
      sync.post_highlight({ book_id = "b", chapter_uid = "3", range = "10-20", text = "原文", style = 1 }, done)
    end)
    eq(ok, true)
    eq(id, "bm_1")
    eq(#seen, 1)
    eq(seen[1].body.markText, vim.base64.encode("原文"))
    eq(seen[1].body.style, 1)
    eq(seen[1].body.range, "10-20")
    matches(seen[1].headers, "[Rr]eferer: " .. vim.pesc(server.url) .. "/web/reader/")
  end)

  it("reports an errCode refusal with the service's message", function()
    reset()
    mode["/web/book/addBookmark"] = "err"
    local ok, message = await(function(done)
      sync.post_highlight({ book_id = "b", chapter_uid = "3", range = "10-20", text = "x" }, done)
    end)
    eq(ok, false)
    eq(message, "划线同步失败：登录超时")
  end)

  it("falls back to the code when the refusal carries no message", function()
    reset()
    mode["/web/book/addBookmark"] = "code_only"
    local ok, message = await(function(done)
      sync.post_highlight({ book_id = "b", chapter_uid = "3", range = "10-20", text = "x" }, done)
    end)
    eq(ok, false)
    eq(message, "划线同步失败：-1")
  end)

  it("names the HTTP status when the body is empty", function()
    reset()
    mode["/web/book/addBookmark"] = "http400"
    local ok, message = await(function(done)
      sync.post_highlight({ book_id = "b", chapter_uid = "3", range = "10-20", text = "x" }, done)
    end)
    eq(ok, false)
    eq(message, "划线同步失败：HTTP 400")
  end)

  it("fails on a reply that is not JSON, without raising", function()
    reset()
    mode["/web/book/addBookmark"] = "garbage"
    local ok, message = await(function(done)
      sync.post_highlight({ book_id = "b", chapter_uid = "3", range = "10-20", text = "x" }, done)
    end)
    eq(ok, false)
    matches(message, "^划线同步失败：")
  end)

  it("fails when the reply has no bookmark id", function()
    reset()
    mode["/web/book/addBookmark"] = "empty"
    local ok, message = await(function(done)
      sync.post_highlight({ book_id = "b", chapter_uid = "3", range = "10-20", text = "x" }, done)
    end)
    eq(ok, false)
    matches(message, "^划线同步失败：")
  end)

  it("reads the origin when called, so a config change redirects the write", function()
    reset()
    local other_seen = 0
    local other = mock_lib.start({
      {
        path = "/web/book/addBookmark",
        handler = function()
          other_seen = other_seen + 1
          return { status = 200, ctype = "application/json", body = '{"bookmarkId":"bm_other"}' }
        end,
      },
    })
    config.setup({ data_dir = tmpdir, base_url = other.url, proxy = "direct", keymaps = false, sync_interval = 0 })
    local ok, id = await(function(done)
      sync.post_highlight({ book_id = "b", chapter_uid = "3", range = "10-20", text = "x" }, done)
    end)
    config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", keymaps = false, sync_interval = 0 })
    other.stop()
    eq(ok, true)
    eq(id, "bm_other")
    eq(other_seen, 1)
    eq(#seen, 0, "the first server never saw it")
  end)
end)

describe("annotations_sync.delete_highlight", function()
  it("sends the bookmark id and succeeds on succ = 1", function()
    reset()
    local ok = await(function(done)
      sync.delete_highlight("bm_1", done)
    end)
    eq(ok, true)
    eq(seen[1].body.bookmarkId, "bm_1")
  end)

  it("reports a refusal with the service's message", function()
    reset()
    mode["/web/book/removeBookmark"] = "err"
    local ok, message = await(function(done)
      sync.delete_highlight("bm_1", done)
    end)
    eq(ok, false)
    eq(message, "删除划线失败：登录超时")
  end)

  it("treats a reply without succ = 1 as a failure", function()
    reset()
    mode["/web/book/removeBookmark"] = "empty"
    local ok, message = await(function(done)
      sync.delete_highlight("bm_1", done)
    end)
    eq(ok, false)
    matches(message, "^删除划线失败：")
  end)

  it("names the HTTP status when the service answers 400", function()
    reset()
    mode["/web/book/removeBookmark"] = "http400"
    local ok, message = await(function(done)
      sync.delete_highlight("bm_1", done)
    end)
    eq(ok, false)
    eq(message, "删除划线失败：HTTP 400")
  end)
end)

describe("annotations_sync.post_thought", function()
  local params = { book_id = "b", chapter_uid = "3", chapter_idx = 5, range = "1-9", content = "好", abstract = "原文" }

  it("returns the service's reply, review id included", function()
    reset()
    local ok, result = await(function(done)
      sync.post_thought(params, done)
    end)
    eq(ok, true)
    eq(result.reviewId, "vid_rev1")
    eq(seen[1].body.abstract, "原文")
    eq(seen[1].body.isPrivate, false)
  end)

  it("fails with the service's message when it refuses", function()
    reset()
    mode["/web/review/add"] = "err"
    local ok, message = await(function(done)
      sync.post_thought(params, done)
    end)
    eq(ok, false)
    eq(message, "写想法失败：登录超时")
  end)

  it("fails when the reply carries no review id", function()
    reset()
    mode["/web/review/add"] = "empty"
    local ok, message = await(function(done)
      sync.post_thought(params, done)
    end)
    eq(ok, false)
    matches(message, "^写想法失败：")
  end)

  it("does not raise on a body that is not JSON", function()
    reset()
    mode["/web/review/add"] = "garbage"
    local ok, message = await(function(done)
      sync.post_thought(params, done)
    end)
    eq(ok, false)
    matches(message, "^写想法失败：")
  end)
end)

describe("annotations_sync.delete_thought", function()
  it("sends the review id with the context it was given", function()
    reset()
    local ok = await(function(done)
      sync.delete_thought("vid_rev1", { book_id = "b", chapter_uid = "3", range = "1-9", book_version = 7 }, done)
    end)
    eq(ok, true)
    eq(seen[1].body.reviewId, "vid_rev1")
    eq(seen[1].body.bookVersion, 7)
  end)

  it("works without any options", function()
    reset()
    local ok = await(function(done)
      sync.delete_thought("vid_rev1", nil, done)
    end)
    eq(ok, true)
  end)

  it("fails with the service's message when it refuses", function()
    reset()
    mode["/web/review/delete"] = "err"
    local ok, message = await(function(done)
      sync.delete_thought("vid_rev1", {}, done)
    end)
    eq(ok, false)
    eq(message, "删除想法失败：登录超时")
  end)

  it("fails on a reply that is not JSON, without raising", function()
    reset()
    mode["/web/review/delete"] = "garbage"
    local ok, message = await(function(done)
      sync.delete_thought("vid_rev1", {}, done)
    end)
    eq(ok, false)
    matches(message, "^删除想法失败：")
  end)
end)

describe("annotations_sync.find_my_thought_web", function()
  local function review(id, range, chapter_uid)
    return { review = { reviewId = id, range = range, chapterUid = chapter_uid, content = "我的" .. id, author = { name = "我", userVid = "vid" } } }
  end

  it("finds my thought under the range and strips zero-width characters", function()
    reset()
    local entry = review("vid_a", "1-9", 3)
    entry.review.content = "带\226\128\139零宽"
    list_reply = vim.json.encode({ reviews = { review("vid_x", "50-60", 3), entry } })
    local ok, thought, err = await(function(done)
      sync.find_my_thought_web("b", "3", "1-9", done)
    end)
    eq(ok, true)
    eq(err, nil)
    eq(thought.id, "vid_a")
    eq(thought.content, "带零宽")
    eq(thought.author_vid, "vid")
  end)

  it("finds nothing, successfully, when no thought sits under the range", function()
    reset()
    list_reply = vim.json.encode({ reviews = { review("vid_x", "50-60", 3) } })
    local ok, thought = await(function(done)
      sync.find_my_thought_web("b", "3", "1-9", done)
    end)
    eq(ok, true)
    eq(thought, nil)
  end)

  it("ignores a thought on the same range in another chapter", function()
    reset()
    list_reply = vim.json.encode({ reviews = { review("vid_a", "1-9", 99) } })
    local ok, thought = await(function(done)
      sync.find_my_thought_web("b", "3", "1-9", done)
    end)
    eq(ok, true)
    eq(thought, nil)
  end)

  it("reports the service's refusal as an error, not as 'nothing found'", function()
    reset()
    mode["/web/review/list"] = "err"
    local ok, thought, err = await(function(done)
      sync.find_my_thought_web("b", "3", "1-9", done)
    end)
    eq(ok, false)
    eq(thought, nil)
    eq(err, "登录超时")
  end)

  it("reports a reply that is not JSON as an error", function()
    reset()
    mode["/web/review/list"] = "garbage"
    local ok, _, err = await(function(done)
      sync.find_my_thought_web("b", "3", "1-9", done)
    end)
    eq(ok, false)
    matches(err, "^读取我的想法失败：")
  end)

  it("stops paging when the server ignores maxIdx and repeats the same page", function()
    reset()
    local page = {}
    for index = 1, 50 do
      page[index] = review("vid_" .. index, "7-8", 3)
    end
    list_reply = vim.json.encode({ reviews = page })
    local ok, thought = await(function(done)
      sync.find_my_thought_web("b", "3", "1-9", done)
    end)
    eq(ok, true)
    eq(thought, nil)
    eq(#seen, 2, "the repeated page earns no third request")
  end)
end)

-- ------------------------------------------------------------------ late callbacks
--
-- A reply can land after the chapter buffer (or the popup) it was started for is
-- gone. The HTTP layer is stubbed so the test decides when the reply arrives.
-- (回复到来时，发起请求的章节 buffer（或弹窗）可能已经不在了。HTTP 层打桩，由测试决定
--  回复什么时候到)

local reader = require("weread.reader")
local store = require("weread.annotations_store")
local thoughts = require("weread.thoughts")
local chapter_module = require("weread.annotations_chapter")
local fetch_module = require("weread.annotations_fetch")

local late_counter = 0

---A buffer standing in for a chapter, with the reader state a write needs.
---(充当章节的 buffer，带上写操作需要的阅读器状态)
---@return integer buf
---@return string book_id
---@return fun() restore
local function fake_chapter()
  late_counter = late_counter + 1
  local book_id = "late-" .. late_counter
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "一行正文" })
  vim.b[buf].weread = { book_id = book_id, chapter_uid = "4", chapter_key = "0004", chapter_title = "章", chapter_index = 1 }
  vim.api.nvim_set_current_buf(buf)
  local catalog, book = reader.state.catalog, reader.state.book
  reader.state.catalog = { chapters = { { chapterUid = 4, chapterIdx = 4 } } }
  reader.state.book = { book_id = book_id, version = 3 }
  return buf, book_id, function()
    reader.state.catalog, reader.state.book = catalog, book
  end
end

---Replace `http.request` with a recorder; the reply is delivered by the test.
---(把 `http.request` 换成记录器；回复由测试投递)
---@return table[] pending
---@return fun() restore
local function stub_http()
  local pending = {}
  local original = http.request
  http.request = function(opts, callback)
    pending[#pending + 1] = { opts = opts, callback = callback }
    return {}
  end
  return pending, function()
    http.request = original
  end
end

---Replace `vim.notify` with a recorder.
---@return string[] messages
---@return fun() restore
local function stub_notify()
  local messages = {}
  local original = vim.notify
  vim.notify = function(message)
    messages[#messages + 1] = message
  end
  return messages, function()
    vim.notify = original
  end
end

---Run `body`, put the stubs back whatever happens, then re-raise.
---(跑 `body`，无论如何都把桩还原，然后重新抛出错误)
local function guarded(restores, body)
  local ok, err = pcall(body)
  for index = #restores, 1, -1 do
    restores[index]()
  end
  if not ok then
    error(err, 0)
  end
end

local function reply(status, body)
  return { code = status, status = status, body = body or "" }
end

---Replace `vim.schedule` with a recorder, so the test runs the deferred work
---itself, inside a pcall, instead of an error vanishing into stderr.
---(把 `vim.schedule` 换成记录器，由测试自己在 pcall 里执行延后的工作，而不是让错误消失在 stderr 里)
---Only around the one call under test: opening a float schedules work of its own.
---(只包住被测的那一次调用：打开浮窗本身也会调度它自己的工作)
---@param trigger fun()
---@return function[] queued what `trigger` deferred(`trigger` 延后的工作)
local function capture_scheduled(trigger)
  local queued = {}
  local original = vim.schedule
  vim.schedule = function(fn)
    queued[#queued + 1] = fn
  end
  local ok, err = pcall(trigger)
  vim.schedule = original
  if not ok then
    error(err, 0)
  end
  return queued
end

describe("annotations_sync.sync_local when the buffer is gone before the reply", function()
  it("still records the bookmark id of an upload that succeeded", function()
    local buf, book_id, restore_state = fake_chapter()
    local pending, restore_http = stub_http()
    local _, restore_notify = stub_notify()
    guarded({ restore_state, restore_http, restore_notify }, function()
      store.add_local(book_id, "0004", "1-9", "一行")
      sync.sync_local(buf, { quiet = true })
      eq(#pending, 1, "the upload went out")

      vim.api.nvim_buf_delete(buf, { force = true })
      pending[1].callback(reply(200, '{"bookmarkId":"bm_late"}'))

      local record = store.local_for(book_id, "0004")[1]
      eq(record.bookmark_id, "bm_late", "the account's id is kept although nothing can be redrawn")
      eq(#pending, 1, "and nothing was posted or deleted a second time")
    end)
  end)

  it("takes an upload back off the account when its record was removed meanwhile", function()
    local buf, book_id, restore_state = fake_chapter()
    local pending, restore_http = stub_http()
    local _, restore_notify = stub_notify()
    guarded({ restore_state, restore_http, restore_notify }, function()
      store.add_local(book_id, "0004", "1-9", "一行")
      sync.sync_local(buf, { quiet = true })
      store.remove_local(book_id, "0004", "1-9")
      vim.api.nvim_buf_delete(buf, { force = true })
      pending[1].callback(reply(200, '{"bookmarkId":"bm_orphan"}'))

      eq(#pending, 2, "a delete followed")
      matches(pending[2].opts.url, "/web/book/removeBookmark$")
      eq(pending[2].opts.body.bookmarkId, "bm_orphan")
    end)
  end)

  it("keeps the local highlight and says so when the upload was refused", function()
    local buf, book_id, restore_state = fake_chapter()
    local pending, restore_http = stub_http()
    local messages, restore_notify = stub_notify()
    guarded({ restore_state, restore_http, restore_notify }, function()
      store.add_local(book_id, "0004", "1-9", "一行")
      sync.sync_local(buf)
      vim.api.nvim_buf_delete(buf, { force = true })
      pending[1].callback(reply(400, ""))

      local record = store.local_for(book_id, "0004")[1]
      eq(record.bookmark_id, nil, "nothing is claimed to be synced")
      eq(#messages, 1)
      matches(messages[1], "划线同步失败：HTTP 400")
    end)
  end)

  it("does not upload twice while a first upload is still in flight", function()
    local buf, book_id, restore_state = fake_chapter()
    local pending, restore_http = stub_http()
    local _, restore_notify = stub_notify()
    guarded({ restore_state, restore_http, restore_notify }, function()
      store.add_local(book_id, "0004", "1-9", "一行")
      sync.sync_local(buf, { quiet = true })
      sync.sync_local(buf, { quiet = true })
      eq(#pending, 1)
      pending[1].callback(reply(200, '{"bookmarkId":"bm_once"}'))
    end)
  end)
end)

describe("annotations_sync.remove_highlight when the buffer is gone before the reply", function()
  it("still drops the local record and reports success", function()
    local buf, book_id, restore_state = fake_chapter()
    local pending, restore_http = stub_http()
    guarded({ restore_state, restore_http }, function()
      store.add_local(book_id, "0004", "1-9", "一行")
      store.mark_synced(book_id, "0004", "1-9", "bm_gone")
      local results = {}
      sync.remove_highlight(buf, { range = "1-9", bookmark_id = "bm_gone" }, function(ok, message)
        results[#results + 1] = { ok = ok, message = message }
      end)
      eq(#pending, 1)
      vim.api.nvim_buf_delete(buf, { force = true })
      pending[1].callback(reply(200, '{"succ":1}'))

      eq(#results, 1)
      eq(results[1].ok, true)
      eq(store.local_for(book_id, "0004"), {}, "the local copy went with it")
    end)
  end)

  it("keeps the local record when the account refuses the delete", function()
    local buf, book_id, restore_state = fake_chapter()
    local pending, restore_http = stub_http()
    guarded({ restore_state, restore_http }, function()
      store.add_local(book_id, "0004", "1-9", "一行")
      store.mark_synced(book_id, "0004", "1-9", "bm_keep")
      local results = {}
      sync.remove_highlight(buf, { range = "1-9", bookmark_id = "bm_keep" }, function(ok, message)
        results[#results + 1] = { ok = ok, message = message }
      end)
      vim.api.nvim_buf_delete(buf, { force = true })
      pending[1].callback(reply(200, '{"errCode":-2012,"errMsg":"登录超时"}'))

      eq(results[1].ok, false)
      matches(results[1].message, "删除划线失败：登录超时")
      eq(#store.local_for(book_id, "0004"), 1, "a refused delete must not forget the highlight")
    end)
  end)
end)

describe("thoughts.write_thought when the buffer is gone before the reply", function()
  it("keeps what was written, marked as not synced, when the service refuses", function()
    local buf, book_id, restore_state = fake_chapter()
    local pending, restore_http = stub_http()
    local messages, restore_notify = stub_notify()
    guarded({ restore_state, restore_http, restore_notify }, function()
      thoughts.write_thought(buf, "1-9", "原文", "我写的想法")
      eq(#pending, 1)
      vim.api.nvim_buf_delete(buf, { force = true })
      pending[1].callback(reply(200, '{"errCode":-2012,"errMsg":"登录超时"}'))

      local record = store.local_for(book_id, "0004")[1]
      truthy(record, "the note was not lost with the buffer")
      eq(record.note, "我写的想法")
      eq(record.note_synced, false)
      eq(record.local_only, true, "a record made only to hold a note is not a highlight")
      eq(#messages, 1)
      matches(messages[1], "写想法失败：登录超时")
    end)
  end)

  it("keeps the review id of a thought the service accepted", function()
    local buf, book_id, restore_state = fake_chapter()
    local pending, restore_http = stub_http()
    local messages, restore_notify = stub_notify()
    local refreshed = 0
    local original_refresh = chapter_module.refresh_after_write
    chapter_module.refresh_after_write = function()
      refreshed = refreshed + 1
    end
    guarded({ restore_state, restore_http, restore_notify, function()
      chapter_module.refresh_after_write = original_refresh
    end }, function()
      thoughts.write_thought(buf, "1-9", "原文", "我写的想法")
      vim.api.nvim_buf_delete(buf, { force = true })
      pending[1].callback(reply(200, '{"reviewId":"vid_late"}'))

      local record = store.local_for(book_id, "0004")[1]
      eq(record.note, "我写的想法")
      eq(record.note_synced, true)
      eq(record.note_review_id, "vid_late", "so it can still be deleted later")
      eq(refreshed, 0, "there is no buffer to refresh")
      matches(messages[1], "想法已发表")
    end)
  end)

  it("refreshes the chapter when the buffer is still there", function()
    local buf, book_id, restore_state = fake_chapter()
    local pending, restore_http = stub_http()
    local _, restore_notify = stub_notify()
    local refreshed = {}
    local original_refresh = chapter_module.refresh_after_write
    chapter_module.refresh_after_write = function(target)
      refreshed[#refreshed + 1] = target
    end
    guarded({ restore_state, restore_http, restore_notify, function()
      chapter_module.refresh_after_write = original_refresh
    end }, function()
      thoughts.write_thought(buf, "1-9", "原文", "我写的想法")
      pending[1].callback(reply(200, '{"reviewId":"vid_now"}'))
      eq(refreshed, { buf })
      eq(store.local_for(book_id, "0004")[1].note_review_id, "vid_now")
    end)
  end)

  it("says so, and sends nothing, outside a chapter buffer", function()
    local stray = vim.api.nvim_create_buf(true, false)
    local pending, restore_http = stub_http()
    local messages, restore_notify = stub_notify()
    guarded({ restore_http, restore_notify }, function()
      thoughts.write_thought(stray, "1-9", "原文", "想法")
      eq(#pending, 0)
      matches(messages[1], "只在微信读书章节里写想法")
    end)
  end)
end)

describe("thoughts.compose_thought when the buffer goes away after submitting", function()
  ---Type into the composer and press its <CR>; returns the queued deferred work.
  ---(在输入框里写字并按它的 <CR>；返回被延后的工作)
  local function submit(buf, text)
    thoughts.compose_thought(buf, "1-9", "原文")
    local composer = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(composer, 0, -1, false, { text })
    local mapping = vim.fn.maparg("<CR>", "i", false, true)
    local queued = capture_scheduled(mapping.callback)
    vim.cmd("stopinsert")
    return queued
  end

  it("does not write a thought for a buffer that is gone", function()
    local buf, _, restore_state = fake_chapter()
    local written = {}
    local original = thoughts.write_thought
    thoughts.write_thought = function(...)
      written[#written + 1] = { ... }
    end
    guarded({ restore_state, function()
      thoughts.write_thought = original
    end }, function()
      local queued = submit(buf, "写到一半章节没了")
      truthy(#queued >= 1, "the post is deferred")
      vim.api.nvim_buf_delete(buf, { force = true })
      -- closing the float schedules a few things of its own first; the post is
      -- scheduled last, after the float is closed
      -- (关浮窗时会先调度几件它自己的事；发表是在关完浮窗之后最后调度的)
      local ok, err = pcall(queued[#queued])
      eq(ok, true, tostring(err))
      eq(#written, 0)
    end)
  end)

  it("writes the thought when the buffer is still there", function()
    local buf, _, restore_state = fake_chapter()
    local written = {}
    local original = thoughts.write_thought
    thoughts.write_thought = function(...)
      written[#written + 1] = { ... }
    end
    guarded({ restore_state, function()
      thoughts.write_thought = original
    end }, function()
      local queued = submit(buf, "好句子")
      queued[#queued]()
      eq(#written, 1)
      eq(written[1], { buf, "1-9", "原文", "好句子" })
    end)
  end)
end)

describe("thoughts.open when the panel is closed before the fetch returns", function()
  local function entries()
    return { { annotation = { range = "1-9", text = "原文", thoughts = {}, count = 0 } } }
  end

  ---Stub the paging fetch; returns the calls it received.
  ---(给分页拉取打桩，返回它收到的调用)
  local function stub_fetch()
    local calls = {}
    local original = fetch_module.fetch_all_thoughts
    fetch_module.fetch_all_thoughts = function(book_id, chapter_uid, range, callback)
      calls[#calls + 1] = { book_id = book_id, chapter_uid = chapter_uid, range = range, callback = callback }
    end
    return calls, function()
      fetch_module.fetch_all_thoughts = original
    end
  end

  it("takes the late thoughts into the session cache without touching the closed window", function()
    thoughts.reset()
    local buf, book_id, restore_state = fake_chapter()
    local calls, restore_fetch = stub_fetch()
    guarded({ restore_state, restore_fetch }, function()
      local view = thoughts.open({ buf = buf, book_id = book_id, chapter_uid = "4", entries = entries() })
      eq(#calls, 1)
      view.float:close()

      local queued = capture_scheduled(function()
        calls[1].callback(true, { { content = "迟到的想法", author = "某人", id = "x_1", likes = 2 } }, 1)
      end)
      eq(#queued, 1)
      local ok, err = pcall(queued[1])
      eq(ok, true, tostring(err))

      -- the list was kept: a second panel on the same highlight asks nobody
      -- (列表被留下了：同一条划线上再开面板，不用再问)
      local again = thoughts.open({ buf = buf, book_id = book_id, chapter_uid = "4", entries = entries() })
      eq(#calls, 1, "served from the session cache")
      local lines = vim.api.nvim_buf_get_lines(again.float.buf, 0, -1, false)
      truthy(table.concat(lines, "\n"):find("迟到的想法", 1, true), "and it shows the thought")
      again.float:close()
    end)
  end)

  it("survives a failed fetch that returns after the panel is closed", function()
    thoughts.reset()
    local buf, book_id, restore_state = fake_chapter()
    local calls, restore_fetch = stub_fetch()
    guarded({ restore_state, restore_fetch }, function()
      local view = thoughts.open({ buf = buf, book_id = book_id, chapter_uid = "4", entries = entries() })
      view.float:close()
      local queued = capture_scheduled(function()
        calls[1].callback(false, "服务端不可用")
      end)
      eq(#queued, 1)
      local ok, err = pcall(queued[1])
      eq(ok, true, tostring(err))
    end)
  end)

  it("paints the thoughts into the panel when it is still open", function()
    thoughts.reset()
    local buf, book_id, restore_state = fake_chapter()
    local calls, restore_fetch = stub_fetch()
    guarded({ restore_state, restore_fetch }, function()
      local view = thoughts.open({ buf = buf, book_id = book_id, chapter_uid = "4", entries = entries() })
      local queued = capture_scheduled(function()
        calls[1].callback(true, { { content = "及时的想法", author = "某人", id = "x_2" } }, 1)
      end)
      queued[1]()
      local lines = vim.api.nvim_buf_get_lines(view.float.buf, 0, -1, false)
      truthy(table.concat(lines, "\n"):find("及时的想法", 1, true))
      view.float:close()
    end)
  end)
end)

describe("annotations_edit.clear_local", function()
  local edit = require("weread.annotations_edit")

  it("empties the chapter and takes the synced highlights off the account too", function()
    local buf, book_id, restore_state = fake_chapter()
    local pending, restore_http = stub_http()
    local _, restore_notify = stub_notify()
    guarded({ restore_state, restore_http, restore_notify }, function()
      store.add_local(book_id, "0004", "1-9", "已同步的")
      store.mark_synced(book_id, "0004", "1-9", "bm_synced")
      store.add_local(book_id, "0004", "20-30", "只在本地的")
      vim.b[buf].weread_server_annotations = { { range = "1-9", mine = true, bookmark_id = "bm_synced", thoughts = {} } }

      eq(edit.clear_local(buf), 2)

      eq(store.local_for(book_id, "0004"), {})
      eq(vim.b[buf].weread_server_annotations, {}, "the account's copy is dropped from the buffer too")
      eq(#pending, 1, "only the synced one needs the account told")
      matches(pending[1].opts.url, "/web/book/removeBookmark$")
      eq(pending[1].opts.body.bookmarkId, "bm_synced")
    end)
  end)

  it("tells the user when the account refuses the delete", function()
    local buf, book_id, restore_state = fake_chapter()
    local pending, restore_http = stub_http()
    local messages, restore_notify = stub_notify()
    guarded({ restore_state, restore_http, restore_notify }, function()
      store.add_local(book_id, "0004", "1-9", "已同步的")
      store.mark_synced(book_id, "0004", "1-9", "bm_synced")
      edit.clear_local(buf)
      pending[1].callback(reply(200, '{"errCode":-2012,"errMsg":"登录超时"}'))
      eq(#messages, 1)
      matches(messages[1], "删除划线失败：登录超时")
    end)
  end)

  it("is 0 outside a chapter buffer", function()
    eq(edit.clear_local(vim.api.nvim_create_buf(true, false)), 0)
  end)
end)
