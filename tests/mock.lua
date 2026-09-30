--[[
Shared mock WeRead server for the integration specs.

Everything the reader and content pipelines need, served from committed
fixtures that were produced by upstream's *python* encoder, so the Lua side is
never checked against itself.
(集成测试共用的 mock 微信读书服务：全部数据来自上游 python 编码器生成的夹具，
 避免 Lua 侧自证)

Note for spec authors: route handlers run inside a libuv callback (a fast event
context), where `vim.fn.*` raises E5560. Read fixtures at file scope.
(给写 spec 的人：路由处理器运行在 libuv 回调里（fast event context），vim.fn.*
 会报 E5560，请把夹具读取放在文件作用域)
]]

local M = {}

-- Fixtures live next to this helper, not relative to the cwd: the helper is
-- also loaded from specs that run with a different working directory.
-- (夹具就在本文件旁边，而不是相对 cwd：本辅助模块也会被工作目录不同的脚本加载)
local FIXTURES = (function()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(source) .. "/fixtures"
end)()

---@param name string
---@return string
function M.fixture_text(name)
  return table.concat(vim.fn.readfile(FIXTURES .. "/" .. name), "\n")
end

---@param name string
---@return string
function M.fixture_bytes(name)
  local file = assert(io.open(FIXTURES .. "/" .. name, "rb"))
  local data = file:read("*a")
  file:close()
  return data
end

---@return table
function M.shards()
  return vim.json.decode(M.fixture_text("shards.json"))
end

---Start a tiny HTTP/1.1 server.
---@param routes table[] ordered { path = "<substring>", handler = fun(method, path, body, headers) }
---@return table server { port, url, requests, stop, reset }
function M.start(routes)
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
    url = "http://127.0.0.1:" .. port,
    requests = requests,
    reset = function()
      for index = #requests, 1, -1 do
        requests[index] = nil
      end
    end,
    stop = function()
      pcall(function()
        server:close()
      end)
    end,
  }
end

---Verify that the signature in a request body covers exactly those bytes.
---(校验请求体里的签名恰好覆盖实际发送的字节)
---@param body string
---@return boolean
---@return string
function M.signature_is_valid(body)
  local protocol = require("weread.protocol")
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

---The full WeRead route table used by the reader + content specs.
---@param ref table whose `url` is filled in after the server starts (the
---   catalog fixture carries a {{BASE}} placeholder that must resolve to the
---   real port, which only exists after binding)
---   (ref.url 在服务启动后填入：目录夹具里的 {{BASE}} 必须解析成真实端口，
---   而端口只有 bind 之后才知道)
---@return table[] routes
function M.weread_routes(ref)
  local shards = M.shards()
  local reader_html = M.fixture_text("reader.html")
  local catalog = M.fixture_text("catalog.json")
  local tar = M.fixture_bytes("images.tar")

  return {
    {
      path = "/web/reader/",
      handler = function()
        return { status = 200, ctype = "text/html", body = reader_html }
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
        return { status = 200, ctype = "application/json", body = catalog:gsub("{{BASE}}", ref.url) }
      end,
    },
    {
      path = "/web/book/chapter/e_0",
      handler = function(_, _, body)
        local ok, err = M.signature_is_valid(body)
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
        return { status = 200, ctype = "application/octet-stream", body = tar }
      end,
    },
  }
end

return M
