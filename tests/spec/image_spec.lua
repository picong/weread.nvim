--[[
Tests for weread.image: the markdown parsing, the viewer geometry and the
degradation path when inline rendering is unavailable.
(image 单测：markdown 解析、浮窗几何、以及无法内联渲染时的降级路径)

Inline rendering itself needs a real kitty terminal and is verified manually;
see the README's verification section.
(内联渲染本身需要真实 kitty 终端，走手工验证；见 README 的验证章节)
]]

local image = require("weread.image")

describe("image.image_in_line", function()
  it("extracts the target and alt text", function()
    local path, alt = image.image_in_line("![](/abs/path/epub_1_44.png)")
    eq(path, "/abs/path/epub_1_44.png")
    eq(alt, "")

    path, alt = image.image_in_line("before ![图 1-6](/abs/图1-6.png) after")
    eq(path, "/abs/图1-6.png")
    eq(alt, "图 1-6")
  end)

  it("ignores plain links and prose", function()
    eq(image.image_in_line("[link](/somewhere)"), nil)
    eq(image.image_in_line("普通正文"), nil)
    eq(image.image_in_line(""), nil)
    eq(image.image_in_line(nil), nil)
  end)

  it("stops at whitespace so a title suffix does not leak into the path", function()
    local path = image.image_in_line('![alt](/abs/x.png "title")')
    eq(path, "/abs/x.png")
  end)
end)

