--[[
Tests for the cookie jar: parsing round trip, and the atomic, private save that
protects the session credentials.
(cookie jar 的测试：解析往返，以及保护会话凭据的原子、私有写入)
]]

local cookies = require("weread.cookies")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local function sample()
  return {
    {
      domain = ".weread.qq.com",
      include_subdomains = true,
      path = "/",
      secure = true,
      expires = 1900000000,
      name = "wr_skey",
      value = "abc",
      http_only = true,
    },
    { domain = "weread.qq.com", path = "/", expires = 0, name = "wr_ql", value = "0" },
  }
end

describe("cookies parse/serialize", function()
  it("round-trips the HttpOnly prefix and the fields", function()
    local parsed = cookies.parse(cookies.serialize(sample()))
    eq(#parsed, 2)
    eq(parsed[1].name, "wr_skey")
    eq(parsed[1].http_only, true)
    eq(parsed[1].expires, 1900000000)
    eq(parsed[2].value, "0")
  end)

  it("ignores comments and short lines", function()
    local parsed = cookies.parse("# Netscape HTTP Cookie File\n\nnot\ta\tcookie\n")
    eq(#parsed, 0)
  end)
end)

describe("cookies.save", function()
  it("writes the jar with mode 0600 and loads it back", function()
    local path = root .. "/jar.txt"
    local ok, err = cookies.save(path, sample())
    eq(ok, true, tostring(err))
    eq(vim.fn.getfperm(path), "rw-------")
    local loaded = cookies.load(path)
    eq(#loaded, 2)
    eq(cookies.get(loaded, "wr_skey").value, "abc")
  end)

  it("leaves no temp file behind", function()
    local dir = root .. "/clean"
    vim.fn.mkdir(dir, "p")
    eq(cookies.save(dir .. "/jar.txt", sample()), true)
    local names = {}
    for name in vim.fs.dir(dir) do
      names[#names + 1] = name
    end
    eq(names, { "jar.txt" })
  end)

  it("replaces an existing jar whole", function()
    local path = root .. "/replace.txt"
    cookies.save(path, sample())
    cookies.save(path, { sample()[2] })
    local loaded = cookies.load(path)
    eq(#loaded, 1)
    eq(loaded[1].name, "wr_ql")
  end)

  it("returns the error instead of raising when the directory is missing", function()
    local ok, err
    local raised = pcall(function()
      ok, err = cookies.save(root .. "/no-such-dir/jar.txt", sample())
    end)
    truthy(raised, "cookies.save must not raise")
    eq(ok, nil)
    truthy(err and err ~= "", "and says why")
  end)

  it("keeps the old jar when a write fails", function()
    if vim.env.USER == "root" then
      return -- root ignores directory permissions(root 不受目录权限约束)
    end
    local dir = root .. "/readonly"
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/jar.txt"
    eq(cookies.save(path, sample()), true)

    vim.uv.fs_chmod(dir, 360) -- 0550
    local ok, err = cookies.save(path, {})
    vim.uv.fs_chmod(dir, 493) -- 0755

    eq(ok, nil)
    truthy(err)
    eq(#cookies.load(path), 2, "the previous jar is intact")
  end)
end)
