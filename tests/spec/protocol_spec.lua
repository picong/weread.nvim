--[[
Tests for weread.protocol.

The `_e()` and `web_app_id()` vectors are ground truth observed from the
WeRead web front end (see plans/weread-nvim.md). The `sign()` vectors were
produced by an independent Python transcription of the algorithm that
upstream weread.koplugin ships and uses in production; note that the
prose pseudo-code in the upstream API reference is subtly different and
does NOT reproduce these values, so these vectors are the trustworthy ones.
(向量取证：_e()/web_app_id() 来自微信读书前端实测；sign() 由上游生产可用实现的
 独立 Python 转写产出。上游文档里的伪码与此不一致，故以实测向量为准。)
]]

local P = require("weread.protocol")

local EDGE_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0"

describe("protocol.e", function()
  it("matches observed front-end hashes", function()
    eq(P.e("43208843"), "c9c321c07293508bc9c79df", "book id")
    eq(P.e("2"), "c81322c012c81e728d9d180", "small chapter uid")
    eq(P.e("119"), "07e323f027707e1cd7dc674", "chapter uid")
  end)

  it("is stable for numbers and numeric strings", function()
    eq(P.e(43208843), P.e("43208843"), "number vs string")
  end)

  it("handles non-numeric input with the byte path", function()
    local encoded = P.e("MP_WXS_3286016687")
    eq(type(encoded), "string", "returns a string")
    truthy(#encoded >= 20, "at least 20 chars")
    eq(encoded, P.e("MP_WXS_3286016687"), "stable")
  end)
end)

describe("protocol.web_app_id", function()
  it("reproduces the observed Edge value", function()
    eq(P.web_app_id(EDGE_UA), "wb115321887466h529830856")
    eq(P.web_app_id(), "wb115321887466h529830856", "default UA matches the same value")
  end)
end)

describe("protocol.urlencode", function()
  it("follows encodeURIComponent spelling", function()
    eq(P.urlencode(true), "true")
    eq(P.urlencode(false), "false")
    eq(P.urlencode(nil), "null")
    eq(P.urlencode("a b"), "a%20b")
    eq(P.urlencode("/web/book/read"), "%2Fweb%2Fbook%2Fread")
    eq(P.urlencode("a=1&b=2"), "a%3D1%26b%3D2")
  end)

  it("leaves unreserved characters untouched", function()
    eq(P.urlencode("aZ0-_.~"), "aZ0-_.~")
  end)
end)

describe("protocol.sorted_query", function()
  it("sorts keys and skips the signature field", function()
    eq(P.sorted_query({ sc = 1, b = "x", s = "ignored" }), "b=x&sc=1")
  end)

  it("uses javascript boolean spelling", function()
    eq(P.sorted_query({ prevChapter = false, st = 0 }), "prevChapter=false&st=0")
  end)
end)

describe("protocol.sign", function()
  it("matches production vectors", function()
    eq(P.sign("a=1"), "2a0a2b58", "a=1")
    eq(P.sign("hello"), "2a0a290c", "hello")
    eq(P.sign("sc=1&st=1"), "2a0a42e0", "sc/st")
    eq(
      P.sign("b=c9c321c07293508bc9c79df&c=c81322c012c81e728d9d180&ct=1780666397&pc=c9c321c07293508b&prevChapter=false&ps=abc&r=25&sc=1&st=0"),
      "70f878cb",
      "realistic content query"
    )
    eq(
      P.sign("b=x&c=y&ct=1&pc=z&prevChapter=false&ps=p&r=4&sc=1&st=1"),
      "6cbe6494",
      "second realistic query"
    )
  end)

  it("is order independent because callers sort first", function()
    local a = P.sign(P.sorted_query({ b = "x", sc = 1, st = 0 }))
    local b = P.sign(P.sorted_query({ st = 0, sc = 1, b = "x" }))
    eq(a, b)
  end)
end)

describe("protocol.make_content_params", function()
  it("signs the body and derives pc from ct", function()
    local params = P.make_content_params("43208843", "2", "psvts-value", { ct = 1780666397 })
    eq(params.b, P.e("43208843"))
    eq(params.c, P.e("2"))
    eq(params.ct, "1780666397")
    eq(params.pc, P.e("1780666397"))
    eq(params.ps, "psvts-value")
    eq(params.sc, 1)
    eq(params.st, 0)
    eq(params.prevChapter, false)
    eq(params.s, P.sign(P.sorted_query(params)))
  end)

  it("bumps ct when _e(ct) would collide with psvts", function()
    local ct = 1780666397
    local params = P.make_content_params("43208843", "2", P.e(ct), { ct = ct })
    eq(params.ct, tostring(ct + 1))
    eq(params.pc, P.e(ct + 1))
  end)

  it("requests the stylesheet shard with st=1", function()
    local params = P.make_content_params("43208843", "2", "p", { ct = 1780666397, style = true })
    eq(params.st, 1)
    eq(params.s, P.sign(P.sorted_query(params)))
  end)

  it("honours an explicit sc override", function()
    local params = P.make_content_params("1", "2", "p", { ct = 1780666397, sc = 0 })
    eq(params.sc, 0)
  end)
end)

describe("protocol.reader_url", function()
  it("builds the reader url from hashed ids", function()
    eq(P.reader_url("43208843"), "https://weread.qq.com/web/reader/c9c321c07293508bc9c79df")
    eq(
      P.reader_url("43208843", "2"),
      "https://weread.qq.com/web/reader/c9c321c07293508bc9c79dfkc81322c012c81e728d9d180"
    )
  end)

  it("has a dedicated mp reader path", function()
    eq(P.mp_reader_url("MP_WXS_1"), "https://weread.qq.com/web/mp/reader/" .. P.e("MP_WXS_1"))
  end)
end)

describe("protocol.make_read_payload", function()
  -- Default options for a read report. Tests clone this table so that a
  -- field can be overridden or genuinely removed (a nil override inside a
  -- table literal is indistinguishable from an absent key in Lua).
  -- (上报默认参数；测试克隆此表以便覆盖或真正删除字段——Lua 表字面量里的
  --  nil 覆盖等价于键不存在，直接传 nil 覆盖不掉字段)
  local function read_opts()
    return {
      book_id = "43208843",
      chapter_uid = "2",
      chapter_idx = 1,
      chapter_offset = 10,
      progress = 3,
      summary = "这是一段中文摘要，用于验证字符截断不会切坏多字节字符",
      psvts = "psvts-value",
      pclts = "pclts-value",
      now = 1780666397,
      ts = 1780666397000,
      rn = 123,
      elapsed_seconds = 30,
    }
  end

  local function payload(overrides, drop)
    local opts = read_opts()
    for key, value in pairs(overrides or {}) do
      opts[key] = value
    end
    for _, key in ipairs(drop or {}) do
      opts[key] = nil
    end
    return P.make_read_payload(opts)
  end

  it("produces a signed payload with every required field", function()
    local params = payload()
    eq(params.b, P.e("43208843"))
    eq(params.c, P.e("2"))
    eq(params.ci, 1)
    eq(params.co, 10)
    eq(params.pr, 3)
    eq(params.rt, 30)
    eq(params.ts, 1780666397000)
    eq(params.rn, 123)
    eq(params.ct, 1780666397)
    eq(params.ps, "psvts-value")
    eq(params.pc, "pclts-value")
    eq(params.sg, require("weread.crypto").sha256_hex("1780666397000" .. "123" .. P.DEFAULT_READER_TOKEN))
    eq(params.s, P.sign(P.sorted_query(params)))
  end)

  it("truncates the summary to 20 characters without splitting utf-8", function()
    local params = payload()
    eq(vim.fn.strchars(params.sm), 20)
    truthy(vim.fn.strchars(params.sm) <= vim.fn.strchars("这是一段中文摘要，用于验证字符截断不会切坏多字节字符"))
  end)

  it("falls back to _e(ct) when pclts is unusable", function()
    eq(payload(nil, { "pclts" }).pc, P.e(1780666397), "absent")
    eq(payload({ pclts = "" }).pc, P.e(1780666397), "empty")
    eq(payload({ pclts = "0" }).pc, P.e(1780666397), "zero")
  end)

  it("clamps progress into 0..100", function()
    eq(payload({ progress = -5 }).pr, 0)
    eq(payload({ progress = 999 }).pr, 100)
  end)
end)

describe("protocol helpers", function()
  it("detects mp books", function()
    truthy(P.is_mp_book("MP_WXS_3286016687"))
    falsy(P.is_mp_book("43208843"))
    falsy(P.is_mp_book(nil))
  end)

  it("upgrades cover urls to the high resolution token", function()
    eq(
      P.normalize_cover_url("https://cdn.weread.qq.com/wrcover/t3_abc"),
      "https://cdn.weread.qq.com/wrcover/t9_abc"
    )
  end)
end)
