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

-- Specs run in one nvim instance, so a spec that stubs modules or vim
-- functions would leak into the next one. Snapshot and restore around each
-- file: import order stops mattering, and a spec can never poison another.
-- (所有 spec 共用一个 nvim 实例，打桩过模块或 vim 函数的 spec 会污染后面的 spec。
--  因此在每个 spec 文件前后做快照与还原：导入顺序不再重要，spec 之间不会互相下毒)
local VIM_HOOKS = {
  { "notify", false },
  { "defer_fn", false },
  { "ui", "input" },
}

local function snapshot()
  local loaded = {}
  for key, value in pairs(package.loaded) do
    loaded[key] = value
  end
  local hooks = {}
  for _, hook in ipairs(VIM_HOOKS) do
    local target = hook[2] and vim[hook[1]][hook[2]] or vim[hook[1]]
    hooks[#hooks + 1] = target
  end
  return { loaded = loaded, hooks = hooks, timer_stop = vim.fn.timer_stop }
end

local function restore(state)
  for key in pairs(package.loaded) do
    if state.loaded[key] == nil then
      package.loaded[key] = nil
    end
  end
  for key, value in pairs(state.loaded) do
    package.loaded[key] = value
  end
  for index, hook in ipairs(VIM_HOOKS) do
    if hook[2] then
      vim[hook[1]][hook[2]] = state.hooks[index]
    else
      vim[hook[1]] = state.hooks[index]
    end
  end
  vim.fn.timer_stop = state.timer_stop
end

for _, name in ipairs(specs) do
  local state = snapshot()
  local ok, err = pcall(dofile, root .. "/tests/spec/" .. name)
  restore(state)
  if not ok then
    io.stdout:write("  !! " .. name .. " raised: " .. tostring(err) .. "\n")
    framework.failed = framework.failed + 1
    table.insert(framework.failures, { name = name, message = tostring(err) })
  end
end

os.exit(framework.finish() and 0 or 1)
