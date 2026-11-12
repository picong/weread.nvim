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

local cache = require("weread.cache")
local content = require("weread.content")
local http = require("weread.http")
local log = require("weread.log")
local tar = require("weread.tar")

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

---Why inline images are unavailable, in words that can be acted on.
---(内联插图不可用的原因，写成可以照着做的说法)
---
---The common one is kitty inside tmux: snacks enables passthrough itself but its
---detection does not mark the terminal as supported there, so nothing is drawn
---until `snacks.image.force = true` says "yes it does".
---(最常见的是 tmux 里的 kitty：snacks 会自己打开 passthrough，但它的探测在 tmux 下没有把终端
--- 标成可用，于是在 `snacks.image.force = true` 明确说「它支持」之前什么都不画)
---@return string
function M.unsupported_reason()
  if M.supports_inline() then
    return ""
  end
  local config = image_config()
  if not config or config.enabled == false then
    return "snacks.nvim 的 image 模块没开（opts.image.enabled = true）"
  end
  if config.force ~= true and vim.env.TMUX and (vim.env.TERM or ""):find("kitty") then
    return "kitty + tmux：snacks 探测不到图形支持，设 snacks.image.force = true 即可"
  end
  return "当前终端没有图形协议支持（kitty / ghostty / wezterm 可以）"
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

---Pixel size of a JPEG: the first start-of-frame marker after the headers.
---(JPEG 的像素尺寸：越过各段头部后的第一个 SOF 标记)
---@param file file*
---@return integer|nil width
---@return integer|nil height
local function jpeg_size(file)
  file:seek("set", 2)
  while true do
    local marker = file:read(2)
    if not marker or #marker < 2 or marker:byte(1) ~= 0xFF then
      return nil
    end
    local kind = marker:byte(2)
    if kind == 0xD8 or kind == 0x01 or (kind >= 0xD0 and kind <= 0xD7) then
      -- standalone markers carry no length (独立标记没有长度字段)
    elseif kind == 0xFF then
      file:seek("cur", -1)
    else
      local size = file:read(2)
      if not size or #size < 2 then
        return nil
      end
      local length = size:byte(1) * 256 + size:byte(2)
      -- SOF0..SOF15, except DHT (C4), JPG (C8) and DAC (CC)
      if kind >= 0xC0 and kind <= 0xCF and kind ~= 0xC4 and kind ~= 0xC8 and kind ~= 0xCC then
        local frame = file:read(5)
        if not frame or #frame < 5 then
          return nil
        end
        return frame:byte(4) * 256 + frame:byte(5), frame:byte(2) * 256 + frame:byte(3)
      end
      if length < 2 or not file:seek("cur", length - 2) then
        return nil
      end
    end
  end
end

---Pixel size of an illustration, read from its header: PNG, JPEG and GIF.
---The DPI the file claims is deliberately not consulted.
---(插图的像素尺寸，从文件头读出：支持 PNG、JPEG、GIF。刻意不看文件声称的 DPI)
---@param path string
---@return integer|nil width
---@return integer|nil height
function M.pixel_size(path)
  local file = type(path) == "string" and io.open(path, "rb") or nil
  if not file then
    return nil
  end
  local header = file:read(24) or ""
  local width, height = nil, nil
  if #header >= 24 and header:sub(2, 4) == "PNG" then
    local function be32(offset)
      local a, b, c, d = header:byte(offset, offset + 3)
      return ((a * 256 + b) * 256 + c) * 256 + d
    end
    width, height = be32(17), be32(21)
  elseif #header >= 10 and header:sub(1, 3) == "GIF" then
    width = header:byte(7) + header:byte(8) * 256
    height = header:byte(9) + header:byte(10) * 256
  elseif #header >= 2 and header:byte(1) == 0xFF and header:byte(2) == 0xD8 then
    local ok, w, h = pcall(jpeg_size, file)
    if ok then
      width, height = w, h
    else
      log.debug("jpeg header of %s did not parse: %s", path, tostring(w))
    end
  end
  file:close()
  if not width or not height or width <= 0 or height <= 0 then
    return nil
  end
  return width, height
