--[[
Guess the language of a code block from its text.
(根据文本猜代码块的语言)

Split out of xhtml.lua, unchanged. WeRead code blocks carry no language, so the
renderer sniffs one from the first words of each line; the heuristics are plain
string matching with no dependency on the rest of the converter.
(从 xhtml.lua 原样拆出。微信读书的代码块不带语言，渲染器靠每行的头几个词嗅探；这些启发
 式只是字符串匹配，不依赖转换器的其余部分)
]]

local M = {}

---First word of a line, lowercased, or nil.
---(一行的第一个词，转小写；没有则为 nil)
---@param line string
---@return string|nil
local function first_word(line)
  local word = line:match("^%s*([%a][%w_]*)")
  return word and word:lower() or nil
end

---Is this line one whose first word is one of `starts`?
---(这一行的第一个词是否属于 `starts`)
---@param line string
---@param starts table<string, boolean>
---@return boolean
local function first_word_is(line, starts)
  local word = first_word(line)
  return word ~= nil and starts[word] == true
end

---Commands whose name at the start of a line means "this is a shell listing".
---(行首出现即说明「这是一份 shell 清单」的命令名)
local SHELL_COMMANDS = {
  claude = true, npm = true, npx = true, pnpm = true, yarn = true, bun = true, node = true,
  git = true, curl = true, wget = true, ssh = true, scp = true, rsync = true, tar = true, unzip = true,
  mkdir = true, cd = true, ls = true, cat = true, echo = true, export = true, source = true,
  find = true, grep = true, rg = true, sed = true, awk = true, chmod = true, chown = true, touch = true,
  python = true, python3 = true, pip = true, pip3 = true, pytest = true, uv = true, poetry = true,
  lua = true, luajit = true, go = true, cargo = true, rustc = true, java = true, javac = true,
  make = true, mvn = true, gradle = true, docker = true, kubectl = true, helm = true, terraform = true,
  sudo = true, brew = true, apt = true, dnf = true, pacman = true, systemctl = true, service = true,
  jq = true, yq = true, gh = true, tmux = true, vim = true, nvim = true, tree = true, which = true,
  rm = true, cp = true, mv = true, ln = true, head = true, tail = true, wc = true, sort = true, uniq = true,
}

---Does this line look like a shell command?
---(这一行像不像 shell 命令)
---@param line string
---@return boolean
local function claim_shell(line)
  if line:match("^#!/") ~= nil or line:match("^%s*%$%s") ~= nil then
    return true
  end
  if line:match("^%s*#") ~= nil then
    -- A comment is not a claim by itself; see the ratio below.
    -- (注释本身不算认领，见下面的比例)
    return false
  end
  if first_word_is(line, SHELL_COMMANDS) then
    return true
  end
  -- a flag or an assignment is shell too: `npm test --watch`, `API_KEY=xxx`
  -- (选项与赋值也算：`npm test --watch`、`API_KEY=xxx`)
  return line:match("^%s*[%a_%.%/][^%s]*%s+%-%-[%a]") ~= nil or line:match("^%s*%u[%u%d_]*=") ~= nil
end

