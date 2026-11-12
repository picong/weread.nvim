--[[
ECDICT, the open English-Chinese dictionary (https://github.com/skywind3000/ECDICT,
MIT), as a local SQLite file: the word lookup that needs no network.
(ECDICT——开源英汉词典——做成本地 SQLite 文件：不需要联网的查词)

The data ships as a 66 MB CSV of about 760 000 entries. `:WeReadDict install`
downloads it once and imports it with the `sqlite3` command line tool into
`data_dir/ecdict.db`, with an index on the headword, so a lookup is one indexed
query. A lookup spawns `sqlite3` for that query: a few milliseconds, and nothing
stays running between lookups.
(数据是约 76 万词条、66MB 的 CSV。`:WeReadDict install` 下载一次，用 `sqlite3` 命令行
 导入成 `data_dir/ecdict.db`，并给词头建索引，查词就是一次走索引的查询。每次查词启动一个
 sqlite3 进程跑这条查询：几毫秒，查完不留常驻进程)

Inflected forms are found through the `exchange` field ECDICT carries
(`0:perceive` on "perceived"): a form whose own entry says little points to its
lemma, and the lemma's entry is shown with it.
(屈折形式靠 ECDICT 自带的 exchange 字段找到原形（"perceived" 上的 `0:perceive`）：自身
 词条没什么内容的形式指向原形，一并显示原形的释义)
]]

local M = {}

M.CSV_URL = "https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv"

---@return string
function M.path()
  local configured = ((require("weread.config").get().lookup or {}).ecdict_db)
  if type(configured) == "string" and configured ~= "" then
    return vim.fn.expand(configured)
  end
  return require("weread.config").path("ecdict.db")
end

---@return boolean
function M.available()
  return vim.fn.executable("sqlite3") == 1 and vim.uv.fs_stat(M.path()) ~= nil
end

---Only letters, digits, spaces, apostrophes, hyphens and dots reach the query:
---the word is spliced into SQL text, so anything else is refused outright.
---(只有字母、数字、空格、撇号、连字符和点能进查询：词是拼进 SQL 文本的，其它字符一律拒绝)
---@param word string
---@return boolean
local function safe(word)
  return type(word) == "string" and word ~= "" and #word <= 64 and not word:find("[^%w '%-%.]")
end

---@param word string
---@return string SQL literal
local function literal(word)
  return "'" .. word:gsub("'", "''") .. "'"
end

---Parse the exchange field: "p:gave/d:given/0:give" -> { p = "gave", ... }.
---(解析 exchange 字段)
---@param exchange string|nil
---@return table<string, string>
function M.parse_exchange(exchange)
  local out = {}
  for item in tostring(exchange or ""):gmatch("[^/]+") do
    local key, value = item:match("^(%w):(.+)$")
    if key then
      out[key] = value
    end
  end
  return out
end

---Run one query; `callback(rows|nil, err)` on the main loop.
---(跑一条查询；在主循环里回调)
---@param sql string
---@param callback fun(rows: table[]|nil, err: string|nil)
---@return table|nil job the sqlite3 process, so a deadline can stop it(sqlite3 进程，供时限到了时终止)
local function query(sql, callback)
  local ok, err = pcall(vim.system, { "sqlite3", "-readonly", "-json", M.path(), sql }, { text = true }, function(done)
    vim.schedule(function()
      if done.code ~= 0 then
        callback(nil, vim.trim(done.stderr or "") ~= "" and vim.trim(done.stderr) or ("sqlite3 exited " .. done.code))
        return
      end
      local text = vim.trim(done.stdout or "")
      if text == "" then
        callback({}, nil)
        return
      end
      local decoded, rows = pcall(vim.json.decode, text)
      local good = decoded and type(rows) == "table"
      callback(good and rows or nil, not good and "bad sqlite3 output" or nil)
    end)
  end)
  if not ok then
    vim.schedule(function()
      callback(nil, "could not start sqlite3: " .. tostring(err))
    end)
    return nil
  end
  return err
end

---@param rows table[]
---@param word string
---@return table|nil
local function pick(rows, word)
  local exact, folded = nil, nil
  for _, row in ipairs(rows) do
    if row.word == word then
      exact = row
    elseif not folded and type(row.word) == "string" and row.word:lower() == word:lower() then
      folded = row
    end
  end
  return exact or folded
end

