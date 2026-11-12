--[[
The chapter cache has to survive being written.

A chapter's map is keyed by line number, and only the handful of lines that are
centred, inset or coloured carry attributes — so those keys are sparse, and
`vim.json.encode` refuses a sparse array outright. The write used to be unchecked,
so the encoder's refusal was invisible: the log said "re-rendered", the map was
never written, and every highlight offset went with it.
(章节缓存必须写得进去。map 以行号为键，而只有少数需要居中/内缩/上色的行带属性——键因此是稀疏的，
 而 `vim.json.encode` 直接拒绝稀疏数组。写入原本不检查结果，因此编码器的拒绝是看不见的：日志
 说「已重排」，map 从未写出，划线偏移一起丢掉)
]]

local config = require("weread.config")
config.setup({ data_dir = vim.fn.tempname() })
config.ensure_dirs()

local cache = require("weread.cache")

describe("cache.write_json", function()
  ---The shape a real chapter has: many lines, attributes on every tenth one,
  ---no `0` key. Keys that are all ≥ 1 make the encoder read it as an array.
  ---(真实章节的形状：行很多、每十行才有一行带属性、没有 `0` 键。键全 ≥1 会让编码器把它当成数组)
  ---@return table
  local function sparse_lines()
    local lines = {}
    for line = 10, 290, 10 do
      lines[line] = { align = "center", cells = 20 }
    end
    return lines
  end

  it("says why an unencodable value could not be written", function()
    -- The bare `false` this used to return is what hid the bug for a whole round.
    -- (它原本只回一个 `false`，正是这个让 bug 藏了一整轮)
    local path = config.path("encode-test.json")
    local ok, err = cache.write_json(path, { lines = sparse_lines() })
    eq(ok, false, "a sparse array cannot be encoded")
    truthy(tostring(err):find("encode", 1, true), "and the reason is reported: " .. tostring(err))
    eq(vim.fn.filereadable(path), 0, "nothing was written")
  end)

  it("writes the whole map once the keys are an object", function()
    -- This is the shape the reader writes, and the one that used to be refused.
    -- (这就是阅读器实际写入的形状，也是原来被拒绝的那个)
    local path = config.path("map.json")
    local ok, err = cache.write_json(path, {
      map = { { src_from = 0, line = 0, col_from = 0, col_to = 10 } },
      headings = { { line = 3, level = 2 } },
      lines = require("weread.xhtml").json_lines(sparse_lines()),
      page_width = 52,
    })
    eq(ok, true, tostring(err))
    local read = cache.read_json(path)
    eq(read.lines["150"].align, "center", "the attributes came back")
    eq(#read.map, 1, "and so did the offset map")
  end)

  it("writes the same data once the keys are an object", function()
    local path = config.path("lines.json")
    local lines = {}
    for line, info in pairs({ [0] = { align = "center", cells = 8 }, [57] = { small = true, cells = 30 } }) do
      lines[tostring(line)] = info
    end
    local ok, err = cache.write_json(path, { lines = lines, page_width = 52 })
    eq(ok, true, tostring(err))
    local read = cache.read_json(path)
    eq(read.lines["0"].align, "center", "and it reads back with the keys it went in with")
    eq(read.lines["57"].small, true)
    eq(read.page_width, 52)
  end)
end)
