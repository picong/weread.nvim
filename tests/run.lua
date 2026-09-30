--[[
Test runner. Run from the repository root:

  nvim --headless --clean -l tests/run.lua

Every `tests/spec/*_spec.lua` file is loaded and registers its cases through
the global helpers exposed below.
(测试入口：在仓库根目录执行；tests/spec/*_spec.lua 通过下面的全局函数注册用例)
]]

local root = vim.fn.getcwd()
if vim.fn.filereadable(root .. "/lua/weread/crypto.lua") ~= 1 then
  io.stderr:write("run tests from the repository root (cd weread.nvim && nvim --headless --clean -l tests/run.lua)\n")
  os.exit(2)
end

vim.opt.runtimepath:prepend(root)

local framework = dofile(root .. "/tests/framework.lua")
_G.describe = framework.describe
_G.it = framework.it
_G.eq = framework.eq
_G.truthy = framework.truthy
_G.falsy = framework.falsy
_G.matches = framework.matches
_G.raises = framework.raises

local specs = {}
for name, kind in vim.fs.dir(root .. "/tests/spec") do
  if kind == "file" and name:match("_spec%.lua$") then
    specs[#specs + 1] = name
  end
end
table.sort(specs)

if #specs == 0 then
  io.stderr:write("no specs found under tests/spec\n")
  os.exit(2)
end

io.stdout:write(string.format("running %d spec file(s) from %s\n", #specs, root))
for _, name in ipairs(specs) do
  dofile(root .. "/tests/spec/" .. name)
end

os.exit(framework.finish() and 0 or 1)
