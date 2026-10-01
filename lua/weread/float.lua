--[[
Generic centred floating window. Used by the login dialog, the image viewer
and the thoughts popup, so that all three share one layout/border/keymap
implementation.
(通用居中浮窗：登录对话框、图片查看器、想法弹窗共用同一套布局/边框/快捷键实现)
]]

local M = {}

---@class weread.float
---@field win integer
---@field buf integer
local Float = {}
Float.__index = Float

---Attach a close handler to a window.
---(为窗口挂关闭回调)
---@param win integer
---@param on_close fun()|nil
local function hook_close(win, on_close)
  if not on_close then
    return
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      pcall(on_close)
    end,
  })
end

---Open a floating window.
---(打开浮窗)
---@param opts table
---@return table|nil
function M.open(opts)
  opts = opts or {}
  local width = math.max(10, math.min(opts.width or 60, vim.o.columns - 4))
  local height = math.max(3, math.min(opts.height or #(opts.lines or {}) + 2, vim.o.lines - 4))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = opts.filetype or "weread-float"

  local row = opts.row
  if row == nil then
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  end
  local col = opts.col
  if col == nil then
    col = math.max(0, math.floor((vim.o.columns - width) / 2))
  end

  ---@type vim.api.keyset.win_config
  local win_config = {
    relative = "editor",
    style = "minimal",
    border = opts.border or "rounded",
    width = width,
    height = height,
    row = row,
    col = col,
    zindex = opts.zindex or 60,
    focusable = opts.focusable ~= false,
  }
  -- `title_pos` is only accepted together with a non-empty title, so a popup
  -- without one must not pass it at all.
  -- (`title_pos` 必须与一个非空 title 同时给出，因此没有标题的弹窗不能传它)
  if type(opts.title) == "string" and opts.title ~= "" then
    win_config.title = opts.title
    win_config.title_pos = "center"
  end

  local win = vim.api.nvim_open_win(buf, opts.enter ~= false, win_config)

  vim.wo[win].wrap = opts.wrap ~= false
  vim.wo[win].cursorline = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].spell = false
  vim.wo[win].list = false

  local self = setmetatable({
    win = win,
    buf = buf,
    width = width,
    height = height,
    on_close = opts.on_close,
  }, Float)

  if opts.lines then
    self:set_lines(opts.lines)
  end

  if opts.keymaps ~= false then
    for _, key in ipairs(opts.close_keys or { "q", "<Esc>", "<C-c>" }) do
      vim.keymap.set("n", key, function()
        self:close()
      end, { buffer = buf, nowait = true, silent = true })
    end
  end

  hook_close(win, function()
    if self.on_close then
      self.on_close()
    end
  end)

  return self
end

---@param lines string[]
function Float:set_lines(lines)
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  -- A single entry must be one line: `nvim_buf_set_lines` rejects a string
  -- containing newlines ("'replacement string' item contains newlines").
  -- Callers pass user content — book thoughts, excerpts — so splitting here
  -- keeps every popup safe instead of relying on each caller to remember.
  -- (每个元素必须是单行：nvim_buf_set_lines 会拒绝含换行的字符串。调用方传进来的
  --  是用户内容（书里的想法、摘录），因此在这里拆行，让所有弹窗都安全，而不是指望
  --  每个调用方都记得)
  local flat = {}
  for _, line in ipairs(lines or {}) do
    if type(line) == "string" and line:find("\n", 1, true) then
      for _, part in ipairs(vim.split(line, "\n", { plain = true })) do
        flat[#flat + 1] = part
      end
    else
      flat[#flat + 1] = line == nil and "" or line
    end
  end

  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, flat)
  vim.bo[self.buf].modifiable = false
  vim.bo[self.buf].modified = false
end

---@param title string|nil
function Float:set_title(title)
  if not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  if type(title) ~= "string" or title == "" then
    return
  end
  vim.api.nvim_win_set_config(self.win, { title = title, title_pos = "center" })
end

---@return integer
function Float:get_buf()
  return self.buf
end

---@return integer
function Float:get_win()
  return self.win
end

---@return boolean
function Float:is_open()
  return vim.api.nvim_win_is_valid(self.win)
end

function Float:close()
  if vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
end

return M
