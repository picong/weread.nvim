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

  it("ignores properties it cannot express", function()
    eq(css.from_declarations("font-size: 1.2em; color: red; margin: 0"), {})
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
  ]]

  it("maps classes to their expressible properties", function()
    local classes = css.parse(sheet)
    eq(classes[".wr-bold"], { bold = true })
    eq(classes[".calibre3"], { italic = true, underline = true })
    eq(classes[".marker"], { mark = true })
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
    eq(classes[".note"], nil, "a font-size-only rule carries nothing")
    eq(classes[".aside-text"], nil)
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
end)
