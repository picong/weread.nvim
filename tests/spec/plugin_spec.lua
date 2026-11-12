--[[
Tests for plugin/weread.lua: the commands that parse ranges and the ones that
must work before the user ever called setup().
(plugin/weread.lua 单测：解析行范围的命令，以及用户从没调过 setup() 时也必须能用的命令)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

local tmpdir = "/tmp/weread-test-plugin"
vim.fn.delete(tmpdir, "rf")
vim.fn.mkdir(tmpdir, "p")

-- Start from modules nobody has configured, so the first describe sees what a
-- user who never called setup() sees. The runner puts package.loaded back
-- after this file.
-- (从没人配置过的模块开始，让第一个 describe 看到的就是从没调过 setup() 的用户所见；
--  runner 会在本文件结束后还原 package.loaded)
for name in pairs(package.loaded) do
  if name == "weread" or name:match("^weread%.") then
    package.loaded[name] = nil
  end
end

-- the commands live in the plugin file, which `--clean -l` does not source
-- (命令定义在 plugin 文件里，而 `--clean -l` 不会自动加载它)
if vim.fn.exists(":WeReadLogin") ~= 2 then
  vim.g.loaded_weread_nvim = nil
  vim.cmd("runtime plugin/weread.lua")
end

---Collect what vim.notify was told while fn ran.
---(收集 fn 运行期间 vim.notify 收到的内容)
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

describe(":WeReadLogin!", function()
  it("sets the plugin up before it logs out", function()
    -- A user who never called setup() has no cookie jar yet: logging out first
    -- used to die with "weread.http.setup() must be called".
    -- (从没调过 setup() 的用户还没有 cookie jar：先 logout 会报
    --  "weread.http.setup() must be called")
    local data_home = tmpdir .. "/xdg-data"
    local original_home = vim.env.XDG_DATA_HOME
    vim.env.XDG_DATA_HOME = data_home

    local auth = require("weread.auth")
    local order = {}
    local real_logout = auth.logout
    auth.logout = function(...)
      order[#order + 1] = "logout"
      return real_logout(...)
    end
    local forced
    auth.login = function(opts)
      order[#order + 1] = "login"
      forced = opts and opts.force
    end

    local ok, err = pcall(function()
      notices(function()
        vim.cmd("WeReadLogin!")
      end)
    end)
    -- data_dir() resolves stdpath() when called, so read it before the sandbox goes
    -- (data_dir() 在调用时才解析 stdpath()，因此要在沙箱撤掉之前读)
    local used_dir = require("weread.config").data_dir()
    -- the default setup() starts a progress timer; this file must not leak it
    -- (默认 setup() 会起一个进度定时器；本文件不能把它漏出去)
    require("weread.progress").stop()
    vim.env.XDG_DATA_HOME = original_home

    truthy(vim.startswith(used_dir, data_home), "the sandboxed data dir was used: " .. used_dir)
    truthy(ok, tostring(err))
    eq(order, { "logout", "login" })
    eq(forced, true, "login is forced after a ! logout")
  end)
end)

-- ------------------------------------------------------------ range commands

local BOOK_ID = "43208843"

local ref = {}
local routes = mock_lib.weread_routes(ref)
local bookmark_calls = {}
routes[#routes + 1] = {
  path = "/web/book/addBookmark",
  handler = function(_, _, body)
    local payload = vim.json.decode(body or "{}")
    bookmark_calls[#bookmark_calls + 1] = { api_name = "add", body = payload }
    return {
      status = 200,
      ctype = "application/json",
      body = vim.json.encode({ bookmarkId = string.format("%s_%s_%s", payload.bookId, payload.chapterUid, payload.range) }),
    }
  end,
}
routes[#routes + 1] = {
  path = "/web/book/removeBookmark",
  handler = function(_, _, body)
    bookmark_calls[#bookmark_calls + 1] = { api_name = "remove", body = vim.json.decode(body or "{}") }
    return { status = 200, ctype = "application/json", body = '{"succ":1}' }
  end,
}
local server = mock_lib.start(routes)
ref.url = server.url

local config = require("weread.config")
local http = require("weread.http")
local auth = require("weread.auth")
local cache = require("weread.cache")
local reader = require("weread.reader")
local annotations = require("weread.annotations")

config.setup({
  data_dir = tmpdir .. "/data",
  base_url = server.url,
  gateway_url = server.url,
  proxy = "direct",
  keymaps = false,
  sync_interval = 0,
})
config.ensure_dirs()
http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 8, retries = 0, proxy = "direct" })
require("weread.log").setup({ debug = true, path = config.path("weread.log") })
auth.save_credentials({
  version = 1,
  account = { name = "测试账号", user_vid = "vid" },
  api_key = "wrk-test-key",
  cookies = { wr_vid = "vid", wr_skey = "skey", wr_ql = "0", wr_rt = "rt" },
})

local unpack_values = table.unpack or unpack

local function await_async(runner)
  local captured
  runner(function(...)
    captured = { n = select("#", ...), ... }
  end)
  vim.wait(20000, function()
    return captured ~= nil
  end, 20)
  if not captured then
    error("timed out waiting for the callback")
  end
  return unpack_values(captured, 1, captured.n)
end

---@return integer buf
local function open_chapter()
  await_async(function(cb)
    reader.load_book(BOOK_ID, cb)
  end)
  reader.open_index(2, {})
  vim.wait(20000, function()
    return reader.buffer_info() ~= nil
  end, 50)
  return vim.api.nvim_get_current_buf()
end

---@param buf integer
---@return table[]
local function stored(buf)
  local info = reader.buffer_info(buf)
  return annotations.local_for(info.book_id, info.chapter_key)
end

---Wait until every stored highlight has reached the account (carries its id): the
---upload is asynchronous, and a removal takes a different path before it.
---(等所有本地划线都进了账号（带上了 id）：上传是异步的，而取消在那之前走的是另一条路)
---@param buf integer
local function settle_uploads(buf)
  notices(function()
    vim.wait(10000, function()
      for _, entry in ipairs(stored(buf)) do
        if not entry.bookmark_id then
          return false
        end
      end
      return true
    end, 20)
  end)
end

---Wait for the number of stored highlights to reach a value: removing a synced
---one waits for the account's answer.
---(等本地划线条数变成某个值：取消已同步的划线要等账号的回应)
---@param buf integer
---@param count integer
local function wait_for_count(buf, count)
  notices(function()
    vim.wait(10000, function()
      return #stored(buf) == count
    end, 20)
  end)
end

-- The fixture's prose lines (1-based): the lines before are blank or headings
-- (第 5、6 行与第 18 行是正文；之前的行是空行或标题)
local FIRST_PROSE, SECOND_PROSE, LAST_PROSE = 5, 6, 18

describe("range arguments of :WeReadHighlight / :WeReadUnhighlight", function()
  local buf = open_chapter()

  it("is looking at the chapter it expects", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    truthy(lines[FIRST_PROSE]:find("汪淼把车停在楼下", 1, true))
    truthy(lines[SECOND_PROSE]:find("叶文洁", 1, true))
    truthy(lines[LAST_PROSE]:find("小标题后的正文", 1, true))
  end)

  it("highlights a single numbered line, not the cursor line", function()
    vim.api.nvim_win_set_cursor(0, { SECOND_PROSE, 0 })
    notices(function()
      vim.cmd(LAST_PROSE .. "WeReadHighlight")
    end)
    local list = stored(buf)
    eq(#list, 1, "exactly one highlight")
    eq(list[1].text, "小标题后的正文。", "and it is the numbered line's, not the cursor's")
    settle_uploads(buf)
  end)

  it("highlights a line range as one highlight", function()
    notices(function()
      vim.cmd(string.format("%d,%dWeReadHighlight", FIRST_PROSE, SECOND_PROSE))
    end)
    settle_uploads(buf)
    local list = stored(buf)
    eq(#list, 2, "one more")
    local joined
    for _, entry in ipairs(list) do
      if entry.text:find("汪淼把车停在楼下", 1, true) then
        joined = entry
      end
    end
    truthy(joined, "the range's highlight is there")
    truthy(joined.text:find("叶文洁", 1, true), "and it runs through the second line")
    falsy(joined.text:find("^　"), "without the paragraph indent")
  end)

  it("reports an unusable line instead of raising", function()
    -- line 1 is blank: there is nothing to highlight, which is a warning
    -- (第 1 行是空行：没有可划的东西，应当是警告而不是报错)
    local seen = notices(function()
      vim.cmd("1WeReadHighlight")
    end)
    eq(#seen, 1)
    eq(seen[1].level, vim.log.levels.WARN)
    eq(#stored(buf), 2, "nothing was added")
  end)

  it("takes a visual-style range too", function()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    -- the lines are already highlighted: this is the refusal, not an error
    -- (这些行已经划过了：应得到拒绝提示，而不是报错)
    local seen = notices(function()
      vim.cmd(string.format("%d,%dWeReadHighlight", FIRST_PROSE, SECOND_PROSE))
    end)
    eq(#seen, 1)
    eq(#stored(buf), 2, "and no duplicate")
  end)

  it("unhighlights a line range", function()
    notices(function()
      vim.cmd(string.format("%d,%dWeReadUnhighlight", FIRST_PROSE, SECOND_PROSE))
    end)
    wait_for_count(buf, 1)
    local list = stored(buf)
    eq(#list, 1, "the range's highlight is gone")
    eq(list[1].text, "小标题后的正文。", "the other one stays")
  end)

  it("unhighlights a single numbered line, not the cursor line", function()
    vim.api.nvim_win_set_cursor(0, { SECOND_PROSE, 0 })
    notices(function()
      vim.cmd(LAST_PROSE .. "WeReadUnhighlight")
    end)
    wait_for_count(buf, 0)
    eq(#stored(buf), 0, "the numbered line's highlight is gone")
  end)

  it("still works without a range, on the cursor line", function()
    vim.api.nvim_win_set_cursor(0, { LAST_PROSE, 0 })
    notices(function()
      vim.cmd("WeReadHighlight")
    end)
    eq(#stored(buf), 1)
    settle_uploads(buf)
    vim.api.nvim_win_set_cursor(0, { LAST_PROSE, 0 })
    notices(function()
      vim.cmd("WeReadUnhighlight")
    end)
    wait_for_count(buf, 0)
    eq(#stored(buf), 0)
  end)
end)

describe(":WeReadFont command", function()
  it("opens the font picker without accepting arguments", function()
    local font = require("weread.font")
    local real_picker = font.picker
    local opened = 0
    font.picker = function()
      opened = opened + 1
    end

    local ok, err = pcall(vim.cmd, "WeReadFont")
    font.picker = real_picker

    truthy(ok, tostring(err))
    eq(opened, 1)
    local command = vim.api.nvim_get_commands({ builtin = false }).WeReadFont
    eq(command.nargs, "*")
  end)
end)

describe(":WeReadLog float", function()
  ---Floats that are open now and were not in `before`: the chapter window may carry
  ---floats of its own (the page footer), which are not what is under test.
  ---(现在开着、而 `before` 里没有的浮窗：章节窗口自己可能带着浮窗（页脚），那不是被测对象)
  ---@param before table<integer, boolean>
  ---@return integer[]
  local function new_floats(before)
    local found = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" and not before[win] then
        found[#found + 1] = win
      end
    end
    return found
  end

  ---@return table<integer, boolean>
  local function snapshot_floats()
    local before = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        before[win] = true
      end
    end
    return before
  end

  ---@param win integer
  ---@return integer
  local function q_mapping_count(win)
    local buf = vim.api.nvim_win_get_buf(win)
    return #vim.tbl_filter(function(map)
      return map.lhs == "q"
    end, vim.api.nvim_buf_get_keymap(buf, "n"))
  end

  it(":WeReadLog opens a float that q closes, bound once by the float itself", function()
    -- a file-less log falls back to the in-memory tail in a float
    -- (没有日志文件时退回到浮窗里的内存日志)
    local log = require("weread.log")
    local original_path = log.path
    log.path = function()
      return ""
    end
    local before = snapshot_floats()
    local ok, err = pcall(vim.cmd, "WeReadLog")
    log.path = original_path
    truthy(ok, tostring(err))

    local opened = new_floats(before)
    eq(#opened, 1, "a float is open")
    eq(q_mapping_count(opened[1]), 1, "one q mapping, not two")
    eq(vim.bo[vim.api.nvim_win_get_buf(opened[1])].filetype, "log")
    vim.api.nvim_feedkeys("q", "x", false)
    eq(#new_floats(before), 0, "q closes it")
  end)
end)

describe(":WeReadTheme, :WeReadZone and :WeReadTrophy", function()
  it("completes theme names and command words", function()
    local items = vim.fn.getcompletion("WeReadTheme ", "cmdline")
    truthy(vim.tbl_contains(items, "paper"), "palettes")
    truthy(vim.tbl_contains(items, "auto"))
    truthy(vim.tbl_contains(items, "next"))
    truthy(vim.tbl_contains(items, "global"))
    local filtered = vim.fn.getcompletion("WeReadTheme da", "cmdline")
    eq(filtered, { "dawn" })
    eq(vim.fn.getcompletion("WeReadZone ", "cmdline"), { "rain", "life", "fire" })
  end)

  it("refuses an unknown theme name with the list of choices", function()
    local seen = notices(function()
      vim.cmd("WeReadTheme sepai")
    end)
    local warned = false
    for _, notice in ipairs(seen) do
      if notice.level == vim.log.levels.WARN and notice.message:find("sepia", 1, true) then
        warned = true
      end
    end
    truthy(warned, "a warning that lists the themes")
  end)

  it("asks for a chapter before playing a zone or showing a card", function()
    local reader = require("weread.reader")
    local saved = reader.state.book
    reader.state.book = nil
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, plain)
    local seen = notices(function()
      vim.cmd("WeReadZone rain")
      vim.cmd("WeReadTrophy")
    end)
    reader.state.book = saved
    eq(#seen, 2)
    vim.api.nvim_buf_delete(plain, { force = true })
  end)
end)