end

---Pixel size of a terminal cell; a 1:2 guess when the terminal does not say.
---(终端单元格的像素尺寸；终端不报告时按 1:2 估计)
---@return number width
---@return number height
local function cell_pixels()
  local ok, size = pcall(function()
    return require("snacks.image.terminal").size()
  end)
  if ok and type(size) == "table" and (size.cell_width or 0) > 0 and (size.cell_height or 0) > 0 then
    return size.cell_width, size.cell_height
  end
  if not ok then
    log.debug("terminal cell size unavailable, assuming 9x18: %s", tostring(size))
  end
  return 9, 18
end

---How much larger than its pixels an illustration may be drawn.
---(插图最多可以画到它像素尺寸的多少倍)
local UPSCALE_LIMIT = 3

---Cells an illustration takes inside a box of `max_width` x `max_height`
---cells, keeping its shape.
---(插图在 max_width x max_height 的格子里占多少格，保持原比例)
---
---snacks sizes an image by the DPI in its file, and book illustrations claim
---300 or 600 DPI: a 480 pixel figure came out 25 cells wide whatever the room.
---Here a pixel is a pixel. Without `upscale` a figure is never drawn larger
---than its pixels; with it (the viewer) it fills the box.
---(snacks 按文件里的 DPI 定尺寸，而书里的插图常标 300 或 600 DPI：480 像素的图不管给多大地方
--- 都只有 25 格宽。这里一个像素就是一个像素。不放大时插图不超过它的像素尺寸；放大时（查看器）
--- 铺满格子)
---@param pixel_width integer
---@param pixel_height integer
---@param max_width integer
---@param max_height integer
---@param upscale boolean|nil
---@return integer width
---@return integer height
function M.fit_cells(pixel_width, pixel_height, max_width, max_height, upscale)
  local cell_width, cell_height = cell_pixels()
  max_width = math.max(1, math.floor(max_width))
  max_height = math.max(1, math.floor(max_height))
  local native_width = pixel_width / cell_width
  local native_height = pixel_height / cell_height
  if not upscale and native_width <= max_width and native_height <= max_height then
    return math.max(1, math.ceil(native_width)), math.max(1, math.ceil(native_height))
  end
  local scale = math.min(max_width / native_width, max_height / native_height)
  if upscale then
    -- A figure blown up past this point is a blur, and a reader who wants more
    -- than that opens the file itself.
    -- (放大超过这个倍数就只是糊了，想要更大的读者会直接打开文件)
    scale = math.min(scale, UPSCALE_LIMIT)
  end
  return math.max(1, math.min(max_width, math.floor(native_width * scale + 0.5))),
    math.max(1, math.min(max_height, math.floor(native_height * scale + 0.5)))
end

