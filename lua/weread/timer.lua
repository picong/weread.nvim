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
    -- Stopped after it fired but before this scheduled call ran: the timer is
    -- already closing, and a cancelled call must not happen.
    -- (到期之后、这次排队的调用执行之前被 stop 了：定时器已经在关闭，被取消的调用不能发生)
    if timer:is_closing() then
      return
    end
    -- Close before running the callback, so a `stop` from inside it is a no-op
    -- rather than a double close.
    -- (先关闭再执行回调，这样回调里再 stop 是空操作而不是重复关闭)
    timer:stop()
    timer:close()
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

---Trailing-edge debounce: every `call` restarts the wait, `fn` runs once after
---`ms` of quiet with the arguments of the last call. `cancel` drops a pending run.
---(尾沿防抖：每次 call 重新计时，安静 ms 毫秒后用最后一次的参数执行一次 fn；
--- cancel 丢弃尚未执行的那一次)
---@param fn fun(...)
---@param ms integer
---@return { call: fun(...), cancel: fun() }
function M.debounce(fn, ms)
  local pending
  local debounced = {}

  function debounced.cancel()
    M.stop(pending)
    pending = nil
  end

  function debounced.call(...)
    -- LuaJIT has no `table.pack`; `vim.F.pack_len` keeps trailing nils too
    -- (LuaJIT 没有 `table.pack`；`vim.F.pack_len` 同样保留末尾的 nil)
    local args = vim.F.pack_len(...)
    M.stop(pending)
    local handle
    handle = M.defer(function()
      -- only the newest call clears the slot: an older one that was already on
      -- its way must not wipe a newer handle, or `cancel` would stop nothing
      -- (只有最新一次调用才清空槽位：已经在路上的旧回调不能抹掉新的句柄，否则 cancel 什么也停不了)
      if pending == handle then
        pending = nil
      end
      fn(vim.F.unpack_len(args))
    end, ms)
    pending = handle
  end

  return debounced
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
