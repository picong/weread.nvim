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
The remote half of progress sync: ask the service where the other devices are,
decide whether that is news, and hold or follow it.

It depends on `progress_state` only (plus config, cache and log); `progress.lua`
depends on both and re-exports everything here, so `require("weread.progress")`
keeps its public surface. Calls into the reader are lazy `require`s inside
functions, never at load time.
(进度同步的远端一半：问服务端其它设备读到哪了，判断算不算新消息，然后扣住或跟过去。
 它只依赖 progress_state（以及 config、cache、log）；progress.lua 同时依赖两者并把这里的
 一切重新导出，所以 `require("weread.progress")` 的公共接口不变。对 reader 的调用都是函数
 内部的惰性 require，绝不在加载期执行)
]]

local config = require("weread.config")
local cache = require("weread.cache")
local log = require("weread.log")
local state = require("weread.progress_state")

local M = {}

---Tolerance when comparing timestamps: clocks are never quite the same.
---(比较时间戳时的容差：两台设备的时钟总不会完全一致)
local TIME_TOLERANCE = 5

---Minimum gap between two polls that are not forced, in uv milliseconds.
---(两次非强制轮询之间的最小间隔，uv 毫秒)
local POLL_GAP_MS = 30 * 1000

---A chapter that failed to download is not retried more often than this.
---(下载失败的章节，重试间隔不短于这个值)
local FOLLOW_RETRY_MS = 60 * 1000

---Identity of a reading position, as the service sees it.
---(阅读位置的标识，以服务端的视角)
---@param payload table { book_id, chapter_uid, chapter_offset }
---@return string
function M.position_key(payload)
  return string.format("%s#%s@%s", payload.book_id, payload.chapter_uid, tostring(payload.chapter_offset))
end

---Can this session ask the service where the other devices are?
---(本次会话能不能问服务端其它设备读到哪了？)
---@return boolean
function M.can_pull()
  if config.get().sync_pull == false then
    return false
  end
  local ok, key = pcall(function()
    return require("weread.auth").api_key()
  end)
  return ok and key ~= nil and key ~= ""
end

---Fetch the service-side reading position for a book.
---(拉取一本书在服务端的阅读位置)
---@param book_id string
---@param callback fun(ok: boolean, remote: table|nil, err: string|nil)
local function fetch_remote(book_id, callback)
  if config.get().sync_pull == false then
    callback(false, nil, "disabled")
    return
  end
  require("weread.api_gateway").progress(book_id, { timeout = 4, retries = 0, silent = true }, function(ok, result)
    if not ok then
      callback(false, nil, tostring(result))
      return
    end
    local book = (result or {}).book
    if type(book) ~= "table" or book.chapterUid == nil or book.updateTime == nil then
      callback(false, nil, "服务端没有可用的进度记录")
      return
    end
    callback(true, {
      book_id = tostring(book_id),
      chapter_uid = tostring(book.chapterUid),
      chapter_offset = tonumber(book.chapterOffset) or 0,
      progress = tonumber(book.progress) or 0,
      summary = book.summary or "",
      update_time = tonumber(book.updateTime) or 0,
      app_id = book.appId,
    })
  end)
end

---Is the remote position a *different* one that was set later than everything
---we know locally?
---(远端是否是一个比本地所知都更新、且位置不同的进度？)
---
---The local `updated_at` is the position file's, and `synced_at` is our own
---last accepted report: a position we uploaded a minute ago must not be treated
---as news from another device.
---(本地的 `updated_at` 来自位置文件，`synced_at` 是我们自己最近一次被接受的上报：一分钟前
--- 刚上传的位置不能当成别的设备带来的新消息)
---@param book_id string
---@param remote table from fetch_remote
---@return boolean
function M.remote_is_newer(book_id, remote)
  local saved = cache.read_position(book_id)
  local local_time = saved and tonumber(saved.updated_at) or 0
  if remote.update_time <= local_time + TIME_TOLERANCE then
    return false
  end
  local synced = state.synced_at[tostring(book_id)]
  if synced and remote.update_time <= synced + TIME_TOLERANCE then
    return false
  end
  if saved then
    local same_chapter = tostring(saved.chapter_uid or "") == remote.chapter_uid
    local local_offset = tonumber(saved.src_from)
    if same_chapter and local_offset and math.abs(local_offset - remote.chapter_offset) <= 20 then
      return false
    end
  end
  if state.last_position == M.position_key({
    book_id = book_id,
    chapter_uid = remote.chapter_uid,
    chapter_offset = remote.chapter_offset,
  }) then
    return false
  end
  return true
end