describe("image.image_at_cursor", function()
  local buf

  local function make_buffer(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_buf(0, buf)
    return buf
  end

  it("finds the image on the cursor line", function()
    make_buffer({ "# 标题", "", "![](/a/one.png)", "正文" })
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    eq(image.image_at_cursor(buf), "/a/one.png")
  end)

  it("looks one line down and one line up", function()
    make_buffer({ "![](/a/one.png)", "", "正文", "", "![](/a/two.png)" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq(image.image_at_cursor(buf), "/a/one.png", "the image above")
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    eq(image.image_at_cursor(buf), "/a/two.png", "the image below")
  end)

  it("returns nothing when there is no image nearby", function()
    make_buffer({ "# 标题", "正文", "更多正文" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq(image.image_at_cursor(buf), nil)
  end)
end)

describe("image.viewer_size", function()
  ---Write a 24 byte PNG header: enough for the geometry code, which only reads
  ---the magic and the IHDR dimensions. No real image data is needed here.
  ---(写一个 24 字节的 PNG 头：几何计算只读魔数与 IHDR 尺寸，不需要真实图像数据)
  ---@param width integer
  ---@param height integer
  ---@return string path
  local function fake_png(width, height)
    local function be32(value)
      return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256
      )
    end
    local path = vim.fn.tempname() .. ".png"
    local file = assert(io.open(path, "wb"))
    file:write("\137PNG\r\n\26\n", be32(13), "IHDR", be32(width), be32(height), "\8\2\0\0\0")
    file:close()
    return path
  end

  it("keeps the float inside the screen", function()
    local width, height = image.viewer_size("/nonexistent/file.png", 200)
    truthy(width >= 10, "width is usable")
    truthy(width <= vim.o.columns - 6, "width fits the screen")
    truthy(height >= 3, "height is usable")
    truthy(height <= vim.o.lines - 6, "height fits the screen")
  end)

  it("derives the height from a PNG's aspect ratio", function()
    local _, wide_height = image.viewer_size(fake_png(200, 20), 40)
    local _, square_height = image.viewer_size(fake_png(100, 100), 40)
    truthy(
      wide_height < square_height,
      string.format("a wide image (%d rows) must be shorter than a square one (%d rows)", wide_height, square_height)
    )
    eq(wide_height, 3, "a 10:1 image at 40 cells wide is three rows tall")
  end)

  it("falls back to a 2:1 shape for unknown formats", function()
    local width, height = image.viewer_size("/nonexistent/file.jpg", 40)
    eq(width, 40)
    eq(height, math.floor(40 * 0.5 * 0.5) + 1)
  end)

  it("caps an illustration at the page it has to live in", function()
    eq(image.inline_max_width(52, 60), 48, "four cells of page margin")
    eq(image.inline_max_width(52, 30), 30, "a smaller configured cap still wins")
    eq(image.inline_max_width(0, 60), 60, "no page, no extra cap")
    eq(image.inline_max_width(12, 60), 10, "never degenerate")
  end)
end)

describe("image.placement_col", function()
  it("centers a figure on the page", function()
    -- `viewer_size` reports the placement width, which is the capped width; a
    -- 40 cell figure on a 52 cell page leaves six cells on each side.
    -- (viewer_size 给出的是放置宽度，即被上限夹过的宽度；40 格的插图放在 52 格的版心上，
    --  左右各留 6 格)
    eq(image.placement_col("/nonexistent/square.png", 52, 40), 6)
    eq(image.placement_col("/nonexistent/square.png", 0, 40), 0, "without a page the figure starts at the margin")
  end)

  it("never anchors a figure at a negative column", function()
    -- page narrower than the configured cap: the page wins, the offset is zero
    -- (版心比配置上限还窄：以版心为准，偏移归一)
    eq(image.placement_col("/nonexistent/square.png", 20, 40), 0)
  end)
end)

describe("image.ensure_local", function()
  local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

  ---A one pixel PNG, so the type sniffer has something real to look at.
  ---(1x1 的 PNG，让类型嗅探有真东西可看)
  local PNG = "\137PNG\r\n\26\n" .. string.rep("\0", 40)

  local calls = { count = 0 }
  local server = mock_lib.start({
    {
      path = "/wrepub/figure.jpeg",
      handler = function()
        calls.count = calls.count + 1
        return { status = 200, ctype = "image/png", body = PNG }
      end,
    },
  })

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local config = require("weread.config")
  config.setup({ data_dir = dir, proxy = "direct" })
  local http = require("weread.http")
  http.setup({ jar = dir .. "/cookies.txt", tmpdir = dir, timeout = 8, retries = 0, proxy = "direct" })

  it("uses a local file as it is", function()
    local done, result = false, nil
    image.ensure_local("/etc/hostname", dir, function(path, err)
      done, result = true, { path, err }
    end)
    vim.wait(5000, function()
      return done
    end, 20)
    eq(result[1], "/etc/hostname", "no download for something already on disk")
  end)

  it("downloads a URL once and remembers where it put it", function()
    local url = server.url .. "/wrepub/figure.jpeg"
    local first = nil
    image.ensure_local(url, dir, function(path, err)
      first = { path, err }
    end)
    vim.wait(20000, function()
      return first ~= nil
    end, 50)
    truthy(first[1], tostring(first[2]))
    truthy(vim.startswith(first[1], dir), "cached under the data dir: " .. tostring(first[1]))
    truthy(first[1]:find("%.png$"), "the extension comes from the bytes, not the url: " .. tostring(first[1]))
    eq(calls.count, 1, "one request")

    local second = nil
    image.ensure_local(url, dir, function(path)
      second = path
    end)
    vim.wait(5000, function()
      return second ~= nil
    end, 20)
    eq(second, first[1], "the second call is served from the cache")
    eq(calls.count, 1, "and makes no request at all")
  end)

  it("explains itself when there is no file and no URL", function()
    local done, result = false, nil
    image.ensure_local("/nope/missing.png", dir, function(path, err)
      done, result = true, { path, err }
    end)
    vim.wait(5000, function()
      return done
    end, 20)
    eq(result[1], nil)
    truthy(tostring(result[2]):find("不存在", 1, true), "with a reason: " .. tostring(result[2]))
  end)
end)

describe("image.ensure_local failure handling", function()
  local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")
  local PNG = "\137PNG\r\n\26\n" .. string.rep("\0", 40)

  -- every path answers with the same picture; the tests tell them apart by name
  -- (所有路径都回同一张图；各用例靠文件名区分)
  local server = mock_lib.start({
    {
      path = "/wrepub/",
      handler = function()
        return { status = 200, ctype = "image/png", body = PNG }
      end,
    },
  })

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local config = require("weread.config")
  config.setup({ data_dir = dir, proxy = "direct" })
  local http = require("weread.http")
  http.setup({ jar = dir .. "/cookies.txt", tmpdir = dir, timeout = 8, retries = 0, proxy = "direct" })

  ---@param url string
  ---@return table result { path, err }
  local function fetch(url)
    local result = nil
    image.ensure_local(url, dir, function(path, err)
      result = { path, err }
    end)
    vim.wait(20000, function()
      return result ~= nil
    end, 20)
    return result
  end

  ---Run `body` with http.download replaced, and put the real one back.
  ---(把 http.download 换掉跑 body，跑完还原)
  ---@param stub function
  ---@param body function
  local function with_download(stub, body)
    local real = http.download
    http.download = stub
    local ok, err = pcall(body)
    http.download = real
    if not ok then
      error(err, 0)
    end
  end

  it("clears the entry and retries when http.download raises synchronously", function()
    local url = server.url .. "/wrepub/raises.jpeg"
    local first = nil
    with_download(function()
      error("curl is gone")
    end, function()
      local ok = pcall(image.ensure_local, url, dir, function(path, err)
        first = { path, err }
      end)
      truthy(ok, "ensure_local itself does not raise")
    end)
    truthy(first, "the waiter was told, not left hanging")
    eq(first[1], nil)
    matches(first[2], "curl is gone")

    -- the entry is gone, so a second call really downloads (条目已清，第二次真的会下载)
    local second = fetch(url)
    truthy(second[1], tostring(second[2]))
    truthy(second[1]:find("%.png$"), tostring(second[1]))
  end)

  it("fails every queued waiter when the download comes back with an error", function()
    local url = server.url .. "/wrepub/queued.jpeg"
    local held = nil
    local results = {}
    with_download(function(_, _, _, callback)
      held = callback
    end, function()
      for index = 1, 3 do
        image.ensure_local(url, dir, function(path, err)
          results[index] = { path, err }
        end)
      end
      truthy(held, "one download started for three requests")
      held({ code = 0, error = "connection refused" })
    end)
    for index = 1, 3 do
      truthy(results[index], "waiter " .. index .. " was told")
      eq(results[index][1], nil)
      matches(results[index][2], "connection refused")
    end

    local retry = fetch(url)
    truthy(retry[1], "a later call is not stuck behind the failed one: " .. tostring(retry[2]))
  end)

  it("settles the entry when the download callback itself raises", function()
    local url = server.url .. "/wrepub/callback-raises.jpeg"
    local result = nil
    with_download(function(_, _, _, callback)
      -- a 200 for a file that was never written: reading it blows up in the callback body
      -- (200 但文件根本没写：回调体里读它会出错)
      callback({ code = 200, status = 200 })
    end, function()
      image.ensure_local(url, dir, function(path, err)
        result = { path, err }
      end)
    end)
    truthy(result, "the waiter was told")
    eq(result[1], nil)
    truthy(result[2], "with a reason")

    local retry = fetch(url)
    truthy(retry[1], "and the entry is free again: " .. tostring(retry[2]))
  end)

  it("keeps the other waiters going when one of them raises", function()
    local url = server.url .. "/wrepub/bad-waiter.jpeg"
    local second = nil
    image.ensure_local(url, dir, function()
      error("waiter blew up")
    end)
    image.ensure_local(url, dir, function(path, err)
      second = { path, err }
    end)
    vim.wait(20000, function()
      return second ~= nil
    end, 20)
    truthy(second and second[1], "the second waiter still got the picture")
  end)

  it("sends the configured origin as the referer, read when asked", function()
    server.reset()
    local previous = config.get()
    config.setup({ data_dir = dir, base_url = server.url .. "/", proxy = "direct" })
    local result = fetch(server.url .. "/wrepub/referer.jpeg")
    config.setup(previous)

    truthy(result[1], tostring(result[2]))
    local request = server.requests[1]
    truthy(request, "the request reached the mock")
    matches(request.headers:lower(), "referer: " .. server.url:lower() .. "/\r\n", "referer is the origin plus one slash")
  end)
end)

describe("image.supports_inline", function()
  it("is false without snacks.nvim installed", function()
    -- the test process runs with --clean, so snacks is absent
    -- (测试进程用 --clean 运行，因此没有 snacks)
    eq(image.supports_inline(), false)
  end)
end)

describe("image.mark_lines", function()
  it("annotates image lines only when inline rendering is unavailable", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "正文", "![](/a/one.png)", "更多" })
    image.mark_lines(buf)

    local namespace = vim.api.nvim_create_namespace("weread.image.hints")
    local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
    eq(#marks, 1, "one hint")
    eq(marks[1][2], 1, "on the image line")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("image.conceal_links", function()
  it("hides the markdown syntax and leaves the caption visible", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local line = "![图 1-6](/home/you/.local/share/nvim/weread/books/43208843/assets/epub_x.png)"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "正文", line })
    image.conceal_links(buf)

    local namespace = vim.api.nvim_create_namespace("weread.image.conceal")
    local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
    eq(#marks, 2, "one mark for the prefix and one for the path")

    local start_col, end_col, alt = line:find("!%[([^%]]*)%]%(([^%s%)]+)%)")
    eq(start_col, 1)
    local concealed = {}
    for _, mark in ipairs(marks) do
      local from = mark[3]
      local to = mark[4].end_col
      concealed[from] = to
    end
    eq(concealed[0], 2, "conceals `![`")
    eq(concealed[2 + #alt], end_col, "conceals `](path)`")

    -- nothing conceals the alt text itself
    -- (没有任何标记盖住 caption 文本)
    truthy(concealed[2] == nil, "the caption stays visible")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("handles an image without alt text", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "![](/abs/short.png)" })
    image.conceal_links(buf)
    local namespace = vim.api.nvim_create_namespace("weread.image.conceal")
    local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
    eq(#marks, 2, "the icon replaces the whole syntax")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("ignores lines that hold no image", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "普通正文", "[普通链接](/x)" })
    image.conceal_links(buf)
    local namespace = vim.api.nvim_create_namespace("weread.image.conceal")
    eq(#vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}), 0)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("image.render_inline", function()
  ---@return integer buf
  local function image_buffer()
    local buf = vim.api.nvim_create_buf(false, true)
    local path = vim.fn.tempname() .. ".png"
    local file = assert(io.open(path, "wb"))
    file:write("\137PNG\r\n\26\n")
    file:close()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "正文",
      "![](/does/not/exist.png)",
      "![](" .. path .. ")",
    })
    return buf, path
  end

  it("does nothing when the terminal cannot show images", function()
    -- headless has no kitty graphics protocol
    -- (headless 环境没有 kitty 图形协议)
    local buf = image_buffer()
    eq(image.render_inline(buf), 0)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("drives one placement per existing image file", function()
    local buf, path = image_buffer()
    local real_supports = image.supports_inline
    image.supports_inline = function()
      return true
    end

    local created = {}
    local cleaned = 0
    package.loaded["snacks.image.placement"] = {
      clean = function()
        cleaned = cleaned + 1
      end,
      new = function(target, src, opts)
        created[#created + 1] = { buf = target, src = src, opts = opts }
      end,
    }

    local count = image.render_inline(buf)
    image.supports_inline = real_supports
    package.loaded["snacks.image.placement"] = nil

    eq(count, 1, "only the image whose file exists gets a placement")
    eq(cleaned, 1, "previous placements are cleared first")
    eq(created[1].buf, buf)
    eq(created[1].src, path)
    eq(created[1].opts.pos[1], 3, "placed on its own line")
    eq(created[1].opts.inline, true, "inline so it scrolls with the text")
    eq(created[1].opts.type, "image")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("survives a placement implementation that throws", function()
    local buf = image_buffer()
    local real_supports = image.supports_inline
    image.supports_inline = function()
      return true
    end
    package.loaded["snacks.image.placement"] = {
      clean = function() end,
      new = function()
        error("no terminal")
      end,
    }

    local ok, count = pcall(image.render_inline, buf)
    image.supports_inline = real_supports
    package.loaded["snacks.image.placement"] = nil

    truthy(ok, "a broken renderer must not take the reader down")
    eq(count, 0, "and reports nothing drawn")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("image.attach", function()
  it("marks the buffer so other renderers can opt out", function()
    local buf = vim.api.nvim_create_buf(false, true)
    image.attach(buf)
    eq(vim.b[buf].weread_book, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("image.inline_max_height", function()
  it("measures the page of the chapter window it is given", function()
    require("weread.config").setup({ data_dir = vim.fn.tempname(), keymaps = false, sync_interval = 0 })
    local pager = require("weread.pager")
    local saved = vim.o.lines
    vim.o.lines = 30
    vim.cmd("split")
    local short = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(short, 8)
    vim.cmd("wincmd j")
    eq(image.inline_max_height(nil, short), pager.page_rows(short) - 2, "the chapter window, not the current one")
    eq(image.inline_max_height(3, short), 3, "the configured limit when it is smaller")
    eq(image.inline_max_height(40, -1), 40, "no chapter window: only the configured limit")
    eq(image.inline_max_height(nil, nil), nil)
    vim.api.nvim_win_close(short, true)
    vim.o.lines = saved
  end)
end)

describe("image.pixel_size", function()
  ---A file of the given prefix plus a little padding: only the header is read.
  ---(给定前缀加一点填充的文件：只读头部)
  ---@param bytes string
  ---@return string path
  local function file_of(bytes)
    local path = vim.fn.tempname()
    local handle = assert(io.open(path, "wb"))
    handle:write(bytes, string.rep("\0", 32))
    handle:close()
    return path
  end

  local function be32(value)
    return string.char(
      math.floor(value / 16777216) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 256) % 256,
      value % 256
    )
  end

  local function le16(value)
    return string.char(value % 256, math.floor(value / 256) % 256)
  end

  it("reads a PNG from its IHDR chunk", function()
    local path = file_of("\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(480) .. be32(342))
    eq(image.pixel_size(path), 480)
    eq(select(2, image.pixel_size(path)), 342)
    vim.fn.delete(path)
  end)

  it("reads a GIF from its screen descriptor", function()
    local path = file_of("GIF89a" .. le16(320) .. le16(200))
    eq(image.pixel_size(path), 320)
    eq(select(2, image.pixel_size(path)), 200)
    vim.fn.delete(path)
  end)

  it("walks the JPEG segments to the start of frame", function()
    -- SOI, an APP0 that must be skipped, then SOF0 with the dimensions
    -- (SOI，一个必须跳过的 APP0，然后是带尺寸的 SOF0)
    local jfif = "\255\216" -- SOI
      .. "\255\224" .. string.char(0, 16) .. "JFIF\0" .. string.rep("\0", 9)
      .. "\255\192" .. string.char(0, 17, 8) .. string.char(0, 200) .. string.char(1, 64) .. "\3"
      .. string.rep("\0", 9)
    local path = file_of(jfif)
    eq(image.pixel_size(path), 320)
    eq(select(2, image.pixel_size(path)), 200)
    vim.fn.delete(path)
  end)

  it("gives nothing for a file it cannot read", function()
    eq(image.pixel_size("/nonexistent/thing.png"), nil)
    local path = file_of("not an image at all")
    eq(image.pixel_size(path), nil)
    vim.fn.delete(path)
  end)
end)

describe("image.fit_cells", function()
  ---Hand the plugin a terminal of a known cell size: there is no kitty here.
  ---(给插件一个已知单元格尺寸的终端：这里没有 kitty)
  ---@param cell_width number
  ---@param cell_height number
  ---@return fun() restore
  local function fake_terminal(cell_width, cell_height)
    local saved = package.loaded["snacks.image.terminal"]
    package.loaded["snacks.image.terminal"] = {
      size = function()
        return { cell_width = cell_width, cell_height = cell_height, columns = 80, rows = 24 }
      end,
    }
    return function()
      package.loaded["snacks.image.terminal"] = saved
    end
  end

  it("keeps a figure at its pixels rather than its DPI", function()
    local restore = fake_terminal(10, 20)
    -- 400x200 pixels on 10x20 cells is 40x10 cells; the file's 600 DPI is noise
    -- (10x20 单元格下 400x200 像素就是 40x10 格；文件的 600 DPI 无关)
    local width, height = image.fit_cells(400, 200, 60, 20, false)
    restore()
    eq(width, 40)
    eq(height, 10)
  end)

  it("never draws a page figure larger than the box", function()
    local restore = fake_terminal(10, 20)
    -- 1200x900 is 120x45 cells, taller in cells than the 48x14 box is: the
    -- height is what binds, and the width follows the shape
    -- (1200x900 是 120x45 格，在格子里比 48x14 的盒子「更高」：限制的是高度，宽度随比例)
    local width, height = image.fit_cells(1200, 900, 48, 14, false)
    restore()
    eq(height, 14, "the page cap wins")
    eq(width, 37)
    truthy(width <= 48, "and the width stays inside the page")
  end)

  it("fills the box when the viewer may enlarge", function()
    local restore = fake_terminal(10, 20)
    -- 400x200 in a 60x20 box: the width is the binding constraint
    -- (60x20 的格子里的 400x200：宽度是限制条件)
    local width, height = image.fit_cells(400, 200, 60, 20, true)
    restore()
    eq(width, 60)
    eq(height, 15, "the shape is kept")
  end)

  it("stops enlarging before the figure turns to mush", function()
    local restore = fake_terminal(10, 20)
    -- 100x50 is 10x2.5 cells: filling a 70x20 box would be 7x, past the limit
    -- (100x50 是 10x2.5 格：填满 70x20 要放大 7 倍，超过上限)
    local width, height = image.fit_cells(100, 50, 70, 20, true)
    restore()
    eq(width, 30, "three times its pixels")
    eq(height, 8)
  end)
end)

describe("image.placements are sized by pixels", function()
  ---A fake snacks placement module, as the real one is shaped for our purposes.
  ---(形状够我们用的假 snacks placement 模块)
  ---@return table module, table placements
  local function fake_placement()
    local created = {}
    local module = {
      clean = function() end,
      new = function(buf, src, opts)
        local placement = {
          buf = buf,
          src = src,
          opts = opts or {},
          img = { file = src, src = src },
        }
        function placement:state()
          -- what snacks computes from the file's DPI, before we correct it
          -- (修正之前，snacks 按文件 DPI 算出的东西)
          return { loc = { width = 25, height = 8 } }
        end
        created[#created + 1] = placement
        return placement
      end,
    }
    package.loaded["snacks.image.placement"] = module
    return module, created
  end

  ---@param width integer
  ---@param height integer
  ---@return string path
  local function png(width, height)
    local function be32(value)
      return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256
      )
    end
    local path = vim.fn.tempname() .. ".png"
    local handle = assert(io.open(path, "wb"))
    handle:write("\137PNG\r\n\26\n", be32(13), "IHDR", be32(width), be32(height), "\8\2\0\0\0")
    handle:close()
    return path
  end

  local function with_chapter_buffer(run)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].weread = { book_id = "B", chapter_index = 1, chapter_key = "0001", chapter_uid = "1" }
    vim.api.nvim_win_set_buf(0, buf)
    local ok, err = pcall(run)
    vim.api.nvim_buf_delete(buf, { force = true })
    truthy(ok, tostring(err))
  end

  it("sizes a preview of one of the book's illustrations by pixels", function()
    local module, created = fake_placement()
    local path = png(480, 342)
    with_chapter_buffer(function()
      image.patch_placements()
      module.new(99, path, { max_width = 60, max_height = 20 })
      local state = created[1]:state()
      truthy(state.loc.width > 25, "wider than what the DPI asked for: " .. state.loc.width)
      truthy(state.loc.height > 8, "and taller: " .. state.loc.height)
      truthy(state.loc.width <= 60, "inside the box")
      truthy(state.loc.height <= 20, "inside the box")
    end)
    vim.fn.delete(path)
    package.loaded["snacks.image.placement"] = nil
  end)

  it("leaves the page's own figures at their pixels", function()
    local module, created = fake_placement()
    local path = png(480, 342)
    with_chapter_buffer(function()
      image.patch_placements()
      module.new(99, path, { inline = true, max_width = 48, max_height = 14 })
      local state = created[1]:state()
      eq(state.loc.width, 25, "an inline figure is the caller's business")
    end)
    vim.fn.delete(path)
    package.loaded["snacks.image.placement"] = nil
  end)

  it("hooks the constructor once, and only for illustrations", function()
    local module = fake_placement()
    eq(image.patch_placements(), true)
    local hooked = module.new
    eq(image.patch_placements(), true)
    eq(module.new, hooked, "hooking twice would wrap the wrapper")
    local plain = vim.fn.tempname() .. ".png"
    local handle = assert(io.open(plain, "wb"))
    handle:write("\137PNG\r\n\26\n")
    handle:close()
    -- nothing to do with this book: someone else's markdown preview
    -- (与本书无关：别人的 markdown 预览)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    local placement = module.new(99, plain, { max_width = 60, max_height = 20 })
    eq(select(1, placement:state().loc.width), 25)
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(plain)
    package.loaded["snacks.image.placement"] = nil
  end)

  it("knows a chapter buffer even without the data dir", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    falsy(image.is_illustration(vim.fn.tempname()))
    vim.b[buf].weread = { book_id = "B", chapter_index = 1, chapter_key = "0001", chapter_uid = "1" }
    truthy(image.is_illustration(vim.fn.tempname()), "the preview opens while a chapter is current")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
