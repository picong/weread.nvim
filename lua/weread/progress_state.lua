--[[
Copyright (C) 2026 finlater and contributors (weread.koplugin, AGPL-3.0)
Copyright (C) 2026 weread.nvim contributors

Split out of progress.lua; the payload shapes it serves follow
https://github.com/QiuYukang/weread.koplugin.

weread.nvim is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.
]]

--[[
The session state shared by the progress modules.

`progress.lua` (reporting) and `progress_remote.lua` (pulling the other devices'
position) both read and write the same fields, for instance `synced_at` and
`last_position` decide whether a remote position counts as news. Keeping the
table in a module of its own lets both depend on it without depending on each
other, so loading never forms a cycle.
(进度模块共用的会话状态。progress.lua（上报）与 progress_remote.lua（拉取其它设备的位置）
 读写同一批字段，例如 `synced_at`、`last_position` 决定远端位置算不算新消息。把这张表放进独立
 模块，两边都只依赖它而不互相依赖，加载时就不会出现循环)
]]

---@class WereadProgressState
local state = {
  reported_at = nil,
  pending_seconds = 0,
  timer = nil,
  last_error = nil,
  -- Our own last accepted report, per book: a position this machine uploaded a
  -- minute ago is not news from another device — but only for that book.
  -- (我们自己最近一次被接受的上报，按书记：本机一分钟前上传的位置不是别的设备带来的消息——
  --  但只对那本书成立)
  synced_at = {},
  -- where the last *accepted* report left the reader, and the timer that waits
  -- for the cursor to settle before sending the next one
  -- (上一次被接受的上报停在哪，以及等待光标停稳再发下一次的定时器)
  last_position = nil,
  debounce = nil,
  pulled_at = nil,
  pulled_position = nil,
  pull_error = nil,
  -- Pulls in flight, per book, with every caller waiting on each.
  -- (在路上的拉取，按书记，以及等着每次拉取的所有调用方)
  pulling = {},
  pull_timer = nil,
  -- When the last poll went out, in uv milliseconds: polls are rate limited.
  -- (上一次轮询发出的时间，uv 毫秒：轮询有频率限制)
  last_poll = 0,
  -- A newer remote position that arrived while the reader was busy: until it
  -- is followed, nothing may push this machine's place over it.
  -- (读者正忙时到达的、更新的远端位置：在跟过去之前，任何上报都不能把本机位置盖上去)
  deferred = nil,
  inflight_since = nil,
  -- One report on the wire at a time; a newer one waits in `queued`, replacing
  -- whatever was waiting there. Two reports racing each other used to let the
  -- previous chapter land last.
  -- (同一时刻只有一个上报在路上；更新的那个在 queued 里等，并替换掉原来在等的。
  --  两个上报互相赛跑，曾经让上一章最后落地)
  inflight = false,
  queued = nil,
  -- Books that got their "enter" handshake in this session, and when each
  -- book's reader context was last refreshed here.
  -- (本次会话里已经握过手的书，以及每本书的阅读上下文最近一次在这里刷新的时间)
  entered = {},
  context_at = {},
  renewed_at = nil,
  -- Last key or mouse event, in uv milliseconds: reading time is only counted
  -- while someone is actually at the keyboard.
  -- (最近一次按键或鼠标事件，单位 uv 毫秒：只有真有人在键盘前才计阅读时长)
  last_input = vim.uv.now(),
  last_report_at = nil,
}

return state