---Pull the remote position; the callback gets it when it should replace ours.
---(拉取远端进度；只有需要覆盖本地时回调才会拿到它)
---@param book_id string
---@param callback fun(remote: table|nil, err: string|nil)
function M.pull(book_id, callback)
  book_id = tostring(book_id)
  local waiting = state.pulling[book_id]
  if waiting then
    -- the same question is already out: wait for its answer
    -- (同一个问题已经发出去了：等它的回答)
    waiting[#waiting + 1] = callback
    return
  end
  waiting = { callback }
  state.pulling[book_id] = waiting
  local function finish(remote, err)
    state.pulling[book_id] = nil
    for _, waiter in ipairs(waiting) do
      pcall(waiter, remote, err)
    end
  end
  local ok, raised = pcall(fetch_remote, book_id, function(ok, remote, err)
    if not ok then
      state.pull_error = err
      log.info("progress pull skipped: %s", tostring(err))
      finish(nil, err or "pull failed")
      return
    end
    state.pull_error = nil
    state.pulled_at = os.time()
    state.pulled_position = remote
    if M.remote_is_newer(book_id, remote) then
      finish(remote, nil)
    else
      finish(nil, nil)
    end
  end)
  if not ok then
    finish(nil, tostring(raised))
  end
end

---A newer remote position the reader has not followed yet, for this book.
---(这本书还没跟过去的、更新的远端位置)
---@param book_id string
---@return table|nil
function M.deferred(book_id)
  -- Judged once, when it arrived: the reader's own checkpoints after that are
  -- not news that makes the phone's place old.
  -- (只在它到达时判断一次：读者此后自己的存档，并不能让手机上的位置变旧)
  local remote = state.deferred
  if remote and remote.book_id == tostring(book_id) then
    return remote
  end
  return nil
end

---Hold a newer remote position until it is followed: every report for that
---book stays back meanwhile.
---(扣住一个更新的远端位置直到跟过去为止：在此期间这本书的所有上报都按住不发)
---@param remote table
function M.defer(remote)
  state.deferred = remote
end

---Let go of a held remote position that could not be followed.
---(放开一个跟不过去的远端位置)
---@param remote table
function M.undefer(remote)
  if state.deferred == remote then
    state.deferred = nil
  end
end

---Follow a held remote position now, if the reader is in that book.
---(读者正在那本书里的话，现在就跟过去)
---@return boolean
function M.follow_deferred()
  local reader = require("weread.reader")
  local session = reader.current()
  local remote = session and M.deferred(session.book.book_id)
  if not remote then
    return false
  end
  -- a chapter that failed to download is not retried on every settled cursor
  -- (下载失败的章节，不会在每次光标停稳时都重试一遍)
  local now = vim.uv.now()
  if remote.tried_at and now - remote.tried_at < FOLLOW_RETRY_MS then
    return false
  end
  remote.tried_at = now
  return reader.follow_remote(remote)
end

---Record that the reader now sits at the remote position, so our own enter
---report is not mistaken for foreign news later.
---(记下读者现在就在远端位置上，免得之后自己的 enter 上报被误判为外部消息)
---@param remote table
function M.adopted(remote)
  if remote.book_id then
    state.synced_at[tostring(remote.book_id)] = os.time()
  end
  state.last_position = nil
  state.pulled_position = remote
  if state.deferred and state.deferred.book_id == remote.book_id then
    state.deferred = nil
  end
end

---Ask the service whether another device moved on, and follow it. Quiet: a
---poll that finds nothing new says nothing.
---(问服务端有没有别的设备往后读了，有就跟过去。安静进行：没发现新东西就什么都不说)
---
---The reader is never pulled away mid-page: when a key was pressed after the
---question went out, the answer waits for the next poll.
---(读者绝不会在一页读到一半时被拽走：问题发出之后有过按键，这次回答就留给下一次轮询)
---@param opts table|nil { force = boolean }
function M.poll(opts)
  opts = opts or {}
  if config.get().sync_pull == false then
    return
  end
  local reader = require("weread.reader")
  local session = reader.current()
  if not session then
    return
  end
  local now = vim.uv.now()
  if not opts.force and now - state.last_poll < POLL_GAP_MS then
    return
  end
  state.last_poll = now
  local book_id = tostring(session.book.book_id)
  local asked_at = state.last_input
  M.pull(book_id, function(remote)
    if not remote then
      return
    end
    if state.last_input ~= asked_at then
      -- Kept, not dropped: a debounced report must not bury it, and the next
      -- quiet moment follows it.
      -- (留着而不是丢掉：防抖上报不能把它埋掉，下一个安静的时刻就跟过去)
      log.info("remote progress newer, but the reader is busy; deferring")
      M.defer(remote)
      return
    end
    reader.follow_remote(remote)
  end)
end

return M
