--[[
The life of a chapter's annotations: attach them when a chapter buffer opens
(cached ones now, fresh ones when they arrive), refresh them on demand, and
reload them after a write.
(一章划线的生命周期：章节 buffer 打开时接上（有缓存立即画，新数据到了再补画）、按需刷新、
 写入之后重新加载)

Rendering never blocks the chapter: cached annotations draw immediately, missing
ones are fetched in the background and drawn when they arrive.
(渲染从不阻塞正文：有缓存立即绘制，没有则后台拉取，回来后补画)

This is the orchestration layer over fetch, store, render and sync.
(这是 fetch、store、render、sync 之上的编排层)
]]

local fetch = require("weread.annotations_fetch")
local log = require("weread.log")
local render = require("weread.annotations_render")
local store = require("weread.annotations_store")
local sync = require("weread.annotations_sync")

local M = {}

---Attach annotations to a chapter buffer: cached ones now, fresh ones later.
---(把划线接到章节 buffer：有缓存立即画，没有就后台拉)
---@param buf integer
function M.attach(buf)
  local reader = require("weread.reader")
  local info = reader.buffer_info(buf)
  if not info then
    return
  end
  local chapter = ((reader.state.catalog or {}).chapters or {})[info.chapter_index]
  if not chapter then
    return
  end

  local map, annotations = store.cached(info.book_id, info.chapter_key)
  if map and annotations then
    -- the server's list is kept aside: adding or removing a local highlight has
    -- to redraw without another round trip
    -- (把服务端那份另存：增删本地划线时重画不该再跑一趟网络)
    vim.b[buf].weread_server_annotations = annotations
    render.render(buf, map, store.merged(info.book_id, info.chapter_key, annotations))
    sync.sync_local(buf, { quiet = true })
    return
  end

  local started = os.time()
  fetch.load(info.book_id, chapter, info.chapter_key, function(ok, result, meta)
    if not ok then
      log.warn("annotation load failed: %s", tostring(result))
      return
    end
    if meta and meta.mine_ok then
      store.prune_synced(info.book_id, info.chapter_key, result, started)
    end
    local fresh_map = store.chapter_map(info.book_id, info.chapter_key)
    if fresh_map and vim.api.nvim_buf_is_valid(buf) then
      vim.b[buf].weread_server_annotations = result
      render.render(buf, fresh_map, store.merged(info.book_id, info.chapter_key, result))
      -- highlights drawn here before they could be synced go up now
      -- (之前没能同步的本地划线，现在补传)
      sync.sync_local(buf, { quiet = true })
    end
  end)
end

---Refetch and redraw the current chapter.
---(重新拉取并重绘当前章节)
---@param refresh boolean|nil
function M.refresh(refresh)
  local reader = require("weread.reader")
  local buf, info = store.chapter_buffer()
  if not buf or not info then
    vim.notify("weread: 当前不在章节 buffer 中", vim.log.levels.WARN)
    return
  end
  local chapter = ((reader.state.catalog or {}).chapters or {})[info.chapter_index]
  if not chapter then
    return
  end

  if refresh then
    vim.uv.fs_unlink(store.annotations_path(info.book_id, info.chapter_key))
  end

  local started = os.time()
  fetch.load(info.book_id, chapter, info.chapter_key, function(ok, result, meta)
    if not ok then
      vim.notify("weread: 划线拉取失败：" .. tostring(result), vim.log.levels.WARN)
      return
    end
    if meta and meta.mine_ok then
      store.prune_synced(info.book_id, info.chapter_key, result, started)
    end
    local map = store.chapter_map(info.book_id, info.chapter_key)
    if map and vim.api.nvim_buf_is_valid(buf) then
      vim.b[buf].weread_server_annotations = result
      local drawn = render.render(buf, map, store.merged(info.book_id, info.chapter_key, result))
      sync.sync_local(buf, { quiet = true })
      if refresh then
        -- Routine: the marks are on screen, the count adds nothing.
        -- (例行消息：划线已经画在屏幕上了，条数没有额外信息)
        require("weread.ui").notify(
          string.format("weread: 已刷新本章划线（%d 条）", drawn),
          vim.log.levels.INFO,
          { routine = true }
        )
      end
    end
  end)
end

---Reload the chapter's annotations from the service and redraw.
---(从服务端重新拉取本章划线并重画)
---@param buf integer
---@param context table
function M.refresh_after_write(buf, context)
  local chapter = (((require("weread.reader").state.catalog or {}).chapters or {})[context.chapter_index])
  if not chapter then
    return
  end
  fetch.load(context.book_id, chapter, context.chapter_key, function(ok, result)
    if not ok or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local map = store.chapter_map(context.book_id, context.chapter_key)
    if map then
      vim.b[buf].weread_server_annotations = result
      render.render(buf, map, store.merged(context.book_id, context.chapter_key, result))
    end
  end)
end

return M
