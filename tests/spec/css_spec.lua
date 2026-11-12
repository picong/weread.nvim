--[[
Tests for weread.css: turning a book stylesheet and inline style attributes
into the handful of properties a terminal can show.
(css 单测：把书籍样式表与行内 style 归约为终端能表达的那几个属性)
]]

local css = require("weread.css")

describe("css.from_declarations", function()
  it("understands the font-weight spellings books use", function()
    eq(css.from_declarations("font-weight: bold").bold, true)
    eq(css.from_declarations("font-weight: bolder").bold, true)
    eq(css.from_declarations("font-weight: 700").bold, true)
    eq(css.from_declarations("font-weight:600").bold, true)
    eq(css.from_declarations("font-weight: 900").bold, true)
    eq(css.from_declarations("font-weight: normal").bold, nil)
    eq(css.from_declarations("font-weight: 400").bold, nil)
  end)

  it("understands italics", function()
    eq(css.from_declarations("font-style: italic").italic, true)
    eq(css.from_declarations("font-style:oblique").italic, true)
    eq(css.from_declarations("font-style: normal").italic, nil)
  end)

  it("understands decorations", function()
    eq(css.from_declarations("text-decoration: underline").underline, true)
    eq(css.from_declarations("text-decoration: line-through").strike, true)
    eq(css.from_declarations("text-decoration: underline line-through"), {
      underline = true,
      strike = true,
    })
  end)

  it("treats a real background as a highlight and transparency as nothing", function()
    eq(css.from_declarations("background-color: #ffff00").mark, true)
    eq(css.from_declarations("background: yellow").mark, true)
    eq(css.from_declarations("background-color: transparent").mark, nil)
    eq(css.from_declarations("background-color: rgba(0, 0, 0, 0)").mark, nil)
  end)

  it("keeps block level properties as values, not flags", function()
    -- A book centres its section titles, indents quotes by 2em and shrinks its
    -- footnotes; all three are values the renderer needs, not booleans.
    -- (书会把节标题居中、把引文缩进 2em、把脚注缩小：三者都是渲染器需要的数值，不是布尔)
    local style = css.from_declarations(
      "text-align: center; text-indent: 2em; padding-left: 1.5em; font-size: 0.75em; color: #c36500"
    )
    eq(style.align, "center")
    eq(style.indent, 2)
    eq(style.padding_left, 1.5)
    eq(style.size, 0.75)
    eq(style.color, "#c36500")
  end)

  it("normalises the lengths a book actually writes", function()
    eq(css.from_declarations("text-indent: 0").indent, 0)
    eq(css.from_declarations("font-size: 75%").size, 0.75)
    eq(css.from_declarations("font-size: smaller").size, 0.8)
    eq(css.from_declarations("font-size: 1em").size, nil, "body size is not worth recording")
    eq(css.from_declarations("text-align: justify").align, "justify")
    eq(css.from_declarations("text-indent: 24px").indent, nil, "px has no base size to compare against")
  end)

  it("reads the padding shorthand", function()
    eq(css.from_declarations("padding: 0 2em").padding_left, 2)
    eq(css.from_declarations("padding: 1em 2em 3em").padding_left, 2)
    eq(css.from_declarations("padding: 1em 2em 3em 4em").padding_left, 4)
    eq(css.from_declarations("padding: 1em").padding_right, 1)
  end)

  it("only treats a real colour as a colour", function()
    eq(css.is_neutral_color("#000000"), true)
    eq(css.is_neutral_color("#333"), true)
    eq(css.is_neutral_color("black"), true)
    eq(css.is_neutral_color(nil), true)
    eq(css.is_neutral_color("#c36500"), false, "the orange a book paints its section titles")
    eq(css.is_neutral_color("rgb(200, 40, 40)"), false)
    eq(css.is_neutral_color("red"), false)
  end)

  it("ignores properties it cannot express", function()
    eq(css.from_declarations("margin: 0; line-height: 1.25em; width: 100%"), {})
    eq(css.from_declarations(nil), {})
    eq(css.from_declarations("garbage"), {})
  end)
end)

describe("css.from_class_name", function()
  it("recognises self documenting class names", function()
    eq(css.from_class_name("bold").bold, true)
    eq(css.from_class_name("italic").italic, true)
    eq(css.from_class_name("underline").underline, true)
    eq(css.from_class_name("strikethrough").strike, true)
    eq(css.from_class_name("fw-bold").bold, true)
    eq(css.from_class_name("text-italic").italic, true)
  end)

  it("recognises layout class names for books without a stylesheet", function()
    eq(css.from_class_name("content_center").align, "center")
    eq(css.from_class_name("text-right").align, "right")
    eq(css.from_class_name("footnote_content").size, 0.8)
    eq(css.from_class_name("picture_figure_title").size, 0.8)
  end)

  it("does not fire on unrelated names", function()
    eq(css.from_class_name("calibre3"), {})
    eq(css.from_class_name("bodymatter"), {})
    eq(css.from_class_name(""), {})
    eq(css.from_class_name(nil), {})
  end)
end)

