--[[
Tests for weread.cookies: the Netscape jar round-trip matters because curl
owns the file and we only ever append the credentials that WeRead returns in
its JSON payloads instead of Set-Cookie headers.
(cookies 单测：jar 的往返一致性很关键，因为文件由 curl 维护，而我们只会往里补写
 微信读书用 JSON 返回、而非 Set-Cookie 下发的凭据)
]]

local cookies = require("weread.cookies")

describe("cookies.parse_line", function()
  it("parses a plain cookie line", function()
    local cookie = cookies.parse_line(".weread.qq.com\tTRUE\t/\tTRUE\t1780666397\twr_vid\t123")
    eq(cookie.domain, ".weread.qq.com")
    eq(cookie.include_subdomains, true)
    eq(cookie.path, "/")
    eq(cookie.secure, true)
    eq(cookie.expires, 1780666397)
    eq(cookie.name, "wr_vid")
    eq(cookie.value, "123")
    eq(cookie.http_only, false)
  end)

  it("parses curl's HttpOnly prefix", function()
    local cookie = cookies.parse_line("#HttpOnly_.weread.qq.com\tTRUE\t/\tTRUE\t0\twr_skey\tabc")
    eq(cookie.http_only, true)
    eq(cookie.domain, ".weread.qq.com")
    eq(cookie.name, "wr_skey")
    eq(cookie.value, "abc")
    eq(cookie.expires, 0, "session cookie")
  end)

  it("keeps empty values and unnamed fields", function()
    local cookie = cookies.parse_line(".weread.qq.com\tTRUE\t/\tFALSE\t0\twr_ql\t")
    eq(cookie.name, "wr_ql")
    eq(cookie.value, "")
    eq(cookie.secure, false)
  end)

  it("rejects comments and malformed lines", function()
    eq(cookies.parse_line("# Netscape HTTP Cookie File"), nil)
    eq(cookies.parse_line(""), nil)
    eq(cookies.parse_line(".weread.qq.com\tTRUE\t/"), nil)
    eq(cookies.parse_line(nil), nil)
  end)
end)

describe("cookies round trip", function()
  it("survives parse(format(parse(x)))", function()
    local text = table.concat({
      "# Netscape HTTP Cookie File",
      ".weread.qq.com\tTRUE\t/\tTRUE\t1780666397\twr_vid\tvid-value",
      "#HttpOnly_.weread.qq.com\tTRUE\t/\tTRUE\t0\twr_skey\tskey-value",
    }, "\n") .. "\n"

    local parsed = cookies.parse(text)
    eq(#parsed, 2, "two cookies")
    local again = cookies.parse(cookies.serialize(parsed))
    eq(#again, 2)
    eq(again[1].name, "wr_vid")
    eq(again[1].value, "vid-value")
    eq(again[1].expires, 1780666397)
    eq(again[2].http_only, true)
    eq(again[2].value, "skey-value")
  end)

  it("tolerates CRLF and a missing trailing newline", function()
    local parsed = cookies.parse(".weread.qq.com\tTRUE\t/\tFALSE\t0\twr_ql\t0\r\n")
    eq(#parsed, 1)
    eq(parsed[1].value, "0")
  end)
end)

describe("cookies.upsert", function()
  it("replaces by name+domain+path and appends new cookies", function()
    local jar = {
      { name = "wr_skey", domain = ".weread.qq.com", path = "/", value = "old", expires = 0 },
    }
    jar = cookies.upsert(jar, { name = "wr_skey", domain = ".weread.qq.com", path = "/", value = "new", expires = 0 })
    eq(#jar, 1, "no duplicate")
    eq(jar[1].value, "new")

    jar = cookies.upsert(jar, { name = "wr_vid", domain = ".weread.qq.com", path = "/", value = "v", expires = 0 })
    eq(#jar, 2)
  end)

  it("treats a missing path as /", function()
    local jar = { { name = "wr_rt", domain = ".weread.qq.com", value = "a" } }
    jar = cookies.upsert(jar, { name = "wr_rt", domain = ".weread.qq.com", path = "/", value = "b" })
    eq(#jar, 1)
    eq(jar[1].value, "b")
  end)
end)

describe("cookies.header", function()
  it("joins live cookies and skips expired ones", function()
    local jar = {
      { name = "a", value = "1", expires = 0 },
      { name = "b", value = "2", expires = 1 },
      { name = "c", value = "3", expires = 4102444800 },
    }
    eq(cookies.header(jar, 1780666397), "a=1; c=3")
  end)

  it("returns an empty string for an empty jar", function()
    eq(cookies.header({}), "")
    eq(cookies.header(nil), "")
  end)
end)

describe("cookies.remove", function()
  it("drops every cookie with the requested name", function()
    local jar = {
      { name = "wr_skey", value = "1" },
      { name = "wr_vid", value = "2" },
      { name = "wr_skey", value = "3" },
    }
    local kept = cookies.remove(jar, "wr_skey")
    eq(#kept, 1)
    eq(kept[1].name, "wr_vid")
  end)
end)
