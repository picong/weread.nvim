--[[
Tests for the reading statistics: the gateway normalizer (served by a mock
gateway), the period arithmetic and the render of each period.
(阅读统计的测试：gateway 归一化（mock gateway 提供数据）、周期运算以及各周期的渲染)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

local MONTH = os.time({ year = 2026, month = 10, day = 1, hour = 0 })
local DAY = 86400

local PAYLOAD = {
  baseTime = MONTH,
  totalReadTime = 146766,
  dayAverageReadTime = 10483,
  readDays = 3,
  compare = -0.0565,
  readTimes = {
    [tostring(MONTH)] = 6731,
    [tostring(MONTH + DAY)] = 7849,
    [tostring(MONTH + 7 * DAY)] = 17193,
  },
  readStat = { { counts = "7本", stat = "读过" }, { counts = "129条", stat = "笔记" } },
  readLongest = {
    { readTime = 61037, tags = { "笔记最多" }, book = { title = "人月神话", author = "布鲁克斯" } },
    { readTime = 7026, tags = {}, albumInfo = {} },
  },
  preferCategory = {
    { categoryTitle = "计算机", readingTime = 7019, readingCount = 2 },
    { categoryTitle = "历史", readingTime = 0, readingCount = 1 },
  },
  preferTime = { 0, 0, 10, 40, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5 },
  preferTimeWord = "偏好上午阅读",
}

local seen = {}
local gateway = mock_lib.start({
  {
    path = "/api/agent/gateway",
    handler = function(_, _, body)
      local request = vim.json.decode(body)
      seen[#seen + 1] = request
      if request.api_name == "/readdata/detail" then
        return { status = 200, ctype = "application/json", body = vim.json.encode(PAYLOAD) }
      end
      return { status = 200, ctype = "application/json", body = '{"errcode":-1,"errmsg":"不存在"}' }
    end,
  },
})

local config = require("weread.config")
local http = require("weread.http")
local auth = require("weread.auth")
local stats = require("weread.stats")

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

local function fetch(mode)
  local result, done = nil, false
  require("weread.api_gateway").read_stats(mode, 0, function(ok, data)
    result = { ok = ok, data = data }
    done = true
  end)
  vim.wait(15000, function()
    return done
  end, 20)
  return result
end

describe("api_gateway.read_stats", function()
  it("normalizes buckets, books and preferences", function()
    local result = fetch("monthly")
    truthy(result.ok, tostring(result.data))
    local data = result.data
    eq(seen[#seen].mode, "monthly")
    eq(seen[#seen].baseTime, 0)
    eq(data.total, 146766)
    eq(#data.buckets, 3)
    eq(data.buckets[1].at, MONTH, "buckets are sorted by time")
    eq(data.longest[1].title, "人月神话")
    truthy(data.longest[2].audio, "an albumInfo entry is an audiobook")
    eq(#data.prefer_time, 24)
  end)
end)

describe("stats formatting", function()
  it("formats durations", function()
    eq(stats.duration(0), "0分钟")
    eq(stats.duration(30), "不到1分钟")
    eq(stats.duration(35 * 60), "35分钟")
    eq(stats.duration(3600), "1小时")
    eq(stats.duration(3661), "1小时1分")
  end)

  it("steps through calendar periods", function()
    local jan = os.time({ year = 2026, month = 1, day = 1, hour = 0 })
    eq(os.date("%Y-%m-%d", stats.step("monthly", jan, -1)), "2025-12-01")
    eq(os.date("%Y-%m-%d", stats.step("annually", jan, 1)), "2027-01-01")
    eq(os.date("%Y-%m-%d", stats.step("weekly", jan, 1)), "2026-01-08")
    eq(stats.step("overall", jan, 1), nil)
  end)
end)

describe("stats.build_lines", function()
  local data = fetch("monthly").data

  it("renders the month as a calendar", function()
    local lines = stats.build_lines(data, { width = 62 })
    local text = table.concat(lines, "\n")
    matches(text, "2026年10月")
    matches(text, "共读 40小时46分")
    matches(text, "比上月 ↓ 6%%")
    matches(text, "▎日历")
    matches(text, " 一   二   三")
    matches(text, "人月神话")
    matches(text, "听书", "the empty audiobook entry is named")
    matches(text, "▎时段  偏好上午阅读")
    falsy(text:find("历史", 1, true), "a category with no time is left out")
    for _, line in ipairs(lines) do
      truthy(vim.api.nvim_strwidth(line) <= 62, "too wide: " .. line)
    end
  end)

  it("renders the other periods as bars", function()
    for _, mode in ipairs({ "weekly", "annually", "overall" }) do
      local copy = vim.deepcopy(data)
      copy.mode = mode
      local lines = stats.build_lines(copy, { width = 62 })
      local text = table.concat(lines, "\n")
      matches(text, "█", mode .. " draws bars")
      for _, line in ipairs(lines) do
        truthy(vim.api.nvim_strwidth(line) <= 62, mode .. " too wide: " .. line)
      end
    end
  end)
end)
