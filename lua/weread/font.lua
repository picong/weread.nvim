--[[
The reading font: what the reader picked, WeRead's own fonts, and how the
choice is applied without touching the terminal for good.
(阅读字体：读者选了什么、微信读书自己的字体，以及如何在不永久改动终端的前提下应用)

The honest boundary of a TUI is unchanged: nvim cannot set a font per buffer.
This module therefore does two things and no more:
(TUI 的诚实边界没有变：nvim 不能按 buffer 设字体。因此本模块只做两件事：)

* it knows the fonts. Local CJK families come from fontconfig; WeRead's own
  catalogue comes from the web reader and is downloaded into the user font
  directory on first use.
  (知道有哪些字体。本机中文字体来自 fontconfig；微信读书自己的字体目录来自网页阅读器，
   首次使用时下载到用户字体目录)
* it remembers the choice and hands it to `weread.font_kitty`, which switches
  kitty for the length of a reading session (`weread.font_session`). Nothing is
  written into kitty.conf.
  (记住选择并交给 `weread.font_kitty`，由它在一次阅读会话里切换 kitty（`weread.font_session`）。
   不往 kitty.conf 里写任何东西)

The old snippet/include machinery is gone. It is cleaned up automatically when
an older installation is found.
(旧的片段/include 机制已经删除；发现旧安装遗留时会自动清理。)
]]

local config = require("weread.config")
local font_catalog = require("weread.font_catalog")
local font_kitty = require("weread.font_kitty")

local M = {}

local SIZES = {
  small = { key = "small", pt = 14, label = "小" },
  medium = { key = "medium", pt = 16, label = "中" },
  large = { key = "large", pt = 18, label = "大" },
}

---Bumped whenever the reader chooses or clears a font. An async download that
---finishes after a newer choice must not put the old font back.
---(读者每次选择或清除字体时递增。较新的选择之后才完成的异步下载，不能把旧字体又装回去)
M._generation = 0

---How long an external helper (`fc-list`) may take. They answer in
---milliseconds; a wedged fontconfig cache must not freeze the editor.
---(外部命令（fc-list）最多等多久。正常是毫秒级；卡死的 fontconfig 缓存不能拖住编辑器)
M.COMMAND_TIMEOUT_MS = 2000

---How long the local family list is trusted. (本机字体列表缓存多久)
M.LOCAL_TTL = 300

---@param args string[]
---@return table|nil result
---@return string|nil err
local function run(args)
  local started, handle = pcall(vim.system, args, { text = true })
  if not started then
    return nil, tostring(handle)
  end
  local waited, result = pcall(handle.wait, handle, M.COMMAND_TIMEOUT_MS)
  if not waited or type(result) ~= "table" then
    pcall(handle.kill, handle, 9)
    return nil, tostring(result)
  end
  if result.code == 124 then
    pcall(handle.kill, handle, 9)
    return nil, "timeout"
  end
  return result, nil
end

---Fonts the reading app itself uses, best first, for the local list's order.
---(阅读类 App 自己会用的字体，越靠前越像书，用于本机列表排序)
local PREFERRED = {
  "source han serif",
  "思源宋体",
  "noto serif cjk",
  "songti",
  "simsun",
  "lxgw",
  "霞鹜文楷",
  "source han sans",
  "思源黑体",
  "noto sans cjk",
  "wenquanyi",
  "文泉驿",
  "noto sans mono cjk",
  "jetbrains maple",
  "sarasa",
  "更纱",
}

---@param name string
---@return integer
local function score(name)
  local lowered = name:lower()
  for index, needle in ipairs(PREFERRED) do
    if lowered:find(needle, 1, true) then
      return index
    end
  end
  return #PREFERRED + 1
end

local local_cache = { at = 0, list = nil }

