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
