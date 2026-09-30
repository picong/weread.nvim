--[[
End-to-end test of the content pipeline against a local mock WeRead server.

What this covers that unit tests cannot: real curl processes, the real cookie
jar, the real request shapes (including the signature covering exactly the
bytes that were transmitted), shard decoding of independently encoded
fixtures, tar unpacking, image sniffing, url rewriting and cache writes.
(用本地 mock 服务器做内容流水线端到端测试：真实 curl 进程、真实 cookie jar、
 真实请求体（含签名必须覆盖实际发送的字节）、独立编码的夹具解码、tar 解包、
 图片嗅探、URL 改写与缓存落盘)
]]

local cache = require("weread.cache")
local config = require("weread.config")
local content = require("weread.content")
local http = require("weread.http")
local log = require("weread.log")
local protocol = require("weread.protocol")

local FIXTURES = vim.fn.getcwd() .. "/tests/fixtures"

local function fixture_text(name)
  return table.concat(vim.fn.readfile(FIXTURES .. "/" .. name), "\n")
end

local function fixture_bytes(name)
  local file = io.open(FIXTURES .. "/" .. name, "rb")
  local data = file:read("*a")
  file:close()
  return data
end

local shards = vim.json.decode(fixture_text("shards.json"))

-- Fixtures are read once, on the main loop. Doing it inside a route handler
-- would run in a libuv callback, where `vim.fn.readfile` raises E5560.
-- (夹具只在主循环里读一次；在路由处理器里读会跑进 libuv 回调，vim.fn.readfile 会报 E5560)
local FIXTURE = {
  reader = fixture_text("reader.html"),
  catalog = fixture_text("catalog.json"),
  tar = fixture_bytes("images.tar"),
}

-- ------------------------------------------------------------------ mock

