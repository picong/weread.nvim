--[[
Tests for weread.config (setup validation, path handling, directory layout) and
for the setup-time checks in weread (init.lua).
(config 单测：setup 校验、路径处理、目录布局，以及 init.lua 里 setup 时的检查)
]]

local config = require("weread.config")

local tmpdir = "/tmp/weread-test-config"
vim.fn.delete(tmpdir, "rf")
vim.fn.mkdir(tmpdir, "p")

---Run fn while collecting what vim.notify was told.
---(执行 fn，同时收集 vim.notify 收到的内容)
---@param fn fun()
---@return { message: string, level: integer }[]
local function notices(fn)
  local seen = {}
  local original = vim.notify
  vim.notify = function(message, level)
    seen[#seen + 1] = { message = message, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = original
  if not ok then
    error(err, 0)
  end
  return seen
end

describe("config.setup validation", function()
  it("keeps the default table when a table key is given a boolean", function()
    local seen = notices(function()
      config.setup({ data_dir = tmpdir, layout = false })
    end)
    eq(type(config.get().layout), "table", "layout stays a table")
    eq(config.get().layout.page_chars, config.defaults.layout.page_chars)
    eq(#seen, 1, "one warning")
    eq(seen[1].level, vim.log.levels.WARN)
    matches(seen[1].message, "layout")
  end)

  it("warns about unknown top-level keys once, listing them all", function()
    local seen = notices(function()
      config.setup({ data_dir = tmpdir, bogus = 1, another = true })
    end)
    eq(#seen, 1)
    eq(seen[1].level, vim.log.levels.WARN)
    matches(seen[1].message, "another")
    matches(seen[1].message, "bogus")
    eq(config.get().bogus, nil, "and the unknown key is not kept")
  end)

  it("skips keys that older versions documented without a warning", function()
    local seen = notices(function()
      config.setup({
        data_dir = tmpdir,
        font = "Noto Serif CJK SC",
        paragraph = { compact = true, chapter_title = false, block_gap = 1 },
      })
    end)
    eq(#seen, 0, "a retired key is not a typo")
    eq(config.get().paragraph.chapter_title, nil, "and it is not kept")
    eq(config.get().paragraph.compact, true, "its valid siblings are")
  end)

  it("still reports a real typo next to a retired key", function()
    local seen = notices(function()
      config.setup({ data_dir = tmpdir, paragraph = { chapter_title = false, compat = true } })
    end)
    eq(#seen, 1)
    matches(seen[1].message, "paragraph.compat")
    falsy(seen[1].message:find("chapter_title", 1, true))
  end)

  it("warns about unknown keys inside a nested table", function()
    local seen = notices(function()
      config.setup({ data_dir = tmpdir, layout = { page_chrs = 30 } })
    end)
    eq(#seen, 1)
    matches(seen[1].message, "layout.page_chrs")
  end)

  it("falls back to the default when the type differs", function()
    local seen = notices(function()
      config.setup({ data_dir = tmpdir, sync_interval = "often", image = { max_width = "wide", max_height = 9 } })
    end)
    eq(config.get().sync_interval, config.defaults.sync_interval)
    eq(config.get().image.max_width, config.defaults.image.max_width)
    eq(config.get().image.max_height, 9, "valid siblings are kept")
    eq(#seen, 2)
  end)

  it("accepts keys whose default is nil, with their own type", function()
    local seen = notices(function()
      config.setup({
        data_dir = tmpdir,
        proxy = "direct",
        cursorline = "screen",
        layout = { line_height = 140, heading_icons = false },
      })
    end)
    eq(#seen, 0, "nothing to complain about")
    eq(config.get().proxy, "direct")
    eq(config.get().cursorline, "screen")
    eq(config.get().layout.line_height, 140)
    eq(config.get().layout.heading_icons, false)
  end)

  it("rejects a wrong type for a nil-default key", function()
    local seen = notices(function()
      config.setup({ data_dir = tmpdir, proxy = 8080 })
    end)
    eq(#seen, 1)
    matches(seen[1].message, "proxy")
    eq(config.get().proxy, nil)
  end)

  it("does not report debug as unknown, and resolves it", function()
    local seen = notices(function()
      config.setup({ data_dir = tmpdir, debug = true })
    end)
    eq(#seen, 0)
    eq(config.get().debug, true)
    notices(function()
      config.setup({ data_dir = tmpdir })
    end)
    eq(config.get().debug, false)
  end)

  it("no longer carries the dead `font` key, and ignores it quietly", function()
    eq(config.defaults.font, nil)
    local seen = notices(function()
      config.setup({ data_dir = tmpdir, font = "Noto Serif CJK SC" })
    end)
    eq(#seen, 0, "a retired key is not a typo")
    eq(config.get().font, nil, "and it is not kept")
  end)

  it("ignores a non-table argument", function()
    local seen = notices(function()
      config.setup("oops")
    end)
    eq(#seen, 1)
    eq(config.get().sync_interval, config.defaults.sync_interval)
    -- restore a safe data dir for the rest of the file
    -- (还原一个安全的数据目录给后面的用例)
    notices(function()
      config.setup({ data_dir = tmpdir })
    end)
  end)

  it("treats an invalid theme as not pinned", function()
    notices(function()
      config.setup({ data_dir = tmpdir, theme = 3 })
    end)
    eq(config.theme_pinned(), false)
    notices(function()
      config.setup({ data_dir = tmpdir, theme = "paper" })
    end)
    eq(config.theme_pinned(), true)
  end)
end)

describe("config.data_dir", function()
  it("expands ~ and makes the path absolute", function()
    notices(function()
      config.setup({ data_dir = "~/weread-config-spec" })
    end)
    eq(config.data_dir(), vim.uv.os_homedir() .. "/weread-config-spec")

    local cwd = vim.uv.cwd()
    notices(function()
      config.setup({ data_dir = "relative/dir" })
    end)
    eq(config.data_dir(), cwd .. "/relative/dir")
    notices(function()
      config.setup({ data_dir = tmpdir })
    end)
  end)

  it("drops a trailing slash so joined paths stay clean", function()
    notices(function()
      config.setup({ data_dir = tmpdir .. "/" })
    end)
    eq(config.data_dir(), tmpdir)
    eq(config.path("books"), tmpdir .. "/books")
  end)

  it("refuses an empty string rather than meaning the working directory", function()
    local seen = notices(function()
      config.setup({ data_dir = "" })
    end)
    eq(#seen, 1)
    matches(seen[1].message, "data_dir")
    eq(config.data_dir(), vim.fn.stdpath("data") .. "/weread")
    notices(function()
      config.setup({ data_dir = tmpdir })
    end)
  end)
end)

describe("config url checks", function()
  it("warns about a plain-http remote", function()
    local seen = notices(function()
      config.setup({ data_dir = tmpdir, base_url = "http://weread.example.com" })
    end)
    eq(#seen, 1)
    eq(seen[1].level, vim.log.levels.WARN)
    matches(seen[1].message, "base_url")
    matches(seen[1].message, "https")
  end)

  it("warns for the gateway url too", function()
    local seen = notices(function()
      config.setup({ data_dir = tmpdir, gateway_url = "http://i.weread.example.com/api/agent/gateway" })
    end)
    eq(#seen, 1)
    matches(seen[1].message, "gateway_url")
  end)

  it("stays silent for https and for local test servers", function()
    local seen = notices(function()
      config.setup({ data_dir = tmpdir, base_url = "https://weread.qq.com", gateway_url = "HTTPS://i.weread.qq.com" })
      config.setup({ data_dir = tmpdir, base_url = "http://127.0.0.1:8123", gateway_url = "http://127.0.0.1:8123" })
      config.setup({ data_dir = tmpdir, base_url = "http://localhost:8123", gateway_url = "http://[::1]:8123/x" })
    end)
    eq(#seen, 0)
  end)

  it("is not fooled by a local-looking userinfo or path", function()
    local seen = notices(function()
      config.setup({ data_dir = tmpdir, base_url = "http://127.0.0.1@evil.example.com/" })
    end)
    eq(#seen, 1)
    seen = notices(function()
      config.setup({ data_dir = tmpdir, base_url = "http://evil.example.com/127.0.0.1" })
    end)
    eq(#seen, 1)
  end)
end)

describe("config.web_origin", function()
  it("strips trailing slashes", function()
    notices(function()
      config.setup({ data_dir = tmpdir, base_url = "http://127.0.0.1:9///" })
    end)
    eq(config.web_origin(), "http://127.0.0.1:9")
    notices(function()
      config.setup({ data_dir = tmpdir })
    end)
    eq(config.web_origin(), "https://weread.qq.com")
  end)
end)

describe("config.ensure_dirs", function()
  it("creates the tree and keeps the credential directories private", function()
    local root = tmpdir .. "/private"
    notices(function()
      config.setup({ data_dir = root })
    end)
    eq(config.ensure_dirs(), root)
    eq(vim.fn.isdirectory(root .. "/books"), 1)
    eq(vim.fn.isdirectory(root .. "/tmp"), 1)
    -- start from something looser, as an older install would have left it
    -- (从更宽松的权限开始，就像旧版本留下的那样)
    assert(vim.uv.fs_chmod(root, tonumber("755", 8)))
    assert(vim.uv.fs_chmod(root .. "/tmp", tonumber("755", 8)))
    config.ensure_dirs()
    eq(bit.band(vim.uv.fs_stat(root).mode, tonumber("777", 8)), tonumber("700", 8))
    eq(bit.band(vim.uv.fs_stat(root .. "/tmp").mode, tonumber("777", 8)), tonumber("700", 8))
    notices(function()
      config.setup({ data_dir = tmpdir })
    end)
  end)

  it("never changes the owner's bits, so a read-only directory stays read-only", function()
    local root = tmpdir .. "/readonly"
    notices(function()
      config.setup({ data_dir = root })
    end)
    config.ensure_dirs()
    assert(vim.uv.fs_chmod(root, tonumber("550", 8)))
    config.ensure_dirs()
    eq(bit.band(vim.uv.fs_stat(root).mode, tonumber("777", 8)), tonumber("500", 8), "group lost its access, owner still cannot write")
    assert(vim.uv.fs_chmod(root, tonumber("700", 8)))
    notices(function()
      config.setup({ data_dir = tmpdir })
    end)
  end)

  it("does not throw when chmod fails", function()
    notices(function()
      config.setup({ data_dir = tmpdir .. "/chmod-fails" })
    end)
    local original = vim.uv.fs_chmod
    vim.uv.fs_chmod = function()
      return nil, "EPERM: operation not permitted"
    end
    local ok, err = pcall(config.ensure_dirs)
    vim.uv.fs_chmod = original
    truthy(ok, tostring(err))
    notices(function()
      config.setup({ data_dir = tmpdir })
    end)
  end)
end)

describe("weread.setup", function()
  ---Load a fresh copy of the entry module, so its once-only flags start clear.
  ---(加载一份全新的入口模块，让它的「只提醒一次」标志从头开始)
  ---@return table
  local function fresh_weread()
    package.loaded["weread"] = nil
    return require("weread")
  end

  ---@param executable_curl integer what `executable("curl")` answers
  ---@param fn fun()
  ---@return { message: string, level: integer }[]
  local function with_curl(executable_curl, fn)
    local original = vim.fn.executable
    vim.fn.executable = function(name)
      if name == "curl" then
        return executable_curl
      end
      return original(name)
    end
    local ok, seen = pcall(notices, fn)
    vim.fn.executable = original
    if not ok then
      error(seen, 0)
    end
    return seen
  end

  local function setup_options()
    return { data_dir = tmpdir .. "/init", sync_interval = 0, sync_pull = false, keymaps = false, proxy = "direct" }
  end

  it("warns once when curl is missing", function()
    local weread = fresh_weread()
    local seen = with_curl(0, function()
      weread.setup(setup_options())
      weread.setup(setup_options())
    end)
    local curl_notices = vim.tbl_filter(function(item)
      return item.message:find("curl", 1, true) ~= nil
    end, seen)
    eq(#curl_notices, 1, "said once, however many times setup ran")
    eq(curl_notices[1].level, vim.log.levels.WARN)
  end)

  it("stays quiet when curl is there", function()
    local weread = fresh_weread()
    local seen = with_curl(1, function()
      weread.setup(setup_options())
    end)
    eq(#seen, 0)
  end)

  it("no longer exports the unused is_setup", function()
    eq(fresh_weread().is_setup, nil)
  end)

  it("takes debug from the resolved config", function()
    local weread = fresh_weread()
    local options = setup_options()
    options.debug = true
    notices(function()
      weread.setup(options)
    end)
    eq(require("weread.log").enabled(), true)
    options.debug = nil
    notices(function()
      weread.setup(options)
    end)
    eq(require("weread.log").enabled(), false)
  end)
end)
