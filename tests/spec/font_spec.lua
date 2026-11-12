--[[
Tests for the reading font: WeRead's catalogue, local font listing, the
remembered choice, and the transient kitty switch — without touching the real
terminal, the network or the user's fonts.
(阅读字体单测：微信读书目录、本机字体列表、记住的选择与 kitty 临时切换——不碰真实终端、
 网络或用户字体)
]]

local saved_env = {
  TERM = vim.env.TERM,
  KITTY_WINDOW_ID = vim.env.KITTY_WINDOW_ID,
  XDG_CONFIG_HOME = vim.env.XDG_CONFIG_HOME,
  XDG_DATA_HOME = vim.env.XDG_DATA_HOME,
  KITTY_CONFIG_DIRECTORY = vim.env.KITTY_CONFIG_DIRECTORY,
  KITTY_LISTEN_ON = vim.env.KITTY_LISTEN_ON,
  KITTY_PID = vim.env.KITTY_PID,
}

local config = require("weread.config")
local tmpdir = "/tmp/weread-test-font"
vim.fn.delete(tmpdir, "rf")
vim.fn.mkdir(tmpdir, "p")
config.setup({ data_dir = tmpdir })

-- Keep every path inside the test directory: the real kitty.conf, the real
-- fontconfig directory and the real data dir must not be touched.
-- (所有路径都关在测试目录里：真实的 kitty.conf、fontconfig 目录与数据目录都不能碰)
vim.env.XDG_CONFIG_HOME = tmpdir
vim.env.XDG_DATA_HOME = tmpdir .. "/xdg"
vim.env.KITTY_CONFIG_DIRECTORY = tmpdir .. "/kitty"
vim.env.KITTY_LISTEN_ON = nil
vim.env.KITTY_PID = nil
vim.env.KITTY_WINDOW_ID = "1"
vim.env.TERM = "xterm-kitty"
vim.fn.mkdir(tmpdir .. "/kitty", "p")
vim.fn.writefile({ "font_family Maple Mono NF CN", "font_size 13.5" }, tmpdir .. "/kitty/kitty.conf")

local cache = require("weread.cache")
local font = require("weread.font")
local catalog = require("weread.font_catalog")
local kitty = require("weread.font_kitty")
local prefs = require("weread.prefs")

-- The tests run without a real kitty, and some machines have no `kitten` in
-- PATH; pretend the probe precondition holds so the switching logic itself is
-- what is exercised.
-- (测试环境没有真实 kitty，有的机器 PATH 里也没有 kitten；假装探测前提成立，专测切换逻辑本身)
local real_available = kitty.available
kitty.available = function()
  return true
end

local meta = tmpdir .. "/xdg/fonts/weread/.weread-fonts.json"
local fontdir = tmpdir .. "/xdg/fonts/weread"
vim.fn.mkdir(fontdir, "p")

local function reset()
  vim.env.KITTY_LISTEN_ON = "unix:/tmp/weread-test-kitty.sock"
  font._reset()
  font._downloading = {}
  kitty.reset()
  prefs.clear()
  prefs._reset()
  vim.fn.delete(meta)
  vim.fn.delete(tmpdir .. "/fonts/catalog.json")
end

local function write_meta(fonts)
  vim.fn.mkdir(fontdir, "p")
  cache.write_json(meta, { version = 1, fonts = fonts })
end

---Install a fake font file and registry entry. (伪造一个已安装字体)
local function fake_installed(id, name, family)
  local file = id .. ".woff"
  vim.fn.writefile({ "fake font" }, fontdir .. "/" .. file)
  write_meta({
    [id] = { name = name, family = family, file = file, suffix = "woff", size = 9, installed_at = os.time() },
  })
end

