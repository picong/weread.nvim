--[[
Tests for weread.timer.

The regression this guards against: `vim.defer_fn` returns a uv timer handle,
and `vim.fn.timer_stop` cannot accept it. The old code therefore "stopped" a
timer that kept running, which stacked a new repeating timer on every setup.
(本文件守护的回归：vim.defer_fn 返回 uv timer 句柄，vim.fn.timer_stop 收不了它。
 旧代码因此「停止」了一个仍在运行的定时器，每次 setup 都会再叠一个重复定时器)
]]

local timer = require("weread.timer")

describe("timer.defer", function()
  it("runs the callback once", function()
    local calls = 0
    timer.defer(function()
      calls = calls + 1
    end, 10)
    vim.wait(500, function()
      return calls > 0
    end, 10)
    eq(calls, 1)
  end)

  it("can actually be stopped before it fires", function()
    local calls = 0
    local handle = timer.defer(function()
      calls = calls + 1
    end, 60)
    truthy(handle, "a handle came back")

    timer.stop(handle)
    vim.wait(400, function()
      return false
    end, 20)
    eq(calls, 0, "a stopped one-shot must never run")
  end)

  it("tolerates being stopped twice and after firing", function()
    local calls = 0
    local handle = timer.defer(function()
      calls = calls + 1
    end, 10)
    vim.wait(300, function()
      return calls > 0
    end, 10)
    eq(calls, 1)

    -- stopping after the callback closed the handle must be a no-op, not an
    -- error, because callers cannot know the timing
    -- (回调关闭句柄之后再 stop 必须是空操作而不是报错：调用方无法预知时序)
    timer.stop(handle)
    timer.stop(handle)
    timer.stop(nil)
    truthy(true, "no error raised")
  end)
end)

describe("timer.every", function()
  it("fires repeatedly and stops on request", function()
    local ticks = 0
    local handle = timer.every(function()
      ticks = ticks + 1
    end, 20)
    truthy(handle)

    vim.wait(500, function()
      return ticks >= 3
    end, 10)
    truthy(ticks >= 3, "repeats: " .. ticks)

    timer.stop(handle)
    local seen = ticks
    vim.wait(300, function()
      return false
    end, 20)
    eq(ticks, seen, "no ticks after stop")
  end)

  it("does not keep the event loop alive", function()
    -- unref'ed handles must not block `:qa`; this is a smoke assertion that the
    -- handle is at least usable
    -- (unref 过的句柄不应拖住 :qa；这里只是确认句柄可用)
    local handle = timer.every(function() end, 1000)
    truthy(handle)
    timer.stop(handle)
  end)
end)
