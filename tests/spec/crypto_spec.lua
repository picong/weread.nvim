--[[
Tests for weread.crypto. Vectors come from coreutils `md5sum`/`sha256sum`
ground truth, not from this implementation.
(crypto 单测；向量取自 coreutils 的 md5sum/sha256sum，而非本实现自身)
]]

local Crypto = require("weread.crypto")

describe("crypto.md5_hex", function()
  it("matches standard vectors", function()
    eq(Crypto.md5_hex(""), "d41d8cd98f00b204e9800998ecf8427e", "empty")
    eq(Crypto.md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72", "abc")
    eq(
      Crypto.md5_hex("The quick brown fox jumps over the lazy dog"),
      "9e107d9d372bb6826bd81d3542a419d6",
      "pangram"
    )
  end)

  it("handles padding block boundaries", function()
    eq(Crypto.md5_hex(string.rep("a", 55)), "ef1772b6dff9a122358552954ad0df65", "55 bytes")
    eq(Crypto.md5_hex(string.rep("a", 56)), "3b0c8ac703f828b04c6c197006d17218", "56 bytes")
    eq(Crypto.md5_hex(string.rep("a", 64)), "014842d480b571495a4a0363793f7367", "64 bytes")
  end)

  it("handles long input across many blocks", function()
    eq(Crypto.md5_hex(string.rep("a", 1000)), "cabe45dcc9ae5b66ba86600cca6b8ba8", "1000 bytes")
  end)

  it("treats input as raw bytes", function()
    eq(Crypto.md5_hex("微信读书 weread 测试"), "00d8c89c8ebf9d3de11bc20d775609fa", "utf-8")
    -- Contains a NUL byte and 0xff; the expected digest was cross-checked
    -- against python hashlib over the exact same byte sequence.
    -- (含 NUL 与 0xff 的字节串；期望值与 python hashlib 对同一字节序列的结果交叉验证过)
    eq(Crypto.md5_hex("中\0binary\255"), "663ad3dc51bd1df14dd59ea216872eaa", "binary")
  end)

  it("accepts non-string input defensively", function()
    eq(Crypto.md5_hex(nil), "d41d8cd98f00b204e9800998ecf8427e", "nil becomes empty")
    eq(Crypto.md5_hex(42), Crypto.md5_hex("42"), "numbers are stringified")
  end)
end)

describe("crypto.sha256_hex", function()
  it("matches standard vectors", function()
    eq(
      Crypto.sha256_hex("abc"),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      "abc"
    )
    eq(
      Crypto.sha256_hex(""),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "empty"
    )
  end)
end)
