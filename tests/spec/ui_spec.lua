--[[
Tests for weread.ui's notification policy.

Reading should not be interrupted by the plugin reporting that it is working:
"resumed book X", "progress uploaded", "annotations refreshed" all arrive in the
middle of a page. `notify = "quiet"` (the default) keeps them out, warnings and
errors always get through, and `notify = "all"` restores everything.
(ui 单测：通知策略。阅读不该被插件「我在正常工作」的报告打断：「续读《X》」「进度已回传」
 「划线已刷新」都会出现在页面正中。`notify = "quiet"`（默认）把它们挡在外面，警告与错误一律
 照常到达，`notify = "all"` 则全部恢复)
]]

local config = require("weread.config")
config.setup({ data_dir = vim.fn.tempname() })

local ui = require("weread.ui")

---Collect what would reach the reader.
---(收集真正会到达读者的消息)
---@return table[] seen
---@return fun() restore
local function capture()
  local seen = {}
  local real = vim.notify
  vim.notify = function(message, level)
    seen[#seen + 1] = { message = message, level = level }
  end
  return seen, function()
    vim.notify = real
  end
end

describe("ui.notify", function()
  it("drops routine traffic while keeping warnings and errors", function()
    local seen, restore = capture()
    local opts = config.get()
    opts.notify = "quiet"

    eq(ui.notify("weread: 续读《三体》", vim.log.levels.INFO, { routine = true }), false, "routine is dropped")
    eq(#seen, 0, "nothing reached the reader")
    eq(ui.notify("weread: 出了点问题", vim.log.levels.WARN), true, "warnings get through")
    eq(ui.notify("weread: 坏了", vim.log.levels.ERROR), true, "and errors")
    eq(#seen, 2)
    restore()
  end)

  it("shows everything when asked", function()
    local seen, restore = capture()
    config.get().notify = "all"
    eq(ui.notify("weread: 续读《三体》", vim.log.levels.INFO, { routine = true }), true, "routine is shown")
    eq(#seen, 1)
    restore()
    config.get().notify = "quiet"
  end)

  it("keeps a manual action's answer", function()
    -- Pressing a key is not routine: the answer is the whole point.
    -- (按键不是例行流量：回应正是重点)
    local seen, restore = capture()
    eq(ui.notify("weread: 已回传进度（第 62 章，85%）", vim.log.levels.INFO), true)
    eq(#seen, 1)
    restore()
  end)
end)
