--[[
Tests for weread.tar: the minimal tar reader and the magic-byte image sniffer.
Archives are built by hand here, so every header field the reader looks at is
pinned down independently of the fixture tarball.
(tar 单测：极简 tar 读取器与按魔数的图片嗅探。归档在这里手工拼出，因此读取器用到的每个
 头部字段都独立于夹具包被钉住)
]]

local tar = require("weread.tar")

local BLOCK = 512

---Overwrite `len` bytes of `block` at 1-based `from` with `text`, zero padded.
---(用 text 覆盖 block 里从 from 开始的 len 个字节，不足补零)
---@param block string
---@param from integer
---@param len integer
---@param text string
---@return string
local function put(block, from, len, text)
  text = (text .. string.rep("\0", len)):sub(1, len)
  return block:sub(1, from - 1) .. text .. block:sub(from + len)
end

---One tar entry: header block plus payload padded to a block boundary.
---(一个 tar 条目：头块加按块对齐补零的载荷)
---@param name string
---@param payload string
---@param opts table|nil { type = "0", prefix = "" }
---@return string
local function entry(name, payload, opts)
  opts = opts or {}
  local header = string.rep("\0", BLOCK)
  header = put(header, 1, 100, name)
  header = put(header, 125, 12, string.format("%011o", #payload))
  header = put(header, 157, 1, opts.type or "0")
  if opts.prefix then
    header = put(header, 346, 155, opts.prefix)
  end
  local padding = (BLOCK - #payload % BLOCK) % BLOCK
  return header .. payload .. string.rep("\0", padding)
end

local END = string.rep("\0", BLOCK * 2)

describe("tar.parse", function()
  it("reads regular files with their exact payload", function()
    local data = entry("a.png", "first") .. entry("dir/b.txt", string.rep("x", 600)) .. END
    local entries = tar.parse(data)
    eq(#entries, 2)
    eq(entries[1].name, "a.png")
    eq(entries[1].data, "first")
    eq(entries[1].size, 5)
    eq(entries[2].name, "dir/b.txt")
    eq(#entries[2].data, 600, "a payload spanning two blocks")
  end)

  it("joins the ustar prefix onto a bare name", function()
    local entries = tar.parse(entry("leaf", "z", { prefix = "deep/er" }) .. END)
    eq(entries[1].name, "deep/er/leaf")
  end)

  it("leaves a name that already has a directory alone", function()
    local entries = tar.parse(entry("own/leaf", "z", { prefix = "ignored" }) .. END)
    eq(entries[1].name, "own/leaf")
  end)

  it("applies a GNU long name to the entry after it", function()
    local long = string.rep("n", 140) .. ".png"
    local data = entry("././@LongLink", long .. "\0", { type = "L" }) .. entry("short", "body") .. END
    local entries = tar.parse(data)
    eq(#entries, 1, "the long-name record is not an entry of its own")
    eq(entries[1].name, long)
    eq(entries[1].data, "body")
  end)

  it("applies a pax path record to the entry after it", function()
    local record = "30 path=pax/dir/real-name.png\n"
    local data = entry("PaxHeader", record, { type = "x" }) .. entry("fallback", "body") .. END
    local entries = tar.parse(data)
    eq(#entries, 1)
    eq(entries[1].name, "pax/dir/real-name.png")
  end)

  it("skips directories and links unless asked for them", function()
    local data = entry("dir/", "", { type = "5" }) .. entry("lnk", "", { type = "2" }) .. entry("f", "ok") .. END
    local files = tar.parse(data)
    eq(#files, 1)
    eq(files[1].name, "f")

    local everything = tar.parse(data, { files_only = false })
    eq(#everything, 3)
    eq(everything[1].type, "5")
    eq(everything[2].type, "2")
  end)

  it("stops at the first all-zero block", function()
    local data = entry("a", "1") .. string.rep("\0", BLOCK) .. entry("after-end", "2")
    local entries = tar.parse(data)
    eq(#entries, 1)
    eq(entries[1].name, "a")
  end)

  it("does not raise on an empty or truncated archive", function()
    eq(tar.parse(""), {})
    eq(tar.parse(string.rep("\0", 100)), {}, "less than one block")
    local cut = (entry("a", string.rep("q", 900)) .. END):sub(1, BLOCK + 100)
    local entries = tar.parse(cut)
    eq(#entries, 1, "the entry is still reported")
    eq(#entries[1].data, 100, "with whatever bytes were there")
  end)

  it("reads the committed fixture tarball", function()
    local entries = tar.parse(tar.read_file(vim.fn.getcwd() .. "/tests/fixtures/images.tar"))
    truthy(#entries >= 3, "two images and a text file")
  end)
end)

describe("tar.detect_type", function()
  it("recognises each image format by its magic bytes", function()
    local cases = {
      { "\137PNG\r\n\26\n" .. string.rep("\0", 8), "png", "image/png" },
      { "\255\216\255\224" .. string.rep("\0", 8), "jpg", "image/jpeg" },
      { "GIF87a" .. string.rep("\0", 8), "gif", "image/gif" },
      { "GIF89a" .. string.rep("\0", 8), "gif", "image/gif" },
      { "RIFF\0\0\0\0WEBPVP8 ", "webp", "image/webp" },
      { "BM" .. string.rep("\0", 20), "bmp", "image/bmp" },
      { '<svg xmlns="http://www.w3.org/2000/svg"/>', "svg", "image/svg+xml" },
      { '<?xml version="1.0"?><svg/>', "svg", "image/svg+xml" },
    }
    for _, case in ipairs(cases) do
      local ext, media = tar.detect_type(case[1])
      eq(ext, case[2], case[3])
      eq(media, case[3])
    end
  end)

  it("returns nil for anything that is not a picture", function()
    eq(tar.detect_type(""), nil)
    eq(tar.detect_type("just some text"), nil)
    eq(tar.detect_type("RIFF\0\0\0\0WAVEfmt "), nil, "RIFF but not WEBP")
    eq(tar.detect_type("PK\3\4" .. string.rep("\0", 20)), nil, "a zip is not a picture")
    eq(tar.detect_type("<html><body>denied</body></html>"), nil)
  end)
end)

describe("tar.read_file", function()
  it("returns the bytes of a file and nil for a missing one", function()
    local path = vim.fn.tempname()
    local file = assert(io.open(path, "wb"))
    file:write("a\0b\r\nc")
    file:close()
    eq(tar.read_file(path), "a\0b\r\nc", "binary safe")
    vim.fn.delete(path)
    eq(tar.read_file(path), nil)
  end)
end)
