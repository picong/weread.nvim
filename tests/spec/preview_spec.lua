--[[
Tests for the shelf book preview: the review/chapter normalizers on the gateway
client, the preview rendering (store book vs uploaded book vs total failure)
and the cached, deduplicated fetch behind it — served by a local mock gateway.
(书架书籍预览的测试：gateway 上的点评/目录归一化、预览渲染（书城书 / 上传书 /
全部失败）以及背后的缓存与去重拉取——数据来自本地 mock gateway)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

local INFO = {
  ["111"] = {
    bookId = "111",
    title = "持续交付2.0",
    author = "乔梁",
    intro = "第一行简介。\n第二行简介，这一行写得特别长，长到一定会被截断，因为预览的行宽是有限的，超出就要收进省略号里。",
    category = "计算机",
    publisher = "人民邮电出版社",
    wordCount = 321000,
    newRating = 87.8,
    newRatingCount = 23456,
  },
  -- an uploaded book: in the shelf but with no store life at all; the Agent
  -- API even refuses its id for reviews/chapters, so the TOC must come from
  -- the web catalog pipeline
  -- (上传的书：在书架里，但书城里什么都没有；Agent API 对它的 id 连点评/目录都会拒绝，
  --  因此目录只能回退到网页目录链路)
  ["333"] = {
    bookId = "333",
    title = "我的私人笔记",
    author = "",
  },
  ["222"] = {
    bookId = "222",
    title = "我的私人笔记",
    author = "",
    wordCount = 8000,
  },
}

local REVIEWS = {
  ["111"] = {
    reviewsCnt = 1234,
    reviews = {
      {
        idx = 1,
        review = {
          reviewId = "r1",
          review = {
            content = "工程实践的经典，每一条建议都有出处。\n第二段想法。",
            star = 80,
            isFinish = 1,
            createTime = os.time() - 86400,
            author = { name = "读者甲" },
          },
        },
      },
      {
        idx = 2,
        review = {
          reviewId = "r2",
          review = {
            content = "入门读有点吃力。",
            star = 60,
            isFinish = 0,
            createTime = os.time() - 3600,
            author = { name = "读者乙" },
          },
        },
      },
    },
  },
  ["222"] = { reviewsCnt = 0, reviews = {} },
}

local CHAPTERS = {
  ["111"] = {
    chapters = {
      { chapterUid = 1, chapterIdx = 1, title = "第一部分 交付2.0", level = 1 },
      { chapterUid = 2, chapterIdx = 2, title = "1.1 引子", level = 2 },
      { chapterUid = 3, chapterIdx = 3, title = "第二部分 双环模型", level = 1 },
    },
  },
  ["222"] = {
    chapters = {
      { chapterUid = 11, chapterIdx = 1, title = "开头", level = 1 },
      { chapterUid = 12, chapterIdx = 2, title = "结尾", level = 1 },
    },
  },
}

local seen = {}

local gateway
gateway = mock_lib.start({
  {
    path = "/api/agent/gateway",
    handler = function(_, _, body)
      local request = vim.json.decode(body)
      seen[#seen + 1] = request
      local book_id = tostring(request.bookId or "")
      if request.api_name == "/book/info" then
        if INFO[book_id] then
          return { status = 200, ctype = "application/json", body = vim.json.encode(INFO[book_id]) }
        end
      elseif request.api_name == "/review/list" then
        if REVIEWS[book_id] then
          return { status = 200, ctype = "application/json", body = vim.json.encode(REVIEWS[book_id]) }
        end
      elseif request.api_name == "/book/chapterinfo" then
        if CHAPTERS[book_id] then
          return { status = 200, ctype = "application/json", body = vim.json.encode(CHAPTERS[book_id]) }
        end
      end
      return { status = 200, ctype = "application/json", body = '{"errcode":-1,"errmsg":"不存在"}' }
    end,
  },
  {
    -- The web catalog pipeline the TOC fallback uses (content.fetch_catalog).
    -- (目录回退用的网页目录链路（content.fetch_catalog）)
    path = "/web/book/chapterInfos",
    handler = function(method, _, body)
      if method ~= "POST" then
        return { status = 405, ctype = "text/plain", body = "POST only" }
      end
      if body and body:find('"333"', 1, true) then
        return {
          status = 200,
          ctype = "application/json",
          body = vim.json.encode({
            data = {
              {
                bookId = "333",
                synckey = 7,
                updated = {
                  { chapterUid = 21, chapterIdx = 1, title = "开篇的话", wordCount = 10, level = 1 },
                  { chapterUid = 22, chapterIdx = 2, title = "正文", wordCount = 900, level = 1 },
                },
              },
            },
          }),
        }
      end
      return { status = 200, ctype = "application/json", body = '{"errcode":-1,"errmsg":"不存在"}' }
    end,
  },
})

local config = require("weread.config")
local http = require("weread.http")
local auth = require("weread.auth")
local gateway_client = require("weread.api_gateway")
local preview = require("weread.preview")

config.setup({ data_dir = tmpdir, gateway_url = gateway.url, base_url = gateway.url, proxy = "direct" })
config.ensure_dirs()
http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 8, retries = 0, proxy = "direct" })

auth.save_credentials({
  version = 1,
  login_method = "qr",
  account = { name = "测试账号", user_vid = "vid" },
  api_key = "wrk-test-key",
  cookies = { wr_vid = "vid", wr_skey = "skey", wr_ql = "0", wr_rt = "rt" },
})

local function join(lines)
  return table.concat(lines, "\n")
end

local function count_requests(api_name, book_id)
  local n = 0
  for _, request in ipairs(seen) do
    if request.api_name == api_name and tostring(request.bookId or "") == tostring(book_id) then
      n = n + 1
    end
  end
  return n
end

local unpack_values = table.unpack or unpack
local function await_async(runner, timeout)
  local captured
  local done = false
  runner(function(...)
    captured = { n = select("#", ...), ... }
    done = true
  end)
  vim.wait(timeout or 15000, function()
    return done
  end, 20)
  if not captured then
    error("timed out waiting for the callback")
  end
  return unpack_values(captured, 1, captured.n)
end

describe("api_gateway.review_list", function()
  it("unwraps the doubly nested review payload", function()
    local ok, data = await_async(function(cb)
      gateway_client.review_list("111", { count = 5 }, cb)
    end)
    truthy(ok, tostring(data))
    eq(data.total, 1234)
    eq(#data.reviews, 2)
    eq(data.reviews[1].name, "读者甲")
    eq(data.reviews[1].star, 80)
    eq(data.reviews[1].is_finish, true, "isFinish 1 becomes a boolean")
    truthy(data.reviews[1].content:find("工程实践", 1, true))
    truthy(data.reviews[1].create_time and data.reviews[1].create_time > 0)
    eq(data.reviews[2].star, 60)
  end)

  it("requests a bounded page, not the default 20", function()
    seen = {}
    await_async(function(cb)
      gateway_client.review_list("111", { count = 5 }, cb)
    end)
    eq(count_requests("/review/list", "111"), 1)
    eq(seen[#seen].count, 5, "count=5 is sent verbatim")
    eq(seen[#seen].reviewListType, 0)
  end)
end)

describe("api_gateway.chapter_info", function()
  it("normalizes chapters with their levels", function()
    local ok, data = await_async(function(cb)
      gateway_client.chapter_info("111", cb)
    end)
    truthy(ok, tostring(data))
    eq(#data.chapters, 3)
    eq(data.chapters[1].title, "第一部分 交付2.0")
    eq(data.chapters[1].level, 1)
    eq(data.chapters[2].level, 2)
    eq(data.chapters[2].idx, 2)
    eq(data.chapters[2].uid, 2)
  end)

  it("reports a missing book as a failure", function()
    local ok, message = await_async(function(cb)
      gateway_client.chapter_info("404", cb)
    end)
    falsy(ok)
    matches(message, "不存在")
  end)
end)

describe("preview.build_lines", function()
  local STORE_RAW = nil ---@type string[]|nil

  it("shows rating, reviews and the TOC for a store book", function()
    STORE_RAW = preview.build_lines({ title = "持续交付2.0", author = "乔梁" }, {
      info = INFO["111"],
      reviews = {
        total = 1234,
        reviews = {
          {
            name = "读者甲",
            star = 80,
            content = "工程实践的经典，每一条建议都有出处。\n第二段想法。",
            create_time = os.time() - 86400,
            is_finish = true,
          },
        },
      },
      chapters = {
        chapters = { { title = "第一部分", level = 1, idx = 1 }, { title = "1.1 引子", level = 2, idx = 2 } },
      },
    })
    local STORE_LINES = join(STORE_RAW)
    matches(STORE_LINES, "持续交付2.0\n%s+乔梁\n")
    matches(STORE_LINES, "推荐值 .* 87%.8%%")
    matches(STORE_LINES, "2.3 万人点评")
    matches(STORE_LINES, "▎简介")
    matches(STORE_LINES, "▎热门点评  共 1234 条")
    matches(STORE_LINES, "★★★★☆") -- star 80 -> four stars(80 分 -> 四星)
    matches(STORE_LINES, "读者甲")
    matches(STORE_LINES, "读完")
    matches(STORE_LINES, "▎目录  共 2 章")
    matches(STORE_LINES, "  1.1 引子", "level 2 chapters indent one step(二级目录缩进一级)")
  end)

  it("keeps every rendered line within the target width", function()
    truthy(STORE_RAW, "the store book render ran first")
    for _, line in ipairs(STORE_RAW) do
      truthy(vim.api.nvim_strwidth(line) <= 64, "line too wide: " .. line)
    end
  end)

  it("reads the per-mille newRating as a percent", function()
    -- the live /book/info encodes 86.2% as 862(线上 /book/info 把 86.2% 编码成 862)
    local lines = join(
      preview.build_lines({ title = "书", author = "" }, {
        info = { newRating = 878, newRatingCount = 12000 },
      })
    )
    matches(lines, " 87%.8%%")
    matches(lines, "1.2 万人点评")
  end)

  it("keeps a plain percent rating as is", function()
    local lines = join(
      preview.build_lines({ title = "书", author = "" }, {
        info = { newRating = 92.5 },
      })
    )
    matches(lines, " 92%.5%%")
  end)

  it("keeps a rejected review call quiet for a ratingless book", function()
    -- uploads are not store books: the review endpoint rejects their id, and
    -- the preview already says why there are no reviews
    -- (上传书不是书城书：点评接口会拒绝它的 id，预览已经说明了为什么没有点评)
    local lines = join(
      preview.build_lines({ title = "上传的书", author = "" }, {
        info = { wordCount = 8000 },
        reviews_err = "参数错误",
        chapters = { chapters = { { title = "开头", level = 1, idx = 1 } } },
      })
    )
    matches(lines, "自己上传的书 · 无书城评分与点评")
    falsy(lines:find("参数错误", 1, true), "the rejection is not rendered")
  end)

  it("collapses an uploaded book to the TOC alone", function()
    local lines = join(
      preview.build_lines({ title = "我的私人笔记", author = "" }, {
        info = INFO["222"],
        reviews = { total = 0, reviews = {} },
        chapters = CHAPTERS["222"],
      })
    )
    matches(lines, "自己上传的书 · 无书城评分与点评")
    falsy(lines:find("热门点评", 1, true), "no review section without reviews(没有点评就没有点评区)")
    falsy(lines:find("推荐值", 1, true), "no rating without a store rating(书城没评分就不显示评分)")
    matches(lines, "▎目录  共 2 章")
    matches(lines, "结尾")
  end)

  it("renders one honest line when everything failed", function()
    local lines = join(
      preview.build_lines({ title = "离线的书", author = "" }, {
        info_err = "网络错误",
        reviews_err = "网络错误",
        chapters_err = "网络错误",
      })
    )
    matches(lines, "详情加载失败")
    matches(lines, "网络错误")
    falsy(lines:find("▎", 1, true), "no sections without data(没有数据就没有分区标题)")
  end)

  it("caps paragraphs, truncates long text and pins deep indents", function()
    local long_intro = table.concat({ "一行", "两行", "三行", "四行", "五行", "六行", "七行", "八行" }, "\n")
    local long_line = string.rep("长", 200)
    local lines = preview.build_lines({ title = "长书", author = "" }, {
      info = { intro = long_intro },
      reviews = {
        total = 1,
        reviews = { { name = "读者丙", star = 100, content = long_line } },
      },
      chapters = { chapters = { { title = "超深层级", level = 9, idx = 1 } } },
    })
    local text = join(lines)

    -- six intro lines, the last one ellipsized because 七行/八行 were left out
    -- (简介六行，末行带省略号，因为「七行」「八行」被略去了)
    matches(text, "五行\n%s+六行…\n")
    falsy(text:find("七行", 1, true), "the intro is capped at six lines")

    for _, line in ipairs(lines) do
      truthy(vim.api.nvim_strwidth(line) <= 64, "line too wide: " .. line)
    end
    -- the review excerpt is truncated with an ellipsis(点评摘录被截断并带省略号)
    matches(text, "长长长…")
    -- a level 9 chapter collapses to the capped indent(九级章节收敛到封顶缩进)
    matches(text, "\n%s+超深层级")
  end)
end)

describe("preview TOC", function()
  local function many_chapters(n)
    local list = {}
    for i = 1, n do
      list[i] = { uid = 100 + i, idx = i, title = "第" .. i .. "章", level = 1, word_count = i == 1 and 0 or 3000 }
    end
    return { chapters = list }
  end

  it("lists every chapter, with no cap", function()
    local lines, _, toc = preview.build_lines({ title = "长书", author = "" }, { chapters = many_chapters(150) })
    local text = join(lines)
    matches(text, "第150章")
    falsy(text:find("省略", 1, true), "nothing is collapsed")
    local rows = 0
    for _ in pairs(toc) do
      rows = rows + 1
    end
    eq(rows, 149, "every chapter with text is clickable; the wordless cover is not")
  end)

  it("maps each TOC row to its chapter", function()
    local lines, _, toc = preview.build_lines({ title = "书", author = "" }, { chapters = many_chapters(5) })
    for row, chapter in pairs(toc) do
      truthy(lines[row]:find(chapter.title, 1, true), "row " .. row .. " shows " .. chapter.title)
    end
  end)

  it("marks the chapter being read, newest position wins", function()
    local data = {
      chapters = many_chapters(5),
      progress = { chapter_uid = "103", percent = 42, update_time = 100 },
    }
    -- the service is newer than the local record(服务端比本机记录更新)
    local lines, highlights, toc = preview.build_lines({ title = "书", author = "" }, data, {
      position = { chapter_uid = "102", updated_at = 50 },
    })
    local text = join(lines)
    matches(text, "▶ 读到 第3章 · 全书 42%%")
    local current = nil
    for _, mark in ipairs(highlights) do
      if mark.group == "WereadPreviewCurrent" and toc[mark.row] then
        current = toc[mark.row]
        break
      end
    end
    eq(current and current.uid, 103)

    -- this machine read later(本机读得更晚)
    lines = preview.build_lines({ title = "书", author = "" }, data, {
      position = { chapter_uid = "104", updated_at = 200 },
    })
    matches(join(lines), "▶ 读到 第4章")
  end)

  it("lays out for the preview width", function()
    local long = { chapters = { { uid = 1, idx = 1, title = string.rep("很长的章节名", 20), level = 1, word_count = 12345 } } }
    for _, width in ipairs({ 30, 50, 90 }) do
      local lines = preview.build_lines({ title = string.rep("书名", 40), author = "" }, { chapters = long }, { width = width })
      for _, line in ipairs(lines) do
        truthy(vim.api.nvim_strwidth(line) <= width, width .. " too wide: " .. line)
      end
      matches(join(lines), "1%.2万", "the word count stays visible on the right")
    end
  end)

  it("opens the book at the chapter on the row", function()
    local reader = require("weread.reader")
    local real_open = reader.open_book
    local opened = nil
    reader.open_book = function(book_id, opts)
      opened = { book_id = book_id, opts = opts }
    end
    local closed = false
    local buf = vim.api.nvim_create_buf(false, true)
    local lines, highlights, toc = preview.build_lines({ title = "书", author = "" }, { chapters = many_chapters(3) })
    local ns = vim.api.nvim_create_namespace("weread_preview_spec")
    local ctx = {
      buf = buf,
      picker = {
        close = function()
          closed = true
        end,
      },
      preview = {
        reset = function() end,
        set_title = function() end,
        set_lines = function(_, l)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, l)
        end,
        ns = function()
          return ns
        end,
      },
    }
    preview._show(ctx, { book_id = "777" }, lines, highlights, toc)
    local row = nil
    for r, chapter in pairs(toc) do
      if chapter.uid == 103 then
        row = r
      end
    end
    falsy(preview.open_row(buf, 1), "the title row opens nothing")
    truthy(preview.open_row(buf, row))
    truthy(closed, "the picker closes first")
    vim.wait(1000, function()
      return opened ~= nil
    end, 10)
    reader.open_book = real_open
    eq(opened.book_id, "777")
    eq(opened.opts.chapter_uid, 103)
  end)
end)

describe("preview.load", function()
  it("fetches once, then serves the cache", function()
    preview.invalidate()
    seen = {}
    local lines = await_async(function(cb)
      preview.load({ book_id = "111", title = "持续交付2.0", author = "乔梁" }, cb)
    end)
    local text = join(lines)
    matches(text, " 87%.8%%")
    matches(text, "▎热门点评  共 1234 条")
    matches(text, "▎目录  共 3 章")
    eq(count_requests("/book/info", "111"), 1)
    eq(count_requests("/review/list", "111"), 1)
    eq(count_requests("/book/chapterinfo", "111"), 1)

    -- a second read for the same book: nothing hits the network again
    -- (同一本书的第二次读取：不再碰网络)
    local again = await_async(function(cb)
      preview.load({ book_id = "111", title = "持续交付2.0", author = "乔梁" }, cb)
    end)
    eq(join(again), text, "the cached render is returned verbatim")
    eq(count_requests("/book/info", "111"), 1)
  end)

  it("does not cache a total failure", function()
    preview.invalidate()
    seen = {}
    local lines = await_async(function(cb)
      preview.load({ book_id = "404", title = "不存在", author = "" }, cb)
    end)
    matches(join(lines), "详情加载失败")
    -- a later read tries again: a failure must not stick to the cache
    -- (之后再读会重试：失败不能粘在缓存上)
    await_async(function(cb)
      preview.load({ book_id = "404", title = "不存在", author = "" }, cb)
    end)
    eq(count_requests("/book/info", "404"), 2)
  end)

  it("falls back to the web catalog for an uploaded book", function()
    -- the Agent API refuses the uploaded id for reviews and chapters; the
    -- preview must still show the TOC, from the web catalog pipeline
    -- (Agent API 拒绝上传书的点评与目录；预览仍要显示目录，从网页目录链路拿)
    preview.invalidate()
    seen = {}
    local lines = await_async(function(cb)
      preview.load({ book_id = "333", title = "我的私人笔记", author = "" }, cb)
    end)
    local text = join(lines)
    matches(text, "自己上传的书 · 无书城评分与点评")
    matches(text, "▎目录  共 2 章")
    matches(text, "开篇的话")
    falsy(text:find("点评：", 1, true), "the rejected review call stays out of the render")
    falsy(text:find("详情加载失败", 1, true), "the fallback TOC counts as success")
  end)
end)

describe("preview failures are quiet", function()
  it("renders errors inline instead of notifying", function()
    -- the preview paints what failed into its own lines; a notify on every
    -- highlighted row is noise the reader never asked for
    -- (预览把失败画进自己的行里；每次高亮都弹通知是读者没要过的噪音)
    preview.invalidate()
    local notified = {}
    local real_notify = vim.notify
    vim.notify = function(message, _level)
      notified[#notified + 1] = tostring(message)
    end

    local ok_info = await_async(function(cb)
      gateway_client.book_info("404", cb)
    end)
    local ok_reviews = await_async(function(cb)
      gateway_client.review_list("404", { count = 5 }, cb)
    end)
    local ok_chapters = await_async(function(cb)
      gateway_client.chapter_info("404", cb)
    end)

    vim.notify = real_notify
    falsy(ok_info)
    falsy(ok_reviews)
    falsy(ok_chapters)
    eq(#notified, 0, "preview gateway failures must not pop a notify")
  end)
end)

-- ------------------------------------------------------------------ snacks adapter

describe("preview.snacks", function()
  -- A stand-in for the snacks preview context: enough surface (reset /
  -- set_lines / set_title / ns) plus a real buffer for the markers.
  -- (替代 snacks 预览上下文的假身：面够用（reset / set_lines / set_title / ns），
  --  buffer 是真的，便于验证标记)
  local function fake_ctx(item, buf)
    local calls = { lines = nil, title = nil }
    local stand_in = {
      reset = function() end,
      set_lines = function(_, lines)
        calls.lines = lines
      end,
      set_title = function(_, title)
        calls.title = title
      end,
      ns = function()
        return vim.api.nvim_create_namespace("weread_preview_spec")
      end,
    }
    return { item = item, buf = buf, preview = stand_in }, calls
  end

  local function with_deferred(runner)
    local deferred = {}
    local real_defer = vim.defer_fn
    vim.defer_fn = function(fn, ms)
      deferred[#deferred + 1] = { fn = fn, ms = ms }
    end
    runner(deferred)
    vim.defer_fn = real_defer
  end

  it("renders a cached book immediately and marks the buffer", function()
    preview.invalidate()
    await_async(function(cb)
      preview.load({ book_id = "111", title = "持续交付2.0", author = "乔梁" }, cb)
    end)
    local buf = vim.api.nvim_create_buf(false, true)
    local ctx, calls = fake_ctx(
      { book = { book_id = "111", title = "持续交付2.0", author = "乔梁" }, text = "持续交付2.0 · ..." },
      buf
    )
    preview.snacks(ctx)
    truthy(calls.lines, "renders from the cache without any fetch")
    matches(join(calls.lines), " 87%.8%%")
    eq(calls.title, "持续交付2.0")
    eq(vim.b[buf].weread_preview_book, "111", "the marker names the book on the buffer")
  end)

  it("shows a placeholder, defers the fetch and repaints when it lands", function()
    preview.invalidate()
    with_deferred(function(deferred)
      local buf = vim.api.nvim_create_buf(false, true)
      local ctx, calls = fake_ctx({ book = { book_id = "222", title = "我的私人笔记" } }, buf)
      preview.snacks(ctx)
      matches(join(calls.lines), "正在加载", "the placeholder is up while loading")
      eq(#deferred, 1, "the fetch is deferred, not fired on highlight")

      deferred[1].fn()
      vim.wait(15000, function()
        return calls.lines and join(calls.lines):find("▎目录", 1, true) ~= nil
      end, 20)
      local text = join(calls.lines)
      matches(text, "自己上传的书 · 无书城评分与点评")
      matches(text, "▎目录  共 2 章")
    end)
  end)

  it("drops a late repaint once the reader moved on", function()
    preview.invalidate()
    seen = {}
    with_deferred(function(deferred)
      local buf = vim.api.nvim_create_buf(false, true)
      local ctx, calls = fake_ctx({ book = { book_id = "111", title = "持续交付2.0" } }, buf)
      preview.snacks(ctx)
      -- the reader scrolled to another book on the same preview buffer
      -- (读者在同一预览 buffer 上划到了另一本书)
      vim.b[buf].weread_preview_book = "999"
      local before = join(calls.lines)
      deferred[1].fn()
      vim.wait(15000, function()
        return count_requests("/book/chapterinfo", "111") > 0
      end, 20)
      -- give the scheduled repaint one tick to (not) happen(给计划中的重绘一拍时间，让它（不）发生)
      vim.wait(200, function()
        return false
      end, 20)
      eq(join(calls.lines), before, "the late render was dropped, the buffer untouched")
    end)
  end)
end)
