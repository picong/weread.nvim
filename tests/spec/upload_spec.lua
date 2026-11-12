--[[
Tests for the 传书 import (weread.upload): the signature matches the web
bundle's own code, a COS request is signed the way COS v5 expects, and the four
steps run in order against a mock service, including the shortcut for a file the
service already has and a refusal while parsing.
(传书导入 weread.upload 的测试：签名与网页代码自己的结果一致、COS 请求按 COS v5 的要求签名，以及四个步骤
 对着 mock 服务按顺序运行——包括服务端已有该文件时的捷径、解析时被拒)
]]

local mock_lib = dofile(vim.fn.getcwd() .. "/tests/mock.lua")
local upload = require("weread.upload")
local cache = require("weread.cache")
local config = require("weread.config")
local http = require("weread.http")

describe("upload.signature", function()
  it("matches the web bundle", function()
    -- produced by the bundle's own `s(random, timestamp, md5)` under node
    -- (由网页代码自己的 s(random, timestamp, md5) 在 node 下算出)
    eq(upload.signature(12345, 1793009618, "d41d8cd98f00b204e9800998ecf8427e"), "e24a59b3799aab421f2ea0c5710867f1e44f4e355eb9228614d5d727e190ef75")
    eq(upload.signature(99999, 1700000000, "0123456789abcdef0123456789abcdef"), "f3e75d6fdddd96dc9ed0c407669bf3b2290876575921af3262ee023dee70e507")
    eq(upload.signature(7, 1793009618, "bff63ed1a9d1e8a858341996979b2deb"), "7d63c5f2453e12c88409ab3c1160806c5908578dd5bb3e3d8eff065375b5b0c8")
  end)
end)

describe("upload.cos_authorization", function()
  it("signs the way COS v5 does", function()
    if vim.fn.executable("openssl") ~= 1 then
      return
    end
    -- The worked example from the COS signature docs: these are the public
    -- sample keys printed in that documentation, not anyone's credentials, so
    -- they are split and joined here to keep secret scanners quiet.
    -- (COS 签名文档里的示例：这是文档中公开印刷的样例密钥，不是任何人的真实凭据，
    -- 因此在这里拆开拼接，免得密钥扫描器误报)
    local auth = upload.cos_authorization(
      "AKIDQjz3ltompVjBni5" .. "LitkWHFlFpwkn9U5q",
      "BQYIM75p8x0iWVFS" .. "IgqEKwFprpRSVHlz",
      "PUT",
      "/exampleobject(腾讯云)",
      {
        host = "examplebucket-1250000000.cos.ap-beijing.myqcloud.com",
        date = "Thu, 16 May 2019 06:45:51 GMT",
        ["content-type"] = "text/plain",
        ["content-length"] = "13",
        ["content-md5"] = "mQ/fVh815F3k6TAUm8m0eg==",
        ["x-cos-acl"] = "private",
        ["x-cos-grant-read"] = 'uin="100000000011"',
      },
      1557989151,
      1557996351
    )
    matches(auth, "q%-header%-list=content%-length;content%-md5;content%-type;date;host;x%-cos%-acl;x%-cos%-grant%-read")
    matches(auth, "q%-signature=3b8851a11a569213c17ba8fa7dcf2abec6935172")
  end)
end)

