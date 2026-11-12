--[[
Runtime font switching for kitty, for the length of a reading session.
(只在阅读期间生效的 kitty 运行时字体切换)

A terminal owns its font, and kitty only allows a font family to be changed
per process, not per window. So "only inside the plugin" is implemented as a
session: entering a chapter asks kitty to use the chosen family, leaving the
chapter puts the original one back. On first need, the plugin writes the remote-control setup for kitty's next
start. A newly configured listener cannot be created by reloading kitty.
(终端拥有自己的字体，而 kitty 只允许按进程换字体族、不能按窗口换。因此「只在插件里生效」
实现为一次会话：进章节时让 kitty 换成本次选中的字体，离开章节时换回原来的。首次需要时，插件自动
写入远程控制设置，供下一次启动 kitty 时建立监听。)

The switch itself is a `kitten @ load-config -o font_family=...` call. kitty
applies the override immediately to every OS window of that instance; the
reader accepted that this is unavoidable for a TUI.
(切换本身是 `kitten @ load-config -o font_family=...`。kitty 会立刻把这个覆盖应用到该实例的
 所有 OS 窗口；TUI 里这一点绕不开，读者已经接受)

Remote control has to be on for terminal switching; automatic setup writes:
(终端切换需要远程控制；自动设置会写入：)

    listen_on unix:${XDG_RUNTIME_DIR:-/tmp}/kitty-weread-{kitty_pid}
    allow_remote_control socket-only

Kitty exports the resulting address as `KITTY_LISTEN_ON` to child processes.
(kitty 会将最终地址以 `KITTY_LISTEN_ON` 导出给子进程。)
]]

local log = require("weread.log")

local M = {}

---How long a single `kitten @` call may take. kitty answers in milliseconds; a
---hang means the socket is wedged and must not freeze the editor.
---(单次 `kitten @` 调用最多等多久。kitty 正常毫秒级返回；卡住说明 socket 有问题，不能拖住编辑器)
M.TIMEOUT_MS = 2500

---How long a remote-control probe is trusted. (远程控制探测结果缓存多久)
M.REMOTE_TTL_MS = 60 * 1000

---@class weread.font_kitty.State
local state = {
  ---The font is currently applied by us. (当前字体是我们换上去的)
  applied = false,
  ---The family we applied. (我们换上的家族名)
  family = nil,
  ---The line height we applied, if any. (我们改过的行距)
  line_height = nil,
  ---The reading font size in points, if any. (阅读字号，单位 pt)
  font_size = nil,
  ---What the terminal had before the first switch. (第一次切换前终端本来的设置)
  original = nil,
  original_line_height = nil,
  ---The last state the reader asked for; nil means "restore". (读者最后要求的状态；nil 表示恢复)
  desired = nil,
  ---A `kitten @` call is in flight. (有一次 kitten 调用在途)
  busy = false,
  ---Where to send a failure from a `clear()` request. (clear() 失败时报到哪里)
  on_error = nil,
  ---GUI nvim's own font, remembered for the restore. (GUI nvim 自己的字体，恢复时用)
  gui_guifont = nil,
  gui_linespace = nil,
  ---nil unknown, true/false the last probe. (nil 未知；true/false 上次探测结果)
  remote = nil,
  remote_at = 0,
  ---A remote-control request is in flight. (远程控制请求正在进行)
  enabling = false,
  ---The reader was already told once that remote control is off. (已经提醒过读者一次远程控制未开)
  remote_warned = false,
}

---@return table
function M.status()
  return {
    applied = state.applied,
    family = state.family,
    line_height = state.line_height,
    font_size = state.font_size,
    original = state.original,
    desired = state.desired and vim.deepcopy(state.desired) or nil,
    busy = state.busy,
    remote = state.remote,
    gui = M.gui(),
  }
end

---Forget every bit of state. Tests use this; a real session should not.
---(清空全部状态；测试用，真实会话不应调用)
function M.reset()
  state.applied = false
  state.family = nil
  state.line_height = nil
  state.font_size = nil
  state.original = nil
  state.original_line_height = nil
  state.desired = nil
  state.busy = false
  state.on_error = nil
  state.gui_guifont = nil
  state.gui_linespace = nil
  state.remote = nil
  state.remote_at = 0
  state.enabling = false
  state.remote_warned = false
