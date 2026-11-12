--[[
Tests for the preferences store: cached in memory, written through, and safe
against a damaged file.
(偏好存储的测试：内存缓存、写穿，以及损坏文件下的安全性)
]]

local config = require("weread.config")
local cache = require("weread.cache")
local prefs = require("weread.prefs")

local function fresh_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  config.setup({ data_dir = dir })
  prefs._reset()
  return dir
end

describe("prefs", function()
  it("starts empty and stores values", function()
    fresh_dir()
    eq(prefs.get("theme"), nil)
    prefs.set("theme", "sepia")
    eq(prefs.get("theme"), "sepia")
    eq(prefs.all().theme, "sepia")
  end)

  it("writes through to disk", function()
    local dir = fresh_dir()
    local ok, err = prefs.set("font", "LXGW")
    eq(ok, true, tostring(err))
    eq(cache.read_json(dir .. "/preferences.json").font, "LXGW")
  end)

  it("reads the file once and serves later reads from memory", function()
    local dir = fresh_dir()
    prefs.set("theme", "dark")

    -- Change the file behind its back: the cached value must still win.
    -- (背着它改文件：缓存里的值必须仍然生效)
    cache.write_json(dir .. "/preferences.json", { theme = "changed-on-disk" })
    eq(prefs.get("theme"), "dark")

    -- ...until the cache is reset, as after a restart.
    -- (……直到缓存被重置，就像重启之后)
    prefs._reset()
    eq(prefs.get("theme"), "changed-on-disk")
  end)

  it("does not read the file again on every get", function()
    fresh_dir()
    prefs.set("a", 1)
    local reads = 0
    local original = cache.read_json
    cache.read_json = function(...)
      reads = reads + 1
      return original(...)
    end
    prefs.get("a")
    prefs.get("a")
    prefs.all()
    cache.read_json = original
    eq(reads, 0, "all served from memory")
  end)

  it("hands out copies so a caller cannot edit the cache", function()
    fresh_dir()
    prefs.set("nested", { size = 12 })
    prefs.get("nested").size = 99
    prefs.all().nested.size = 77
    eq(prefs.get("nested").size, 12)
  end)

  it("keeps the other keys when one is set", function()
    local dir = fresh_dir()
    prefs.set("a", 1)
    prefs.set("b", 2)
    prefs._reset()
    eq(prefs.get("a"), 1)
    eq(prefs.get("b"), 2)
    eq(cache.read_json(dir .. "/preferences.json").b, 2)
  end)

  it("follows the data directory", function()
    fresh_dir()
    prefs.set("theme", "one")
    local other = vim.fn.tempname()
    vim.fn.mkdir(other, "p")
    config.setup({ data_dir = other })
    eq(prefs.get("theme"), nil, "a different directory starts from its own file")
  end)

  it("clear removes the file and the memory copy", function()
    local dir = fresh_dir()
    prefs.set("theme", "x")
    prefs.clear()
    eq(prefs.get("theme"), nil)
    eq(vim.uv.fs_stat(dir .. "/preferences.json"), nil)
  end)

  it("keeps a damaged file as a backup and starts over", function()
    local dir = fresh_dir()
    cache.write(dir .. "/preferences.json", "{not json")

    eq(prefs.get("theme"), nil, "reads as empty")
    prefs.set("theme", "dark")

    eq(prefs.get("theme"), "dark")
    local backups = {}
    for name in vim.fs.dir(dir) do
      if name:find("preferences.json.corrupt-", 1, true) then
        backups[#backups + 1] = name
      end
    end
    eq(#backups, 1, "the damaged file was kept")
    eq(cache.read(dir .. "/" .. backups[1]), "{not json")
  end)

  it("reports a failed write but keeps the value in memory", function()
    local dir = fresh_dir()
    -- a regular file where preferences.json's directory should be(把数据目录换成一个普通文件)
    vim.fn.delete(dir, "rf")
    cache.write(dir, "i am a file")
    prefs._reset()
    local ok, err = prefs.set("theme", "dark")
    eq(ok, false)
    truthy(err and err ~= "")
    eq(prefs.get("theme"), "dark", "the session still sees the choice")
  end)
end)