---Words that open a line of the given language.
---(某种语言里可以出现在行首的关键词)
local PYTHON_STARTS = {
  ["assert"] = true, ["async"] = true, ["await"] = true, ["class"] = true, ["def"] = true, ["elif"] = true, ["else"] = true, ["except"] = true, ["finally"] = true, ["from"] = true, ["global"] = true, ["import"] = true, ["lambda"] = true, ["pass"] = true, ["raise"] = true, ["return"] = true, ["try"] = true, ["with"] = true, ["yield"] = true,
}
local LUA_STARTS = {
  ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true, ["end"] = true, ["for"] = true, ["function"] = true, ["if"] = true, ["local"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["until"] = true, ["while"] = true,
}
local JAVASCRIPT_STARTS = {
  ["async"] = true, ["await"] = true, ["class"] = true, ["const"] = true, ["export"] = true, ["function"] = true, ["import"] = true, ["interface"] = true, ["let"] = true, ["new"] = true, ["return"] = true, ["throw"] = true, ["type"] = true, ["var"] = true,
}

---Language of a code listing, or nil when it cannot be told.
---(代码清单的语言；判断不出来时为 nil)
---
---Books do not mark their listings: every `<pre>` in every chapter of three
---sampled books carries the same CSS class and no language at all. A fence with
---no language gets **no syntax highlighting**, so the language has to be read off
---the text.
---
---The reading is deliberately timid. A listing is given a language only when
---roughly half of its lines look like that language, and never otherwise: colouring
---prose as if it were code is worse than leaving it monochrome, because a page of
---Chinese in embedded-YAML colours looks like a rendering bug.
---(书里不标语言：抽样三本书，每一章的 `<pre>` 都只有同一个 CSS 类，没有任何语言信息。
--- 没有语言的围栏**不会**得到语法高亮，因此只能从内容读。
---
--- 这个判断刻意保守：只有大约一半以上的行都像某种语言时才给出结论，其余一律不给——把散文
--- 按代码上色比不着色更糟，一整页中文套上 YAML 配色看起来就像渲染坏了)
---@param text string listing body(清单正文)
---@return string|nil
function M.language_of(text)
  local lines = {}
  for _, raw in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local line = raw:gsub("%s+$", "")
    if line:match("%S") then
      lines[#lines + 1] = line
    end
  end
  if #lines == 0 then
    return nil
  end

  -- Things that answer themselves: JSON parses or it does not, and a block of
  -- `key: value` is a configuration file whatever else it is.
  -- (能自己回答的：JSON 要么解析得动要么解析不动，而整块 `key: value` 无论怎么算都是配置文件)
  local joined = table.concat(lines, "\n")
  if joined:sub(1, 1) == "{" or joined:sub(1, 1) == "[" then
    if pcall(vim.json.decode, joined) then
      return "json"
    end
  end
  if #lines >= 2 then
    local keyed, prose = 0, 0
    for _, line in ipairs(lines) do
      if line:match("^%s*[%w_%.%-]+%s*:") then
        keyed = keyed + 1
      end
      if not line:match("^%s*#") and not line:match("^%s*%-%-%-%s*$") then
        prose = prose + 1
      end
    end
    -- Comments and list items are the file's own prose: a front matter block is
    -- mostly comments in real books, and counting them would hide the keys.
    -- (注释与列表项属于文件自己的文字：真实书里的前置元数据大半是注释，把它们算进总数会把键淹掉)
    if keyed >= 1 and keyed * 2 >= math.max(prose, 1) then
      return "yaml"
    end
  end

  -- One claim per line per candidate; the winner needs half the lines and at
  -- least one, which keeps a two line "comment + command" listing working. Bash
  -- is asked before markdown on purpose: `# comment` followed by a command is a
  -- shell listing that happens to have a comment in it.
  -- (每个候选对每行各认领一次；胜者需要占一半以上的行、且至少一行，这样两行的
  --  「注释 + 命令」清单也能判出来。bash 刻意排在 markdown 前面：`# 注释` 后面跟一条命令是
  --  一份带注释的 shell 清单)
  local CLAIMS = {
    { name = "bash", claim = claim_shell },
    { name = "markdown", claim = function(line)
      return line:match("^#+%s") ~= nil or line:match("^%-%s") ~= nil or line:match("^%*%s") ~= nil
        or line:match("^>%s") ~= nil or line:match("^|.*|$") ~= nil or line:match("^%*%*") ~= nil
        or line:match("^%-%-%-$") ~= nil
    end },
    { name = "python", claim = function(line)
      return first_word_is(line, PYTHON_STARTS) or line:match("self%.") ~= nil
        or line:match("print%(") ~= nil or line:match("__name__") ~= nil
    end },
    { name = "lua", claim = function(line)
      return first_word_is(line, LUA_STARTS) or line:match("require%(") ~= nil or line:match("vim%.") ~= nil
    end },
    { name = "javascript", claim = function(line)
      return first_word_is(line, JAVASCRIPT_STARTS) or line:match("=>") ~= nil
        or line:match("console%.") ~= nil or line:match("module%.exports") ~= nil
    end },
    { name = "html", claim = function(line)
      return line:match("^%s*<") ~= nil and line:find(">", 1, true) ~= nil
    end },
    { name = "toml", claim = function(line)
      return line:match("^%s*%[.+%]%s*$") ~= nil or line:match("^%s*[%w_%.%-]+%s*=") ~= nil
    end },
  }

  -- Two signals settle it on their own, ratio or no ratio: a shebang, and a `$`
  -- prompt — a listing that shows a prompt is a shell session even when most of
  -- its lines are the command's output.
  -- (两个信号可以单独定案，不看比例：shebang，以及 `$` 提示符——写着提示符的清单就是一次
  --  shell 会话，哪怕大半行是命令的输出)
  for _, line in ipairs(lines) do
    if line:match("^#!/") ~= nil or line:match("^%s*%$%s") ~= nil then
      return "bash"
    end
  end

  -- Comment lines do not count towards the total they are measured against: a
  -- listing of a comment and a command is a shell listing, and markdown headings
  -- are comments by exactly the same rule.
  -- (注释行不计入它们所对比的总数：一行注释加一行命令就是一份 shell 清单，而 markdown 标题
  --  按同一条规则也算注释)
  local scored = 0
  for _, line in ipairs(lines) do
    if not line:match("^%s*#") then
      scored = scored + 1
    end
  end
  scored = math.max(scored, 1)

  local winner, winner_claims = nil, 0
  for _, candidate in ipairs(CLAIMS) do
    local claims = 0
    for _, line in ipairs(lines) do
      if candidate.claim(line) then
        claims = claims + 1
      end
    end
    if claims > winner_claims then
      winner, winner_claims = candidate.name, claims
    end
  end
  if winner and winner_claims * 2 >= scored then
    return winner
  end
  -- Nothing claimed the block, but it opens with a markdown heading: a markdown
  -- sample made mostly of Chinese prose and one heading is still markdown.
  -- (没有谁认领这一块，但它以 markdown 标题开头：以中文散文为主、只带一个标题的样例仍然是 markdown)
  if lines[1]:match("^#+%s") and #lines >= 2 then
    return "markdown"
  end
  return nil
end

return M
