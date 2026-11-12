--[[
Tests for weread.float.

The regression this guards: a single entry containing newlines made
`nvim_buf_set_lines` fail with "'replacement string' item contains newlines",
which is exactly what happened when a book thought spanned several paragraphs.
(本文件守护的回归：单个元素里带换行会让 nvim_buf_set_lines 报
 "'replacement string' item contains newlines"——书里的想法跨多段时正是如此)
]]

local float = require("weread.float")

---@param lines string[]
---@return table|nil win
local function open(lines, opts)
  opts = opts or {}
  opts.lines = lines
  opts.enter = false
  return float.open(opts)
end

---@param win table
---@return string[]
local function lines_of(win)
  return vim.api.nvim_buf_get_lines(win:get_buf(), 0, -1, false)
end

describe("float.set_lines", function()
  it("splits entries that contain newlines", function()
    -- A real thought from a book: several paragraphs in one field.
    -- (来自真实书籍的想法：一个字段里有好几个自然段)
    local thought = "上次研究这个，还是2006年了。\n\nGNU=GNU's Not Unix，强调免费使用\n\nGNU工具链包括多个关键组件。"
    local win = open({ "第一条", thought, "最后一条" })
    truthy(win, "the float opened")

    local lines = lines_of(win)
    eq(lines[1], "第一条")
    eq(lines[2], "上次研究这个，还是2006年了。")
    eq(lines[3], "")
    eq(lines[4], "GNU=GNU's Not Unix，强调免费使用")
    eq(lines[5], "")
    eq(lines[6], "GNU工具链包括多个关键组件。")
    eq(lines[7], "最后一条")
    eq(#lines, 7, "every embedded newline became a real line")

    win:close()
  end)

  it("keeps empty entries as blank lines", function()
    local win = open({ "甲", "", "乙" })
    eq(lines_of(win), { "甲", "", "乙" })
    win:close()
  end)

  it("tolerates nil input", function()
    -- A Lua list cannot carry a nil hole, so the only nil case worth covering
    -- is the whole argument being nil.
    -- (Lua 的列表无法带 nil 空洞，因此值得覆盖的 nil 情况只有整个参数为 nil)
    local win = open({ "甲", "" })
    win:set_lines(nil)
    eq(lines_of(win), { "" })
    win:close()
  end)

  it("handles carriage returns from recorded data", function()
    local win = open({ "第一行\r\n第二行" })
    eq(lines_of(win), { "第一行\r", "第二行" }, "the split is on \\n only")
    win:close()
  end)
end)

describe("float lifecycle", function()
  it("closes on request and reports its state", function()
    local win = open({ "内容" })
    truthy(win:is_open())
    win:close()
    falsy(win:is_open())
    -- closing twice must not raise
    -- (重复关闭不应报错)
    win:close()
  end)

  it("should not touch a buffer that was wiped behind its back", function()
    local win = open({ "内容" })
    local buf = win:get_buf()
    vim.api.nvim_buf_delete(buf, { force = true })
    local ok = pcall(function()
      win:set_lines({ "新内容" })
    end)
    truthy(ok, "set_lines survives an invalid buffer")
  end)
end)

describe("float keys and decorations", function()
  it("closes with q", function()
    local win = open({ "x" })
    vim.api.nvim_buf_call(win:get_buf(), function()
      vim.fn.maparg("q", "n", false, true).callback()
    end)
    falsy(win:is_open())
  end)

  it("ignores title, footer and lines changes after it was closed", function()
    local win = open({ "x" })
    win:close()
    win:set_title("晚了")
    win:set_footer("晚了")
    win:set_lines({ "晚了" })
    falsy(win:is_open())
  end)
end)

---Replace `log.warn` with a recorder for the duration of `body`.
---(在 `body` 期间把 `log.warn` 换成记录器)
---@param body fun(warnings: string[])
local function with_warnings(body)
  local log = require("weread.log")
  local warnings = {}
  local original = log.warn
  log.warn = function(format, ...)
    warnings[#warnings + 1] = string.format(format, ...)
  end
  local ok, err = pcall(body, warnings)
  log.warn = original
  if not ok then
    error(err, 0)
  end
end

describe("float on_close", function()
  it("runs when the window closes", function()
    local ran = 0
    local win = open({ "x" }, {
      on_close = function()
        ran = ran + 1
      end,
    })
    win:close()
    eq(ran, 1)
  end)

  it("logs a handler that throws, and the window still closes", function()
    with_warnings(function(warnings)
      local win = open({ "x" }, {
        on_close = function()
          error("handler broke")
        end,
      })
      win:close()
      falsy(win:is_open())
      eq(#warnings, 1)
      matches(warnings[1], "float on_close failed")
      matches(warnings[1], "handler broke")
    end)
  end)

  it("logs nothing for a handler that behaves", function()
    with_warnings(function(warnings)
      open({ "x" }, { on_close = function() end }):close()
      eq(#warnings, 0)
    end)
  end)
end)
