--[[
Tests for the official Agent API client and the shelf/search pickers, served by
a local mock gateway.
(官方 Agent API 客户端与书架/搜索选择器的测试，用本地 mock gateway 提供数据)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

local SHELF = {
  books = {
    {
      bookId = "43208843",
      title = "持续交付2.0",
      author = "乔梁",
      cover = "https://cdn.weread.qq.com/wrcover/t3_abc",
      category = "计算机",
      readUpdateTime = 1780666397,
      finishReading = 0,
    },
    {
      bookId = "3300045871",
      title = "三体全集",
      author = "刘慈欣",
      cover = "https://cdn.weread.qq.com/wrcover/t6_def",
      readUpdateTime = 1780660000,
      finishReading = 1,
    },
  },
  albums = { { albumInfo = { albumId = "album-1", name = "某有声书" } } },
  mp = { name = "公众号" },
  bookCount = 3,
}

local SEARCH = {
  sid = "s-1",
  hasMore = 0,
  results = {
    {
      title = "电子书",
      scope = 10,
      books = {
        {
          searchIdx = 1,
          newRating = 92.5,
          readingCount = 12345,
          bookInfo = {
            bookId = "907755",
            title = "三体",
            author = "刘慈欣",
            cover = "https://cdn.weread.qq.com/wrcover/t2_xyz",
          },
        },
      },
    },
    { title = "作者", scope = 6, books = {} },
  },
}

local seen = {}

local gateway
gateway = mock_lib.start({
  {
    path = "/api/agent/gateway",
    handler = function(_, _, body, headers)
      local request = vim.json.decode(body)
      seen[#seen + 1] = { request = request, headers = headers }

      if not headers:find("Bearer wrk%-test", 1) then
        return { status = 401, ctype = "application/json", body = '{"errCode":-2010,"errMsg":"用户不存在"}' }
      end
      if not request.skill_version or request.skill_version == "" then
        return { status = 400, ctype = "text/plain", body = "missing skill_version" }
      end
      if request.api_name == "/shelf/sync" then
        return { status = 200, ctype = "application/json", body = vim.json.encode(SHELF) }
      end
      if request.api_name == "/store/search" then
        return { status = 200, ctype = "application/json", body = vim.json.encode(SEARCH) }
      end
      if request.api_name == "/book/info" then
        return { status = 200, ctype = "application/json", body = '{"bookId":"907755","title":"三体"}' }
      end
      if request.api_name == "/book/getprogress" then
        return { status = 200, ctype = "application/json", body = '{"book":{"progress":42}}' }
      end
      if request.api_name == "/expired" then
        return { status = 200, ctype = "application/json", body = '{"errCode":-2012,"errMsg":"登录超时"}' }
      end
      if request.api_name == "/upgrade" then
        return { status = 200, ctype = "application/json", body = '{"upgrade_info":{"skill_version":"2.0.0"}}' }
      end
      return { status = 404, ctype = "text/plain", body = "unknown api_name " .. tostring(request.api_name) }
    end,
  },
})

local config = require("weread.config")
local http = require("weread.http")
local auth = require("weread.auth")
local gateway_client = require("weread.api_gateway")

config.setup({ data_dir = tmpdir, gateway_url = gateway.url, proxy = "direct" })
config.ensure_dirs()
http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 8, retries = 0, proxy = "direct" })

-- a logged-in account with an official api key
auth.save_credentials({
  version = 1,
  login_method = "qr",
  account = { name = "测试账号", user_vid = "vid" },
  api_key = "wrk-test-key",
  cookies = { wr_vid = "vid", wr_skey = "skey", wr_ql = "0", wr_rt = "rt" },
})

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

describe("api_gateway.gateway_url", function()
  it("accepts an origin or a full endpoint url", function()
    local saved = config.get().gateway_url
    config.setup({ data_dir = tmpdir, gateway_url = nil, proxy = "direct" })
    eq(gateway_client.gateway_url(), "https://i.weread.qq.com/api/agent/gateway", "default")

    config.setup({ data_dir = tmpdir, gateway_url = "https://example.com", proxy = "direct" })
    eq(gateway_client.gateway_url(), "https://example.com/api/agent/gateway", "bare origin gains the path")

    config.setup({ data_dir = tmpdir, gateway_url = "https://example.com/", proxy = "direct" })
    eq(gateway_client.gateway_url(), "https://example.com/api/agent/gateway", "trailing slash")

    config.setup({ data_dir = tmpdir, gateway_url = "https://example.com/custom/path", proxy = "direct" })
    eq(gateway_client.gateway_url(), "https://example.com/custom/path", "a full url is left alone")

    config.setup({ data_dir = tmpdir, gateway_url = saved, proxy = "direct" })
  end)
end)

describe("api_gateway.call", function()
  it("sends the api key, the skill version and no nested params", function()
    seen = {}
    local ok = await_async(function(cb)
      gateway_client.call("/book/info", { bookId = "907755" }, cb)
    end)
    truthy(ok)
    eq(#seen, 1)
    eq(seen[1].request.api_name, "/book/info")
    eq(seen[1].request.bookId, "907755", "business params stay top level")
    truthy(seen[1].request.skill_version, "every request carries skill_version")
  end)

  it("turns a revoked session into a re-login hint", function()
    local ok, message = await_async(function(cb)
      gateway_client.call("/expired", {}, cb)
    end)
    falsy(ok)
    matches(message, ":WeReadLogin")
  end)

  it("understands the gateway's lowercase error fields", function()
    -- the real gateway answers errcode/errmsg, unlike the web API's errCode
    -- (真实 gateway 返回 errcode/errmsg，与网页 API 的 errCode 不同)
    local auth_module = require("weread.auth")
    matches(auth_module.describe_error({ errcode = -2010, errmsg = "用户不存在" }), ":WeReadLogin")
    eq(auth_module.describe_error({ errcode = -1, errmsg = "别的错误" }), "别的错误")
  end)

  it("stops on upgrade_info instead of guessing", function()
    local ok, message = await_async(function(cb)
      gateway_client.call("/upgrade", {}, cb)
    end)
    falsy(ok)
    matches(message, "升级")
  end)

  it("explains a missing api key", function()
    local saved = auth.load_credentials().api_key
    auth.save_credentials({
      version = 1,
      account = { name = "n", user_vid = "v" },
      api_key = "",
      cookies = { wr_vid = "v", wr_skey = "s" },
    })
    local ok, message = await_async(function(cb)
      gateway_client.call("/book/info", { bookId = "1" }, cb)
    end)
    auth.save_credentials({
      version = 1,
      account = { name = "n", user_vid = "v" },
      api_key = saved,
      cookies = { wr_vid = "v", wr_skey = "s" },
    })
    falsy(ok)
    matches(message, ":WeReadLogin")
  end)
end)

describe("api_gateway.shelf", function()
  it("lists books, skips albums and upgrades cover urls", function()
    local ok, books = await_async(function(cb)
      gateway_client.shelf(cb)
    end)
    truthy(ok, tostring(books))
    eq(#books, 2, "albums and the mp entry are not books")
    eq(books[1].book_id, "43208843")
    eq(books[1].title, "持续交付2.0")
    eq(books[1].finish_reading, false)
    eq(books[2].finish_reading, true, "finishReading 1 becomes a boolean")
    eq(books[1].cover, "https://cdn.weread.qq.com/wrcover/t9_abc", "t3 -> t9")
  end)
end)

describe("api_gateway.search", function()
  it("flattens the result groups into books", function()
    local ok, books = await_async(function(cb)
      gateway_client.search("三体", cb)
    end)
    truthy(ok, tostring(books))
    eq(#books, 1, "the author group contributed no books")
    eq(books[1].book_id, "907755")
    eq(books[1].title, "三体")
    eq(books[1].rating, "92.5%")
  end)
end)

describe("api_gateway.progress", function()
  it("passes the payload through", function()
    local ok, data = await_async(function(cb)
      gateway_client.progress("907755", cb)
    end)
    truthy(ok)
    eq(data.book.progress, 42)
  end)
end)

-- ------------------------------------------------------------------ pickers

-- Replace the ui module reference (not its contents) so the runner's per-spec
-- snapshot restores the real one afterwards.
-- (替换 ui 模块的引用而非其内容，这样运行器的按 spec 快照能还原真身)
local captured = nil
local real_ui = require("weread.ui")
package.loaded["weread.ui"] = setmetatable({
  select = function(opts)
    captured = opts
  end,
}, { __index = real_ui })

describe("reader pickers", function()
  -- `weread.reader` captures the ui module at load time, so a copy loaded by an
  -- earlier spec would keep the real picker and block on stdin. Drop it and let
  -- it pick up the stub above.
  -- (weread.reader 在加载时就抓住了 ui 模块，因此更早的 spec 加载过的副本会继续用真选择器，
  --  卡在标准输入上。丢掉它，让它去拿上面的桩)
  package.loaded["weread.reader"] = nil
  local reader = require("weread.reader")

  ---@param runner fun()
  local function settle(runner)
    runner()
    vim.wait(15000, function()
      return captured ~= nil
    end, 20)
  end

  it("formats the shelf with local reading positions first", function()
    local cache = require("weread.cache")
    cache.write_position("43208843", {
      chapter_key = "0002",
      chapter_index = 2,
      chapter_uid = "2",
      line = 40,
      updated_at = os.time(),
    })

    captured = nil
    settle(function()
      reader.pick_book()
    end)

    truthy(captured, "the picker opened")
    matches(captured.title, "书架")
    eq(#captured.items, 2)

    -- sorted by last read time, newest first
    -- (按最近阅读时间倒序)
    eq(captured.items[1].book.book_id, "43208843")
    truthy(captured.items[1].text:find("本地读到第 2 章", 1, true), "shows the local position")
    truthy(captured.items[2].text:find("已读完", 1, true), "shows the shelf badge")
  end)

  it("formats search results", function()
    captured = nil
    settle(function()
      reader.search_book("三体")
    end)
    truthy(captured)
    matches(captured.title, "三体")
    eq(#captured.items, 1)
    truthy(captured.items[1].text:find("刘慈欣", 1, true))
  end)
end)

describe("api_gateway default endpoint", function()
  it("falls back to the configured default instead of a second literal", function()
    local config_mod = require("weread.config")
    local previous = config_mod.get().gateway_url
    config_mod.get().gateway_url = ""
    local url = require("weread.api_gateway").gateway_url()
    config_mod.get().gateway_url = previous
    eq(url, config_mod.defaults.gateway_url .. "/api/agent/gateway")
  end)

  it("keeps the api key out of the curl command line", function()
    local original = vim.system
    local argv
    vim.system = function(args, _, on_exit)
      argv = vim.deepcopy(args)
      on_exit({ code = 0, stdout = "200", stderr = "" })
      return { kill = function() end }
    end
    local ok = pcall(function()
      local done = false
      require("weread.http").request({
        url = "https://example.invalid/api/agent/gateway",
        headers = { Authorization = "Bearer wrk-test-cmdline" },
        retries = 0,
      }, function()
        done = true
      end)
      vim.wait(2000, function()
        return done
      end, 10)
    end)
    vim.system = original
    truthy(ok)
    falsy(table.concat(argv, "\n"):find("wrk-test-cmdline", 1, true), "the bearer token must not appear in argv")
  end)
end)