end

---Running inside kitty, possibly through a multiplexer?
---(是否运行在 kitty 里（可能隔着一层复用器）)
---@return boolean
function M.in_kitty()
  return (vim.env.KITTY_WINDOW_ID or "") ~= "" or (vim.env.TERM or ""):find("kitty", 1, true) ~= nil
end

---A GUI nvim can really change its font; the terminal cannot. (GUI 版 nvim 真能换字体；终端不行)
---@return boolean
function M.gui()
  return vim.g.neovide == true or vim.g.goneovim == true or vim.fn.has("gui_running") == 1
end

---Can a switch be attempted at all? (有没有尝试切换的基本条件)
---@return boolean
function M.available()
  return M.gui() or (M.in_kitty() and vim.fn.executable("kitten") == 1)
end

---@return string
function M.config_path()
  local directory = vim.env.KITTY_CONFIG_DIRECTORY
  if directory and directory ~= "" then
    return directory .. "/kitty.conf"
  end
  local config_home = vim.env.XDG_CONFIG_HOME
  if not config_home or config_home == "" then
    config_home = (vim.env.HOME or vim.fn.expand("~")) .. "/.config"
  end
  return config_home .. "/kitty/kitty.conf"
end

---@param pid integer
---@return integer|nil
local function parent_pid(pid)
  local file = io.open("/proc/" .. pid .. "/status", "rb")
  if not file then
    return nil
  end
  local contents = file:read("*a") or ""
  file:close()
  return tonumber(contents:match("\nPPid:%s*(%d+)"))
end

---@param pid integer
---@return string|nil
local function process_socket_address(pid)
  local file = io.open("/proc/" .. pid .. "/environ", "rb")
  if not file then
    return nil
  end
  local contents = file:read("*a") or ""
  file:close()
  for entry in contents:gmatch("[^%z]+") do
    local address = entry:match("^KITTY_LISTEN_ON=(.+)$")
    if address and address ~= "" then
      return address
    end
  end
  return nil
end

---Some terminal clients and session wrappers drop KITTY_LISTEN_ON while keeping
---their parent shell alive. The shell's listener belongs to this same terminal
---ancestry, so recover it instead of silently saving a font that cannot apply.
---(某些终端客户端和会话包装器会丢掉 KITTY_LISTEN_ON，但保留父 shell。该 shell 的监听器
---仍属于当前终端祖先链，因此恢复它，而不是悄悄保存一个无法应用的字体选择。)
---@return string|nil
local function parent_socket_address()
  local pid = vim.fn.getpid()
  for _ = 1, 32 do
    pid = parent_pid(pid)
    if not pid or pid <= 1 then
      return nil
    end
    local address = process_socket_address(pid)
    if address then
      return address
    end
  end
  return nil
end

---Tests replace this seam to emulate a terminal wrapper that lost its environment.
---(测试替换此接缝，以模拟丢失环境变量的终端包装器。)
M._parent_socket_address = parent_socket_address

---@return string|nil
local function socket_address()
  local address = vim.env.KITTY_LISTEN_ON
  if address and address ~= "" then
    return address
  end
  return M._parent_socket_address()
end

---@param args string[]
---@return string[]|nil command
---@return string|nil err
local function command_args(args)
  local address = socket_address()
  if not address then
    return nil, "kitty 控制 socket 未传入当前 Neovim；请从新打开的 kitty 重新启动 Neovim"
  end
  local command = { "kitten", "@", "--to", address }
  vim.list_extend(command, args)
  return command, nil
end

---Tests inspect the exact subprocess argv through this seam. (测试通过此接缝检查子进程 argv。)
M._command_args = command_args

---@return string|nil
local function listener_config_value()
  local runtime = vim.env.XDG_RUNTIME_DIR
  if not runtime or runtime == "" then
    return nil
  end
  return "unix:" .. runtime .. "/kitty-weread-{kitty_pid}"
