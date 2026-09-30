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
---@param opts table { title, items, format?, on_choice }
function M.select(opts)
  local snacks = M.snacks()
  if snacks then
    snacks.picker.pick({
      title = opts.title,
      items = opts.items,
      format = opts.format or "text",
      preview = opts.preview,
      confirm = function(picker, item)
        picker:close()
        if item then
          opts.on_choice(item)
        end
      end,
    })
    return
  end

  vim.ui.select(opts.items, {
    prompt = opts.title,
    format_item = function(item)
      return item.text
    end,
  }, function(item)
    if item then
      opts.on_choice(item)
    end
  end)
end

---Format a reading-progress percentage.
---(格式化阅读进度)
---@param value number|nil
---@return string
function M.progress_badge(value)
  local percent = tonumber(value) or 0
  if percent <= 0 then
    return "未读"
  end
  if percent >= 100 then
    return "已读完"
  end
  return string.format("%d%%", percent)
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