---Is this placement one of a book's illustrations?
---(这个放置是不是某本书的插图？)
---
---Two answers, either one enough: the file sits in this plugin's own data
---directory, or the placement is being made while a chapter is the current
---buffer — which is the case for the hover preview snacks opens by itself, even
---when the illustration is still an URL that snacks fetched to its own cache.
---(两个答案，任一成立即可：文件在本插件自己的数据目录里，或者放置是在章节 buffer 为当前
--- buffer 时创建的——snacks 自己弹出的 hover 预览就是后者，即使那张插图还是 snacks 取到
--- 自己缓存里的 URL)
---@param src string|nil
---@return boolean
function M.is_illustration(src)
  if type(src) == "string" and src ~= "" then
    local root = require("weread.config").data_dir()
    if root ~= nil and root ~= "" and src:sub(1, #root) == root then
      return true
    end
  end
  local ok, reader = pcall(require, "weread.reader")
  return ok and type(reader.buffer_info) == "function" and reader.buffer_info() ~= nil
end

---Make a snacks placement use `fit_cells` for its size instead of the DPI.
---(让 snacks 的放置用 fit_cells 定尺寸，而不是文件里的 DPI)
---@param placement table snacks.image.Placement
---@param src string
---@param max_width integer|nil
---@param max_height integer|nil
---@param upscale boolean|nil
function M.size_by_pixels(placement, src, max_width, max_height, upscale)
  if type(placement) ~= "table" or type(placement.state) ~= "function" then
    return
  end
  local max_w = tonumber(max_width) or (vim.o.columns - 6)
  local max_h = tonumber(max_height) or (vim.o.lines - 6)
  local state = placement.state
  placement.state = function(self)
    local result = state(self)
    local width, height = M.pixel_size(self.img and self.img.file or src)
    if not width then
      width, height = M.pixel_size(src)
    end
    if width and result and result.loc then
      result.loc.width, result.loc.height = M.fit_cells(width, height, max_w, max_h, upscale)
    end
    return result
  end
end

---Size every placement of a book's illustration by pixels, not by its DPI.
---(把本书插图的每个放置都按像素定尺寸，而不是按 DPI)
---
---The reader sizes its own placements, but snacks opens a hover preview by
---itself whenever the cursor touches an image line (`doc.float`), and that one
---comes out at the size the file's DPI asks for: a 480 pixel figure in a 25 cell
---box. A placement is only reachable through the constructor it came out of, so
---that is where the hook goes — idempotent, and limited to this book's files.
---(阅读器自己的放置由它自己定尺寸，但光标碰到图片行时 snacks 会自己弹出 hover 预览
--- （`doc.float`），那一个是按文件 DPI 定尺寸的：480 像素的插图只占 25 格。放置只能从
--- 产生它的构造函数拿到，所以钩子挂在那里——幂等，且只作用于本书的文件)
---@return boolean patched
function M.patch_placements()
  local ok, placement = pcall(require, "snacks.image.placement")
  if not ok or type(placement) ~= "table" or type(placement.new) ~= "function" then
    log.debug("snacks.image.placement not patchable: %s", ok and "no placement.new" or tostring(placement))
    return false
  end
  if placement.weread_sized then
    return true
  end
  local original = placement.new
  placement.new = function(buf, src, opts)
    local created = original(buf, src, opts)
    opts = opts or {}
    -- Inline figures stay at their pixels: a figure stretched on the page is a
    -- blurry figure, and the page has one key for looking closer.
    -- (页面里的插图保持像素尺寸：被拉伸的插图只会发虚，而页面上有一个键可以凑近看)
    if not opts.inline and M.is_illustration(src) then
      M.size_by_pixels(created, src, opts.max_width, opts.max_height, true)
    end
    return created
  end
  placement.weread_sized = true
  return true
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
  local pixel_width, pixel_height = M.pixel_size(path)
  if pixel_width and pixel_height and pixel_width > 0 then
    ratio = pixel_height / pixel_width
  end

  local height = math.floor(width * ratio * 0.5) + 1
  height = math.max(3, math.min(screen_height, height))
  return width, height
end

---Max width an illustration may take on the page.
---(插在图版心上最多能有多宽)
---
---The configured cap is a cap, not a target, and a figure wider than the page
---would stick out of it.
---(配置里的上限只是上限而非目标；比版心还宽的插图会出格)
---@param page integer page width in cells, 0 when there is no page(版心宽度，0 表示无版心)
---@param configured integer|nil
---@return integer
function M.inline_max_width(page, configured)
  local width = tonumber(configured) or 60
  if page and page > 0 then
    width = math.max(10, math.min(width, page - 4))
  end
  return width
end

---Column an illustration is anchored at: centered on the page, the way a book
---sets a figure.
---(插图锚定的列：在版心上居中，就像书里排插图那样)
---@param path string
---@param page integer
---@param max_width integer
---@param max_height integer|nil rows the figure may take; with it, the width is the one actually drawn(插图可占行数；给了就用实际画出的宽度)
---@return integer col
function M.placement_col(path, page, max_width, max_height)
  if not page or page <= 0 then
    return 0
  end
  local width = select(1, M.viewer_size(path, max_width))
  local pixel_width, pixel_height = M.pixel_size(path)
  if max_height and pixel_width then
    width = select(1, M.fit_cells(pixel_width, pixel_height, max_width, max_height))
  end
  return math.max(0, math.floor((page - width) / 2))
end

---Open the image at the cursor in a floating window.
---(在浮窗中放大查看光标处的插图)
---@param path string|nil
function M.hover(path)
  path = path or M.image_at_cursor()
  -- the zoom is a placement too: the hook is what keeps it out at pixel size
  -- (放大也是一个放置：像素尺寸靠这个钩子)
  M.patch_placements()
  if not path then
    vim.notify("weread: 光标附近没有插图", vim.log.levels.INFO)
    return
  end
  if vim.fn.filereadable(path) ~= 1 then
    if not M.is_remote(path) then
      vim.notify("weread: 图片文件不存在：" .. path, vim.log.levels.WARN)
      return
    end
    -- A URL-shaped illustration: fetch it, then open it like any other.
    -- (URL 形式的插图：先取下来，再照常打开)
    local info = require("weread.reader").buffer_info()
    local dir = info and cache.assets_dir(info.book_id) or nil
    M.ensure_local(path, dir, function(local_path, err)
      if not local_path then
        vim.notify("weread: " .. tostring(err), vim.log.levels.WARN)
        return
      end
      M.hover(local_path)
    end)
    return
  end
  if not M.supports_inline() then
    vim.notify(
      "weread: 当前终端或 snacks.image 不支持内联图片，文件位于 " .. path,
      vim.log.levels.WARN
    )
    return
  end

  -- The viewer is for looking closely: the figure fills the screen, keeping its
  -- shape, and the float is cut to the figure.
  -- (查看器是用来细看的：插图按原比例铺满屏幕，浮窗按插图裁成同样大小)
  local float = require("weread.float")
  local width, height = M.viewer_size(path, vim.o.columns)
  local pixel_width, pixel_height = M.pixel_size(path)
  if pixel_width then
    width, height = M.fit_cells(pixel_width, pixel_height, vim.o.columns - 6, vim.o.lines - 6, true)
    width = math.max(10, width)
    height = math.max(3, height)
  end
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
    local snacks_buf = require("snacks.image.buf")
    local opts = { src = path, max_width = width, max_height = height }
    -- `attach` waits for terminal detection; `_attach` is what returns the
    -- placement, so call it from the same callback
    -- (`attach` 要等终端探测完；返回放置的是 `_attach`，因此在同一个回调里调它)
    require("snacks.image.terminal").detect(function()
      local placement = snacks_buf._attach(win:get_buf(), opts)
      M.size_by_pixels(placement, path, width, height, true)
      if placement and placement.update then
        placement._state = nil
        placement:update()
      end
    end)
  end)
  if not ok then
    win:close()
    vim.notify("weread: 图片渲染失败：" .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.hover_at_cursor()
  M.hover()
end

---Place an extmark, tolerating a position that moved out of range under us.
---(放一个 extmark；位置在我们眼皮底下越界时容忍之)
---@param buf integer
---@param namespace integer
---@param row integer 0-based
---@param col integer 0-based
---@param opts table
local function set_extmark(buf, namespace, row, col, opts)
  local ok, err = pcall(vim.api.nvim_buf_set_extmark, buf, namespace, row, col, opts)
  if not ok then
    log.debug("extmark at %d:%d skipped: %s", row, col, tostring(err))
  end
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
      set_extmark(buf, namespace, index - 1, start_col - 1, {
        end_col = start_col + 1,
        conceal = icon .. " ",
      })
      -- and `](path)` into nothing
      set_extmark(buf, namespace, index - 1, alt_start + #alt, {
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
      set_extmark(buf, namespace, index - 1, 0, {
        virt_text = { { " 插图 · <leader>wo 查看文件", "Comment" } },
        virt_text_pos = "eol",
      })
    end
  end
end

---Is this source something to download rather than to open?
---(这个来源是需要下载的，还是直接打开的？)
---@param src string
---@return boolean
function M.is_remote(src)
  return type(src) == "string" and src:find("^https?://") ~= nil
end

---Illustrations already being downloaded, keyed by source, so a chapter that
---shows the same figure twice fetches it once.
---(正在下载的插图，按来源索引：同一张图在一章里出现两次也只下一次)
local inflight = {}

---Make sure an illustration exists on disk, downloading it if it is a URL.
---(确保插图在磁盘上存在；如果是 URL 就下载下来)
---
---Two shapes of book ship illustrations two ways: a resource pack next to the
---chapter, or plain URLs in the markup. The pack is not always usable — some
---books ship a *zip* under a `tar` url, which the tarball reader finds nothing in
---— so the URLs the chapter itself carries are the reliable route, and they are
---the same images.
---(书里的插图有两种下发方式：章节旁边的资源包，或正文里的普通 URL。资源包并不总是能用——
--- 有些书在 `tar` 字段下发的其实是 **zip**，tar 解包器在里面一无所获——因此章节自己带着的
--- URL 才是可靠路径，而它们就是同一批图)
---@param src string path or url
---@param dir string|nil directory to cache downloads in(下载缓存目录)
---@param callback fun(path: string|nil, err: string|nil)
function M.ensure_local(src, dir, callback)
  if type(src) ~= "string" or src == "" then
    callback(nil, "没有图片地址")
    return
  end
  if vim.fn.filereadable(src) == 1 then
    callback(src, nil)
    return
  end
  if not M.is_remote(src) then
    callback(nil, "图片文件不存在：" .. src)
    return
  end
  if (require("weread.config").get().image or {}).download == false then
    callback(nil, "已关闭图片下载（image.download = false）")
    return
  end

  local id = content.image_id(src)
  -- Looked up by the extensions a picture can have rather than by `url-<id>.*`:
  -- the downloader leaves a `.headers` file next to its output, and a glob would
  -- happily hand that to the renderer as the illustration.
  -- (按图片可能的扩展名查找，而不是 `url-<id>.*`：下载器会在输出旁边留一个 `.headers`
  --  文件，而通配会把那个当成插图交给渲染器)
  local existing = nil
  for _, ext in ipairs({ "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg" }) do
    local candidate = string.format("%s/url-%s.%s", dir or "", id, ext)
    if vim.fn.filereadable(candidate) == 1 then
      existing = candidate
      break
    end
  end
  if existing then
    callback(existing, nil)
    return
  end
  if inflight[src] then
    inflight[src][#inflight[src] + 1] = callback
    return
  end
  inflight[src] = { callback }

  -- Settles the entry exactly once and tells every waiter. The flag matters: a
  -- waiter may ask for the same source again, and a late second `finish` must not
  -- wipe that new entry.
  -- (只结算一次并通知所有等待者。这个标志不可少：等待者可能马上又请求同一来源，
  --  迟到的第二次 finish 不能把新登记的条目清掉)
  local settled = false
  local temp = nil
  local function finish(path, err)
    if settled then
      return
    end
    settled = true
    local waiters = inflight[src] or {}
    inflight[src] = nil
    for _, waiter in ipairs(waiters) do
      local ok, waiter_err = pcall(waiter, path, err)
      if not ok then
        log.warn("illustration waiter for %s raised: %s", src, tostring(waiter_err))
      end
    end
  end

  ---Give up on a failed attempt: drop the partial files and fail every waiter.
  ---(放弃失败的尝试：清掉残留文件，并让所有等待者失败)
  ---@param reason string
  local function fail(reason)
    if temp then
      vim.uv.fs_unlink(temp)
      vim.uv.fs_unlink(temp .. ".headers")
    end
    finish(nil, reason)
  end

  ---@param res table|nil
  local function on_downloaded(res)
    -- the downloader keeps its header dump next to the body
    -- (下载器会把响应头留在正文旁边)
    vim.uv.fs_unlink(temp .. ".headers")
    res = res or {}
    if res.code ~= 200 and res.status ~= 200 then
      fail(string.format("插图下载失败（HTTP %s）", tostring(res.status or res.error)))
      return
    end
    local file = io.open(temp, "rb")
    local head = file and file:read(64) or nil
    if file then
      file:close()
    end
    local ext = head and select(1, tar.detect_type(head)) or nil
    if not ext then
      fail("下载到的内容不是图片")
      return
    end
    local path = string.format("%s/url-%s.%s", dir, id, ext)
    local ok = vim.uv.fs_rename(temp, path)
    if not ok then
      fail("无法写入 " .. path)
      return
    end
    log.debug("downloaded illustration %s -> %s", src, path)
    finish(path, nil)
  end

  -- Everything that can throw before the download is under way is inside the
  -- pcall: an exception here would otherwise leave `inflight[src]` set for good
  -- and every later request for this figure would queue behind a download that
  -- never ends.
  -- (下载真正开始前所有可能抛错的步骤都放进 pcall：否则异常会让 inflight[src] 永远
  --  留着，之后对这张图的每次请求都排在一个永远不结束的下载后面)
  local started, start_err = pcall(function()
    vim.fn.mkdir(dir, "p")
    -- Downloaded under a neutral name first: the extension comes from the bytes,
    -- because a URL's extension is a hint at best.
    -- (先下成中性文件名：扩展名以字节为准，URL 的后缀最多只是提示)
    temp = string.format("%s/url-%s.download", dir, id)
    -- origin read at call time, not frozen at load (在调用时读取 origin，而不是加载时固化)
    local referer = require("weread.config").web_origin() .. "/"
    http.download(src, temp, { referer = referer, timeout = 45, retries = 1 }, function(res)
      -- the body can throw too (reading the file, sniffing it); that must settle as well
      -- (回调体同样可能抛错：读文件、嗅探类型；也必须结算)
      local ok, err = pcall(on_downloaded, res)
      if not ok then
        log.warn("illustration download callback for %s raised: %s", src, tostring(err))
        fail("插图处理出错：" .. tostring(err))
      end
    end)
  end)
  if not started then
    log.warn("illustration download for %s could not start: %s", src, tostring(start_err))
    fail("插图下载出错：" .. tostring(start_err))
  end
end

---Draw the images of a chapter with snacks' placement API, driven by the image
---lines we can see ourselves.
---(用 snacks 的 placement API 把章节里的插图画出来，位置由我们自己扫描到的图片行决定)
---
---Why not rely on snacks' markdown document mode: it finds images through the
---treesitter `images` query, which runs against the *injected* `markdown_inline`
---tree. On this machine that injection never gets parsed (the markdown tree
---keeps `inline` as an opaque leaf), so document mode silently renders nothing.
---Driving placements directly depends on nothing but the file being there.
---(为什么不直接用 snacks 的 markdown 文档模式：它靠 treesitter 的 `images` 查询找图，
--- 而该查询跑在**注入的** `markdown_inline` 树上。本机上这个注入从未被解析
--- （markdown 树里的 inline 始终是不透明叶子），于是文档模式静默地什么都不画。
--- 直接驱动 placement 只依赖文件存在这一件事)
---@param buf integer
---@return integer created number of placements created(创建的放置数)
function M.render_inline(buf)
  if not M.supports_inline() or not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  local ok_placement, placement = pcall(require, "snacks.image.placement")
  if not ok_placement then
    log.debug("snacks.image.placement unavailable, no inline images: %s", tostring(placement))
    return 0
  end

  -- re-attaching (a re-render, a theme change) must not stack duplicates
  -- (重新接上（重排、换主题）不能叠加重复的放置)
  local cleaned, clean_err = pcall(placement.clean, buf)
  if not cleaned then
    log.debug("clearing old placements failed: %s", tostring(clean_err))
  end

  local image_config = (require("weread.config").get().image or {})
  local page = require("weread.reader").page_width() or 0
  local max_width = M.inline_max_width(page, image_config.max_width)

  -- A generation per attach: an illustration that finishes downloading after the
  -- reader has moved on must not be placed into the new chapter.
  -- (每次接上算一代：读者已经翻走之后才下完的插图，不能画进新的章节里)
  local generation = (vim.b[buf].weread_image_generation or 0) + 1
  vim.b[buf].weread_image_generation = generation
  local info = require("weread.reader").buffer_info(buf) or {}

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local created = 0

  local function place(index, path)
    if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].weread_image_generation ~= generation then
      return
    end
    -- Figures are centered on the page. The placement is anchored in the text
    -- area, so the offset is measured from the left edge of the page.
    -- (插图在版心上居中。放置锚定在文本区，因此偏移量从版心左缘算起)
    local max_height = M.inline_max_height(image_config.max_height, vim.fn.bufwinid(buf))
    local col = M.placement_col(path, page, max_width, max_height)
    local ok, created_placement = pcall(placement.new, buf, path, {
      pos = { index, col },
      inline = true,
      auto_resize = true,
      type = "image",
      conceal = false,
      max_width = max_width,
      max_height = max_height,
    })
    if ok then
      -- by pixels, not by the DPI the file claims (按像素定尺寸，而不是文件声称的 DPI)
      M.size_by_pixels(created_placement, path, max_width, max_height or 14)
      created = created + 1
    else
      log.debug("placement failed for %s: %s", path, tostring(created_placement))
    end
  end

  for index, line in ipairs(lines) do
    local src = M.image_in_line(line)
    if src then
      if vim.fn.filereadable(src) == 1 then
        place(index, src)
      else
        -- Not on disk: it is a URL, and the chapter's own images are worth a
        -- download — this is what makes illustrations appear *in* the text
        -- instead of only in the hover viewer.
        -- (磁盘上没有：那是个 URL，而章节自带的图值得下一份——插图因此能出现在**正文里**，
        --  而不是只在放大查看时可见)
        local dir = info.book_id and cache.assets_dir(info.book_id) or nil
        M.ensure_local(src, dir, function(path, err)
          if path then
            place(index, path)
          else
            log.debug("illustration unavailable: %s (%s)", src, tostring(err))
          end
        end)
      end
    end
  end
  return created
end

---Rows an illustration may take: the configured limit, and never more than a
---page holds — a figure taller than the window could not sit on any page.
---(插图最多占几行：配置的上限，且绝不超过一页能装下的——比窗口还高的图放不进任何一页)
---
---The page is the chapter's window, not whichever window has the cursor: a
---figure that finishes downloading while the reader is in the outline is still
---placed on the chapter's page.
---(页指的是章节所在的窗口，而不是光标所在的那个：读者待在目录里时才下完的插图，仍然放在章节的页上)
---@param configured integer|nil
---@param win integer|nil the chapter window; without one, only the configured limit applies(章节窗口；没有就只用配置的上限)
---@return integer|nil
function M.inline_max_height(configured, win)
  local limit = tonumber(configured)
  local pager = require("weread.pager")
  if not pager.enabled() or not win or win <= 0 or not vim.api.nvim_win_is_valid(win) then
    return limit
  end
  local rows = pager.page_rows(win) - 2
  if rows < 3 then
    return limit
  end
  return limit and math.min(limit, rows) or rows
end

---Hook a chapter buffer up for image rendering.
---(把章节 buffer 接上图片渲染)
---@param buf integer
function M.attach(buf)
  -- Lets a user-side guard for other markdown renderers opt out:
  -- `enabled = function() return not vim.b.weread_book end`
  -- (给用户侧的其它 markdown 渲染器留一个开关)
  vim.b[buf].weread_book = true
  M.patch_placements()
  M.conceal_links(buf)
  M.render_inline(buf)
  M.mark_lines(buf)
end

return M