end

---@param args string[]
---@return table|nil result
---@return string|nil err
local function run_sync(args, timeout)
  local command, command_err = M._command_args(args)
  if not command then
    return nil, command_err
  end
  local ok, result = pcall(function()
    return vim.system(command, { text = true }):wait(timeout or M.TIMEOUT_MS)
  end)
  if not ok then
    return nil, tostring(result)
  end
  if type(result) ~= "table" then
    return nil, "kitten returned nothing"
  end
  return result, nil
end

---Tests replace this too: `restore_sync` runs on the way out of the editor.
---(测试同样替换它：`restore_sync` 在退出编辑器时运行)
M._run_sync = run_sync

---Run `kitten @ ...` asynchronously. The callback always runs in the main loop.
---(异步执行 `kitten @ ...`；回调总在主循环里)
---@param args string[]
---@param callback fun(result: table|nil, err: string|nil)
function M.run(args, callback)
  local command, command_err = M._command_args(args)
  if not command then
    vim.schedule(function()
      callback(nil, command_err)
    end)
    return
  end
  local started, result = pcall(vim.system, command, { text = true, timeout = M.TIMEOUT_MS }, function(done)
    vim.schedule(function()
      callback(done, nil)
    end)
  end)
  if not started then
    vim.schedule(function()
      callback(nil, tostring(result))
    end)
  end
end

---Tests replace this to keep every call away from a real kitty. (测试替换它，避免碰真实 kitty)
M._run = M.run

---Send a signal to the kitty GUI processes, the way kitty's own reload-all does.
---(向 kitty 图形进程发信号，和 kitty 自己的「全部重载」一样)
---@return boolean sent
function M.signal_reload()
  if vim.fn.executable("pgrep") ~= 1 then
    return false
  end
  local uid = vim.uv.getuid and vim.uv.getuid() or nil
  local args = { "pgrep", "-a", "-x", "kitty" }
  if uid then
    table.insert(args, 2, "-u")
    table.insert(args, 3, tostring(uid))
  end
  local ok, result = pcall(function()
    return vim.system(args, { text = true }):wait(2000)
  end)
  if not ok or type(result) ~= "table" or result.code ~= 0 then
    return false
  end
  local sent = false
  for line in (result.stdout or ""):gmatch("[^\n]+") do
    local pid, rest = line:match("^(%d+)%s+%S+%s*(.*)$")
    local first = (rest or ""):sub(1, 1)
    if pid and first ~= "@" and first ~= "+" then
      if pcall(vim.uv.kill, tonumber(pid), "sigusr1") then
        sent = true
      end
    end
  end
  return sent
end

---Probe kitty's remote control, with a short-lived cache.
---(探测 kitty 的远程控制，结果短暂缓存)
---@param callback fun(ok: boolean, err: string|nil)
---@param force boolean|nil ignore the cached answer(忽略缓存结果)
function M.remote(callback, force)
  if not M.available() then
    callback(false, "当前不在 kitty 里，或找不到 kitten 命令")
    return
  end
  -- Every `vim.system()` child has no controlling terminal. Refuse to invoke
  -- `kitten @` until kitty has exported its listener address to this process.
  -- (`vim.system()` 的子进程没有控制终端；只有 kitty 将监听地址导出到当前进程后才调用 `kitten @`。)
  if not socket_address() then
    callback(false, "kitty 控制 socket 未传入当前 Neovim；请从新打开的 kitty 重新启动 Neovim")
    return
  end
  if (vim.env.TMUX or "") ~= "" and not socket_address() then
    callback(false, "tmux 里需要把 kitty 控制 socket 传入会话")
    return
  end
  if not force and state.remote ~= nil and (vim.uv.now() - state.remote_at) < M.REMOTE_TTL_MS then
    callback(state.remote, state.remote and nil or "kitty 不接受远程控制")
    return
  end
  M._run({ "ls" }, function(result, err)
    local ok = result ~= nil and result.code == 0
    state.remote = ok
    state.remote_at = vim.uv.now()
    if ok then
      callback(true, nil)
    else
      local reason = err
        or (result and (result.stderr ~= "" and result.stderr or ("exit " .. tostring(result.code))))
        or "kitten @ ls 失败"
      callback(false, vim.trim(reason))
    end
  end)
