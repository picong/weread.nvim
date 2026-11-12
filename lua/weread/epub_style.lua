--[[
One typesetting for the whole exported book (:WeReadEpub): the book's own
stylesheets are left out and this one stands in for all of them, so every page
reads alike — the same face, size, leading and first-line indent — and nothing
the publisher drew around a block (the grey sidebar box, the bordered tip and
warning, the black label tag) comes along as a box on the phone.
(导出整本书时只用一套排版（:WeReadEpub）：不带书自己的样式表，由这一份统一代替，让每一页读起来一样
 ——同样的字体、字号、行距、首行缩进——出版社给块加的框（灰底侧栏、带边框的提示和警告、黑底标签）
 不会在手机上变成一个个框)

The rules follow what was settled by hand on Fundamentals of Software
Architecture, written against the markup O'Reilly-style books carry
(`data-type` sidebars, tips, examples, equations, parts, index divisions) and
plain HTML for every other book.
(规则沿用在《Fundamentals of Software Architecture》上手工定下的排版，按 O'Reilly 一类书的标记
 （带 data-type 的侧栏、提示、示例、公式、部、索引分组）编写，其它书按普通 HTML 生效)
]]

local M = {}

---The single stylesheet of a restyled book.
---(统一排版后全书唯一的样式表)
M.CSS = table.concat({
  '@charset "utf-8";',
  "html, body { margin: 0; padding: 0; }",
  "body {",
  '  font-family: "Noto Serif CJK SC", "Source Han Serif SC", "Songti SC", "SimSun", serif;',
  "  font-size: 1em; line-height: 1.8; text-align: justify; color: #000; background: transparent;",
  "  margin: 0 0.6em;",
  "}",
  -- no block keeps a background of its own; code blocks set theirs again below
  -- (所有块都不带自己的底色；代码块在下面重新设置)
  "* { background: transparent; box-shadow: none; }",
  "p { font-size: 1em; line-height: 1.8; text-indent: 2em; margin: 0 0 0.5em 0; }",
  "h1, h2, h3, h4, h5, h6 { font-family: inherit; color: inherit; line-height: 1.4; text-indent: 0; text-align: left; font-weight: bold; font-style: normal; text-transform: none; page-break-after: avoid; }",
  "h1 { font-size: 1.6em; margin: 1.2em 0 1em 0; text-align: center; }",
  "h2 { font-size: 1.35em; margin: 1.4em 0 0.6em 0; }",
  "h3 { font-size: 1.18em; margin: 1.2em 0 0.5em 0; }",
  "h4 { font-size: 1.06em; margin: 1.1em 0 0.4em 0; }",
  "h5, h6 { font-size: 1em; margin: 1em 0 0.4em 0; }",
  -- a part page: its title a third of the way down(部的分隔页：标题放在页面三分之一处)
  '[data-type="part"] h1 { margin-top: 30%; font-size: 1.8em; }',
  '[data-type="part"] p, div.partintro p { text-indent: 2em; }',
  -- sidebars, tips, notes and warnings: no box, a marked title(侧栏、提示、注意、警告：不加框，标题加标记)
  'aside, div.sidebar, [data-type="sidebar"], [data-type="tip"], [data-type="note"], [data-type="warning"], [data-type="caution"], [data-type="important"] { border: none; padding: 0; margin: 0.8em 0; width: auto; float: none; }',
  'aside h5, div.sidebar h5, [data-type="sidebar"] h5 { font-size: 1.06em; border-left: 3px solid #888; padding-left: 0.5em; }',
  '[data-type="tip"] h6, [data-type="note"] h6, [data-type="warning"] h6, [data-type="caution"] h6, [data-type="important"] h6 { font-size: 1em; margin: 0.8em 0 0.2em 0; }',
  "span.label { color: inherit; font-weight: bold; padding: 0; border: none; }",
  '[data-type="example"] h5, [data-type="equation"] h5 { font-size: 0.92em; margin: 1em 0 0.3em 0; }',
  '[data-type="equation"] { text-align: center; margin: 0.6em 0 1em 0; }',
  -- figures and their captions(插图与图注)
  "figure, div.figure { text-align: center; margin: 1em 0; width: auto; page-break-inside: avoid; border: none; }",
  "img { max-width: 100%; height: auto; }",
  "figcaption, figure h6, div.figure h6 { text-indent: 0; text-align: center; font-size: 0.9em; font-weight: normal; color: #444; margin: 0.4em 0 0.8em 0; }",
  -- code: the one block that keeps a tint(代码：唯一保留底色的块)
  "pre {",
  '  font-family: "DejaVu Sans Mono", "Noto Sans Mono", Consolas, monospace;',
  "  font-size: 0.8em; line-height: 1.45; white-space: pre-wrap; word-wrap: break-word; text-indent: 0;",
  "  background: #f4f4f4; border: 1px solid #ddd; padding: 0.6em 0.8em; margin: 0.6em 0 1em 0; text-align: left;",
  "}",
  "pre * { font-family: inherit; color: inherit; font-weight: normal; font-style: normal; }",
  'code { font-family: "DejaVu Sans Mono", "Noto Sans Mono", Consolas, monospace; font-size: 0.92em; }',
  "pre code { font-size: 1em; }",
  "table { border-collapse: collapse; width: 100%; margin: 0.8em 0 1.2em 0; font-size: 0.88em; line-height: 1.5; }",
  "caption { font-weight: bold; padding-bottom: 0.4em; caption-side: top; text-align: left; }",
  "th, td { border: 1px solid #999; padding: 0.3em 0.5em; vertical-align: top; text-align: left; }",
  "th { background: #eee; }",
  "td p, th p, li p, dd p, caption p { text-indent: 0; margin: 0; }",
  "blockquote { margin: 0.8em 2em; padding: 0; border: none; }",
  '[data-type="attribution"] { text-align: right; text-indent: 0; }',
  '[data-type="attribution"]:before { content: "—— "; }',
  "ul, ol { margin: 0.3em 0 0.6em 0; padding-left: 2.5em; }",
  "li { line-height: 1.8; margin: 0.15em 0; text-indent: 0; }",
  "dt { font-weight: bold; margin-top: 0.5em; }",
  "dd { margin: 0 0 0.5em 2em; }",
  '[data-type="indexdiv"] ul { list-style: none; padding-left: 1.2em; }',
  "nav ol { list-style: none; padding-left: 1.2em; }",
  -- ours: the translation under the original, the cover page(我们自己的：原文下面的译文、封面页)
  ".wr-translation { color: #6b6b6b; }",
  ".wr-cover { margin: 0; padding: 0; text-align: center; page-break-after: always; }",
  ".wr-cover img { max-width: 100%; max-height: 100vh; }",
  "",
}, "\n")

---Take out of a chapter body what would beat the stylesheet: inline `style`,
---`bgcolor` and `<font>`, which the publisher's markup sometimes carries.
---(去掉章节正文里会压过样式表的东西：出版社标记里有时带着的行内 style、bgcolor 与 <font>)
---@param body string
---@return string
function M.body(body)
  body = body:gsub("(<%a[^<>]-)%s+style%s*=%s*\"[^\"]*\"", "%1")
  body = body:gsub("(<%a[^<>]-)%s+style%s*=%s*'[^']*'", "%1")
  body = body:gsub("(<%a[^<>]-)%s+bgcolor%s*=%s*\"[^\"]*\"", "%1")
  body = body:gsub("</?[Ff][Oo][Nn][Tt][^>]*>", "")
  return body
end

return M
