--[[
QR code generation and display.
(二维码生成与显示)

Two rendering paths:
(两条渲染路径)

* Preferred: `qrencode` writes a PNG and `snacks.image` draws it in a floating
  window through the kitty graphics protocol.
  (首选：qrencode 生成 PNG，由 snacks.image 经 kitty 图形协议在浮窗里绘制)
* Fallback: `qrencode -t ASCII` renders the code with `##` blocks, which works
  in any terminal and needs no image support at all.
  (兜底：qrencode -t ASCII 用 ## 方块输出，任何终端都能显示，完全不依赖图片能力)
]]

local float = require("weread.float")
local log = require("weread.log")

local M = {}

---@return string
local function png_path()
  local config = require("weread.config")
  config.ensure_dirs()
  return config.path("tmp", "login-qr.png")
end

---@param name string
---@return boolean
local function executable(name)
  return vim.fn.executable(name) == 1
end

---Width/height of a PNG file, read straight from the IHDR chunk.
---(直接读 IHDR 块拿到 PNG 宽高，避免依赖图片库)
---@param path string
---@return integer|nil width
---@return integer|nil height
local function png_size(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local header = file:read(24)
  file:close()
  if not header or #header < 24 or header:sub(2, 4) ~= "PNG" then
    return nil
  end
  local function be32(offset)
    local a, b, c, d = header:byte(offset, offset + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return be32(17), be32(21)
end

---Render `text` as a PNG with qrencode.
---(用 qrencode 生成 PNG)
---@param text string
---@param path string
---@param opts table|nil scale/margin in modules
---@return boolean ok
---@return string|nil err
function M.encode(text, path, opts)
  if not executable("qrencode") then
    return false, "qrencode not found"
  end
  opts = opts or {}
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local result = vim.system({
    "qrencode",
    "--output",
    path,
    "--type",
    "PNG",
    "--size",
    tostring(opts.scale or 6),
    "--margin",
    tostring(opts.margin or 2),
    "--level",
    opts.level or "M",
    text,
  }, { text = true }):wait()
  if result.code ~= 0 then
    return false, vim.trim(result.stderr or "qrencode failed")
  end
  return true
end

---Render `text` as ASCII art lines with qrencode.
---(用 qrencode 生成 ASCII 文本二维码)
---@param text string
---@param opts table|nil
---@return string[]|nil lines
---@return string|nil err
function M.encode_ascii(text, opts)
  if not executable("qrencode") then
    return nil, "qrencode not found"
  end
  opts = opts or {}
  local result = vim.system({
    "qrencode",
    "--output",
    "-",
    "--type",
    "ASCII",
    "--margin",
    tostring(opts.margin or 1),
    "--level",
    opts.level or "M",
    text,
  }, { text = true }):wait()
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or "qrencode failed")
  end
  local lines = vim.split(result.stdout or "", "\n", { plain = true })
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  if #lines == 0 then
    return nil, "qrencode produced no output"
  end
  return lines, nil
end

---Is inline image rendering usable right now?
---(当前能否用图片渲染)
---@return boolean
function M.image_supported()
  local ok, image = pcall(require, "weread.image")
  return ok and image.supports_inline()
end

---@class weread.qr.Dialog
---@field float table
---@field png string|nil
---@field mode string

---Show a QR code for `text` in a floating window.
---(在浮窗中显示 text 对应的二维码)
---@param text string
---@param opts table|nil
---@return weread.qr.Dialog|nil
---@return string|nil err
function M.show(text, opts)
  opts = opts or {}
  local title = opts.title or "微信读书 · 扫码登录"
  local png = opts.png or png_path()

  if M.image_supported() and M.encode(text, png, { scale = opts.scale or 6 }) then
    local size = png_size(png)
    local width = opts.width or 44
    local height = opts.height or width
    if size and size.width > 0 and size.height > 0 then
      -- Terminal cells are roughly twice as tall as wide, so keep the float
      -- square by halving the aspect ratio.
      -- (终端单元格大致高宽比为 2:1，因此把宽高比折半以保持浮窗接近正方形)
      local ratio = size.height / size.width
      height = math.max(6, math.floor(width * ratio * 0.5))
    end

    local win = float.open({
      title = title,
      width = width,
      height = height,
      filetype = "image",
      on_close = opts.on_close,
      close_keys = opts.close_keys or { "q", "<Esc>", "<C-c>" },
    })
    if win then
      vim.api.nvim_buf_set_name(win:get_buf(), png)
      local ok, err = pcall(function()
        require("snacks.image.buf").attach(win:get_buf(), {
          src = png,
          max_width = width,
          max_height = height,
        })
      end)
      if ok then
        return { float = win, png = png, mode = "image" }, nil
      end
      log.warn("snacks.image attach failed: %s", tostring(err))
      win:close()
    end
  end

  local lines, err = M.encode_ascii(text, { margin = 1 })
  if not lines then
    return nil, err
  end

  local width = #lines[1]
  local win = float.open({
    title = title .. " (ASCII)",
    width = width + 2,
    height = #lines + 1,
    filetype = "weread-qr",
    on_close = opts.on_close,
    keymaps = false,
  })
  if not win then
    return nil, "could not open the QR window"
  end
  win:set_lines(lines)
  local handle = { float = win, png = nil, mode = "ascii" }
  for _, key in ipairs(opts.close_keys or { "q", "<Esc>", "<C-c>" }) do
    vim.keymap.set("n", key, function()
      win:close()
    end, { buffer = win:get_buf(), nowait = true, silent = true })
  end
  return handle, nil
end

return M