end

---Strip quotes and a trailing comment from a config value. (去掉引号与行尾注释)
---@param value string
---@return string
local function clean_value(value)
  value = vim.trim(value)
  value = value:gsub("%s+#.*$", "")
  local quoted = value:match('^"(.*)"$') or value:match("^'(.*)'$")
  return vim.trim(quoted or value)
end

---The last `font_family` in a config file and everything it includes.
---(某个配置文件及其 include 里最后一条 font_family)
---@param path string
---@param seen table<string, boolean>
---@param depth integer
---@return string|nil
local function family_in_file(path, seen, depth)
  if depth > 16 or seen[path] or vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  seen[path] = true
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  local family = nil
  local directory = vim.fs.dirname(path)
  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not trimmed:match("^#") then
      local include = trimmed:match("^include%s+(.+)$")
      if include then
        local target = vim.fn.expand(clean_value(include))
        if target:sub(1, 1) ~= "/" then
          target = directory .. "/" .. target
        end
        local matches = vim.fn.glob(target, false, true)
        if #matches == 0 and vim.fn.filereadable(target) == 1 then
          matches = { target }
        end
        for _, included in ipairs(matches) do
          local found = family_in_file(included, seen, depth + 1)
          if found then
            family = found
          end
        end
      else
        local value = trimmed:match("^font_family%s+(.+)$")
        if value then
          local cleaned = clean_value(value)
          if cleaned ~= "" then
            family = cleaned
          end
        end
      end
    end
  end
  return family
end

---The font family kitty would use without our override. (没有我们的覆盖时 kitty 会用的字体族)
---@return string
function M.config_family()
  local family = family_in_file(M.config_path(), {}, 0)
  return family or "monospace"
end