---Installed CJK families from fontconfig, deduplicated and sorted so book-ish
---serif faces come first.
---(fontconfig 里已安装的中文字体，去重并按「像书的衬线体优先」排序)
---@return string[]
function M.installed()
  local now = os.time()
  if local_cache.list and now - local_cache.at < M.LOCAL_TTL then
    return vim.deepcopy(local_cache.list)
  end
  if vim.fn.executable("fc-list") ~= 1 then
    return {}
  end
  local result = run({ "fc-list", ":lang=zh-cn", "family" })
  if not result or result.code ~= 0 then
    return {}
  end

  local seen, families = {}, {}
  for line in (result.stdout or ""):gmatch("[^\n]+") do
    for name in line:gmatch("[^,]+") do
      name = vim.trim(name)
      if name ~= "" and not seen[name] then
        seen[name] = true
        families[#families + 1] = name
      end
    end
  end
  table.sort(families, function(left, right)
    local left_score, right_score = score(left), score(right)
    if left_score ~= right_score then
      return left_score < right_score
    end
    return left < right
  end)
  local_cache = { at = now, list = families }
  return vim.deepcopy(families)
end

---Forget the local family cache. For tests and after `fc-cache`.
---(丢弃本机字体缓存；供测试和 fc-cache 之后使用)
function M._reset()
  local_cache = { at = 0, list = nil }
  M._downloading = {}
  M._download_failed_at = {}
  M._missing_local = {}
  M._generation = 0
end

---@param family string
---@return boolean
function M.has_local(family)
  local wanted = family:lower()
  for _, name in ipairs(M.installed()) do
    if name:lower() == wanted then
      return true
    end
  end
  -- Without fontconfig there is no way to check; do not block the choice.
  -- (没有 fontconfig 就没法检查；不要因此拦住选择)
  return vim.fn.executable("fc-list") ~= 1
end

---The remembered choice, as a string: the display name of a WeRead font or a
---local family.
---(记住的选择，字符串：微信读书字体的显示名，或本机字体族)
---@return string|nil
function M.current()
  local name = require("weread.prefs").get("font")
  return type(name) == "string" and name ~= "" and name or nil
end

---@class weread.font.Choice
---@field kind "weread"|"local"
---@field name string
---@field id string|nil
---@field family string|nil the family to give kitty(交给 kitty 的家族名)
---@field entry table|nil installed WeRead entry(已安装的微信读书字体条目)

---The remembered choice with everything needed to apply it.
---(记住的选择，连同应用它所需的一切)
---@return weread.font.Choice|nil
function M.choice()
  local name = M.current()
  if not name then
    return nil
  end
  local prefs = require("weread.prefs")
  local kind = prefs.get("font_kind")
  local id = prefs.get("font_id")
  local catalog = font_catalog
  local entry = catalog.find_installed(id or name)
  if not entry and kind == nil then
    -- A choice written before `font_kind` existed may still be a WeRead font;
    -- match it by display name before treating it as a local family.
    -- (在 `font_kind` 出现之前写下的选择仍可能是微信读书字体；先按显示名匹配，再当成本机字体)
    for _, item in ipairs(catalog.installed()) do
      if catalog.name_key(item.name) == catalog.name_key(name) then
        entry = item
        break
      end
    end
  end
  if kind == "weread" or (kind == nil and (type(id) == "string" or entry)) then
    return {
      kind = "weread",
      name = name,
      id = id or (entry and entry.id),
      family = entry and entry.family,
      entry = entry,
    }
  end
  return { kind = "local", name = name, family = name }
end

---The current reading font size profile. (当前阅读字号档位)
---@return table { key: string, pt: integer, label: string }
function M.size()
  local key = require("weread.prefs").get("font_size")
  return vim.deepcopy(SIZES[type(key) == "string" and key or "medium"] or SIZES.medium)
end

---@param key string
---@param opts table|nil
---@return boolean ok
---@return string message
function M.set_size(key, opts)
  local size = SIZES[key]
  if not size then
    return false, "字号只能选小、中或大"
  end
  require("weread.prefs").set("font_size", key)
  require("weread.font_session").refresh(opts and opts.from_chapter)
  return true, string.format("阅读字号 → %s（%d pt）", size.label, size.pt)
end

---Line height for the reading font, from the choice or the config.
---(阅读字体的行距；先看选择时记下的，再看配置)
---@return number|nil
function M.line_height()
  local stored = require("weread.prefs").get("font_line_height")
  local value = tonumber(stored) or tonumber((config.get().layout or {}).line_height)
  return value and value > 0 and value or nil
end

---@param message string
---@param level integer|nil
local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

---@param kind "weread"|"local"
---@param fields table { name, id, family, line_height }
local function remember(kind, fields)
  local prefs = require("weread.prefs")
  prefs.set("font", fields.name)
  prefs.set("font_kind", kind)
  prefs.set("font_id", fields.id)
  prefs.set("font_line_height", tonumber(fields.line_height) or nil)
  if fields.font_size then
    prefs.set("font_size", fields.font_size)
  end
end

---Split a command argument into its font name and optional cell height. A known
---font whose name ends in a number (for example `仓耳今楷 04`) stays whole; `@140`
---is the unambiguous form for any other numeric name.
---(把命令参数拆成字体名和可选 cell 高度。已知字体名末尾的数字（如 `仓耳今楷 04`）不拆；
--- 对其它带数字的名字，用 `@140` 是无歧义写法)
---@param value string|nil
---@return string name
---@return number|nil line_height
function M.parse_command(value)
  local name = vim.trim(value or "")
  local explicit_name, explicit_height = name:match("^(.-)%s+@(%d+)$")
  if explicit_name then
    return vim.trim(explicit_name), tonumber(explicit_height)
  end
  local whole = font_catalog.find_installed(name)
  if whole or M.has_local(name) then
    return name, nil
  end
  local family, line_height = name:match("^(.-)%s+(%d+)$")
  if family then
    return vim.trim(family), tonumber(line_height)
  end
  return name, nil
end

---@param name string
---@param opts table|nil
---@return boolean ok
---@return string message
function M.apply(name, opts)
  opts = opts or {}
  if type(name) ~= "string" or vim.trim(name) == "" then
    return false, "需要一个字体名字（:WeReadFont 不带参数可以打开选择器）"
  end
  name = vim.trim(name)
  local catalog = font_catalog

  -- Explicit prefixes let the picker and scripts say exactly which list they
  -- mean; a bare name prefers an installed WeRead font, then an exact local
  -- family, then WeRead's catalogue.
  -- (显式前缀让选择器和脚本说清指哪一份列表；裸名字先找已安装的微信读书字体，再找完全同名的
  --  本机字体，最后才查微信读书目录)
  local kind, target = name:match("^(weread):(.+)$")
  if kind then
    return M.apply_we_read(target, opts)
  end
  kind, target = name:match("^(local):(.+)$")
  if kind then
    return M.apply_local(target, opts)
  end

  local installed = catalog.find_installed(name)
  if installed then
    return M.apply_we_read(installed.id, opts)
  end
  for _, item in ipairs(catalog.installed()) do
    if item.name == name or catalog.name_key(item.name) == catalog.name_key(name) then
      return M.apply_we_read(item.id, opts)
    end
  end
  if M.has_local(name) then
    return M.apply_local(name, opts)
  end
  return M.apply_we_read(name, opts)
end

---Choose one of WeRead's own fonts; download it when it is not installed yet.
---(选择一款微信读书自己的字体；还没装就下载)
---@param id string catalogue id or display name(目录 id 或显示名)
---@param opts table|nil
---@return boolean ok
---@return string message
function M.apply_we_read(id, opts)
  opts = opts or {}
  local catalog = font_catalog
  M._generation = M._generation + 1
  local generation = M._generation
  local installed = catalog.find_installed(id)
  if installed then
    remember("weread", {
      name = installed.name,
      id = installed.id,
      line_height = opts.line_height,
      font_size = opts.font_size,
    })
    require("weread.font_session").refresh(opts.from_chapter)
    return true, string.format("阅读字体 →「%s」（微信读书字体，已安装）", installed.name)
  end

  catalog.ensure_by_name(id, function(entry, err, item)
    if generation ~= M._generation then
      return
    end
    if not entry then
      notify("weread: " .. tostring(err or "下载字体失败"), vim.log.levels.ERROR)
      return
    end
    remember("weread", {
      name = item and item.name or entry.name,
      id = entry.id,
      line_height = opts.line_height,
      font_size = opts.font_size,
    })
    notify(string.format("weread: 阅读字体 →「%s」（已下载；若当前 kitty 还看不到这款字体，重开一次 kitty）", entry.name))
    require("weread.font_session").refresh(opts.from_chapter)
  end)
  return true, string.format("正在获取「%s」；下载完成后仍在阅读时自动应用", opts.label or id)
end

---Choose a local font family. (选择本机字体族)
---@param family string
---@param opts table|nil
---@return boolean ok
---@return string message
function M.apply_local(family, opts)
  opts = opts or {}
  M._generation = M._generation + 1
  if type(family) ~= "string" or family == "" then
    return false, "需要一个本机字体名"
  end
  if not M.has_local(family) then
    return false, string.format("本机没有「%s」这款字体；请在选择器中重新选择", family)
  end
  remember("local", { name = family, line_height = opts.line_height, font_size = opts.font_size })
  require("weread.font_session").refresh(opts.from_chapter)
  return true, string.format("阅读字体 →「%s」（本机字体）", family)
end

---Switch to the remembered choice right now, if a chapter is reading.
---(如果正在读章节，立刻切到记住的字体)
function M.activate()
  local choice = M.choice()
  local kitty = font_kitty
  if not choice then
    kitty.clear()
    return
  end
  local line_height = M.line_height()
  local size = M.size()
  if choice.kind == "local" then
    if not M.has_local(choice.name) then
      M._missing_local = M._missing_local or {}
      if not M._missing_local[choice.name] then
        M._missing_local[choice.name] = true
        notify(string.format("weread: 本机找不到字体「%s」，终端字体保持不变", choice.name), vim.log.levels.WARN)
      end
      return
    end
    kitty.set(choice.family, { line_height = line_height, font_size = size.pt })
    return
  end

  if choice.entry then
    kitty.set(choice.entry.family, { line_height = line_height, font_size = size.pt })
    return
  end

  -- The choice survived a restart but the font file did not (or the reader
  -- picked from a catalogue item before it finished). Fetch it once, then apply.
  -- (选择活过了重启，但字体文件不在了（或者读者在下载完成前就选了目录项）。取一次，然后应用)
  local catalog = font_catalog
  if M._downloading == nil then
    M._downloading = {}
  end
  local key = choice.id or choice.name
  if M._downloading[key] then
    return
  end
  -- Offline for a moment? Do not try to download the same font on every
  -- chapter enter; a minute later is soon enough.
  -- (只是暂时离线？不要每次进章节都为同一款字体重试下载；一分钟后再说)
  if M._download_failed_at and M._download_failed_at[key] and os.time() - M._download_failed_at[key] < 60 then
    return
  end
  M._downloading[key] = true
  local generation = M._generation
  notify(string.format("weread: 「%s」还没下载，正在下载…", choice.name))
  catalog.ensure_by_name(choice.id or choice.name, function(entry, err)
    M._downloading[key] = nil
    if generation ~= M._generation then
      return
    end
    if not entry then
      M._download_failed_at = M._download_failed_at or {}
      M._download_failed_at[key] = os.time()
      notify("weread: " .. tostring(err or "下载字体失败"), vim.log.levels.ERROR)
      return
    end
    if M._download_failed_at then
      M._download_failed_at[key] = nil
    end
    remember("weread", { name = choice.name, id = entry.id, line_height = line_height })
    require("weread.font_session").refresh()
  end)
end

---Put the terminal's own font back. (恢复终端自己的字体)
function M.deactivate()
  font_kitty.clear()
end

---Restore the terminal font by hand, for after a crash or a stuck session.
---(手动恢复终端字体，用于崩溃或会话卡住之后)
---@return boolean ok
---@return string message
function M.restore()
  local kitty = font_kitty
  local status = kitty.status()
  if not status.applied then
    return true, "当前没有应用阅读字体，终端字体本来就是自己的"
  end
  kitty.clear({ on_error = function(message)
    notify("weread: " .. message, vim.log.levels.ERROR)
  end })
  return true, "已请求恢复终端字体"
end

---Forget the choice and restore. (忘掉选择并恢复)
---@return boolean ok
---@return string message
function M.clear(opts)
  opts = opts or {}
  M._generation = M._generation + 1
  local prefs = require("weread.prefs")
  prefs.set("font", nil)
  prefs.set("font_kind", nil)
  prefs.set("font_id", nil)
  prefs.set("font_line_height", nil)
  -- A picker opened outside reading only changes the saved preference. It must
  -- not restore a terminal font that belongs to another context. A source chapter
  -- which was left while the picker was open is stale for the same reason.
  -- (在阅读外打开的选择器只改已记住的选择，不能恢复属于其它上下文的终端字体。选择器打开后
  -- 已离开的来源章节同样过期。)
  local source_is_current = type(opts.from_chapter) ~= "number"
    or (vim.api.nvim_get_current_buf() == opts.from_chapter and vim.b[opts.from_chapter].weread_book ~= nil)
  if opts.from_chapter ~= false and source_is_current then
    font_kitty.clear({ on_error = function(message)
      notify("weread: " .. message, vim.log.levels.ERROR)
    end })
  end
  return true, "阅读字体已关闭，跟随终端字体"
end

---Ask kitty to allow runtime reloads, if it does not already.
---(如果 kitty 还不允许运行时重载，询问后开启)
---@return boolean ok
---@return string message
function M.enable()
  font_kitty.enable_remote(function(ok, message)
    notify("weread: " .. message, ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end)
  return true, "正在检查 kitty 的远程控制…"
end

---A human-readable status block. (给人看的状态)
---@return string
function M.status()
  local choice = M.choice()
  local kitty = font_kitty
  local state = kitty.status()
  local lines = {}
  if not choice then
    lines[#lines + 1] = "阅读字体：未选择（跟随终端）"
  elseif choice.kind == "weread" then
    lines[#lines + 1] = "阅读字体：" .. choice.name .. "（微信读书字体）"
    lines[#lines + 1] = "字体族：" .. (choice.entry and choice.entry.family or "未安装（进入章节时会下载）")
  else
    lines[#lines + 1] = "阅读字体：" .. choice.name .. "（本机字体）"
    if not M.has_local(choice.name) then
      lines[#lines + 1] = "注意：fontconfig 里找不到这款字体"
    end
  end

  local line_height = M.line_height()
  lines[#lines + 1] = line_height and string.format("行距：cell_height %d%%", math.floor(line_height))
    or "行距：跟随终端"

  lines[#lines + 1] = state.gui and "生效方式：GUI 版 nvim 直接设置 guifont，离开章节或退出时恢复"
    or "生效方式：进入章节时临时切换 kitty 字体，离开章节或退出时恢复（不写 kitty.conf）"
  if state.gui then
    -- no kitty remote control in a GUI (GUI 里不需要 kitty 远程控制)
  elseif not kitty.available() then
    lines[#lines + 1] = "当前不在 kitty 里（或没有 kitten），运行时切换暂不可用"
  elseif state.remote == true then
    lines[#lines + 1] = "kitty 远程控制：已就绪"
  elseif state.remote == false then
    lines[#lines + 1] = "kitty 远程控制：不可用（选择字体时会自动启用）"
  else
    lines[#lines + 1] = "kitty 远程控制：尚未检测（选择字体时会自动启用）"
  end
  lines[#lines + 1] = "当前状态：" .. (state.applied and ("已应用「" .. tostring(state.family) .. "」") or "未应用")
  if state.original then
    lines[#lines + 1] = "kitty 原始字体：" .. state.original
  end
  lines[#lines + 1] = "已安装微信读书字体：" .. #font_catalog.installed() .. " 款"
  lines[#lines + 1] = "字体目录：" .. font_catalog.dir()
  lines[#lines + 1] = "本机中文字体：" .. #M.installed() .. " 款"
  if vim.fn.filereadable(M.snippet_path()) == 1 then
    lines[#lines + 1] = "旧版本片段还在：" .. M.snippet_path() .. "（可手动删除）"
  end
  return table.concat(lines, "\n")
end

---Local and installed-WeRead lists for the `list` command. Offline by design.
---(`list` 命令用的本机字体与已装微信读书字体列表；刻意不联网)
---@return string[]
function M.list_lines()
  local catalog = font_catalog
  local lines = {}
  local wr = catalog.installed()
  lines[#lines + 1] = string.format("微信读书字体（已安装 %d 款）", #wr)
  local from_we_read = {}
  if #wr == 0 then
    lines[#lines + 1] = "  还没有；:WeReadFont 选择后会自动下载"
  else
    for _, item in ipairs(wr) do
      from_we_read[item.family] = true
      lines[#lines + 1] = string.format("  %s  [%s]", item.name, item.family)
    end
  end
  local locals = {}
  for _, family in ipairs(M.installed()) do
    if not from_we_read[family] then
      locals[#locals + 1] = family
    end
  end
  lines[#lines + 1] = string.format("本机中文字体（%d 款）", #locals)
  for _, family in ipairs(locals) do
    lines[#lines + 1] = "  " .. family
  end
  return lines
end

---The local family lines kept for compatibility with older callers.
---(保留给旧调用方的本机字体列表)
---@return string[]
function M.local_lines()
  return M.installed()
end

---Build the picker items from the catalogue, installed fonts and local families.
---(由目录、已装字体和本机字体构造选择器条目)
---@param items weread.font.Item[]|nil
---@return table[]
local function picker_items(items)
  local catalog = font_catalog
  local choice = M.choice()
  local current_kind = choice and choice.kind
  local current_name = choice and choice.name
  local installed = {}
  local from_we_read = {}
  for _, entry in ipairs(catalog.installed()) do
    installed[entry.id] = entry
    from_we_read[entry.family] = true
  end

  local result = {}
  local function add(item)
    result[#result + 1] = item
  end

  add({
    text = (choice == nil and "▶ " or "  ") .. "不使用阅读字体（跟随终端）",
    kind = "none",
  })

  -- installed WeRead fonts first (offline and ready), then the catalogue
  -- (already installed entries are skipped in the second pass)
  -- (先放已装的微信读书字体（离线可用），再放目录（第二遍跳过已装的）)
  for _, entry in ipairs(catalog.installed()) do
    add({
      text = (current_kind == "weread" and current_name == entry.name and "▶ " or "  ")
        .. entry.name
        .. "  ✓  · 微信读书",
      kind = "weread",
      id = entry.id,
      name = entry.name,
      family = entry.family,
      installed = true,
    })
  end
  for _, item in ipairs(items or {}) do
    if not installed[item.id] then
      local size = item.size > 0 and string.format("  %.1f MB", item.size / 1048576) or ""
      add({
        text = (current_kind == "weread" and current_name == item.name and "▶ " or "  ")
          .. item.name
          .. "  ↓"
          .. size
          .. "  · 微信读书"
          .. (item.vip and "（会员）" or ""),
        kind = "weread",
        id = item.id,
        name = item.name,
        installed = false,
      })
    end
  end

  for _, family in ipairs(M.installed()) do
    if not from_we_read[family] then
      add({
        text = (current_kind == "local" and current_name == family and "▶ " or "  ")
          .. family
          .. "  · 本机",
        kind = "local",
        family = family,
        name = family,
        installed = true,
      })
    end
  end
  return result
end

---@return table[]
local function size_items()
  local current = M.size().key
  local result = {}
  for _, key in ipairs({ "small", "medium", "large" }) do
    local size = SIZES[key]
    result[#result + 1] = {
      key = key,
      text = string.format("%s %s · %d pt", key == current and "▶" or " ", size.label, size.pt),
    }
  end
  return result
end

---@param ctx table
function M.snacks_preview(ctx)
  local item = ctx.item or {}
  local view = ctx.preview
  view:reset()
  if view.minimal then
    pcall(view.minimal, view)
  end
  view:set_title("阅读字体预览")
  local size = M.size()
  local lines = {
    item.name or "跟随终端字体",
    "",
    "春眠不觉晓，处处闻啼鸟。",
    "落花人独立，微雨燕双飞。",
    "",
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "0123456789  ，。！？（）",
    "",
    string.format("阅读字号：%s · %d pt", size.label, size.pt),
  }
  if item.kind == "none" then
    lines[#lines + 1] = "使用终端原字体"
  elseif item.kind == "weread" and not item.installed then
    lines[#lines + 1] = "选择后下载，当前无法真实预览"
  else
    lines[#lines + 1] = "移动光标可试用已安装字体"
  end
  view:set_lines(lines)
end

---@param item table|nil
---@param from_chapter integer|false
---@param source_win integer
function M.preview(item, from_chapter, source_win)
  if not item or not from_chapter or not vim.api.nvim_win_is_valid(source_win) then
    return
  end
  if vim.api.nvim_win_get_buf(source_win) ~= from_chapter or vim.b[from_chapter].weread_book == nil then
    return
  end
  local family = item.family
  if item.kind == "weread" and item.installed then
    family = item.family
  end
  if family and (item.kind == "local" or item.installed) then
    font_kitty.set(family, { line_height = M.line_height(), font_size = M.size().pt })
  end
end

---Open the font picker. The catalogue is fetched in the background; local and
---installed fonts show up even when it cannot be reached.
---(打开字体选择器。目录在后台抓取；即使抓不到，已装字体和本机字体仍会出现)
---@param opts table|nil
---@return boolean
function M.picker(opts)
  opts = opts or {}
  local session = require("weread.font_session")
  local from_chapter = session.active() and vim.api.nvim_get_current_buf() or false
  local source_win = from_chapter and vim.api.nvim_get_current_win() or -1
  local catalog = font_catalog
  if vim.fn.filereadable(catalog.catalog_path()) ~= 1 then
    notify("weread: 正在获取微信读书字体目录…")
  end
  catalog.catalog(function(items, err)
    if not items and #catalog.installed() == 0 and #M.installed() == 0 then
      notify("weread: 没找到可用字体：" .. tostring(err), vim.log.levels.WARN)
      return
    end
    if err then
      notify("weread: 微信读书字体目录获取失败：" .. tostring(err) .. "（仍可选择本机字体）", vim.log.levels.WARN)
    end
    local timer = require("weread.timer")
    local trying = timer.debounce(function(item)
      M.preview(item, from_chapter, source_win)
    end, 80)
    require("weread.ui").select({
      title = "微信读书 · 阅读字体（微信读书字体 / 本机字体）",
      items = picker_items(items),
      preview = M.snacks_preview,
      on_change = function(item)
        trying.call(item)
      end,
      on_close = function()
        trying.cancel()
      end,
      on_choice = function(item)
        vim.schedule(function()
          if item.kind == "none" then
            local still_reading = from_chapter
              and vim.api.nvim_get_current_buf() == from_chapter
              and require("weread.font_session").active()
            local ok, message = M.clear({ from_chapter = still_reading })
            notify(message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
            return
          end
          require("weread.ui").select({
            title = "微信读书 · 阅读字号",
            items = size_items(),
            preview = "none",
            snacks = { layout = { preview = false } },
            on_choice = function(size)
              vim.schedule(function()
                local apply_opts = vim.tbl_extend("force", {}, opts, {
                  label = item.name,
                  from_chapter = from_chapter,
                  font_size = size.key,
                })
                local ok, message
                if item.kind == "weread" then
                  ok, message = M.apply_we_read(item.id, apply_opts)
                else
                  ok, message = M.apply_local(item.family, apply_opts)
                end
                notify(message .. string.format(" · 字号%s", SIZES[size.key].label), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
              end)
            end,
          })
        end)
      end,
    })
  end, { prefer_cache = true })
  return true
end

---Completion for `:WeReadFont`. Reads cached data only, never the network.
---(`:WeReadFont` 的补全；只读缓存，不联网)
---@param lead string
---@return string[]
function M.complete(lead)
  lead = lead or ""
  local words = { "status", "list", "restore", "off", "enable", "cleanup" }
  local catalog = font_catalog
  for _, entry in ipairs(catalog.installed()) do
    words[#words + 1] = entry.name
  end
  for _, family in ipairs(M.installed()) do
    words[#words + 1] = family
  end
  local prefix = lead:lower()
  local seen = {}
  local result = {}
  for _, word in ipairs(words) do
    if not seen[word] and word:lower():sub(1, #prefix) == prefix then
      seen[word] = true
      result[#result + 1] = word
    end
  end
  return result
end

---The snippet a previous version wrote. (旧版本写下的片段)
---@return string
function M.snippet_path()
  -- The old version always wrote this under XDG_CONFIG_HOME/kitty, even when
  -- KITTY_CONFIG_DIRECTORY pointed elsewhere; cleanup has to look there.
  -- (旧版本总是把它写在 XDG_CONFIG_HOME/kitty 下，即使 KITTY_CONFIG_DIRECTORY 指向别处；
  --  清理时要去那里找)
  local directory = (vim.env.XDG_CONFIG_HOME or ((vim.env.HOME or vim.fn.expand("~")) .. "/.config")) .. "/kitty"
  return directory .. "/weread-font.conf"
end

---@return string
function M.kitty_conf_path()
  return font_kitty.config_path()
end

---Remove the snippet/include an older version installed, with the reader's
---consent. Nothing writes one again.
---(在读者同意后清掉旧版本装过的片段/include；之后不再写)
---@return boolean ok
---@return string message
function M.cleanup()
  local snippet = M.snippet_path()
  local conf = M.kitty_conf_path()
  local has_snippet = vim.fn.filereadable(snippet) == 1
  local has_include = false
  if vim.fn.filereadable(conf) == 1 then
    for _, line in ipairs(vim.fn.readfile(conf)) do
      if line:match("^%s*include%s+.*weread%-font%.conf%s*$") then
        has_include = true
        break
      end
    end
  end
  if not has_snippet and not has_include then
    return true, "没有找到旧版本留下的字体片段，终端配置是干净的"
  end
  if #vim.api.nvim_list_uis() == 0 then
    return false, "无界面运行时不改 kitty 配置；请手动删掉 " .. snippet .. " 和 kitty.conf 里的 include"
  end
  local choice = vim.fn.confirm(
    string.format("要删除旧版本留下的 %s，以及 kitty.conf 里对应的 include 行吗？", snippet),
    "&删除\n&不用",
    1
  )
  if choice ~= 1 then
    return false, "没有改动；旧的 include 仍可能覆盖运行时字体"
  end
  if has_snippet then
    vim.fn.delete(snippet)
  end
  if has_include then
    local kept = {}
    for _, line in ipairs(vim.fn.readfile(conf)) do
      local is_include = line:match("^%s*include%s+.*weread%-font%.conf%s*$") ~= nil
      local is_comment = line:find("weread.nvim", 1, true)
        and (line:find(":WeReadFont", 1, true) or line:find("阅读字体", 1, true))
      if not is_include and not is_comment then
        kept[#kept + 1] = line
      end
    end
    local ok, err = pcall(vim.fn.writefile, kept, conf)
    if not ok then
      return false, "写入 " .. conf .. " 失败：" .. tostring(err)
    end
  end
  font_kitty.signal_reload()
  return true, "已清掉旧字体片段；kitty 已重载（或按 ctrl+shift+F5）"
end

---Why runtime switching is unavailable, in words that can be acted on.
---(运行时切换不可用的原因，写成可以照着做的说法)
---@return string
function M.unavailable_reason()
  local kitty = font_kitty
  if kitty.gui() then
    return ""
  end
  if not kitty.in_kitty() then
    return "当前终端不是 kitty；运行时换字体需要 kitty，字体选择仍会被记住"
  end
  if vim.fn.executable("kitten") ~= 1 then
    return "找不到 kitten 命令；请确认 kitty 安装完整"
  end
  if kitty.status().remote == false then
    return "kitty 远程控制不可用；选择字体时会自动启用"
  end
  return ""
end

return M
