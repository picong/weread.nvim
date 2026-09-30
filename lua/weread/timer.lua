--[[
Timers that can actually be stopped.

`vim.defer_fn` returns a **uv timer handle**, not the numeric id `timer_start`
produces. Handing that handle to `vim.fn.timer_stop` fails with
`E5101: Cannot convert given Lua type` and — worse — leaves the timer running,
so every re-setup would stack another live repeating timer. This module owns the
handles and stops them through the uv API instead.
(vim.defer_fn 返回的是 uv timer 句柄，而不是 timer_start 那种数字 id。把它交给
 vim.fn.timer_stop 会报 E5101 并且**根本没停下来**，于是每次重新 setup 都会再叠一个
 活着的定时器。本模块自己持有句柄，通过 uv API 停止)

`vim.schedule_wrap` matters too: uv callbacks run outside the main loop, where
`vim.fn.*` raises E5560.
(vim.schedule_wrap 同样关键：uv 回调不在主循环里，那里调用 vim.fn.* 会报 E5560)
]]

local M = {}

---One-shot timer.
---(一次性定时器)
---@param fn fun()
---@param ms integer
---@return uv_timer_t|nil
function M.defer(fn, ms)
  local timer = vim.uv.new_timer()
  if not timer then
    return nil
  end
  timer:start(math.max(0, math.floor(ms)), 0, vim.schedule_wrap(function()
    -- Close before running the callback, so a `stop` from inside it is a no-op
    -- rather than a double close.
    -- (先关闭再执行回调，这样回调里再 stop 是空操作而不是重复关闭)
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    fn()
  end))
  return timer
end

---Repeating timer. Unreferenced so it can never keep the event loop alive.
---(重复定时器；unref 过，绝不会拖住事件循环)
---@param fn fun()
---@param ms integer
---@return uv_timer_t|nil
function M.every(fn, ms)
  local timer = vim.uv.new_timer()
  if not timer then
    return nil
  end
  timer:start(math.max(1, math.floor(ms)), math.max(1, math.floor(ms)), vim.schedule_wrap(fn))
  timer:unref()
  return timer
end

---Stop and close a timer created by this module. Safe to call twice.
---(停止并关闭本模块创建的定时器；可重复调用)
---@param timer uv_timer_t|nil
function M.stop(timer)
  if type(timer) ~= "userdata" then
    return
  end
  if timer:is_closing() then
    return
  end
  pcall(function()
    timer:stop()
  end)
  pcall(function()
    timer:close()
  end)
end

return M
