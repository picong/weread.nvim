--[[
QR code generation and display.
(二维码生成与显示)

Two rendering paths:
(两条渲染路径)

* Preferred: `qrencode` writes a PNG and `snacks.image` draws it in a floating
  window through the kitty graphics protocol.
  (首选：qrencode 生成 PNG，由 snacks.image 经 kitty 图形协议在浮窗里绘制)
* Fallback: the module matrix from `qrencode -t ASCII` is redrawn with half
  blocks in fixed black on white, which works in any terminal and needs no image
  support at all. The raw `##` art was twice as tall and took the
  colourscheme's colours, so dark themes produced an inverted code that phones
  often failed to read.
  (兜底：取 qrencode -t ASCII 的模块矩阵，用半块字符以固定黑白重新绘制，任何终端都能
   显示，完全不依赖图片能力。原先直接用 `##` 图案，高度翻倍且沿用配色方案的颜色，深色
   主题下成了反色码，手机常常扫不出来)
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
  -- vim.fn.mkdir raises (E739) instead of returning a status, so a bad target
  -- would escape as a hard error rather than this function's error contract.
  -- (vim.fn.mkdir 失败时抛 E739 而不是返回状态，否则写不进去时会以硬错误逃逸，
  --  破坏本函数的错误契约)
  local made, mkdir_err = pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
  if not made then
    return false, "无法创建目录：" .. tostring(mkdir_err)
  end
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

---Module matrix of the QR code for `text`, without any quiet zone.
---(text 对应二维码的模块矩阵，不含静默区)
---
---Parsed from `qrencode -t ASCII`, which prints every module as two
---characters, `##` for dark and two spaces for light.
---(解析 `qrencode -t ASCII` 的输出：每个模块占两个字符，`##` 为深色、两个空格为浅色)
---@param text string
---@param opts table|nil
---@return boolean[][]|nil matrix rows of modules, true = dark
---@return string|nil err
function M.matrix(text, opts)
  opts = opts or {}
  local lines, err = M.encode_ascii(text, { margin = 0, level = opts.level })
  if not lines then
    return nil, err
  end
  local size = math.floor(#lines[1] / 2)
  local matrix = {}
  for _, line in ipairs(lines) do
    local row = {}
    for index = 1, size do
      row[index] = line:sub(index * 2 - 1, index * 2) == "##"
    end
    matrix[#matrix + 1] = row
  end
  return matrix, nil
end

---Turn a module matrix into text lines plus the highlights they need.
---(把模块矩阵变成文本行以及所需的高亮)
---
---Half blocks (`▀▄█`) pack two module rows into one screen line, so the code is
---a quarter of the `##` art and still square on a 2:1 cell. Those glyphs are
---East Asian ambiguous, though: with `ambiwidth=double` they take two cells and
---the code falls apart, so that case paints spaces with a background instead.
---Either way the colours are fixed black on white — a light-on-dark code from a
---dark colourscheme is one many scanners refuse.
---(半块字符 `▀▄█` 把两行模块压进一行屏幕，体积只有 `##` 版的四分之一，在 2:1 的单元
--- 格上依然是正方形。但它们属于东亚歧义宽度字符：`ambiwidth=double` 时占两格，图案
--- 就散了，所以这种情况改用带背景色的空格绘制。两种方式都固定黑块白底——深色配色下
--- 浅色模块深色底的反色码，很多扫码器不认)
---@param matrix boolean[][]
---@param opts table|nil margin in modules, ambiwidth override
---@return string[] lines
---@return table[] highlights `{ line, col_start, col_end, group }`, 0-based byte columns
function M.render(matrix, opts)
  opts = opts or {}
  local margin = opts.margin or 2
  local ambiwidth = opts.ambiwidth or vim.o.ambiwidth
  local size = #matrix
  local function dark(row, col)
    local r = row - margin
    local c = col - margin
    return r >= 1 and r <= size and c >= 1 and c <= size and matrix[r][c] == true
  end
  local total = size + margin * 2
  local lines, highlights = {}, {}

  if ambiwidth == "double" then
    -- Two spaces per module, dark runs painted with a background.
    -- (每个模块两个空格，深色段用背景色绘制)
    for row = 1, total do
      local line_index = #lines
      lines[#lines + 1] = string.rep(" ", total * 2)
      highlights[#highlights + 1] = { line_index, 0, total * 2, "WereadQrLight" }
      local col = 1
      while col <= total do
        if dark(row, col) then
          local first = col
          while col <= total and dark(row, col) do
            col = col + 1
          end
          highlights[#highlights + 1] = { line_index, (first - 1) * 2, (col - 1) * 2, "WereadQrDark" }
        else
          col = col + 1
        end
      end
    end
    return lines, highlights
  end

  for row = 1, total, 2 do
    local cells = {}
    for col = 1, total do
      local top, bottom = dark(row, col), dark(row + 1, col)
      if top and bottom then
        cells[col] = "█"
      elseif top then
        cells[col] = "▀"
      elseif bottom then
        cells[col] = "▄"
      else
        cells[col] = " "
      end
    end
    local line = table.concat(cells)
    highlights[#highlights + 1] = { #lines, 0, #line, "WereadQr" }
    lines[#lines + 1] = line
  end
  return lines, highlights
end

---Highlight groups of the text QR. Fixed colours on purpose: scanners want
---dark modules on a light ground whatever the colourscheme.
---(文本二维码的高亮组；故意用固定颜色：无论配色方案如何，扫码器都要深色模块浅色底)
function M.define_highlights()
  vim.api.nvim_set_hl(0, "WereadQr", { fg = "#000000", bg = "#ffffff", ctermfg = 16, ctermbg = 231, default = true })
  vim.api.nvim_set_hl(0, "WereadQrDark", { bg = "#000000", ctermbg = 16, default = true })
  vim.api.nvim_set_hl(0, "WereadQrLight", { bg = "#ffffff", ctermbg = 231, default = true })
end

local ns = vim.api.nvim_create_namespace("weread.qr")

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
---@field mode string "image" | "text"

---Map the dialog keys: the close keys plus any caller actions.
---(映射对话框按键：关闭键加上调用方提供的动作)
---@param win table
---@param opts table
local function map_keys(win, opts)
  local buffer = win:get_buf()
  for _, key in ipairs(opts.close_keys or { "q", "<Esc>", "<C-c>" }) do
    vim.keymap.set("n", key, function()
      win:close()
    end, { buffer = buffer, nowait = true, silent = true })
  end
  for key, action in pairs(opts.actions or {}) do
    vim.keymap.set("n", key, action, { buffer = buffer, nowait = true, silent = true })
  end
end

---Show a QR code for `text` in a floating window.
---(在浮窗中显示 text 对应的二维码)
---@param text string
---@param opts table|nil title, footer, on_close, actions `{ [lhs] = fn }`
---@return weread.qr.Dialog|nil
---@return string|nil err
function M.show(text, opts)
  opts = opts or {}
  local title = opts.title or "微信读书 · 扫码登录"
  local png = opts.png or png_path()

  if not executable("qrencode") then
    return nil, "未找到 qrencode，请先安装（如 pacman -S qrencode / apt install qrencode / brew install qrencode）"
  end

  if M.image_supported() and M.encode(text, png, { scale = opts.scale or 6 }) then
    -- pixel_size returns two values; taking only the first silently produced a
    -- number where a table was expected — i.e. this whole branch crashed, and
    -- only terminals with image support ever reached it.
    -- It lives in weread.image, required here rather than at load time:
    -- image_supported() just loaded it, and it keeps the header parsing in one place.
    -- (pixel_size 返回两个值；只接第一个会让 size 变成数字而不是表 —— 整条图片分支
    --  都会崩，而只有支持图片的终端才会走到这里。
    --  它在 weread.image 里，这里按需 require 而不是加载期：image_supported() 刚刚加载过它，
    --  这样头部解析只有一份)
    local pixel_width, pixel_height = require("weread.image").pixel_size(png)
    local screen_width = math.max(20, vim.o.columns - 6)
    local screen_height = math.max(5, vim.o.lines - 6)
    local width = math.max(10, math.min(opts.width or 44, screen_width))
    local height = opts.height or width
    if pixel_width and pixel_height and pixel_width > 0 then
      -- Terminal cells are roughly twice as tall as wide, so halve the aspect
      -- ratio to keep the QR code square on screen.
      -- (终端单元格大致高宽比 2:1，因此把宽高比折半，让二维码在屏幕上保持正方形)
      local ratio = pixel_height / pixel_width
      height = math.floor(width * ratio * 0.5) + 1
    end
    height = math.max(3, math.min(height, screen_height))

    -- The image is an extmark-driven placement, not text in the buffer.
    -- Closing the window alone can leave it rendered until the next redraw, so
    -- keep the placement and close it explicitly too.
    -- (图片是由 extmark 驱动的 placement，不是 buffer 文本。只关窗口可能在下次重绘前
    --  一直留着它，因此同时保存 placement 并显式关闭)
    local placement = nil
    local function cleanup()
      if placement and type(placement.close) == "function" then
        pcall(placement.close, placement)
      end
      placement = nil
    end

    local win = float.open({
      title = title,
      width = width,
      height = height,
      footer = opts.footer,
      filetype = "image",
      on_close = function()
        cleanup()
        if opts.on_close then
          opts.on_close()
        end
      end,
      keymaps = false,
    })
    if win then
      map_keys(win, opts)
      vim.api.nvim_buf_set_name(win:get_buf(), png)
      local ok, err = pcall(function()
        placement = require("snacks.image.buf").attach(win:get_buf(), {
          src = png,
          max_width = width,
          max_height = height,
        })
      end)
      if ok then
        return { float = win, png = png, mode = "image", placement = placement, cleanup = cleanup }, nil
      end
      log.warn("snacks.image attach failed: %s", tostring(err))
      cleanup()
      win:close()
    end
  end

  local matrix, err = M.matrix(text)
  if not matrix then
    return nil, err
  end
  M.define_highlights()
  local lines, highlights = M.render(matrix, { margin = opts.margin or 2 })

  local win = float.open({
    title = title,
    footer = opts.footer,
    width = vim.api.nvim_strwidth(lines[1]),
    height = #lines,
    filetype = "weread-qr",
    on_close = opts.on_close,
    wrap = false,
    keymaps = false,
  })
  if not win then
    return nil, "could not open the QR window"
  end
  win:set_lines(lines)
  for _, mark in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(win:get_buf(), ns, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
  map_keys(win, opts)
  return { float = win, png = nil, mode = "text" }, nil
end

return M
