--[[
Tests for weread.timer: the stoppable timers and the trailing-edge debounce.
(timer 单测：可停止的定时器与尾沿防抖)

The callbacks run through `vim.schedule_wrap`, so the tests wait on the main loop
with `vim.wait` instead of sleeping.
(回调经 vim.schedule_wrap 在主循环里执行，因此测试用 vim.wait 等主循环，而不是睡眠)
]]

local timer = require("weread.timer")

---Let the main loop run for `ms`, asserting nothing.
---(让主循环跑 ms 毫秒，不做断言)
---@param ms integer
local function settle(ms)
  vim.wait(ms, function()
    return false
  end, 5)
end

describe("weread.timer.debounce", function()
  it("fires once for a burst of calls", function()
    local runs = 0
    local debounced = timer.debounce(function()
      runs = runs + 1
    end, 40)
    for _ = 1, 5 do
      debounced.call()
    end
    eq(runs, 0, "nothing runs on the leading edge")
    truthy(vim.wait(1000, function()
      return runs > 0
    end, 5), "it runs after the quiet")
    settle(120)
    eq(runs, 1, "and only once")
  end)

  it("runs with the arguments of the last call", function()
    local got
    local debounced = timer.debounce(function(...)
      got = vim.F.pack_len(...)
    end, 40)
    debounced.call("first", 1)
    debounced.call("second", 2)
    debounced.call("third", nil, 3)
    truthy(vim.wait(1000, function()
      return got ~= nil
    end, 5))
    eq(got.n, 3, "trailing nils are kept")
    eq(got[1], "third")
    eq(got[2], nil)
    eq(got[3], 3)
  end)

  it("restarts the wait on every call", function()
    local ran_at
    local debounced = timer.debounce(function()
      ran_at = vim.uv.hrtime()
    end, 80)
    local last_call
    for _ = 1, 3 do
      debounced.call()
      last_call = vim.uv.hrtime()
      settle(40)
    end
    truthy(vim.wait(1000, function()
      return ran_at ~= nil
    end, 5))
    -- 3 x 40 ms of calls, each inside the 80 ms window of the one before: had the
    -- first call's timer survived, the run would have come before the last call
    -- (三次调用每次间隔 40 毫秒、都落在前一次的 80 毫秒窗口内：若第一次的计时没被取消，
    --  执行会早于最后一次调用)
    truthy(ran_at > last_call, "the run came after the last call")
    truthy((ran_at - last_call) / 1e6 >= 60, "and a full wait after it")
  end)

  it("does not fire after cancel", function()
    local runs = 0
    local debounced = timer.debounce(function()
      runs = runs + 1
    end, 30)
    debounced.call()
    debounced.cancel()
    settle(150)
    eq(runs, 0)
  end)

  it("can be cancelled with nothing pending, and twice", function()
    local debounced = timer.debounce(function() end, 30)
    debounced.cancel()
    debounced.call()
    debounced.cancel()
    debounced.cancel()
    settle(80)
  end)

  it("can be called again after it fired", function()
    local seen = {}
    local debounced = timer.debounce(function(value)
      seen[#seen + 1] = value
    end, 30)
    debounced.call("a")
    truthy(vim.wait(1000, function()
      return #seen == 1
    end, 5))
    debounced.call("b")
    truthy(vim.wait(1000, function()
      return #seen == 2
    end, 5))
    eq(seen, { "a", "b" })
  end)

  it("can be called again after a cancel", function()
    local seen = {}
    local debounced = timer.debounce(function(value)
      seen[#seen + 1] = value
    end, 30)
    debounced.call("dropped")
    debounced.cancel()
    debounced.call("kept")
    truthy(vim.wait(1000, function()
      return #seen > 0
    end, 5))
    settle(100)
    eq(seen, { "kept" })
  end)

  it("keeps separate debouncers apart", function()
    local a, b = 0, 0
    local first = timer.debounce(function()
      a = a + 1
    end, 30)
    local second = timer.debounce(function()
      b = b + 1
    end, 30)
    first.call()
    second.call()
    second.cancel()
    truthy(vim.wait(1000, function()
      return a > 0
    end, 5))
    settle(100)
    eq(a, 1)
    eq(b, 0, "cancelling one does not touch the other")
  end)
end)

describe("weread.timer.defer and stop", function()
  it("stop prevents a deferred call, and may be repeated", function()
    local ran = false
    local handle = timer.defer(function()
      ran = true
    end, 30)
    timer.stop(handle)
    timer.stop(handle)
    timer.stop(nil)
    settle(120)
    falsy(ran)
  end)

  it("a stop from inside the callback is a no-op", function()
    local handle
    local ran = false
    handle = timer.defer(function()
      ran = true
      timer.stop(handle)
    end, 10)
    truthy(vim.wait(1000, function()
      return ran
    end, 5))
  end)
end)

describe("weread.timer.defer stopped after it fired", function()
  it("does not run a call stopped between firing and the scheduled callback", function()
    local timer = require("weread.timer")
    local ran = false
    local handle = timer.defer(function()
      ran = true
    end, 0)
    -- let the uv timer fire (queueing the scheduled callback) without letting
    -- the main loop run it, then stop the handle
    -- (让 uv 定时器到期（排上那次 schedule 回调），但不让主循环执行它，然后 stop)
    vim.uv.run("nowait")
    vim.uv.sleep(5)
    vim.uv.run("nowait")
    timer.stop(handle)
    vim.wait(50)
    falsy(ran, "the cancelled call did not happen")
  end)
end)

describe("weread.timer.debounce with a call already on its way", function()
  it("lets cancel stop the newest call even after an older one fired", function()
    local timer = require("weread.timer")
    local ran = {}
    local debounced = timer.debounce(function(name)
      ran[#ran + 1] = name
    end, 0)
    debounced.call("A")
    -- A's timer fires and its scheduled callback is queued (A 的定时器到期，回调已排队)
    vim.uv.run("nowait")
    vim.uv.sleep(5)
    vim.uv.run("nowait")
    debounced.call("B")
    debounced.cancel()
    vim.wait(50)
    eq(ran, {}, "neither ran: A was replaced, B was cancelled")
  end)
end)
