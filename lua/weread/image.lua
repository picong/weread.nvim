--[[
Illustrations: inline rendering through snacks.image, plus a hover viewer.
(插图：由 snacks.image 负责内联渲染，另提供浮窗放大查看)

Inline rendering needs three things, and degrading well when one is missing
matters more than the happy path:
(内联渲染需要三个条件；缺一个时如何优雅降级比顺利路径更重要)

1. `snacks.nvim` installed with `image = { enabled = true }`
2. a terminal speaking the kitty graphics protocol (kitty, ghostty, wezterm)
3. `filetype=markdown` with a treesitter parser, which chapter buffers satisfy

When (1) or (2) is missing the reader still works: image lines get a hint and
`<leader>wo` reports where the file is.
(缺少条件时阅读仍可继续：图片行会加提示，<leader>wo 也会告知文件位置)
]]

local M = {}

---@return table|nil snacks_config
local function image_config()
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" or not snacks.config then
    return nil
  end
  return snacks.config.image
end

---Is inline image rendering available right now?
---(当前是否可用内联图片渲染)
---@return boolean
function M.supports_inline()
  local config = image_config()
  if not config or config.enabled == false then
    return false
  end
  local ok, supported = pcall(function()
    return require("snacks.image").supports_terminal()
  end)
  return ok and supported == true
end

---Extract the first markdown image target from a line.
---(从一行里取出第一个 markdown 图片地址)
---@param line string
---@return string|nil path
---@return string|nil alt
function M.image_in_line(line)
  if not line or not line:find("!%[", 1) then
    return nil
  end
  local alt, path = line:match("!%[([^%]]*)%]%(([^%s%)]+)")
  return path, alt
end

---Find the image the cursor is on, looking at the neighbouring lines too, so
---the mapping works from the paragraph right above an illustration.
---(找光标所在行的图片；同时看相邻行，这样站在插图上一段也能用)
---@param buf integer|nil
---@return string|nil path
---@return integer|nil line
function M.image_at_cursor(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local total = vim.api.nvim_buf_line_count(buf)
  for _, line_no in ipairs({ cursor, cursor + 1, cursor - 1 }) do
    if line_no >= 1 and line_no <= total then
      local line = vim.api.nvim_buf_get_lines(buf, line_no - 1, line_no, false)[1]
      local path = M.image_in_line(line)
      if path then
        return path, line_no
      end
    end
  end
  return nil, nil
end

---Pixel size of a PNG, straight from the IHDR chunk.
---(PNG 的像素尺寸，直接读 IHDR 块)
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

---Cell size for the float that will hold the image.
---(承载图片的浮窗尺寸，单位为单元格)
---@param path string
---@param max_width integer|nil
---@return integer width
---@return integer height
function M.viewer_size(path, max_width)
  local screen_width = math.max(20, vim.o.columns - 6)
  local screen_height = math.max(5, vim.o.lines - 6)
  local width = math.max(10, math.min(max_width or 80, screen_width))

  -- Missing or unreadable images fall back to a 2:1 shape. Terminal cells are
  -- roughly twice as tall as they are wide, hence the 0.5 factor.
  -- (读不到尺寸时按 2:1 处理；终端单元格大致高是宽的两倍，故乘 0.5)
  local ratio = 0.5
  local pixel_width, pixel_height = png_size(path)
  if pixel_width and pixel_height and pixel_width > 0 then
    ratio = pixel_height / pixel_width
  end

  local height = math.floor(width * ratio * 0.5) + 1
  height = math.max(3, math.min(screen_height, height))
  return width, height
end

---Open the image at the cursor in a floating window.
---(在浮窗中放大查看光标处的插图)
---@param path string|nil
function M.hover(path)
  path = path or M.image_at_cursor()
  if not path then
    vim.notify("weread: 光标附近没有插图", vim.log.levels.INFO)
    return
  end
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("weread: 图片文件不存在：" .. path, vim.log.levels.WARN)
    return
  end
  if not M.supports_inline() then
    vim.notify(
      "weread: 当前终端或 snacks.image 不支持内联图片，文件位于 " .. path,
      vim.log.levels.WARN
    )
    return
  end

  local config = require("weread.config").get()
  local max_width = (config.image or {}).max_width
  local float = require("weread.float")
  local width, height = M.viewer_size(path, max_width)
  local win = float.open({
    title = vim.fs.basename(path),
    width = width,
    height = height,
    filetype = "image",
  })
  if not win then
    return
  end
  vim.api.nvim_buf_set_name(win:get_buf(), path)
  local ok, err = pcall(function()
    require("snacks.image.buf").attach(win:get_buf(), {
      src = path,
      max_width = width,
      max_height = height,
    })
  end)
  if not ok then
    win:close()
    vim.notify("weread: 图片渲染失败：" .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.hover_at_cursor()
  M.hover()
end

---Replace the markdown image syntax with a short icon while reading.
---(阅读时把 markdown 图片语法替换成一个短图标)
---
---`![图 1-6](/home/you/.local/share/nvim/weread/books/43208843/assets/epub_x.png)`
---turns into `⧉ 图 1-6`. The long cache path is the single ugliest thing on a
---reading screen, and it is pure noise once the figure is rendered or reachable
---with <leader>wo.
---(长缓存路径是阅读界面里最丑的东西，而且一旦插图渲染出来、或能用 <leader>wo
--- 查看，它就是纯噪音)
---@param buf integer
function M.conceal_links(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local namespace = vim.api.nvim_create_namespace("weread.image.conceal")
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

  local icon = (require("weread.config").get().image or {}).icon or "⧉"
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for index, line in ipairs(lines) do
    local start_col, end_col, alt = line:find("!%[([^%]]*)%]%(([^%s%)]+)%)")
    if start_col then
      alt = alt or ""
      local alt_start = start_col + 1 -- 0-based column of the alt text(alt 的 0 基列号)
      -- conceal `![` into the icon
      pcall(vim.api.nvim_buf_set_extmark, buf, namespace, index - 1, start_col - 1, {
        end_col = start_col + 1,
        conceal = icon .. " ",
      })
      -- and `](path)` into nothing
      pcall(vim.api.nvim_buf_set_extmark, buf, namespace, index - 1, alt_start + #alt, {
        end_col = end_col,
        conceal = "",
      })
    end
  end
end

---Mark image lines when inline rendering is unavailable, so a reader is not
---left wondering why a line holds nothing but a path.
---(无法内联渲染时给图片行加提示，免得读者对着一行路径发愣)
---@param buf integer
function M.mark_lines(buf)
  if M.supports_inline() then
    return
  end
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local namespace = vim.api.nvim_create_namespace("weread.image.hints")
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for index, line in ipairs(lines) do
    if M.image_in_line(line) then
      pcall(vim.api.nvim_buf_set_extmark, buf, namespace, index - 1, 0, {
        virt_text = { { " 插图 · <leader>wo 查看文件", "Comment" } },
        virt_text_pos = "eol",
      })
    end
  end
end

---Hook a chapter buffer up for image rendering.
---(把章节 buffer 接上图片渲染)
---@param buf integer
function M.attach(buf)
  -- Lets a user-side guard for other markdown renderers opt out:
  -- `enabled = function() return not vim.b.weread_book end`
  -- (给用户侧的其它 markdown 渲染器留一个开关)
  vim.b[buf].weread_book = true
  M.conceal_links(buf)
  M.mark_lines(buf)
end

return M
