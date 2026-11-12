--[[
Tests for weread.http's cookie jar under concurrent persisting requests.

curl rewrites the whole jar it read at start. Two persisting requests in flight
at once used to lose each other's cookies: a page fetch that started before a
renewal wrote the stale tokens back after it.
(http 单测：并发持久化请求下的 cookie jar。curl 会把启动时读到的整份 jar 重写回去，过去两个
 同时在途的持久化请求会互相丢掉对方的 cookie：续期之前发出的页面请求，在续期之后把旧令牌写了回去)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

local server = mock_lib.start({
  {
    path = "/slow",
    handler = function()
      return { status = 200, ctype = "text/plain", body = "slow", delay = 400, headers = { "Set-Cookie: page=1; Path=/" } }
    end,
  },
  {
    path = "/renew",
    handler = function()
      return { status = 200, ctype = "text/plain", body = "ok", headers = { "Set-Cookie: wr_skey=new; Path=/" } }
    end,
  },
})

local config = require("weread.config")
local http = require("weread.http")
local cookies = require("weread.cookies")

config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct" })
config.ensure_dirs()
http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), proxy = "direct" })

---@param name string
---@return string|nil
local function jar_value(name)
  local cookie = cookies.get(http.load_cookies(), name)
  return cookie and cookie.value or nil
end

describe("http jar under concurrent requests", function()
  it("keeps a renewed cookie when an older persisting request finishes after it", function()
    local host = server.url:match("^https?://([^:/]+)")
    http.set_cookies({ { name = "wr_skey", value = "old", domain = host, path = "/", expires = 0 } })
    local finished = {}
    -- the page request starts first and finishes last
    -- (页面请求先发出、后结束)
    http.request({ url = server.url .. "/slow", persist = true, retries = 0 }, function()
      finished[#finished + 1] = "page"
    end)
    http.request({ url = server.url .. "/renew", persist = true, retries = 0 }, function()
      finished[#finished + 1] = "renew"
    end)
    vim.wait(5000, function()
      return #finished == 2
    end, 20)
    eq(finished, { "renew", "page" }, "the renewal finished first")
    eq(jar_value("wr_skey"), "new", "the renewed token survives whichever finished last")
    eq(jar_value("page"), "1", "and the page's own cookie was merged in too")
  end)

  it("leaves no private jar behind", function()
    local left = vim.fn.glob(config.path("tmp") .. "/*jar*", false, true)
    eq(#left, 0)
  end)
end)
