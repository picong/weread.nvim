--[[
Tests for the cache's file IO: atomic writes, permissions, and telling a missing
file from a corrupt one.
(缓存文件读写的测试：原子写入、权限，以及区分「文件不存在」与「文件损坏」)
]]

local config = require("weread.config")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
config.setup({ data_dir = root })
config.ensure_dirs()

local cache = require("weread.cache")

---@param path string
---@return string[] names in the directory(目录里的文件名)
local function listing(path)
  local names = {}
  for name in vim.fs.dir(path) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

---@param dir string
---@param needle string
---@return string[]
local function matching(dir, needle)
  local out = {}
  for _, name in ipairs(listing(dir)) do
    if name:find(needle, 1, true) then
      out[#out + 1] = name
    end
  end
  return out
end

describe("cache.atomic_write", function()
  it("writes the content with mode 0600 and leaves no temp file", function()
    local dir = root .. "/atomic-ok"
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/secret.json"
    local ok, err = cache.atomic_write(path, '{"k":"v"}')
    eq(ok, true, tostring(err))
    eq(cache.read(path), '{"k":"v"}')
    eq(vim.fn.getfperm(path), "rw-------", "private from the moment it exists")
    eq(listing(dir), { "secret.json" }, "the temp file was renamed away")
  end)

  it("honours an explicit mode", function()
    local dir = root .. "/atomic-mode"
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/open.txt"
    -- 0644
    local ok, err = cache.atomic_write(path, "x", 420)
    eq(ok, true, tostring(err))
    -- the umask can only remove bits, never add them
    -- (umask 只会去掉位，不会加位)
    matches(vim.fn.getfperm(path), "^rw%-")
  end)

  it("replaces an existing file whole", function()
    local dir = root .. "/atomic-replace"
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/a.txt"
    eq(cache.atomic_write(path, "first, and longer"), true)
    eq(cache.atomic_write(path, "second"), true)
    eq(cache.read(path), "second")
  end)

  it("handles a payload larger than one write call", function()
    local dir = root .. "/atomic-big"
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/big.bin"
    local data = string.rep("0123456789abcdef", 256 * 1024) -- 4 MiB
    local ok, err = cache.atomic_write(path, data)
    eq(ok, true, tostring(err))
    eq(#cache.read(path), #data)
  end)

  it("fails without touching the old file when the directory is gone", function()
    local dir = root .. "/atomic-gone"
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/keep.json"
    eq(cache.atomic_write(path, "old"), true)

    local missing = dir .. "/no-such-dir/keep.json"
    local ok, err = cache.atomic_write(missing, "new")
    eq(ok, nil)
    truthy(err and err ~= "", "the failure carries a reason")
    eq(cache.read(path), "old", "an unrelated old file is untouched")
  end)

  it("keeps the previous content when the directory is read-only", function()
    if vim.env.USER == "root" then
      return -- root ignores directory permissions(root 不受目录权限约束)
    end
    local dir = root .. "/atomic-ro"
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/keep.json"
    eq(cache.atomic_write(path, "old"), true)

    vim.uv.fs_chmod(dir, 360) -- 0550: no write permission(无写权限)
    local ok, err = cache.atomic_write(path, "new")
    vim.uv.fs_chmod(dir, 493) -- 0755
    eq(ok, nil)
    truthy(err and err ~= "", "the failure carries a reason")
    eq(cache.read(path), "old", "the old content survived")
    eq(listing(dir), { "keep.json" }, "and no temp file was left behind")
  end)

  it("refuses data that is not a string", function()
    local ok, err = cache.atomic_write(root .. "/never.json", { 1 })
    eq(ok, nil)
    matches(err, "table")
    eq(vim.uv.fs_stat(root .. "/never.json"), nil)
  end)

  it("uses a different temp name every time", function()
    -- Two writes to one target must not share a temp file; the counter in the
    -- name is what guarantees it.
    -- (同一目标的两次写入不能共用临时文件，名字里的计数器保证这一点)
    local dir = root .. "/atomic-names"
    vim.fn.mkdir(dir, "p")
    local seen = {}
    local original = vim.uv.fs_open
    vim.uv.fs_open = function(path, ...)
      seen[#seen + 1] = path
      return original(path, ...)
    end
    local ok = pcall(function()
      cache.atomic_write(dir .. "/n.json", "1")
      cache.atomic_write(dir .. "/n.json", "2")
    end)
    vim.uv.fs_open = original
    truthy(ok)
    eq(#seen, 2)
    truthy(seen[1] ~= seen[2], "temp names differ: " .. vim.inspect(seen))
    matches(seen[1], "%.tmp%-%d+%-%d+$")
  end)
end)

describe("cache.write", function()
  it("creates the parent directory and keeps its bool/err contract", function()
    local path = root .. "/write/nested/deeper/file.txt"
    local ok, err = cache.write(path, "hello")
    eq(ok, true, tostring(err))
    eq(err, nil)
    eq(cache.read(path), "hello")
  end)

  it("reports a failure instead of raising", function()
    -- the parent "directory" is a regular file(父“目录”其实是个普通文件)
    local blocker = root .. "/write-blocker"
    eq(cache.write(blocker, "i am a file"), true)
    local ok, err = cache.write(blocker .. "/child.txt", "x")
    eq(ok, false)
    truthy(err and err ~= "")
    eq(cache.read(blocker), "i am a file", "the blocker is untouched")
  end)

  it("takes 0600 for credential-like files", function()
    local path = root .. "/write-private.json"
    eq(cache.write(path, "{}", 384), true)
    eq(vim.fn.getfperm(path), "rw-------")
  end)
end)

describe("cache.write_new", function()
  it("creates a private file and refuses to overwrite one", function()
    local path = root .. "/new.hdr"
    eq(cache.write_new(path, "Authorization: x\n"), true)
    eq(vim.fn.getfperm(path), "rw-------")
    local ok, err = cache.write_new(path, "other")
    eq(ok, nil)
    truthy(err)
    eq(cache.read(path), "Authorization: x\n", "the existing file was not touched")
  end)
end)

describe("cache.read_json", function()
  it("returns nil for a file that does not exist, with no side effects", function()
    local path = root .. "/json-missing.json"
    eq(cache.read_json(path), nil)
    local data, status = cache.load_json(path)
    eq(data, nil)
    eq(status, "missing")
    eq(vim.uv.fs_stat(path), nil)
  end)

  it("treats an empty file as missing, not corrupt", function()
    local path = root .. "/json-empty.json"
    cache.write(path, "")
    local _, status = cache.load_json(path)
    eq(status, "missing")
    eq(matching(root, "json-empty.json.corrupt"), {})
  end)

  it("decodes a valid object", function()
    local path = root .. "/json-ok.json"
    cache.write(path, '{"a":1}')
    local data, status = cache.load_json(path)
    eq(data.a, 1)
    eq(status, "ok")
  end)

  local function corrupt_case(label, content)
    it("moves aside a corrupt file: " .. label, function()
      local name = "json-bad-" .. label:gsub("%W", "") .. ".json"
      local path = root .. "/" .. name
      cache.write(path, content)

      local data, status, backup = cache.load_json(path)
      eq(data, nil)
      eq(status, "corrupt")
      truthy(backup, "the backup path is reported")
      matches(backup, "%.corrupt%-%d+%-%d+")
      eq(vim.uv.fs_stat(path), nil, "the bad file is no longer in the way")
      eq(cache.read(backup), content, "and its bytes are preserved")
    end)
  end

  corrupt_case("truncated", '{"a":')
  corrupt_case("garbage", "not json at all")
  corrupt_case("null", "null")
  corrupt_case("number", "42")
  corrupt_case("string", '"text"')

  it("lets the next write start clean without losing the bad file", function()
    local path = root .. "/json-recover.json"
    cache.write(path, "{broken")
    eq(cache.read_json(path), nil)
    eq(cache.write_json(path, { fine = true }), true)
    eq(cache.read_json(path).fine, true)
    eq(#matching(root, "json-recover.json.corrupt-"), 1, "exactly one backup")
  end)

  it("never overwrites an earlier backup made within the same second", function()
    local path = root .. "/json-twice.json"
    cache.write(path, "{one")
    cache.read_json(path)
    cache.write(path, "{two")
    cache.read_json(path)
    local backups = matching(root, "json-twice.json.corrupt-")
    eq(#backups, 2)
    local contents = {}
    for _, name in ipairs(backups) do
      contents[#contents + 1] = cache.read(root .. "/" .. name)
    end
    table.sort(contents)
    eq(contents, { "{one", "{two" })
  end)

  it("logs a warning when it quarantines a file", function()
    local log = require("weread.log")
    log.clear()
    local path = root .. "/json-logged.json"
    cache.write(path, "{nope")
    cache.read_json(path)
    local found = false
    for _, line in ipairs(log.tail(20)) do
      if line:find("[WARN]", 1, true) and line:find("json-logged.json", 1, true) then
        found = true
      end
    end
    truthy(found, "a WARN line names the file")
  end)
end)

describe("cache positions", function()
  it("keeps a corrupt positions.json as a backup instead of overwriting it", function()
    local path = config.path("positions.json")
    cache.write(path, "{this is not json")

    eq(cache.read_position("1"), nil, "reads as empty")
    local ok, err = cache.write_position("1", { chapter = 3 })
    eq(ok, true, tostring(err))

    eq(cache.read_position("1").chapter, 3)
    local backups = matching(config.data_dir(), "positions.json.corrupt-")
    eq(#backups, 1, "the damaged file was kept")
    eq(cache.read(config.path(backups[1])), "{this is not json")
  end)

  it("returns the write outcome", function()
    local ok = cache.write_position("2", { chapter = 1 })
    eq(ok, true)
  end)
end)

describe("cache.write_meta / write_catalog", function()
  it("hand the write result back instead of dropping it", function()
    local ok, err = cache.write_meta("book-1", { title = "t" })
    eq(ok, true, tostring(err))
    eq(cache.read_meta("book-1").title, "t")

    ok, err = cache.write_catalog("book-1", { { chapterUid = 1 } })
    eq(ok, true, tostring(err))
    eq(cache.read_catalog("book-1")[1].chapterUid, 1)
  end)

  it("report why an unencodable value could not be written", function()
    local ok, err = cache.write_meta("book-2", { bad = function() end })
    eq(ok, false)
    matches(err, "encode")
  end)

  it("report a failed write", function()
    -- a regular file where the book directory should be(本应是书目录的位置放了个普通文件)
    local blocker = config.path("books", "book-3")
    vim.fn.mkdir(vim.fs.dirname(blocker), "p")
    eq(cache.write(blocker, "x"), true)
    local ok, err = cache.write_meta("book-3", { title = "t" })
    eq(ok, false)
    truthy(err and err ~= "")
  end)
end)

describe("cache dead code", function()
  it("no longer exposes clear_book", function()
    eq(cache.clear_book, nil)
  end)
end)
