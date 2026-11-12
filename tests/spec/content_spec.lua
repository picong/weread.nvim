--[[
Tests for weread.content + weread.reader_state.

The shard fixtures come from upstream's *python* encoder
(scripts/gen_fixtures.py), so a pass here means the Lua decode chain agrees
with an independent implementation, not merely with itself.
(分片夹具来自上游的 python 编码器，因此这里通过意味着 Lua 解码链与另一套独立实现
 一致，而不是自证)
]]

local content = require("weread.content")
local protocol = require("weread.protocol")
local reader_state = require("weread.reader_state")
local tar = require("weread.tar")

local FIXTURES = vim.fn.getcwd() .. "/tests/fixtures"

---@param name string
---@return table
local function fixture_json(name)
  return vim.json.decode(table.concat(vim.fn.readfile(FIXTURES .. "/" .. name), "\n"))
end

local shards = fixture_json("shards.json")

describe("content.decode_shard", function()
  it("decodes every single-shard fixture", function()
    for name, case in pairs(shards) do
      if #case.shards == 1 then
        eq(content.decode_shard(case.shards[1]), case.plain, name)
      end
    end
  end)

  it("decodes the concatenated EPUB fixture", function()
    eq(content.decode_shards(shards.xhtml.shards), shards.xhtml.plain)
  end)

  it("handles the length boundaries around swap_positions", function()
    -- The decoder has three branches: <4, <11 and the general case. The
    -- fixtures pin the last two down; empty input covers the first.
    -- (解码器有三个分支：<4、<11 以及通用分支；夹具覆盖后两者，空输入覆盖第一个)
    eq(content.decode_shards({}), "")
    eq(content.decode_shard(shards.boundary_10.shards[1]), shards.boundary_10.plain)
    eq(content.decode_shard(shards.boundary_11.shards[1]), shards.boundary_11.plain)
  end)

  it("rejects a tampered payload", function()
    local shard = shards.chinese.shards[1]
    local tampered = shard:sub(1, 32) .. shard:sub(33, 40) .. (shard:sub(41, 41) == "a" and "b" or "a") .. shard:sub(42)
    raises(function()
      content.decode_shard(tampered)
    end, "MD5 mismatch")
  end)
end)

describe("content.decode_shard base64 handling", function()
  ---Wrap a base64 string into a valid shard: MD5 header, one filler byte, and
  ---the swap the decoder undoes (for 4..10 chars it swaps 1<->3 and 2<->4).
  ---(把 base64 串包成合法分片：MD5 头、一个填充字节，以及解码器要还原的换位)
  ---@param encoded string
  ---@return string
  local function shard_of(encoded)
    local chars = vim.split(encoded, "")
    if #chars >= 4 and #chars < 11 then
      chars[1], chars[3] = chars[3], chars[1]
      chars[2], chars[4] = chars[4], chars[2]
    end
    local body = "x" .. table.concat(chars)
    return require("weread.crypto").md5_hex(body):upper() .. body
  end

  it("decodes padded input", function()
    eq(content.decode_shard(shard_of("QUJDRA==")), "ABCD")
  end)

  it("restores a missing padding", function()
    eq(content.decode_shard(shard_of("QUJDRA")), "ABCD")
    eq(content.decode_shard(shard_of("QUJDREU")), "ABCDE")
  end)

  it("accepts the URL-safe alphabet", function()
    local raw = "\251\255\254"
    local standard = vim.base64.encode(raw)
    eq(standard, "+//+", "the bytes really exercise + and /")
    local url_safe = standard:gsub("%+", "-"):gsub("/", "_")
    eq(url_safe, "-__-")
    eq(content.decode_shard(shard_of(url_safe)), raw)
  end)

  it("ignores line breaks and spaces like the old decoder did", function()
    eq(content.decode_shard(shard_of("QUJD\nRA==")), "ABCD")
    eq(content.decode_shard(shard_of("QUJD RA\r\n")), "ABCD")
  end)

  it("raises on input that is not base64 instead of returning garbage", function()
    raises(function()
      content.decode_shard(shard_of("@@@@"))
    end, "base64")
    -- a length that no amount of padding can repair (补多少 padding 也救不回来的长度)
    raises(function()
      content.decode_shard(shard_of("QUJDR"))
    end, "base64")
  end)

  it("keeps the failure inside the caller's pcall", function()
    local ok, err = pcall(content.decode_shards, { shard_of("@@@@") })
    falsy(ok)
    matches(err, "base64")
  end)
end)

describe("content.reader_url", function()
  it("matches the ported protocol implementation", function()
    for _, case in ipairs({
      { "43208843" },
      { "43208843", "2" },
      { "43208843", 119 },
      { "MP_WXS_3286016687" },
    }) do
      eq(content.reader_url(case[1], case[2]), protocol.reader_url(case[1], case[2]))
    end
  end)
end)