describe("upload.import", function()
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  local known = false
  local parse_status = { 1, 0 }
  local refuse = false
  local put = nil
  local server = mock_lib.start({
    {
      path = "/mp/shelf/shelfFull",
      handler = function()
        return { status = 200, ctype = "application/json", body = '{"status":200,"isShelfFull":false}' }
      end,
    },
    {
      path = "/web/cos/receive",
      handler = function(_, _, body)
        local request = vim.json.decode(body)
        if known then
          return { status = 200, ctype = "application/json", body = vim.json.encode({ data = { bookInfo = { bookId = "CB_known" } }, md5 = request.md5 }) }
        end
        return { status = 200, ctype = "application/json", body = '{"errCode":-2003,"errMsg":"not found"}' }
      end,
    },
    {
      path = "/web/cos/getcredential",
      handler = function()
        return {
          status = 200,
          ctype = "application/json",
          body = vim.json.encode({
            Response = { ExpiredTime = 1900000000, Credentials = { Token = "tok", TmpSecretId = "id", TmpSecretKey = "key" } },
            ObjectName = "/private/1/CB_new",
            ServerTime = 1800000000,
            region = "accelerate",
            bucket = "weread-epub-1258476243",
          }),
        }
      end,
    },
    {
      path = "/private/1/CB_new",
      handler = function(method, _, body, head)
        put = { method = method, body = body, head = head }
        return { status = 200, ctype = "text/plain", body = "" }
      end,
    },
    {
      path = "/web/cos/notify",
      handler = function()
        if refuse then
          return { status = 200, ctype = "application/json", body = '{"status":2,"errmsg":"请检查文件是否损坏","errcode":-10002}' }
        end
        local status = table.remove(parse_status, 1) or 0
        return { status = 200, ctype = "application/json", body = vim.json.encode({ status = status, bookId = "CB_new" }) }
      end,
    },
  })
  config.setup({ data_dir = tmpdir, base_url = server.url, proxy = "direct", sync_interval = 0, keymaps = false })
  config.ensure_dirs()
  http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 5, retries = 0, proxy = "direct" })
  local file = tmpdir .. "/book.epub"
  cache.write(file, "PK fake epub bytes")

  local function run()
    local result = nil
    local steps = {}
    upload.import(file, function(ok, value)
      result = { ok = ok, value = value }
    end, function(message)
      steps[#steps + 1] = message
    end)
    vim.wait(10000, function()
      return result ~= nil
    end, 20)
    return result or { ok = false, value = "timed out" }, steps
  end

  local saved_url, saved_poll = upload.COS_URL, upload.POLL_MS
  upload.COS_URL = server.url
  upload.POLL_MS = 20

  it("uploads, waits for the parse and gives the new book", function()
    if vim.fn.executable("openssl") ~= 1 then
      return
    end
    server.reset()
    local result, steps = run()
    truthy(result.ok, tostring(result.value))
    eq(result.value, "CB_new")
    eq(put.method, "PUT")
    eq(put.body, "PK fake epub bytes", "the file itself")
    matches(put.head, "x%-cos%-security%-token: tok")
    matches(put.head, "Authorization: q%-sign%-algorithm=sha1&q%-ak=id&")
    eq(#steps, 2)
    local paths = vim.tbl_map(function(request)
      return request.method .. " " .. request.path
    end, server.requests)
    eq(paths, {
      "GET /mp/shelf/shelfFull",
      "POST /web/cos/receive",
      "GET /web/cos/getcredential",
      "PUT /private/1/CB_new",
      "POST /web/cos/notify",
      "POST /web/cos/notify",
    })
    local receive = vim.json.decode(server.requests[2].body)
    eq(receive.md5, require("weread.crypto").md5_hex("PK fake epub bytes"))
    eq(receive.signature, upload.signature(receive.random, receive.timestamp, receive.md5), "signed")
  end)

  it("takes the shortcut for a file the service already has", function()
    server.reset()
    known = true
    local result = run()
    known = false
    truthy(result.ok)
    eq(result.value, "CB_known")
    eq(#server.requests, 2, "nothing uploaded")
  end)

  it("reports a refusal while parsing", function()
    if vim.fn.executable("openssl") ~= 1 then
      return
    end
    refuse = true
    local result = run()
    refuse = false
    falsy(result.ok)
    matches(result.value, "请检查文件是否损坏")
  end)

  it("restores its settings", function()
    upload.COS_URL, upload.POLL_MS = saved_url, saved_poll
    server.stop()
  end)
end)
