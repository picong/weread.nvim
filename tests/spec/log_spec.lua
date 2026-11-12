--[[
Tests for the file log: warnings and errors always land on disk, debug and info
only with the debug switch, the file is private and rolls over at 1 MB.
(文件日志的测试：warn/error 始终落盘，debug/info 仅在 debug 开关下落盘，文件私有，超过 1MB 滚动)
]]

local log = require("weread.log")

---@return string
local function new_path()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir .. "/weread.log"
end

---@param path string
---@return string
local function slurp(path)
  local file = io.open(path, "rb")
  if not file then
    return ""
  end
  local data = file:read("*a")
  file:close()
  return data
end

describe("log with debug off", function()
  it("writes warn and error to the file", function()
    local path = new_path()
    log.setup({ debug = false, path = path })
    log.warn("careful %s", "now")
    log.error("it broke: %d", 7)
    local text = slurp(path)
    matches(text, "%[WARN%] careful now")
    matches(text, "%[ERROR%] it broke: 7")
  end)

  it("keeps debug and info out of the file", function()
    local path = new_path()
    log.setup({ debug = false, path = path })
    log.debug("noisy detail")
    log.info("routine news")
    eq(slurp(path), "")
    eq(vim.uv.fs_stat(path), nil, "not even created")
  end)

  it("still keeps info in the in-memory tail", function()
    local path = new_path()
    log.setup({ debug = false, path = path })
    log.clear()
    log.info("remember me")
    log.debug("but not me")
    local tail = table.concat(log.tail(10), "\n")
    matches(tail, "remember me")
    falsy(tail:find("but not me", 1, true))
  end)

  it("creates the file with mode 0600", function()
    local path = new_path()
    log.setup({ debug = false, path = path })
    log.warn("x")
    eq(vim.fn.getfperm(path), "rw-------")
  end)

  it("creates the directory when it does not exist yet", function()
    local path = vim.fn.tempname() .. "/a/b/weread.log"
    log.setup({ debug = false, path = path })
    log.warn("deep")
    matches(slurp(path), "deep")
  end)
end)

describe("log with debug on", function()
  it("writes every level", function()
    local path = new_path()
    log.setup({ debug = true, path = path })
    log.debug("d")
    log.info("i")
    log.warn("w")
    log.error("e")
    local text = slurp(path)
    for _, level in ipairs({ "DEBUG", "INFO", "WARN", "ERROR" }) do
      matches(text, "%[" .. level .. "%]")
    end
  end)
end)

describe("log without a path", function()
  it("neither raises nor writes anywhere", function()
    log.setup({ debug = false })
    log.warn("nowhere to go")
    log.error("still fine")
    truthy(true)
    eq(log.path(), "")
  end)
end)

describe("log rolling", function()
  it("moves a file past 1 MB to .1 and starts a fresh one", function()
    local path = new_path()
    log.setup({ debug = false, path = path })
    local chunk = string.rep("x", 1000)
    for _ = 1, 1100 do -- ~1.1 MB
      log.warn("%s", chunk)
    end
    local rolled = vim.uv.fs_stat(path .. ".1")
    truthy(rolled, "a rolled file exists")
    truthy(rolled.size > 900 * 1024, "it holds the old content")
    local current = vim.uv.fs_stat(path)
    truthy(current, "and a current file continues")
    truthy(current.size < 1024 * 1024, "which is back under the limit")
  end)

  it("replaces the previous .1 instead of piling up", function()
    local path = new_path()
    vim.fn.writefile({ "ancient" }, path .. ".1")
    -- start with an almost full file so one more line rolls it
    -- (从一个几乎写满的文件开始，再写一行就滚动)
    local file = assert(io.open(path, "wb"))
    file:write(string.rep("y", 1024 * 1024 - 10))
    file:close()
    log.setup({ debug = false, path = path })
    log.warn("this one rolls the file")
    local rolled = slurp(path .. ".1")
    falsy(rolled:find("ancient", 1, true), "the old .1 was overwritten")
    truthy(#rolled > 1000000)
    matches(slurp(path), "this one rolls the file")
    local siblings = {}
    for name in vim.fs.dir(vim.fs.dirname(path)) do
      siblings[#siblings + 1] = name
    end
    table.sort(siblings)
    eq(siblings, { "weread.log", "weread.log.1" })
  end)

  it("recovers the size of an existing file after setup", function()
    local path = new_path()
    local file = assert(io.open(path, "wb"))
    file:write(string.rep("z", 1024 * 1024 - 50))
    file:close()
    log.setup({ debug = false, path = path })
    log.warn(string.rep("q", 200))
    truthy(vim.uv.fs_stat(path .. ".1"), "rolled even though this process wrote little")
  end)
end)

describe("log never raises", function()
  it("survives an unwritable target", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    -- the log path is a directory(日志路径是个目录)
    log.setup({ debug = false, path = dir })
    local ok = pcall(log.warn, "into a directory")
    truthy(ok)
  end)

  it("survives a bad format string", function()
    local path = new_path()
    log.setup({ debug = false, path = path })
    local ok = pcall(log.warn, "%d", "not a number")
    truthy(ok)
  end)
end)