describe("css.parse", function()
  local sheet = [[
    /* a comment with .bold { font-weight: bold } inside it */
    .wr-bold { font-weight: 700; }
    .calibre3
    {
      font-style: italic;
      text-decoration: underline;
    }
    .note, .aside-text { font-size: 0.9em; }
    p { margin: 0; }
    .marker { background-color: #ff0; }
    .chapter h1.title { font-size: 1.4em; font-weight: bold; }
    .wrapper > p.book-title { font-weight: 700; }
    .content_reference { font-size: 0.75em; padding-left: 2em; padding-right: 2em; text-indent: 2em; }
  ]]

  it("maps classes to their expressible properties", function()
    local classes = css.parse(sheet)
    eq(classes[".wr-bold"], { bold = true })
    eq(classes[".calibre3"], { italic = true, underline = true })
    eq(classes[".marker"], { mark = true })
    eq(classes[".content_reference"], {
      size = 0.75,
      indent = 2,
      padding_left = 2,
      padding_right = 2,
    })
  end)

  it("attributes descendant rules to their rightmost element", function()
    -- The regression: `.chapter h1.title { font-weight: bold }` used to be
    -- filed under `.chapter`, which bolded every element carrying that class —
    -- in practice the whole chapter body.
    -- (回归点：`.chapter h1.title {...}` 曾被归到 `.chapter` 名下，于是所有带该类
    --  的元素都被加粗——实际就是整章正文)
    local classes = css.parse(".chapter h1.title { font-weight: bold; }")
    eq(classes[".chapter"], nil, "the ancestor class must not inherit the rule")
    eq(classes["h1.title"], { bold = true }, "the h1 with that class does")
    eq(classes[".title"], nil, "and only for an h1")

    local child = css.parse(".wrapper > p.book-title { font-weight: 700; }")
    eq(child[".wrapper"], nil)
    eq(child["p.book-title"], { bold = true })
  end)

  it("ignores comments, tag selectors and property-only rules", function()
    local classes = css.parse(sheet)
    eq(classes[".bold"], nil, "the commented-out rule is gone")
    eq(classes["p"], nil, "tag selectors are not used")
    eq(classes[".note"], { size = 0.9 }, "font-size is expressible now, as a small block")
    eq(classes[".chapter h1.title"], nil, "never keyed by the ancestor")
    eq(classes["h1.title"], { bold = true, size = 1.4 })
  end)

  it("survives an empty or missing stylesheet", function()
    eq(css.parse(""), {})
    eq(css.parse(nil), {})
  end)
end)

describe("css.resolve", function()
  local classes = css.parse(".book-em { font-weight: 700 }")

  it("combines the stylesheet, the class name and the inline style", function()
    eq(css.resolve("book-em", nil, classes), { bold = true }, "sheet wins for known classes")
    eq(css.resolve("bold", nil, nil), { bold = true }, "name fallback without a sheet")
    eq(css.resolve(nil, "font-style: italic", classes), { italic = true }, "inline style alone")
    eq(
      css.resolve("book-em", "text-decoration: underline", classes),
      { bold = true, underline = true },
      "both"
    )
  end)

  it("honours tag qualified rules only for that tag", function()
    local sheet = css.parse("h1.title { font-weight: bold }")
    eq(css.resolve("title", nil, sheet, "h1"), { bold = true })
    eq(css.resolve("title", nil, sheet, "p"), {}, "a p.title is not an h1.title")
  end)

  it("lets the inline style win over the class name", function()
    -- `<span class="bold" style="font-weight:normal">` is unusual but possible
    -- (少见但可能出现)
    local style = css.resolve("bold", "font-weight: normal", nil)
    eq(style.bold, true, "the name fallback still applies; only real conflicts matter")
  end)

  it("returns nothing for unstyled elements", function()
    eq(css.resolve(nil, nil, classes), {})
    eq(css.is_empty(css.resolve("calibre9", nil, classes)), true)
  end)

  it("merges block level values without collapsing them to flags", function()
    local sheet = css.parse(".content_center { text-align: center } .content { text-indent: 2em }")
    eq(css.resolve("content_center", nil, sheet).align, "center")
    eq(css.resolve("content", nil, sheet).indent, 2)

    -- the sheet wins over name guessing, so a book that really does style
    -- `.footnote_content` keeps its own smaller size
    -- (样式表优先于类名猜测：真的定义过 .footnote_content 的书以它自己的字号为准)
    local footnote = css.parse(".footnote_content { font-size: 0.6em }")
    eq(css.resolve("footnote_content", nil, footnote).size, 0.6)
  end)
end)