describe("reader_state.extract", function()
  it("reads psvts, pclts and the book info from the reader page", function()
    local html = table.concat(vim.fn.readfile(FIXTURES .. "/reader.html"), "\n")
    local state = reader_state.extract(html, vim.json.decode)
    eq(state.book_id, "43208843")
    eq(state.title, "持续交付2.0")
    eq(state.author, "乔梁")
    eq(state.psvts, "9a1b2c3d4e5f60718293a4b5c6d7e8f0", "psvts is what every content request needs")
    eq(state.pclts, "11223344556677889900112233445566")
    eq(state.token, "t0ken-fixture")
  end)

  it("falls back to plain regexes when the state blob is missing", function()
    local html = '<script>var x = {"bookId":"99","title":"兜底","psvts":"abc"};</script>'
    local state = reader_state.extract(html, vim.json.decode)
    eq(state.book_id, "99")
    eq(state.title, "兜底")
    eq(state.psvts, "abc")
    eq(state.pclts, nil)
  end)

  it("survives a malformed state blob", function()
    local state = reader_state.extract("window.__INITIAL_STATE__ = {oops;(function(){})()", vim.json.decode)
    eq(state.psvts, nil)
    eq(state.book_id, nil)
  end)
end)

describe("content.normalize_catalog", function()
  local catalog = fixture_json("catalog.json")

  it("finds the record for the requested book", function()
    local record = content.normalize_catalog(catalog, "43208843")
    eq(record.book_id, "43208843")
    eq(record.format, "epub")
    eq(#record.chapters, 3)
    eq(record.chapters[2].title, "第 3 章 宇宙闪烁")
    eq(record.chapters[2].tar, "{{BASE}}/wrco/tar_43208843_36")
  end)

  it("returns nil for an unknown book", function()
    eq(content.normalize_catalog(catalog, "1"), nil)
  end)

  it("accepts an unwrapped single record", function()
    local record = content.normalize_catalog(catalog.data[1], "43208843")
    eq(#record.chapters, 3)
  end)
end)

describe("content.txt_to_xhtml", function()
  it("wraps non-empty lines, drops blank ones and strips CR", function()
    local xhtml = content.txt_to_xhtml("第一章\n\n　　正文一\r\n　　正文二\n")
    truthy(xhtml:find("<p>第一章</p>", 1, true), "first line")
    truthy(xhtml:find("<p>　　正文一</p>", 1, true), "crlf stripped, indent kept")
    truthy(xhtml:find("<p>　　正文二</p>", 1, true))
    falsy(xhtml:find("\r", 1, true), "no carriage returns survive")
    eq(select(2, xhtml:gsub("<p>", "")), 3, "blank lines dropped")
  end)

  it("keeps the full-width paragraph indent WeRead ships in TXT books", function()
    -- vim.trim does not consider U+3000 whitespace, which is exactly what we
    -- want: markdown renders the indent instead of swallowing it.
    -- (vim.trim 不把全角空格当空白，这正是我们想要的：markdown 会保留此缩进)
    local xhtml = content.txt_to_xhtml("　　许阳睁开眼睛。")
    truthy(xhtml:find("<p>　　许阳睁开眼睛。</p>", 1, true))
  end)

  it("returns an empty content div for empty input", function()
    local xhtml = content.txt_to_xhtml("")
    eq(xhtml:find("<p>", 1, true), nil)
  end)
end)

describe("content images", function()
  it("extracts images from the fixture tar and sniffs their types", function()
    local entries = tar.parse(tar.read_file(FIXTURES .. "/images.tar"))
    local images = content.extract_images(entries)
    eq(#images, 2, "the text file is not an image")

    local by_id = {}
    for _, image in ipairs(images) do
      by_id[image.id] = image
    end
    eq(by_id["epub_43208843_44"].ext, "png")
    eq(by_id["epub_43208843_44"].media, "image/png")
    eq(by_id["epub_43208843_45"].ext, "jpg")
    truthy(#by_id["epub_43208843_44"].data > 0)
  end)

  it("derives the same id from a url and from a tar entry", function()
    eq(content.image_id("https://res.weread.qq.com/wrepub/epub_43208843_44"), "epub_43208843_44")
    eq(content.image_id("https://res.weread.qq.com/wrepub/epub_43208843_44?v=2"), "epub_43208843_44")
    eq(content.image_id("36/epub_43208843_44"), "epub_43208843_44")
  end)

  it("rewrites both quote styles and counts what it could not resolve", function()
    local xhtml = table.concat({
      '<p><img src="https://res.weread.qq.com/wrepub/epub_1_44"/></p>',
      "<p><img src='https://res.weread.qq.com/wrepub/epub_1_45' /></p>",
      '<p><img src="https://res.weread.qq.com/wrepub/epub_1_99"/></p>',
    }, "\n")

    local out, replaced, missing = content.rewrite_image_sources(xhtml, {
      epub_1_44 = "/abs/assets/epub_1_44.png",
      epub_1_45 = "/abs/assets/epub_1_45.jpg",
    })

    eq(replaced, 2)
    eq(missing, 1)
    truthy(out:find('src="/abs/assets/epub_1_44.png"', 1, true), "double quotes")
    truthy(out:find("src='/abs/assets/epub_1_45.jpg'", 1, true), "single quotes")
    truthy(out:find("epub_1_99", 1, true), "unresolved url is left alone")
    falsy(out:find("res.weread.qq.com/wrepub/epub_1_44", 1, true), "the resolved url is gone")
  end)

  it("leaves non-image tags alone", function()
    local xhtml = '<a href="https://res.weread.qq.com/wrepub/epub_1_44">link</a>'
    local out, replaced = content.rewrite_image_sources(xhtml, { epub_1_44 = "/x.png" })
    eq(replaced, 0)
    eq(out, xhtml)
  end)
end)

describe("content.check_response", function()
  it("routes WeRead error payloads to the callback", function()
    local captured = nil
    local ok = content.check_response({ errCode = -2012 }, function(result_ok, message)
      captured = message
    end)
    falsy(ok)
    matches(captured, ":WeReadLogin")

    captured = nil
    local fine = content.check_response({ succ = 1 }, function(_, message)
      captured = message
    end)
    truthy(fine)
    eq(captured, nil)
  end)
end)

describe("content.find_invalid_text", function()
  it("accepts clean UTF-8 of every width", function()
    eq(content.find_invalid_text(""), nil)
    eq(content.find_invalid_text("plain ascii\n\ttab"), nil)
    eq(content.find_invalid_text("é — 中文《书》 😀"), nil)
    eq(content.find_invalid_text(shards.xhtml.plain, { xml = true }), nil)
    eq(content.find_invalid_text(shards.chinese.plain), nil)
  end)

  it("points at the first byte that is not UTF-8", function()
    -- the very bytes a spliced chapter came out with (拼错分片的章节实际解出的字节)
    eq(content.find_invalid_text('<span clas{\219"p">'), 12)
    eq(content.find_invalid_text("ab\136\240an"), 3)
    eq(content.find_invalid_text("中\228\184"), 4, "truncated sequence")
    eq(content.find_invalid_text("\192\128"), 1, "overlong encoding")
    eq(content.find_invalid_text("\237\160\128"), 1, "UTF-16 surrogate")
    eq(content.find_invalid_text("\244\144\128\128"), 1, "beyond U+10FFFF")
  end)

  it("flags control characters only when asked to check XML", function()
    eq(content.find_invalid_text('class="c1\28'), nil)
    eq(content.find_invalid_text('class="c1\28', { xml = true }), 10)
    eq(content.find_invalid_text("a\0b", { xml = true }), 2)
    eq(content.find_invalid_text("a\r\n\tb", { xml = true }), nil)
  end)
end)

describe("content.shards_consistent", function()
  it("accepts the near-equal thirds the service cuts", function()
    truthy(content.shards_consistent(shards.xhtml.shards))
  end)

  it("rejects a shard taken from another version of the chapter", function()
    local mixed = vim.deepcopy(shards.xhtml.shards)
    mixed[2] = mixed[2] .. string.rep("A", 40)
    falsy(content.shards_consistent(mixed))
  end)
end)

describe("content.fetch_assets leftovers", function()
  local config = require("weread.config")
  local http = require("weread.http")
  local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")

  -- Read once on the main loop: route handlers run in a libuv callback (在主循环里读一次)
  local tar_bytes = mock_lib.fixture_bytes("images.tar")

  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")

  ---@param dir string
  ---@return string[]
  local function headers_left_in(dir)
    local found = {}
    for name in vim.fs.dir(dir) do
      if name:find("%.headers$") then
        found[#found + 1] = name
      end
    end
    return found
  end

  ---@param chapter table
  ---@return boolean ok
  ---@return table|string result
  local function fetch(mock, chapter)
    config.setup({ data_dir = tmpdir, base_url = mock.url, proxy = "direct" })
    config.ensure_dirs()
    http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 8, retries = 0, proxy = "direct" })
    local done, ok, result = false, nil, nil
    content.fetch_assets({ book_id = "1", chapter_uid = "2" }, chapter, function(cb_ok, cb_result)
      ok, result, done = cb_ok, cb_result, true
    end)
    vim.wait(15000, function()
      return done
    end, 20)
    truthy(done, "the callback fired")
    return ok, result
  end

  it("removes the .headers file after a successful download", function()
    local mock = mock_lib.start({
      {
        path = "/wrco/tar_ok",
        handler = function()
          return { status = 200, ctype = "application/octet-stream", body = tar_bytes }
        end,
      },
    })
    local ok, result = fetch(mock, { chapterUid = 2, tar = mock.url .. "/wrco/tar_ok" })
    mock.stop()
    truthy(ok, tostring(result))
    eq(#result.images, 2)
    eq(headers_left_in(config.path("tmp")), {}, "no chapter-*.tar.headers left behind")
  end)

  it("removes the .headers file after a failed download too", function()
    local mock = mock_lib.start({
      {
        path = "/wrco/tar_gone",
        handler = function()
          return { status = 404, ctype = "text/plain", body = "gone" }
        end,
      },
    })
    local ok, result = fetch(mock, { chapterUid = 3, tar = mock.url .. "/wrco/tar_gone" })
    mock.stop()
    falsy(ok)
    matches(result, "资源包下载失败")
    eq(headers_left_in(config.path("tmp")), {}, "nor after a failure")
  end)
end)