---Start a tiny HTTP/1.1 server. `routes` is an ordered list of
---{ path = "<substring>", handler = fun(method, path, body, headers) }.
---(启动一个极小的 HTTP/1.1 服务；routes 为按顺序匹配的路由表)
---@param routes table[]
---@return table server { port, requests, stop }
local function start_mock(routes)
  local server = vim.uv.new_tcp()
  assert(server:bind("127.0.0.1", 0), "could not bind the mock server")
  local port = server:getsockname().port
  local requests = {}

  server:listen(128, function(listen_err)
    if listen_err then
      return
    end
    local client = vim.uv.new_tcp()
    server:accept(client)
    local chunks = {}

    client:read_start(function(read_err, data)
      if read_err or not data then
        pcall(function()
          client:close()
        end)
        return
      end
      chunks[#chunks + 1] = data
      local raw = table.concat(chunks)
      local header_end = raw:find("\r\n\r\n", 1, true)
      if not header_end then
        return
      end

      local head = raw:sub(1, header_end - 1)
      local body = raw:sub(header_end + 4)
      local length = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
      if #body < length then
        return -- keep reading the body (继续读 body)
      end
      client:read_stop()

      local method, path = head:match("^(%u+)%s+(%S+)")
      path = (path or ""):gsub("%?.*$", "")
      body = body:sub(1, length)
      requests[#requests + 1] = { method = method, path = path, body = body, headers = head }

      local response = { status = 404, ctype = "text/plain", body = "not found" }
      for _, route in ipairs(routes) do
        if path:find(route.path, 1, true) then
          response = route.handler(method, path, body, head) or response
          break
        end
      end

      local payload = table.concat({
        "HTTP/1.1 " .. tostring(response.status),
        "Content-Type: " .. response.ctype,
        "Content-Length: " .. #response.body,
        "Connection: close",
        "",
        response.body,
      }, "\r\n")

      client:write(payload, function()
        pcall(function()
          client:close()
        end)
      end)
    end)
  end)

  return {
    port = port,
    requests = requests,
    url = "http://127.0.0.1:" .. port,
    stop = function()
      pcall(function()
        server:close()
      end)
    end,
  }
end

---@param body string
---@return boolean
---@return string
local function signature_is_valid(body)
  local ok, params = pcall(vim.json.decode, body)
  if not ok or type(params) ~= "table" then
    return false, "body is not JSON"
  end
  local claimed = params.s
  if type(claimed) ~= "string" or claimed == "" then
    return false, "no signature in the request body"
  end
  local expected = protocol.sign(protocol.sorted_query(params))
  if expected ~= claimed then
    return false, string.format("signature mismatch: sent %s, expected %s", claimed, expected)
  end
  return true, ""
end

---Run an async function and block until its callback fires.
---(运行异步函数并阻塞到回调触发)
---@param runner fun(callback: function)
---@return any
local unpack_values = table.unpack or unpack
local function await(runner, timeout)
  local captured = nil
  local done = false
  runner(function(...)
    captured = { n = select("#", ...), ... }
    done = true
  end)
  vim.wait(timeout or 15000, function()
    return done
  end, 20)
  if not captured then
    error("timed out waiting for the callback")
  end
  return unpack_values(captured, 1, captured.n)
end

-- ------------------------------------------------------------------ setup

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

-- Declare first, assign second: the route handlers below capture `mock` as an
-- upvalue, and a local only enters scope after its declaration statement.
-- (先声明再赋值：下面的路由处理器把 mock 当上值捕获，而局部变量的作用域始于其声明
--  语句之后)
local mock
mock = start_mock({
  {
    path = "/web/reader/",
    handler = function()
      return { status = 200, ctype = "text/html", body = FIXTURE.reader }
    end,
  },
  {
    path = "/web/book/chapterInfos",
    handler = function(method, _, body)
      if method ~= "POST" then
        return { status = 405, ctype = "text/plain", body = "POST only" }
      end
      if not body:find("43208843", 1, true) then
        return { status = 400, ctype = "text/plain", body = "missing bookIds" }
      end
      -- {{BASE}} resolves to whatever port the mock ended up on
      -- ({{BASE}} 解析为 mock 实际监听的地址)
      return { status = 200, ctype = "application/json", body = FIXTURE.catalog:gsub("{{BASE}}", mock.url) }
    end
  },
  {
    path = "/web/book/chapter/e_0",
    handler = function(_, _, body)
      local ok, err = signature_is_valid(body)
      if not ok then
        return { status = 400, ctype = "text/plain", body = "bad signature: " .. err }
      end
      return { status = 200, ctype = "text/plain", body = shards.xhtml.shards[1] }
    end,
  },
  {
    path = "/web/book/chapter/e_1",
    handler = function()
      return { status = 200, ctype = "text/plain", body = shards.xhtml.shards[2] }
    end,
  },
  {
    path = "/web/book/chapter/e_3",
    handler = function()
      return { status = 200, ctype = "text/plain", body = shards.xhtml.shards[3] }
    end,
  },
  {
    path = "/web/book/chapter/e_2",
    handler = function(_, _, body)
      local params = vim.json.decode(body)
      if params.st ~= 1 then
        return { status = 400, ctype = "text/plain", body = "the css shard needs st=1" }
      end
      return { status = 200, ctype = "text/plain", body = shards.css.shards[1] }
    end,
  },
  {
    path = "/wrco/tar_",
    handler = function()
      return { status = 200, ctype = "application/octet-stream", body = FIXTURE.tar }
    end,
  },
  {
    path = "/web/book/chapterInfos",
    handler = function()
      return { status = 500, ctype = "text/plain", body = "unreachable" }
    end,
  },
})

config.setup({ data_dir = tmpdir, base_url = mock.url, proxy = "direct" })
config.ensure_dirs()
http.setup({ jar = config.path("cookies.txt"), tmpdir = config.path("tmp"), timeout = 8, retries = 0, proxy = "direct" })
log.setup({ debug = true, path = config.path("weread.log") })

-- A logged-in jar, so the requests look like a real session.
http.set_cookies({
  { name = "wr_vid", value = "vid", domain = ".weread.qq.com", path = "/", expires = 0, include_subdomains = true },
  { name = "wr_skey", value = "skey", domain = ".weread.qq.com", path = "/", expires = 0, include_subdomains = true },
})

local BOOK_ID = "43208843"
local CHAPTER = { chapterUid = 2, chapterIdx = 2, title = "第 3 章 宇宙闪烁", tar = nil }

describe("content pipeline against a mock server", function()
  it("fetches the reader state", function()
    local ok, state = await(function(cb)
      content.fetch_reader_state(BOOK_ID, nil, cb)
    end)
    truthy(ok, tostring(state))
    eq(state.psvts, "9a1b2c3d4e5f60718293a4b5c6d7e8f0")
    eq(state.book_id, BOOK_ID)
    eq(state.title, "持续交付2.0")
  end)

  it("fetches and normalizes the catalog", function()
    local ok, record = await(function(cb)
      content.fetch_catalog(BOOK_ID, cb)
    end)
    truthy(ok, tostring(record))
    eq(#record.chapters, 3)
    eq(record.format, "epub")
    CHAPTER.tar = record.chapters[2].tar
    truthy(CHAPTER.tar:find(mock.url, 1, true), "the tar url points at the mock")
  end)

  it("fetches and decodes a chapter, verifying the signature server side", function()
    local book = { book_id = BOOK_ID, chapter_uid = "2", psvts = "9a1b2c3d4e5f60718293a4b5c6d7e8f0" }
    local ok, result = await(function(cb)
      content.fetch_chapter(book, cb)
    end, 20000)

    truthy(ok, tostring(result))
    eq(result.format, "epub")
    eq(result.xhtml, shards.xhtml.plain, "decoded XHTML matches the independent encoder")
    eq(result.css, shards.css.plain, "stylesheet shard decoded too")

    -- The mock rejected anything whose signature did not cover the very bytes
    -- that were sent, so a 200 here proves the request shape is self-consistent.
    -- (mock 会拒绝签名与实际发送字节不一致的请求，因此 200 即证明请求体自洽)
    local shard_requests = 0
    for _, request in ipairs(mock.requests) do
      if request.path:find("/chapter/e_", 1, true) then
        shard_requests = shard_requests + 1
        local params = vim.json.decode(request.body)
        eq(params.ps, "9a1b2c3d4e5f60718293a4b5c6d7e8f0", "psvts carried")
        eq(params.prevChapter, false, "prevChapter is a JS false")
        eq(params.pc, protocol.e(params.ct), "pc is derived from ct")
      end
    end
    eq(shard_requests, 4, "e_0, e_1, e_3 and e_2")
  end)

  it("surfaces a WeRead error payload instead of an empty chapter", function()
    -- A revoked session answers the EPUB shard with an errCode payload rather
    -- than a shard, which must not be mistaken for a TXT-format book.
    -- (会话失效时 EPUB 分片会返回 errCode 负载而不是分片数据，不能误判成 TXT 型书籍)
    local denied = start_mock({
      {
        path = "/web/book/chapter/e_0",
        handler = function()
          return { status = 200, ctype = "application/json", body = '{"errCode":-2012,"errMsg":"登录超时"}' }
        end,
      },
    })
    local previous = config.get().base_url
    config.setup({ data_dir = tmpdir, base_url = denied.url, proxy = "direct" })

    local book = { book_id = BOOK_ID, chapter_uid = "2", psvts = "x" }
    local ok, message = await(function(cb)
      content.fetch_chapter(book, cb)
    end)
    config.setup({ data_dir = tmpdir, base_url = previous, proxy = "direct" })
    denied.stop()

    falsy(ok, "the fetch must fail")
    matches(message, "登录已过期")
  end)

  it("downloads, unpacks and sniffs the chapter images", function()
    local book = { book_id = BOOK_ID, chapter_uid = "2", psvts = "psvts" }
    local ok, result = await(function(cb)
      content.fetch_assets(book, CHAPTER, cb)
    end, 20000)
    truthy(ok, tostring(result))
    eq(#result.images, 2, "png + jpg, the text file is skipped")

    local by_id = {}
    for _, image in ipairs(result.images) do
      by_id[image.id] = image
    end
    eq(by_id["epub_43208843_44"].ext, "png")
    eq(by_id["epub_43208843_44"].data:sub(1, 8), "\137PNG\r\n\26\n")
    eq(by_id["epub_43208843_45"].ext, "jpg")
  end)

  it("writes the chapter and its assets into the cache", function()
    local book = { book_id = BOOK_ID, chapter_uid = "2", psvts = "9a1b2c3d4e5f60718293a4b5c6d7e8f0" }
    cache.ensure_book_dirs(BOOK_ID)

    local _, chapter = await(function(cb)
      content.fetch_chapter(book, cb)
    end, 20000)
    local _, assets = await(function(cb)
      content.fetch_assets(book, CHAPTER, cb)
    end, 20000)

    local id_to_path = {}
    for _, image in ipairs(assets.images) do
      local path = cache.assets_dir(BOOK_ID) .. "/" .. image.id .. "." .. image.ext
      local wrote = cache.write(path, image.data)
      truthy(wrote, "wrote " .. path)
      id_to_path[image.id] = path
    end

    local rewritten, replaced, missing = content.rewrite_image_sources(chapter.xhtml, id_to_path)
    eq(replaced, 2)
    eq(missing, 0)

    local html_path = cache.chapter_file(BOOK_ID, CHAPTER, "xhtml")
    local md_path = cache.chapter_file(BOOK_ID, CHAPTER, "md")
    truthy(cache.write(html_path, chapter.xhtml))
    truthy(cache.write(md_path, rewritten))
    truthy(cache.write(cache.book_file(BOOK_ID, "catalog.json"), vim.json.encode({ ok = true })))

    eq(vim.fn.filereadable(html_path), 1, "source XHTML cached")
    eq(vim.fn.filereadable(md_path), 1, "rendered body cached")
    eq(vim.fn.filereadable(id_to_path["epub_43208843_44"]), 1, "image cached")
    truthy(vim.fn.getfsize(id_to_path["epub_43208843_44"]) > 0)

    local rewritten_on_disk = cache.read(md_path)
    truthy(rewritten_on_disk:find(id_to_path["epub_43208843_44"], 1, true), "markdown points at the local file")
    falsy(rewritten_on_disk:find("res.weread.qq.com", 1, true), "no remote image urls left")

    truthy(cache.book_cache_size(BOOK_ID) > 0, "cache size is reported")

    -- The temp tarball must not be left behind (下载用的临时 tar 必须清理干净)
    local leftovers = vim.fn.glob(config.path("tmp", "chapter-*.tar"), false, true)
    eq(#leftovers, 0, "no leftover tarballs")
  end)

  it("maps a WeRead error payload into an actionable message", function()
    local failing = start_mock({
      {
        path = "/web/book/chapterInfos",
        handler = function()
          return { status = 200, ctype = "application/json", body = '{"errCode":-2012,"errMsg":"登录超时"}' }
        end,
      },
    })
    local previous = config.get().base_url
    config.setup({ data_dir = tmpdir, base_url = failing.url, proxy = "direct" })

    local ok, message = await(function(cb)
      content.fetch_catalog(BOOK_ID, cb)
    end)
    config.setup({ data_dir = tmpdir, base_url = previous, proxy = "direct" })

    falsy(ok)
    matches(message, "登录已过期")
    failing.stop()
  end)
end)