local function stub_runs()
  local calls = {}
  local sync_calls = {}
  local real_run, real_sync = kitty._run, kitty._run_sync
  local real_launch = kitty._launch_overrides
  kitty._launch_overrides = function()
    return {}
  end
  kitty._run = function(args, callback)
    calls[#calls + 1] = vim.deepcopy(args)
    callback({ code = 0, stdout = "" }, nil)
  end
  kitty._run_sync = function(args)
    sync_calls[#sync_calls + 1] = vim.deepcopy(args)
    return { code = 0, stdout = "" }
  end
  -- Prime the remote-control probe, then forget that call: the tests assert on
  -- the font transitions, not on the probe.
  -- (先探测一次远程控制，再忘掉那次调用：测试断言的是字体切换，不是探测)
  kitty.remote(function() end, true)
  for index = #calls, 1, -1 do
    calls[index] = nil
  end
  return calls, sync_calls, function()
    kitty._run, kitty._run_sync, kitty._launch_overrides = real_run, real_sync, real_launch
  end
end

describe("font.installed", function()
  it("lists CJK families once each, book-ish ones first", function()
    if vim.fn.executable("fc-list") ~= 1 then
      return
    end
    font._reset()
    local families = font.installed()
    truthy(#families > 0, "found some CJK fonts")

    local seen = {}
    for _, family in ipairs(families) do
      falsy(seen[family], "no duplicates: " .. family)
      seen[family] = true
    end

    local serif_index, mono_index = nil, nil
    for index, family in ipairs(families) do
      local lowered = family:lower()
      if not serif_index and lowered:find("serif", 1, true) then
        serif_index = index
      end
      if not mono_index and lowered:find("mono", 1, true) then
        mono_index = index
      end
    end
    if serif_index and mono_index then
      truthy(serif_index < mono_index, "serif before mono")
    end
  end)

  it("gives up on a hung fc-list instead of freezing the editor", function()
    reset()
    local real_system, real_executable = vim.system, vim.fn.executable
    local waited, killed = nil, nil
    vim.fn.executable = function()
      return 1
    end
    vim.system = function()
      return {
        wait = function(_, timeout)
          waited = timeout
          return { code = 124, stdout = "" }
        end,
        kill = function(_, signal)
          killed = signal
        end,
      }
    end
    local families = font.installed()
    vim.system, vim.fn.executable = real_system, real_executable
    eq(families, {}, "no fonts rather than a frozen editor")
    eq(waited, font.COMMAND_TIMEOUT_MS)
    eq(killed, 9)
  end)
end)

describe("font catalogue", function()
  it("reads its cache without the network", function()
    reset()
    cache.write_json(catalog.catalog_path(), {
      fetched_at = os.time(),
      items = {
        { font = "cejk", fontName = "仓耳今楷 04", url = "https://x/cejk.zip", suffix = "woff", fileSize = 100, index = 1 },
      },
    })
    local seen = nil
    catalog.catalog(function(items, err, info)
      eq(err, nil)
      seen = items
      eq(info.cached, true)
    end)
    truthy(seen, "callback ran")
    eq(#seen, 1)
    eq(seen[1].id, "cejk")
    eq(seen[1].name, "仓耳今楷 04")
  end)

  it("matches a typed name without the thin space", function()
    local items = {
      { id = "cejk", name = "仓耳今楷 04" },
      { id = "aik", name = "AI楷" },
    }
    eq(catalog.find(items, "仓耳今楷04").id, "cejk")
    eq(catalog.find(items, "cejk").id, "cejk")
    eq(catalog.find(items, "AI楷").id, "aik")
    eq(catalog.find(items, "不存在"), nil)
  end)

  it("refreshes a stale cache from the API", function()
    reset()
    local http = require("weread.http")
    local real_request = http.request
    cache.write_json(catalog.catalog_path(), { fetched_at = 0, items = {} })
    http.request = function(_, callback)
      callback({
        code = 200,
        status = 200,
        body = '{"items":[{"font":"syst","fontName":"思源宋体","url":"https://x/syst.zip","suffix":"woff","fileSize":42,"index":3}]}',
      })
    end
    local seen = nil
    catalog.catalog(function(items)
      seen = items
    end)
    http.request = real_request
    truthy(seen, "callback ran")
    eq(#seen, 1)
    eq(seen[1].name, "思源宋体")
    local stored = cache.read_json(catalog.catalog_path())
    truthy(stored and stored.fetched_at > 0, "cache was rewritten")
  end)

  it("returns an installed font without downloading", function()
    reset()
    fake_installed("cejk", "仓耳今楷 04", "TsangerJinKai W04")
    local calls = 0
    local entry = nil
    catalog.ensure({ id = "cejk", name = "仓耳今楷 04", url = "https://x/cejk.zip" }, function(found)
      calls = calls + 1
      entry = found
    end)
    eq(calls, 1)
    eq(entry.family, "TsangerJinKai W04")
  end)

  it("says which tool is missing instead of unpacking a zip", function()
    reset()
    local real_executable = vim.fn.executable
    vim.fn.executable = function(name)
      if name == "unzip" then
        return 0
      end
      return real_executable(name)
    end
    local message = nil
    catalog.ensure({ id = "x", name = "X", url = "https://x/x.zip" }, function(_, err)
      message = err
    end)
    vim.fn.executable = real_executable
    matches(message, "unzip")
  end)
end)

describe("font choice", function()
  it("remembers a local family and never writes a kitty snippet", function()
    reset()
    local real_has_local = font.has_local
    font.has_local = function()
      return true
    end
    local settlement = require("weread.font_session")
    local real_refresh = settlement.refresh
    local refreshed = 0
    settlement.refresh = function()
      refreshed = refreshed + 1
    end
    local ok, message = font.apply("local:思源宋体 CN")
    settlement.refresh, font.has_local = real_refresh, real_has_local
    truthy(ok, message)
    matches(message, "本机")
    eq(font.current(), "思源宋体 CN")
    eq(prefs.get("font_kind"), "local")
    eq(refreshed, 1)
    eq(vim.fn.filereadable(font.snippet_path()), 0, "no snippet is written")
  end)

  it("uses the family fontconfig gave an installed WeRead font", function()
    reset()
    fake_installed("cejk", "仓耳今楷 04", "TsangerJinKai W04")
    local real_refresh = require("weread.font_session").refresh
    require("weread.font_session").refresh = function() end
    local ok, message = font.apply("weread:cejk")
    require("weread.font_session").refresh = real_refresh
    truthy(ok, message)
    eq(font.current(), "仓耳今楷 04")
    local choice = font.choice()
    eq(choice.kind, "weread")
    eq(choice.family, "TsangerJinKai W04")
  end)

  it("downloads a WeRead font that is not installed yet", function()
    reset()
    local real_ensure = catalog.ensure_by_name
    local asked = nil
    catalog.ensure_by_name = function(id, callback)
      asked = id
      callback({ id = "syst", name = "思源宋体", family = "Source Han Serif CN" }, nil, { name = "思源宋体" })
    end
    local real_refresh = require("weread.font_session").refresh
    require("weread.font_session").refresh = function() end
    local ok, message = font.apply("weread:syst")
    catalog.ensure_by_name = real_ensure
    require("weread.font_session").refresh = real_refresh
    truthy(ok, message)
    eq(asked, "syst")
    eq(prefs.get("font_kind"), "weread")
    eq(prefs.get("font", nil), "思源宋体")
  end)

  it("ignores a download that finishes after the choice was cleared", function()
    reset()
    local real_ensure = catalog.ensure_by_name
    local pending = nil
    catalog.ensure_by_name = function(_, callback)
      pending = callback
    end
    font.apply_we_read("syst")
    font.clear()
    truthy(pending, "the download was started")
    pending({ id = "syst", name = "思源宋体", family = "Source Han Serif CN" }, nil, { name = "思源宋体" })
    catalog.ensure_by_name = real_ensure
    eq(prefs.get("font", nil), nil, "the cleared choice stays cleared")
  end)

  it("clears the choice and asks for the terminal font back", function()
    reset()
    prefs.set("font", "思源宋体 CN")
    prefs.set("font_kind", "local")
    local calls = {}
    local real_run = kitty._run
    kitty._run = function(args, callback)
      calls[#calls + 1] = args
      callback({ code = 0 }, nil)
    end
    kitty._launch_overrides = function()
      return {}
    end
    kitty.set("思源宋体 CN")
    local ok, message = font.clear()
    kitty._run, kitty._launch_overrides = real_run, nil
    truthy(ok, message)
    eq(font.current(), nil)
    eq(calls[#calls - 1], { "load-config", "--ignore-overrides" }, "the terminal gets its font back")
    eq(calls[#calls], { "set-font-size", "0" })
  end)
end)

describe("font_kitty", function()
  it("reads the last font_family, following includes in order", function()
    reset()
    vim.fn.writefile({ "font_family Maple Mono NF CN", "include more.conf" }, tmpdir .. "/kitty/kitty.conf")
    vim.fn.writefile({ "font_family 仓耳明楷 W04" }, tmpdir .. "/kitty/more.conf")
    eq(kitty.config_family(), "仓耳明楷 W04")
    vim.fn.writefile({ "font_family Maple Mono NF CN" }, tmpdir .. "/kitty/kitty.conf")
    eq(kitty.config_family(), "Maple Mono NF CN")
  end)

  it("applies a family with a line height and restores the config", function()
    reset()
    vim.fn.writefile({ "font_family Maple Mono NF CN" }, tmpdir .. "/kitty/kitty.conf")
    local calls, _, restore = stub_runs()
    kitty.set("仓耳明楷 W04", { line_height = 140 })
    eq(kitty.status().applied, true)
    eq(calls[1], {
      "load-config",
      "-o",
      "symbol_map=U+3000-U+303F,U+3400-U+4DBF,U+4E00-U+9FFF,U+F900-U+FAFF,U+FE10-U+FE6F,U+FF00-U+FFEF 仓耳明楷 W04",
      "-o",
      "modify_font=cell_height 140%",
    })
    kitty.clear()
    eq(kitty.status().applied, false)
    eq(calls[3], { "load-config", "--ignore-overrides" })
    eq(calls[4], { "set-font-size", "0" })
    restore()
  end)

  it("puts a command-line font override back instead of dropping it", function()
    reset()
    vim.fn.writefile({ "font_family Maple Mono NF CN" }, tmpdir .. "/kitty/kitty.conf")
    local calls = {}
    local real_run = kitty._run
    kitty._launch_overrides = function()
      return { "font_family=Original", "font_size=15" }
    end
    kitty._run = function(args, callback)
      calls[#calls + 1] = args
      callback({ code = 0 }, nil)
    end
    kitty.remote(function() end, true)
    for index = #calls, 1, -1 do
      calls[index] = nil
    end
    kitty.set("Reading Font")
    kitty.clear()
    kitty._run, kitty._launch_overrides = real_run, nil
    eq(calls[3], { "load-config", "-o", "font_family=Original" })
    eq(calls[4], { "set-font-size", "0" })
  end)

  it("restores synchronously on the way out", function()
    reset()
    local calls, sync_calls, restore = stub_runs()
    kitty.set("Reading Font")
    eq(kitty.restore_sync(), true)
    eq(kitty.status().applied, false)
    eq(sync_calls[1], { "load-config", "--ignore-overrides" })
    truthy(#calls >= 1)
    restore()
  end)

  it("reports a working remote control", function()
    reset()
    local real_run = kitty._run
    kitty._run = function(args, callback)
      eq(args, { "ls" })
      callback({ code = 0, stdout = "[]" }, nil)
    end
    local ready = nil
    kitty.remote(function(ok)
      ready = ok
    end, true)
    kitty._run = real_run
    eq(ready, true)
    eq(kitty.status().remote, true)
  end)

  it("passes kitty's exported listener to every subprocess", function()
    reset()
    vim.env.KITTY_LISTEN_ON = "unix:/run/user/1000/kitty-weread-42"
    eq(kitty._command_args({ "ls" }), {
      "kitten",
      "@",
      "--to",
      "unix:/run/user/1000/kitty-weread-42",
      "ls",
    })
    eq(kitty._command_args({ "load-config", "--ignore-overrides" }), {
      "kitten",
      "@",
      "--to",
      "unix:/run/user/1000/kitty-weread-42",
      "load-config",
      "--ignore-overrides",
    })
  end)

  it("does not invoke kitten without the exported listener", function()
    reset()
    vim.env.KITTY_LISTEN_ON = nil
    local calls, ready, message = 0, nil, nil
    local real_run = kitty._run
    kitty._run = function()
      calls = calls + 1
    end
    kitty.remote(function(ok, err)
      ready, message = ok, err
    end, true)
    kitty._run = real_run
    falsy(ready)
    eq(calls, 0)
    matches(message, "重新启动 Neovim")
  end)

  it("uses the listener inherited by an ancestor when an intermediary dropped it", function()
    reset()
    vim.env.KITTY_LISTEN_ON = nil
    local real_parent = kitty._parent_socket_address
    kitty._parent_socket_address = function()
      return "unix:/run/user/1000/kitty-weread-42"
    end
    local command = kitty._command_args({ "ls" })
    kitty._parent_socket_address = real_parent
    eq(command, {
      "kitten",
      "@",
      "--to",
      "unix:/run/user/1000/kitty-weread-42",
      "ls",
    })
  end)

  it("writes remote-control setup without a confirmation", function()
    reset()
    vim.env.KITTY_LISTEN_ON = nil
    vim.fn.writefile({ "font_family Maple Mono NF CN" }, tmpdir .. "/kitty/kitty.conf")
    local real_remote = kitty.remote
    local real_uis, real_confirm = vim.api.nvim_list_uis, vim.fn.confirm
    local attempts, done, message = 0, nil, nil
    kitty.remote = function(callback)
      attempts = attempts + 1
      callback(false, "disabled")
    end
    vim.api.nvim_list_uis = function()
      return { {} }
    end
    vim.fn.confirm = function()
      error("automatic enable must not prompt")
    end

    kitty.enable_remote(function(ok, text)
      done, message = ok, text
    end, true)

    kitty.remote = real_remote
    vim.api.nvim_list_uis, vim.fn.confirm = real_uis, real_confirm
    falsy(done)
    eq(attempts, 1)
    matches(message, "完全退出")
    local lines = vim.fn.readfile(tmpdir .. "/kitty/kitty.conf")
    truthy(vim.tbl_contains(lines, "allow_remote_control socket-only"))
    truthy(vim.tbl_contains(lines, "listen_on unix:" .. vim.env.XDG_RUNTIME_DIR .. "/kitty-weread-{kitty_pid}"))

    local again = nil
    kitty.remote = function(callback)
      callback(false, "disabled")
    end
    kitty.enable_remote(function(ok)
      again = ok
    end, true)
    kitty.remote = real_remote
    falsy(again)
    eq(vim.fn.readfile(tmpdir .. "/kitty/kitty.conf"), lines, "does not append duplicate setup")
  end)
end)

describe("font command", function()
  it("accepts status and a font name for immediate verification", function()
    vim.cmd("runtime plugin/weread.lua")
    local command = vim.api.nvim_get_commands({ builtin = false }).WeReadFont
    eq(command.nargs, "*")
    truthy(command.complete ~= nil)
  end)
end)

describe("font picker", function()
  it("previews an installed font while the Snacks picker overlays its source chapter", function()
    reset()
    local calls, _, restore = stub_runs()
    local chapter = vim.api.nvim_get_current_buf()
    local source_win = vim.api.nvim_get_current_win()
    vim.b[chapter].weread_book = true
    local picker = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_open_win(picker, true, {
      relative = "editor",
      width = 20,
      height = 1,
      row = 0,
      col = 0,
      style = "minimal",
    })

    font.preview({ kind = "local", family = "思源宋体 CN", installed = true }, chapter, source_win)
    vim.wait(100, function()
      return #calls > 0
    end, 10)

    vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
    vim.b[chapter].weread_book = nil
    restore()
    eq(calls[1], {
      "load-config",
      "-o",
      "symbol_map=U+3000-U+303F,U+3400-U+4DBF,U+4E00-U+9FFF,U+F900-U+FAFF,U+FE10-U+FE6F,U+FF00-U+FFEF 思源宋体 CN",
    })
  end)

  it("opens the size picker without a preview pane", function()
    reset()
    local ui = require("weread.ui")
    local real_catalog, real_select = catalog.catalog, ui.select
    local select_font, size_picker = nil, nil
    catalog.catalog = function(callback)
      callback({}, nil)
    end
    ui.select = function(options)
      if options.title:find("字号", 1, true) then
        size_picker = options
      else
        select_font = options.on_choice
      end
    end

    font.picker()
    select_font({ kind = "local", family = "思源宋体 CN" })
    vim.wait(100, function()
      return size_picker ~= nil
    end, 10)

    catalog.catalog, ui.select = real_catalog, real_select
    eq(size_picker.preview, "none")
    eq(size_picker.snacks.layout.preview, false)
  end)

  it("applies a picked local font immediately when opened from a chapter", function()
    reset()
    local session = require("weread.font_session")
    local ui = require("weread.ui")
    local real_catalog, real_select = catalog.catalog, ui.select
    local calls, _, restore = stub_runs()
    local selected, choose_size = nil, nil
    local real_has_local = font.has_local
    font.has_local = function()
      return true
    end
    local chapter = vim.api.nvim_get_current_buf()
    vim.b[chapter].weread_book = true
    catalog.catalog = function(callback)
      callback({}, nil)
    end
    ui.select = function(options)
      if options.title:find("字号", 1, true) then
        choose_size = options.on_choice
      else
        selected = options.on_choice
      end
    end
    font.picker()
    local picker = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, picker)
    selected({ kind = "local", family = "思源宋体 CN" })
    vim.api.nvim_win_set_buf(0, chapter)
    vim.wait(100, function()
      return choose_size ~= nil
    end, 10)
    choose_size({ key = "medium" })
    vim.wait(100, function()
      return #calls > 0
    end, 10)

    catalog.catalog, ui.select, font.has_local = real_catalog, real_select, real_has_local
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, plain)
    vim.b[chapter].weread_book = nil
    restore()
    eq(calls[1], {
      "load-config",
      "-o",
      "symbol_map=U+3000-U+303F,U+3400-U+4DBF,U+4E00-U+9FFF,U+F900-U+FAFF,U+FE10-U+FE6F,U+FF00-U+FFEF 思源宋体 CN",
    })
    eq(session.active(), false, "the normal buffer is not treated as a reading window")
  end)

  it("applies a downloaded font after its picker closes over a chapter", function()
    reset()
    local ui = require("weread.ui")
    local real_catalog, real_select, real_ensure = catalog.catalog, ui.select, catalog.ensure_by_name
    local calls, _, restore = stub_runs()
    local selected, choose_size, pending = nil, nil, nil
    local chapter = vim.api.nvim_get_current_buf()
    vim.b[chapter].weread_book = true
    catalog.catalog = function(callback)
      callback({ { id = "syst", name = "思源宋体", size = 0 } }, nil)
    end
    catalog.ensure_by_name = function(_, callback)
      pending = callback
    end
    ui.select = function(options)
      if options.title:find("字号", 1, true) then
        choose_size = options.on_choice
      else
        selected = options.on_choice
      end
    end
    font.picker()
    local picker = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, picker)
    selected({ kind = "weread", id = "syst", name = "思源宋体" })
    vim.api.nvim_win_set_buf(0, chapter)
    vim.wait(100, function()
      return choose_size ~= nil
    end, 10)
    choose_size({ key = "medium" })
    vim.wait(100, function()
      return pending ~= nil
    end, 10)
    fake_installed("syst", "思源宋体", "Source Han Serif CN")
    pending({ id = "syst", name = "思源宋体", family = "Source Han Serif CN" })
    vim.wait(100, function()
      return #calls > 0
    end, 10)

    catalog.catalog, ui.select, catalog.ensure_by_name = real_catalog, real_select, real_ensure
    restore()
    eq(calls[1], {
      "load-config",
      "-o",
      "symbol_map=U+3000-U+303F,U+3400-U+4DBF,U+4E00-U+9FFF,U+F900-U+FAFF,U+FE10-U+FE6F,U+FF00-U+FFEF Source Han Serif CN",
    })
  end)

  it("does not switch after leaving the chapter while the picker is open", function()
    reset()
    local ui = require("weread.ui")
    local real_catalog, real_select = catalog.catalog, ui.select
    local calls, _, restore = stub_runs()
    local selected = nil
    local real_has_local = font.has_local
    font.has_local = function()
      return true
    end
    catalog.catalog = function(callback)
      callback({}, nil)
    end
    ui.select = function(options)
      selected = options.on_choice
    end

    local chapter = vim.api.nvim_get_current_buf()
    vim.b[chapter].weread_book = true
    font.picker()
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, plain)
    selected({ kind = "local", family = "思源宋体 CN" })
    vim.wait(200, function()
      return false
    end, 10)

    catalog.catalog, ui.select, font.has_local = real_catalog, real_select, real_has_local
    restore()
    vim.api.nvim_win_set_buf(0, chapter)
    vim.b[chapter].weread_book = nil
    eq(calls, {}, "a stale picker must not switch the terminal after leaving reading")
  end)

  it("does not restore the terminal when the picker was opened outside a chapter", function()
    reset()
    local ui = require("weread.ui")
    local real_catalog, real_select = catalog.catalog, ui.select
    local calls, _, restore = stub_runs()
    local selected = nil
    prefs.set("font", "旧阅读字体")
    prefs.set("font_kind", "local")
    kitty.set("旧阅读字体")
    for index = #calls, 1, -1 do
      calls[index] = nil
    end
    catalog.catalog = function(callback)
      callback({}, nil)
    end
    ui.select = function(options)
      selected = options.on_choice
    end

    font.picker()
    selected({ kind = "none" })
    vim.wait(200, function()
      return false
    end, 10)

    catalog.catalog, ui.select = real_catalog, real_select
    restore()
    eq(calls, {}, "clearing a saved choice outside reading must not touch the terminal")
  end)
end)

describe("font_session", function()
  it("wants the font only while a chapter is on screen", function()
    local session = require("weread.font_session")
    local real_kitty = package.loaded["weread.font_kitty"]
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello" })
    vim.b.weread_book = true
    eq(session.want(), true)
    vim.b.weread_book = nil
    eq(session.want(), false)
    package.loaded["weread.font_kitty"] = real_kitty
  end)

  it("activates on a chapter and releases after leaving it", function()
    local session = require("weread.font_session")
    local activated, deactivated = 0, 0
    local real_activate, real_deactivate = font.activate, font.deactivate
    font.activate = function()
      activated = activated + 1
    end
    font.deactivate = function()
      deactivated = deactivated + 1
    end
    vim.b.weread_book = true
    session.check()
    vim.b.weread_book = nil
    session.check()
    vim.wait(400, function()
      return deactivated > 0
    end, 20)
    font.activate, font.deactivate = real_activate, real_deactivate
    eq(activated, 1)
    eq(deactivated, 1)
  end)
end)

describe("font.cleanup", function()
  it("removes the old snippet and its include", function()
    reset()
    vim.fn.writefile({ "# generated by weread.nvim — :WeReadFont", "font_family Old" }, font.snippet_path())
    vim.fn.writefile({
      "font_family Maple Mono NF CN",
      "",
      "# Reading font chosen with :WeReadFont in weread.nvim. Delete these lines to go back.",
      "# (weread.nvim 的 :WeReadFont 选的阅读字体；删掉这几行即恢复原字体)",
      "include " .. font.snippet_path(),
    }, font.kitty_conf_path())
    local real_confirm = vim.fn.confirm
    local real_signal = kitty.signal_reload
    local real_uis = vim.api.nvim_list_uis
    vim.api.nvim_list_uis = function()
      return { {} }
    end
    vim.fn.confirm = function()
      return 1
    end
    kitty.signal_reload = function()
      return true
    end
    local ok, message = font.cleanup()
    vim.api.nvim_list_uis, vim.fn.confirm, kitty.signal_reload = real_uis, real_confirm, real_signal
    truthy(ok, message)
    eq(vim.fn.filereadable(font.snippet_path()), 0)
    local lines = vim.fn.readfile(font.kitty_conf_path())
    eq(lines, { "font_family Maple Mono NF CN", "" })
  end)
end)

describe("font.status", function()
  it("names the choice and explains the transient switch", function()
    reset()
    prefs.set("font", "仓耳今楷 04")
    prefs.set("font_kind", "weread")
    prefs.set("font_id", "cejk")
    local text = font.status()
    truthy(text:find("仓耳今楷 04", 1, true))
    truthy(text:find("临时切换", 1, true))
    truthy(text:find("不写 kitty.conf", 1, true))
  end)
end)

describe("font tests", function()
  it("put the environment back for the next spec", function()
    kitty.available = real_available
    for name, value in pairs(saved_env) do
      vim.env[name] = value
    end
  end)
end)