---@param translation string|nil
---@return string[]
local function lines_of(translation)
  local out = {}
  for line in tostring(translation or ""):gsub("\\n", "\n"):gmatch("[^\r\n]+") do
    line = vim.trim(line)
    if line ~= "" then
      out[#out + 1] = line
    end
  end
  return out
end

---Look a word up. The result is nil when the dictionary has no entry.
---(查一个词；词典里没有时结果为 nil)
---@param word string
---@param callback fun(result: { word: string, phonetic: string|nil, lines: string[], lemma: string|nil }|nil, err: string|nil)
---@return { kill: fun() } handle stops the query running now(终止正在跑的查询)
function M.lookup(word, callback)
  local current = nil
  local handle = {
    kill = function()
      if current then
        pcall(current.kill, current, 15)
      end
    end,
  }
  if not M.available() then
    vim.schedule(function()
      callback(nil, "ECDICT 未安装（:WeReadDict install）")
    end)
    return handle
  end
  if not safe(word) then
    vim.schedule(function()
      callback(nil, nil)
    end)
    return handle
  end
  local sql = "SELECT word, phonetic, translation, exchange FROM stardict WHERE word = "
    .. literal(word)
    .. " COLLATE NOCASE LIMIT 8;"
  current = query(sql, function(rows, err)
    if not rows then
      callback(nil, err)
      return
    end
    local row = pick(rows, word)
    if not row then
      callback(nil, nil)
      return
    end
    local result = { word = row.word, phonetic = row.phonetic ~= "" and row.phonetic or nil, lines = lines_of(row.translation) }
    local lemma = M.parse_exchange(row.exchange)["0"]
    if not lemma or lemma:lower() == tostring(row.word):lower() or not safe(lemma) then
      callback(#result.lines > 0 and result or nil, nil)
      return
    end
    -- An inflected form. When its own entry only points at the lemma ("run的
    -- 过去式"), the lemma's meanings are what the reader wants; when it has
    -- meanings of its own, the lemma is only named, so the popup holds one
    -- set of meanings, not two.
    -- (屈折形式。它自己的词条只是指向原形（"run的过去式"）时，读者要的是原形的释义；它自己有
    --  释义时只写出原形，弹窗里只有一组释义，而不是两组)
    result.lemma = lemma
    local only_pointers = true
    for _, line in ipairs(result.lines) do
      if not line:lower():find(lemma:lower(), 1, true) or vim.api.nvim_strwidth(line) > 24 then
        only_pointers = false
        break
      end
    end
    if not only_pointers then
      callback(result, nil)
      return
    end
    current = query("SELECT word, phonetic, translation FROM stardict WHERE word = " .. literal(lemma) .. " COLLATE NOCASE LIMIT 4;", function(lemma_rows)
      local base = lemma_rows and pick(lemma_rows, lemma)
      if base then
        result.phonetic = result.phonetic or (base.phonetic ~= "" and base.phonetic or nil)
        for _, line in ipairs(lines_of(base.translation)) do
          if not vim.tbl_contains(result.lines, line) then
            result.lines[#result.lines + 1] = line
          end
        end
      end
      callback(#result.lines > 0 and result or nil, nil)
    end)
  end)
  return handle
end

---Import a downloaded CSV into the SQLite file (to a temporary name first, so a
---failed import never leaves a broken dictionary in place).
---(把下载好的 CSV 导入 SQLite 文件——先写到临时文件名，失败的导入绝不会留下一个坏词典)
---@param csv string
---@param callback fun(ok: boolean, message: string)
function M.build(csv, callback)
  if vim.fn.executable("sqlite3") ~= 1 then
    callback(false, "需要 sqlite3 命令行工具")
    return
  end
  local target = M.path()
  local temporary = target .. ".building"
  os.remove(temporary)
  vim.fn.mkdir(vim.fs.dirname(target), "p")
  local script = table.concat({
    -- double quotes so a data directory with spaces still imports
    -- (加双引号，数据目录带空格时也能导入)
    '.import --csv "' .. csv:gsub('"', '\\"') .. '" stardict',
    "CREATE INDEX IF NOT EXISTS stardict_word ON stardict(word COLLATE NOCASE);",
    "SELECT count(*) FROM stardict;",
  }, "\n")
  local ok, err = pcall(vim.system, { "sqlite3", temporary }, { text = true, stdin = script }, function(done)
    vim.schedule(function()
      if done.code ~= 0 then
        os.remove(temporary)
        callback(false, "导入失败：" .. vim.trim(done.stderr or ""))
        return
      end
      local count = tonumber((done.stdout or ""):match("(%d+)%s*$")) or 0
      if count == 0 then
        os.remove(temporary)
        callback(false, "导入失败：CSV 里没有词条")
        return
      end
      os.remove(target)
      local renamed, rename_err = os.rename(temporary, target)
      if not renamed then
        callback(false, "无法写入 " .. target .. "：" .. tostring(rename_err))
        return
      end
      callback(true, string.format("ECDICT 已就绪：%d 个词条（%s）", count, target))
    end)
  end)
  if not ok then
    callback(false, "could not start sqlite3: " .. tostring(err))
  end
end

---Download the CSV and build the dictionary. Slow links take minutes: the CSV is
---66 MB, so the request is allowed half an hour.
---(下载 CSV 并生成词典。慢的网络要好几分钟：CSV 有 66MB，所以请求允许跑半小时)
---@param url string|nil mirror of the CSV(CSV 的镜像地址)
---@param callback fun(ok: boolean, message: string)
local installing = false

function M.install(url, callback)
  if installing then
    callback(false, "词典正在下载中，请稍候")
    return
  end
  if vim.fn.executable("sqlite3") ~= 1 then
    callback(false, "需要 sqlite3 命令行工具（例如 pacman -S sqlite / apt install sqlite3）")
    return
  end
  local csv = require("weread.config").path("tmp") .. "/ecdict.csv"
  installing = true
  local done = callback
  callback = function(ok, message)
    installing = false
    done(ok, message)
  end
  require("weread.http").download(url or M.CSV_URL, csv, {
    timeout = 1800,
    retries = 1,
    no_cookies = true,
    referer = false,
    origin = false,
    max_filesize = 200 * 1024 * 1024,
  }, function(res)
    if res.code ~= 200 then
      os.remove(csv)
      callback(false, "下载失败：" .. tostring(res.error or res.code))
      return
    end
    M.build(csv, function(ok, message)
      os.remove(csv)
      callback(ok, message)
    end)
  end)
end

return M
