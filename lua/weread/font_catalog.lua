--[[
WeRead's own reading fonts: the catalogue, on-demand download, and the small
local registry that remembers which ones are installed.
(微信读书自己的阅读字体：目录、按需下载，以及一份记录已安装字体的本地登记表)

The web reader fetches its font list from `/feconfig/font/list?type=web_v2` and
each entry is a zip containing one WOFF file. The fonts are public CDN assets;
they are not part of the book license, only the reader's typeface choices.
(网页阅读器从 `/feconfig/font/list?type=web_v2` 取字体目录，每一项是一个只含一个 WOFF
 文件的 zip。字体是公开的 CDN 资源，不属于书籍授权，只是阅读器的字体选择)

Installed fonts live in the user font directory so fontconfig (and therefore
kitty) can see them. That directory is not the plugin's data directory: it has
to be somewhere the font stack scans, and `$XDG_DATA_HOME/fonts` is that place.
(装好的字体放在用户字体目录，fontconfig（进而 kitty）才看得见。它不是插件的数据目录：
 必须落在字体栈会扫描的位置，也就是 `$XDG_DATA_HOME/fonts`)

Downloading is deliberately explicit: a font can be 20 MB, so nothing is fetched
until the reader picks it in `:WeReadFont`.
(下载是显式的：一款字体可能有 20 MB，因此在读者用 :WeReadFont 选中它之前不下载任何东西)
]]

local cache = require("weread.cache")
local config = require("weread.config")
local http = require("weread.http")
local log = require("weread.log")

local M = {}

---Callbacks waiting on the same catalogue refresh or font download, so a picker
---and a chapter opening at once cannot fetch the same 20 MB twice.
---(等待同一次目录刷新或字体下载的回调，避免选择器和章节同时打开时把同一份 20 MB 下两遍)
local waiting_catalog = nil
local waiting_fonts = {}

---Where the catalogue comes from. (目录地址)
M.URL = "https://weread.qq.com/feconfig/font/list?type=web_v2"

---How long a downloaded catalogue is trusted before it is fetched again.
---(下载的目录在多久之内可以直接复用)
M.MAX_AGE = 7 * 24 * 3600

---The font formats a zip may carry. (zip 里可能带的字体格式)
local FONT_EXTENSIONS = { "woff2", "woff", "ttf", "ttc", "otf" }