---Options passed to kitty on its command line, as `name=value` strings. They
---survive a config reload unless `--ignore-overrides` is used, so the restore
---path has to put them back.
---(kitty 命令行上带 `name=value` 的覆盖项。除非用 `--ignore-overrides`，它们会在重载后
--- 继续生效，所以恢复时要放回去)
---@return string[]
function M.launch_overrides()
  local pid = vim.env.KITTY_PID
  if not pid or pid == "" then
    return {}
  end
  local file = io.open("/proc/" .. pid .. "/cmdline", "rb")
  if not file then
    return {}
  end
  local raw = file:read("*a") or ""
  file:close()
  local args = vim.split(raw, "\0", { plain = true, trimempty = true })
  local overrides = {}
  local index = 1
  while index <= #args do
    local arg = args[index]
    local value = arg:match("^%-%-override=(.*)$") or arg:match("^%-o=(.*)$")
    if value then
      overrides[#overrides + 1] = value
    elseif arg == "--override" or arg == "-o" then
      local next_arg = args[index + 1]
      if next_arg and next_arg ~= "" then
        overrides[#overrides + 1] = next_arg
        index = index + 1
      end
    end
    index = index + 1
  end
  return overrides
end

---Tests replace this. (测试替换它)
M._launch_overrides = M.launch_overrides

---@param overrides string[]
---@param name string
---@return string|nil
local function override_value(overrides, name)
  local found = nil
  for _, entry in ipairs(overrides) do
    local key, value = entry:match("^([^=]+)=(.*)$")
    if key == name then
      found = value
    end
  end
  return found
end

---The original family, preferring a command-line override over kitty.conf.
---(原始字体族；命令行覆盖优先于 kitty.conf)
---@return string
function M.original_family()
  local overrides = M._launch_overrides()
  local from_command = override_value(overrides, "font_family")
  if from_command and from_command ~= "" then
    return from_command
  end
  return M.config_family()
end

---@return string|nil
local function modify_font_in_file()
  local path = M.config_path()
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  local found = nil
  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not trimmed:match("^#") then
      local value = trimmed:match("^modify_font%s+(.+)$")
      if value then
        found = clean_value(value)
      end
    end
  end
  return found
end

---The original `modify_font` setting, if there is one. (原来的 modify_font 设置)
---@return string|nil
function M.original_modify_font()
  local overrides = M._launch_overrides()
  local from_command = override_value(overrides, "modify_font")
  if from_command and from_command ~= "" then
    return from_command
  end
  return modify_font_in_file()
end

---@return string
local function cjk_map(family)
  return "symbol_map=U+3000-U+303F,U+3400-U+4DBF,U+4E00-U+9FFF,U+F900-U+FAFF,U+FE10-U+FE6F,U+FF00-U+FFEF " .. family
end

---@param opts table|nil { line_height: number }
---@return string[]
local function apply_args(family, opts)
  -- kitty accepts only mono/dual-width fonts as `font_family`; book fonts are
  -- proportional, so map CJK glyphs while keeping the terminal face for Latin
  -- text and Nerd Font symbols.
  -- (kitty 只接受等宽/双宽字体作 `font_family`；书籍字体多为比例字体，因此映射 CJK 字形，同时保留终端字体负责拉丁文和 Nerd Font 图标。)
  local args = { "load-config", "-o", cjk_map(family) }
  local line_height = tonumber(opts and opts.line_height)
  if line_height and line_height > 0 then
    args[#args + 1] = "-o"
    args[#args + 1] = string.format("modify_font=cell_height %d%%", math.floor(line_height))
  end
  return args
end

---@return string[]
local function restore_args()
  local overrides = M._launch_overrides()
  if #overrides == 0 then
    -- Nothing was passed on the command line: reloading the config without any
    -- overrides puts every option, including the font, back exactly as it was.
    -- (命令行没传覆盖项：不带覆盖地重载配置，就能把包括字体在内的所有选项原样放回)
    return { "load-config", "--ignore-overrides" }
  end
  -- kitty forgot what its command-line overrides were, so put the font back by
  -- hand and leave the rest of the overrides in place.
  -- (kitty 记不住命令行覆盖项，只能手动把字体放回去，其余覆盖项保持不动)
  local args = { "load-config", "-o", "font_family=" .. (state.original or M.original_family()) }
  if state.line_height then
    args[#args + 1] = "-o"
    args[#args + 1] = "modify_font=" .. (state.original_line_height or "cell_height 100%")
  end
  return args
end

---Ask for one state: a font family (and optional line height), or nil to restore.
---(请求一个状态：字体族（可带行距），nil 表示恢复)
---@param family string|nil
---@param opts table|nil { line_height: number, font_size: number, on_error: fun(message: string) }
function M.set(family, opts)
  state.on_error = nil
  if not family or family == "" then
    state.desired = nil
  else
    state.desired = {
      family = family,
      line_height = tonumber(opts and opts.line_height),
      font_size = tonumber(opts and opts.font_size),
      on_error = opts and opts.on_error or nil,
    }
  end
  if not family or family == "" then
    M.pump()
    return
  end
  if M.gui() then
    M.pump()
    return
  end
  -- Do not fire a `load-config` at a kitty that is not listening: it fails
  -- every time a chapter opens, and the reader only needs to be told once.
  -- (不要对着没在监听的 kitty 反复发 `load-config`：每次进章节都会失败，而读者只需要被提醒一次)
  if state.remote ~= true then
    M.remote(function(ok, err)
      if not ok then
        if not state.remote_warned then
          state.remote_warned = true
          local message = "阅读字体暂时无法切换：" .. tostring(err or "kitty 不可用")
          if M.available() and not state.enabling then
            message = message .. "；正在自动启用 kitty 远程控制"
            M.enable_remote(function(enabled, enable_message)
              if not enabled then
                vim.notify("weread: " .. tostring(enable_message), vim.log.levels.WARN)
              end
            end, true)
          end
          log.warn("%s", message)
          vim.notify("weread: " .. message, vim.log.levels.WARN)
        end
        return
      end
      state.remote_warned = false
      M.pump()
    end)
    return
  end
  M.pump()
end

---Put the terminal's own font back. (恢复终端自己的字体)
---@param opts table|nil { on_error: fun(message: string) }
function M.clear(opts)
  state.desired = nil
  state.on_error = opts and opts.on_error or nil
  M.pump()
end

---@param message string
local function report(message)
  local handler = (state.desired and state.desired.on_error) or state.on_error
  if handler then
    handler(message)
  else
    log.warn("%s", message)
  end
end

---Run the next transition if nothing is in flight. (没有在途调用时执行下一次切换)
function M.pump()
  if state.busy then
    return
  end
  local desired = state.desired
  if not desired then
    if not state.applied then
      return
    end
    if M.gui() then
      pcall(function()
        if state.gui_guifont then
          vim.o.guifont = state.gui_guifont
        end
        if state.gui_linespace then
          vim.o.linespace = state.gui_linespace
        end
      end)
      state.applied = false
      state.family = nil
      state.line_height = nil
      state.font_size = nil
      state.gui_guifont = nil
      state.gui_linespace = nil
      return
    end
    state.busy = true
    M._run(restore_args(), function(result, err)
      if result and result.code == 0 then
        M._run({ "set-font-size", "0" }, function(size_result, size_err)
          state.busy = false
          if size_result and size_result.code == 0 then
            state.applied = false
            state.family = nil
            state.line_height = nil
            state.font_size = nil
            -- Read the config again on the next apply: the reader may have changed
            -- their terminal font in between.
            -- (下次应用时重新读配置：这期间读者可能换过终端字体)
            state.original = nil
            state.original_line_height = nil
          else
            report("没能恢复原来的 kitty 字号：" .. tostring(size_err or (size_result and size_result.stderr) or "未知原因"))
          end
          M.pump()
        end)
        return
      end
      state.busy = false
      report("没能恢复原来的 kitty 字体：" .. tostring(err or (result and result.stderr) or "未知原因"))
      M.pump()
    end)
    return
  end

  if state.applied and state.family == desired.family and state.line_height == desired.line_height and state.font_size == desired.font_size then
    return
  end
  if M.gui() then
    state.gui_guifont = state.gui_guifont or vim.o.guifont
    state.gui_linespace = state.gui_linespace or vim.o.linespace
    local size = tonumber(desired.font_size) or 14
    local linespace = tonumber(desired.linespace) or 4
    local ok, err = pcall(function()
      vim.o.guifont = string.format("%s:h%d", desired.family, size)
      vim.o.linespace = linespace
    end)
    if ok then
      state.applied = true
      state.family = desired.family
      state.line_height = desired.line_height
      state.font_size = desired.font_size
    else
      report("切换 GUI 字体失败：" .. tostring(err))
    end
    return
  end
  state.original = state.original or M.original_family()
  state.original_line_height = state.original_line_height or M.original_modify_font()
  local args = apply_args(desired.family, desired)
  if state.line_height and not desired.line_height then
    -- The previous choice had a line height and this one does not: put the
    -- terminal's own line height back instead of leaving the old override on.
    -- (上一次的选择带行距、这次不带：把终端自己的行距放回去，而不是留着旧覆盖)
    args[#args + 1] = "-o"
    args[#args + 1] = "modify_font=" .. (state.original_line_height or "cell_height 100%")
  end
  state.busy = true
  M._run(args, function(result, err)
    if not result or result.code ~= 0 then
      state.busy = false
      report("切换 kitty 字体失败：" .. tostring(err or (result and result.stderr) or "未知原因"))
      M.pump()
      return
    end
    M._run({ "set-font-size", tostring(math.floor(tonumber(desired.font_size) or 16)) }, function(size_result, size_err)
      state.busy = false
      if size_result and size_result.code == 0 then
        state.applied = true
        state.family = desired.family
        state.line_height = desired.line_height
        state.font_size = desired.font_size
      else
        report("切换 kitty 字号失败：" .. tostring(size_err or (size_result and size_result.stderr) or "未知原因"))
      end
      M.pump()
    end)
  end)
end

---Restore synchronously, for `VimLeavePre`: an async request would be killed
---with the process and leave the terminal in the reading font.
---(退出时同步恢复：异步请求会随进程被杀，终端就留在阅读字体上)
---@return boolean ok
function M.restore_sync()
  if not state.applied then
    return true
  end
  if M.gui() then
    local ok = pcall(function()
      if state.gui_guifont then
        vim.o.guifont = state.gui_guifont
      end
      if state.gui_linespace then
        vim.o.linespace = state.gui_linespace
      end
    end)
    if ok then
      state.applied = false
      state.family = nil
      state.line_height = nil
      state.gui_guifont = nil
      state.gui_linespace = nil
    end
    return ok
  end
  local result = M._run_sync(restore_args(), 2000)
  if result and result.code == 0 then
    state.applied = false
    state.family = nil
    state.line_height = nil
    state.original = nil
    state.original_line_height = nil
    return true
  end
  return false
end

---Is a patch of the config enough to know remote control was requested?
---(配置里是否已经写了远程控制)
---@return string|nil value
function M.remote_setting()
  local path = M.config_path()
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not trimmed:match("^#") then
      local value = trimmed:match("^allow_remote_control%s+(.+)$")
      if value then
        return clean_value(value)
      end
    end
  end
  return nil
end

---Add the control socket and `allow_remote_control socket-only` when automatic
---font switching needs it. kitty creates a newly configured socket only at startup.
---(自动切换字体需要时写入控制 socket 与 `allow_remote_control socket-only`。kitty 只在启动时创建新增 socket。)
---@param callback fun(ok: boolean, message: string)
---@param automatic boolean|nil skip the interactive confirmation(跳过交互确认)
function M.enable_remote(callback, automatic)
  callback = callback or function() end
  if M.gui() then
    callback(true, "GUI 版 nvim 直接设置字体，不需要 kitty 的远程控制")
    return
  end
  if state.enabling then
    return
  end
  state.enabling = true
  local function finish(ok, message)
    state.enabling = false
    callback(ok, message)
  end
  if not M.in_kitty() then
    finish(false, "当前不在可控制的 kitty 终端中，字体选择已保存但不能立即应用")
    return
  end
  if (vim.env.TMUX or "") ~= "" and not socket_address() then
    finish(false, "tmux 里需要把 kitty 控制 socket 传入会话")
    return
  end
  M.remote(function(ok)
    if ok then
      state.remote_warned = false
      M.pump()
      finish(true, "kitty 远程控制已可用")
      return
    end
    local setting = M.remote_setting()
    if setting and setting ~= "no" and vim.fn.filereadable(M.config_path()) == 1 then
      finish(false, "kitty 控制 socket 未传入当前 Neovim；请完全退出全部 kitty 实例后重新打开")
      return
    end
    if #vim.api.nvim_list_uis() == 0 then
      finish(false, "无界面运行时不修改 kitty.conf；请手动加上 allow_remote_control yes")
      return
    end
    if not automatic then
      local choice = vim.fn.confirm("要现在加上并重载 kitty 吗？", "&加上\n&不用", 1)
      if choice ~= 1 then
        finish(false, "没有修改 kitty.conf；手动加上 allow_remote_control yes 后重试")
        return
      end
    end
    local path = M.config_path()
    local address = listener_config_value()
    if not address then
      finish(false, "找不到运行时目录，无法创建 kitty 控制 socket")
      return
    end
    pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
    local file = io.open(path, "ab")
    if not file then
      finish(false, "无法写入 " .. path)
      return
    end
    local written = file:write(table.concat({
      "",
      "# weread.nvim: runtime font control",
      "listen_on " .. address,
      "allow_remote_control socket-only",
      "",
    }, "\n"))
    local closed = file:close()
    if not written or not closed then
      finish(false, "写入 " .. path .. " 失败")
      return
    end
    -- kitty cannot create a new `listen_on` listener on config reload. It will
    -- export the final PID-specific address to children after a full restart.
    -- (kitty 不能通过重载配置新建 `listen_on` 监听；完全重启后才会向子进程导出最终的 PID 地址。)
    finish(false, "已写入 kitty 控制 socket；请完全退出全部 kitty 实例后重新打开，再从新 kitty 启动 Neovim")
  end, true)
end

return M
