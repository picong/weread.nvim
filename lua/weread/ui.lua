--[[
Picker helpers. Uses snacks.picker when it is installed (it is what the rest
of a LazyVim setup uses) and falls back to `vim.ui.select`.
(选择器：装了 snacks.picker 就用它，否则退回 vim.ui.select)
]]

local M = {}

---@return table|nil snacks
function M.snacks()
  local ok, snacks = pcall(require, "snacks")
  if ok and type(snacks) == "table" and snacks.picker then
    return snacks
  end
  return nil
end

---@class weread.ui.Item
---@field text string required by snacks for filtering
---@field [string] any

---Pick one item.
---(选择一项)
---
---`on_change(item)` follows the cursor through the list and `on_close(chosen)`
---runs once the picker is gone, told whether an item was confirmed; both are
---snacks only, `vim.ui.select` has no such hooks.
---(`on_change(item)` 跟随光标在列表里移动，`on_close(chosen)` 在选择器关闭后执行一次，并告知是否
--- 选定了某项；两者只在 snacks 下有效，`vim.ui.select` 没有这类钩子)
---@param opts table { title, items, format?, preview?, snacks?, on_change?, on_close?, on_choice } snacks: extra snacks.picker options(额外的 snacks.picker 选项)
function M.select(opts)
  local snacks = M.snacks()
  if snacks then
    -- set before the picker closes, so `on_close` already knows the outcome
    -- (在选择器关闭之前设置，让 `on_close` 已经知道结果)
    local chosen = false
    local extra = opts.snacks or {}
    snacks.picker.pick(vim.tbl_extend("force", extra, {
      -- `Snacks.picker.resume()` reopens with these very closures, so the
      -- outcome of the last run is forgotten every time the picker shows
      -- (`Snacks.picker.resume()` 会用同一批闭包重新打开，所以每次显示时都忘掉上一次的结果)
      on_show = function(picker)
        chosen = false
        if extra.on_show then
          extra.on_show(picker)
        end
      end,
      on_change = opts.on_change and function(_, item)
        opts.on_change(item)
      end or nil,
      on_close = opts.on_close and function()
        opts.on_close(chosen)
      end or nil,
      title = opts.title,
      items = opts.items,
      format = opts.format or "text",
      -- Items here are books and chapters, not files: snacks' default preview is
      -- the file preview, which paints `Item has no \`file\`` over the picker for
      -- every entry. Callers that do want one (a chapter's text, say) pass it in.
      -- (这里的条目是书与章节，不是文件：snacks 默认的预览是文件预览，会对每个条目在
      --  选择器上刷一行 `Item has no \`file\``。确实需要预览的调用方（比如章节正文）自己传)
      preview = opts.preview or "none",
      confirm = function(picker, item)
        chosen = item ~= nil
        picker:close()
        if item then
          opts.on_choice(item)
        end
      end,
    }))
    return
  end

  vim.ui.select(opts.items, {
    prompt = opts.title,
    format_item = function(item)
      return item.label or item.text
    end,
  }, function(item)
    if item then
      opts.on_choice(item)
    end
  end)
end

---Show a message to the reader — if it is worth reading.
---(把消息给读者看——前提是值得一看)
---
---Routine messages (a chapter resumed, progress uploaded, highlights refreshed)
---are dropped unless `notify = "all"`: they are about the plugin doing its job,
---not about anything the reader has to do, and they arrive in the middle of the
---page. Warnings and errors always go through.
---(例行消息（续读某章、进度已回传、划线已刷新）在 `notify ~= "all"` 时丢弃：它们说的是插件
--- 在正常工作，而不是读者需要做什么，而且会出现在页面正中。警告与错误一律照常显示)
---@param message string
---@param level integer|nil vim.log.levels
---@param opts table|nil { routine = boolean } routine traffic(例行流量)
function M.notify(message, level, opts)
  level = level or vim.log.levels.INFO
  local routine = type(opts) == "table" and opts.routine == true
  local mode = (require("weread.config").get().notify or "quiet"):lower()
  if routine and mode ~= "all" then
    local ok, log = pcall(require, "weread.log")
    if ok and log and log.info then
      pcall(log.info, "%s", tostring(message))
    end
    return false
  end
  vim.notify(message, level)
  return true
end

---@param bytes integer
---@return string
function M.bytes(bytes)
  local units = { "B", "K", "M", "G" }
  local value = tonumber(bytes) or 0
  local index = 1
  while value >= 1024 and index < #units do
    value = value / 1024
    index = index + 1
  end
  if index == 1 then
    return string.format("%d%s", value, units[index])
  end
  return string.format("%.1f%s", value, units[index])
end

---@param timestamp integer|nil unix seconds
---@return string
function M.relative_time(timestamp)
  if not timestamp or timestamp <= 0 then
    return "从未"
  end
  local delta = os.time() - timestamp
  if delta < 3600 then
    return "刚刚"
  end
  if delta < 86400 then
    return string.format("%d 小时前", math.floor(delta / 3600))
  end
  if delta < 86400 * 30 then
    return string.format("%d 天前", math.floor(delta / 86400))
  end
  return os.date("%Y-%m-%d", timestamp)
end

return M