---External helpers the installer needs. (安装器需要的外部命令)
---@return string[] missing
function M.missing_tools()
  local missing = {}
  for _, tool in ipairs({ "unzip", "fc-scan", "fc-cache" }) do
    if vim.fn.executable(tool) ~= 1 then
      missing[#missing + 1] = tool
    end
  end
  return missing
end

---The user font directory that fontconfig scans. (fontconfig 会扫描的用户字体目录)
---@return string
function M.dir()
  local data = vim.env.XDG_DATA_HOME
  if not data or data == "" then
    local home = vim.env.HOME
    if not home or home == "" then
      home = vim.fn.expand("~")
    end
    data = home .. "/.local/share"
  end
  return data .. "/fonts/weread"
end

---Registry of the fonts this plugin installed, kept beside them. Hidden from
---fontconfig because it is not a font file.
---(本插件装过的字体登记表，放在字体目录里。它不是字体文件，fontconfig 会忽略)
---@return string
function M.meta_path()
  return M.dir() .. "/.weread-fonts.json"
end

---Cached copy of the remote catalogue. (远程目录的缓存)
---@return string
function M.catalog_path()
  return config.path("fonts", "catalog.json")
end

---@class weread.font.Item
---@field id string catalogue id (`cejk`)(目录 id)
---@field name string display name (`仓耳今楷 04`)(显示名)
---@field url string zip url
---@field suffix string font suffix inside the zip(zip 内字体的扩展名)
---@field size integer inner font size in bytes(字体本身字节数)
---@field zip_size integer zip size in bytes(zip 字节数)
---@field sha256 string|nil
---@field vip boolean paid-member font(付费会员字体)
---@field group string catalogue group (`仓耳`, `方正`...)(目录分组)
---@field index integer catalogue order(目录顺序)

---@class weread.font.Installed
---@field id string
---@field name string display name(显示名)
---@field family string family name fontconfig/kitty use(fontconfig/kitty 使用的家族名)
---@field file string file name inside `M.dir()`(字体目录里的文件名)
---@field path string absolute path(绝对路径)
---@field suffix string
---@field size integer
---@field installed_at integer

---Turn the API's loose JSON into a stable shape, dropping what cannot be used.
---(把接口返回的松散 JSON 收敛成固定形状，丢掉不能用的条目)
---@param raw any
---@return weread.font.Item[]
local function normalize(raw)
  local items = {}
  if type(raw) ~= "table" then
    return items
  end
  for _, entry in ipairs(raw) do
    if type(entry) == "table" and type(entry.font) == "string" and type(entry.url) == "string" then
      items[#items + 1] = {
        id = entry.font,
        name = type(entry.fontName) == "string" and entry.fontName or entry.font,
        url = entry.url,
        suffix = type(entry.suffix) == "string" and entry.suffix:lower() or "woff",
        size = math.max(0, tonumber(entry.fileSize) or 0),
        zip_size = math.max(0, tonumber(entry.zipSize) or 0),
        sha256 = type(entry.Sha256) == "string" and entry.Sha256 or nil,
        vip = tonumber(entry.isVIPFont) == 1,
        group = type(entry.fontType) == "string" and entry.fontType or "",
        index = tonumber(entry.index) or 0,
      }
    end
  end
  table.sort(items, function(left, right)
    if left.index ~= right.index then
      return left.index < right.index
    end
    return left.name < right.name
  end)
  return items
end

---Read the cached catalogue, or nil when there is none or it is unreadable.
---(读取缓存的目录；没有或读不懂时为 nil)
---@return table|nil
local function read_catalog()
  local stored = cache.read_json(M.catalog_path())
  if type(stored) ~= "table" or type(stored.items) ~= "table" then
    return nil
  end
  return stored
end

---Fetch the catalogue, or reuse the cached one while it is fresh.
---(抓取目录；缓存还新鲜时直接复用)
---
---The callback always runs in the main loop. A network failure still hands back
---a stale cache when one exists, so `:WeReadFont` keeps working offline.
---(回调总在主循环里执行。网络失败时只要还有旧缓存就交回旧缓存，离线也能用 :WeReadFont)
---@param callback fun(items: weread.font.Item[]|nil, err: string|nil, meta: table|nil)
---@param opts table|nil { force: boolean }
function M.catalog(callback, opts)
  opts = opts or {}
  local stored = read_catalog()
  local fresh = stored
    and type(stored.fetched_at) == "number"
    and (os.time() - stored.fetched_at) < M.MAX_AGE
  if fresh and not opts.force then
    callback(normalize(stored.items), nil, { cached = true })
    return
  end
  if opts.prefer_cache and stored then
    -- The picker should open now, with the last list, and refresh in the
    -- background: waiting out a dead network would freeze the picker for a
    -- minute before showing local fonts.
    -- (选择器应当立刻打开，用上一份目录，后台再刷新：等一个坏掉的网络会让选择器卡一分钟才显示
    --  本机字体)
    callback(normalize(stored.items), nil, { stale = true })
    M.catalog(function() end, { force = true })
    return
  end
  if waiting_catalog then
    waiting_catalog[#waiting_catalog + 1] = callback
    return
  end
  waiting_catalog = { callback }

  http.request({ url = M.URL, timeout = 12, retries = 1 }, function(res)
    local data, err = http.decode_json(res)
    local callbacks = waiting_catalog or {}
    waiting_catalog = nil
    if not data or type(data.items) ~= "table" then
      if stored then
        log.warn("font catalogue refresh failed (%s); using the cached copy", tostring(err))
        for _, waiting in ipairs(callbacks) do
          waiting(normalize(stored.items), nil, { stale = true, error = err })
        end
      else
        for _, waiting in ipairs(callbacks) do
          waiting(nil, err or "字体目录格式不对")
        end
      end
      return
    end
    local items = normalize(data.items)
    if #items == 0 then
      for _, waiting in ipairs(callbacks) do
        waiting(nil, "字体目录是空的")
      end
      return
    end
    local ok, write_err = cache.write_json(M.catalog_path(), {
      fetched_at = os.time(),
      items = data.items,
    })
    if not ok then
      log.warn("could not cache the font catalogue: %s", tostring(write_err))
    end
    for _, waiting in ipairs(callbacks) do
      waiting(items, nil, { cached = false })
    end
  end)
end

---The fonts this plugin has installed, newest name order, with missing files
---left out.
---(本插件已安装的字体，按名字排序；文件已经不在了的条目不返回)
---@return weread.font.Installed[]
function M.installed()
  local stored = cache.read_json(M.meta_path())
  local fonts = type(stored) == "table" and type(stored.fonts) == "table" and stored.fonts or {}
  local list = {}
  for id, entry in pairs(fonts) do
    if type(entry) == "table" and type(entry.file) == "string" and type(entry.family) == "string" then
      local path = M.dir() .. "/" .. entry.file
      local stat = vim.uv.fs_stat(path)
      if stat and stat.size > 0 then
        list[#list + 1] = {
          id = id,
          name = type(entry.name) == "string" and entry.name or id,
          family = entry.family,
          file = entry.file,
          path = path,
          suffix = type(entry.suffix) == "string" and entry.suffix or "woff",
          size = tonumber(entry.size) or stat.size,
          installed_at = tonumber(entry.installed_at) or 0,
        }
      end
    end
  end
  table.sort(list, function(left, right)
    if left.name ~= right.name then
      return left.name < right.name
    end
    return left.id < right.id
  end)
  return list
end

---Find an installed font by catalogue id. (按目录 id 找已安装字体)
---@param id string|nil
---@return weread.font.Installed|nil
function M.find_installed(id)
  if type(id) ~= "string" or id == "" then
    return nil
  end
  local wanted = M.name_key and M.name_key(id) or id
  for _, entry in ipairs(M.installed()) do
    if entry.id == id or entry.family == id or M.name_key(entry.name) == wanted then
      return entry
    end
  end
  return nil
end

---A name key that ignores the spaces the catalogue sprinkles in (`仓耳今楷 04`
---has a U+2005 between the digits), so typed names still match.
---(忽略目录名里那些空格的比较键（`仓耳今楷 04` 的数字之间是 U+2005），手敲的名字也能对上)
---@param name string
---@return string
function M.name_key(name)
  return (name:gsub("%s+", ""):gsub("\226\128\133", "")):lower()
end

---Find a catalogue entry by id or display name. (按 id 或显示名找目录条目)
---@param items weread.font.Item[]
---@param name string
---@return weread.font.Item|nil
function M.find(items, name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local wanted = M.name_key(name)
  for _, item in ipairs(items or {}) do
    if item.id == name then
      return item
    end
  end
  for _, item in ipairs(items or {}) do
    if M.name_key(item.name) == wanted then
      return item
    end
  end
  return nil
end

---Read a font's primary family with fc-scan. The API's display name is not
---always the family kitty needs (`仓耳明楷 04` is stored as `TsangerMingKai W04`).
---(用 fc-scan 读字体的主家族名。接口的显示名不总是 kitty 需要的家族名
--- （`仓耳明楷 04` 实际是 `TsangerMingKai W04`）)
---@param path string
---@return string|nil family
function M.scan_family(path)
  if vim.fn.executable("fc-scan") ~= 1 then
    return nil
  end
  local ok, result = pcall(vim.system, { "fc-scan", "--format", "%{family}\n", path }, { text = true })
  if not ok then
    return nil
  end
  local waited, done = pcall(result.wait, result, 5000)
  if not waited or type(done) ~= "table" or done.code ~= 0 then
    return nil
  end
  local first = (done.stdout or ""):match("^%s*([^\n]+)")
  if not first then
    return nil
  end
  -- Prefer the most specific family: a font family may carry a base name
  -- (`TsangerMingKai`), a localized one (`仓耳明楷`) and the face's own name
  -- (`TsangerMingKai W04`). The last one keeps 04 and 05 apart.
  -- (优先用最具体的家族名：一个字体可能同时有基础名（TsangerMingKai）、中文名（仓耳明楷）
  --  和这个字面自己的名字（TsangerMingKai W04）。用最后一个才能把 04 和 05 分开)
  local family = nil
  for part in first:gmatch("[^,]+") do
    local cleaned = vim.trim(part:gsub('^"(.*)"$', "%1"))
    if cleaned ~= "" and (family == nil or #cleaned > #family) then
      family = cleaned
    end
  end
  return family
end

---Pick the largest font file an extracted zip left behind. (挑出解压后最大的字体文件)
---@param dir string
---@return string|nil path
---@return string|nil extension
local function largest_font(dir)
  local best, best_size, best_ext = nil, -1, nil
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" then
      local lower = name:lower()
      for _, ext in ipairs(FONT_EXTENSIONS) do
        if lower:sub(-(#ext + 1)) == "." .. ext then
          local path = dir .. "/" .. name
          local stat = vim.uv.fs_stat(path)
          if stat and stat.size > best_size then
            best, best_size, best_ext = path, stat.size, ext
          end
          break
        end
      end
    end
  end
  return best, best_ext
end

---Move a file, falling back to a copy across filesystems. (移动文件；跨文件系统时退回复制)
---@param from string
---@param to string
---@return boolean ok
---@return string|nil err
local function move(from, to)
  local ok, err = vim.uv.fs_rename(from, to)
  if ok then
    return true, nil
  end
  local copied, copy_err = vim.uv.fs_copyfile(from, to)
  if copied then
    vim.uv.fs_unlink(from)
    return true, nil
  end
  return false, tostring(err or copy_err)
end

---Write one installed font into the registry. (把一款已安装字体写进登记表)
---@param entry weread.font.Installed
---@return boolean ok
---@return string|nil err
local function remember(entry)
  local stored = cache.read_json(M.meta_path())
  if type(stored) ~= "table" or type(stored.fonts) ~= "table" then
    stored = { version = 1, fonts = {} }
  end
  stored.version = 1
  stored.fonts[entry.id] = {
    name = entry.name,
    family = entry.family,
    file = entry.file,
    suffix = entry.suffix,
    size = entry.size,
    installed_at = entry.installed_at,
  }
  return cache.write_json(M.meta_path(), stored)
end

---Download, extract and install one catalogue font.
---(下载、解压并安装一款目录字体)
---
---The callback runs once, in the main loop: `entry` on success, `nil` plus a
---sentence on failure. Already installed fonts are returned without touching
---the network.
---(回调在主循环里跑一次：成功给 entry，失败给 nil 和一句话。已安装的字体直接返回，不联网)
---@param item weread.font.Item
---@param callback fun(entry: weread.font.Installed|nil, err: string|nil)
function M.ensure(item, callback)
  local installed = M.find_installed(item.id)
  if installed then
    callback(installed, nil)
    return
  end
  if waiting_fonts[item.id] then
    waiting_fonts[item.id][#waiting_fonts[item.id] + 1] = callback
    return
  end
  waiting_fonts[item.id] = { callback }
  local function finish(entry, err)
    local callbacks = waiting_fonts[item.id] or { callback }
    waiting_fonts[item.id] = nil
    for _, waiting in ipairs(callbacks) do
      waiting(entry, err)
    end
  end

  local missing = M.missing_tools()
  if #missing > 0 then
    finish(nil, "缺少命令：" .. table.concat(missing, "、") .. "（安装器需要它们解压和登记字体）")
    return
  end

  local tmp = config.path("tmp", "font-" .. item.id .. ".zip")
  local extract_dir = config.path("tmp", "font-" .. item.id)
  vim.fn.delete(tmp)
  vim.fn.delete(extract_dir, "rf")
  vim.fn.mkdir(vim.fs.dirname(tmp), "p")
  vim.fn.mkdir(M.dir(), "p")

  http.download(item.url, tmp, { timeout = 180, retries = 2 }, function(res)
    if res.code ~= 200 then
      vim.fn.delete(tmp)
      finish(nil, string.format("下载「%s」失败（HTTP %s）", item.name, tostring(res.status or res.error or res.code)))
      return
    end
    local stat = vim.uv.fs_stat(tmp)
    if not stat or stat.size == 0 then
      vim.fn.delete(tmp)
      finish(nil, "下载「" .. item.name .. "」失败：文件是空的")
      return
    end
    if item.zip_size > 0 and stat.size ~= item.zip_size then
      log.warn(
        "font zip size differs from the catalogue for %s (%d != %d); continuing",
        item.id,
        stat.size,
        item.zip_size
      )
    end

    vim.fn.mkdir(extract_dir, "p")
    local unpacked, unzip_result = pcall(function()
      return vim.system({ "unzip", "-o", "-j", tmp, "-d", extract_dir }, { text = true }):wait(30000)
    end)
    if not unpacked or type(unzip_result) ~= "table" or unzip_result.code ~= 0 then
      vim.fn.delete(tmp)
      vim.fn.delete(extract_dir, "rf")
      finish(nil, "解压「" .. item.name .. "」失败：" .. tostring(unpacked and unzip_result and unzip_result.stderr or unzip_result))
      return
    end

    local source, extension = largest_font(extract_dir)
    if not source then
      vim.fn.delete(tmp)
      vim.fn.delete(extract_dir, "rf")
      finish(nil, "「" .. item.name .. "」的 zip 里没有字体文件")
      return
    end

    local file = item.id:gsub("[^%w%-_]", "_") .. "." .. extension
    local destination = M.dir() .. "/" .. file
    local moved, move_err = move(source, destination)
    if not moved then
      vim.fn.delete(tmp)
      vim.fn.delete(extract_dir, "rf")
      finish(nil, "写入字体失败：" .. tostring(move_err))
      return
    end

    -- fontconfig has to learn about the new file before kitty can resolve it.
    -- (kitty 能解析这个名字之前，fontconfig 得先认识这个文件)
    local cached, cache_result = pcall(function()
      return vim.system({ "fc-cache", "-f", M.dir() }, { text = true }):wait(15000)
    end)
    if not cached or type(cache_result) ~= "table" or cache_result.code ~= 0 then
      log.warn("fc-cache failed after installing %s", item.id)
    end

    local family = M.scan_family(destination)
    if not family then
      -- The display name is the best fallback; a wrong family only means kitty
      -- falls back to its default, and `:WeReadFont status` shows what happened.
      -- (退回到显示名；家族名不对只会让 kitty 用回默认字体，`:WeReadFont status` 能看到结果)
      family = item.name
      log.warn("could not read the family of %s; using the display name", destination)
    end

    local entry = {
      id = item.id,
      name = item.name,
      family = family,
      file = file,
      path = destination,
      suffix = extension,
      size = (vim.uv.fs_stat(destination) or {}).size or item.size,
      installed_at = os.time(),
    }
    local ok, err = remember(entry)
    if not ok then
      log.warn("could not record the installed font %s: %s", item.id, tostring(err))
    end

    vim.fn.delete(tmp)
    vim.fn.delete(extract_dir, "rf")
    finish(entry, nil)
  end)
end

---Install (if needed) the catalogue entry a name points at.
---(按名字找到目录条目并确保它已安装)
---@param name string id or display name(目录 id 或显示名)
---@param callback fun(entry: weread.font.Installed|nil, err: string|nil, item: weread.font.Item|nil)
function M.ensure_by_name(name, callback)
  local installed = M.find_installed(name)
  if installed then
    callback(installed, nil, nil)
    return
  end
  M.catalog(function(items, err)
    if not items then
      callback(nil, "无法获取微信读书字体目录：" .. tostring(err), nil)
      return
    end
    local item = M.find(items, name)
    if not item then
      callback(nil, "微信读书字体里没有「" .. name .. "」", nil)
      return
    end
    local already = M.find_installed(item.id)
    if already then
      callback(already, nil, item)
      return
    end
    M.ensure(item, function(entry, install_err)
      callback(entry, install_err, item)
    end)
  end)
end

return M
