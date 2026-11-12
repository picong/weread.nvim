--[[
Copyright (C) 2026 finlater and contributors (weread.koplugin, AGPL-3.0)
Copyright (C) 2026 weread.nvim contributors

This file is part of weread.nvim, ported from
https://github.com/QiuYukang/weread.koplugin (weread/lib/reader_state.lua).

weread.nvim is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.
]]

--[[
Extracts the state the web reader embeds in its HTML. `psvts` in particular is
required by every chapter content request, and it is re-issued per chapter, so
this runs on the hot path.
(从网页阅读器 HTML 中提取其内嵌状态。psvts 是每次正文请求的必需参数，且逐章变化，
 因此本模块在热路径上)
]]

local ReaderState = {}

---@param html string
---@param json_decode fun(text: string): table
---@return table
function ReaderState.extract(html, json_decode)
  local reader
  if type(json_decode) == "function" then
    local encoded = html:match(
      [[window%.__INITIAL_STATE__%s*=%s*(.-)%s*;%s*%(function]]
    )
    if encoded then
      local ok, initial_state = pcall(json_decode, encoded)
      if ok and type(initial_state) == "table" then
        reader = initial_state.reader
      end
    end
  end

  reader = type(reader) == "table" and reader or {}
  local book_info = type(reader.bookInfo) == "table" and reader.bookInfo or {}
  local current_chapter = type(reader.currentChapter) == "table" and reader.currentChapter or {}
  local progress = type(reader.progress) == "table" and reader.progress or {}
  local progress_book = type(progress.book) == "table" and progress.book or progress

  return {
    book_id = book_info.bookId
      or html:match([["bookId"%s*:%s*"([^"]+)"]])
      or html:match([["bookId"%s*:%s*(%d+)]]),
    title = book_info.title or html:match([["title"%s*:%s*"([^"]+)"]]),
    author = book_info.author or html:match([["author"%s*:%s*"([^"]+)"]]),
    psvts = reader.psvts or html:match([["psvts"%s*:%s*"([^"]+)"]]),
    pclts = reader.pclts or html:match([["pclts"%s*:%s*"([^"]+)"]]),
    token = reader.token or html:match([["token"%s*:%s*"([^"]+)"]]),
    current_chapter = current_chapter,
    progress = progress_book,
    -- `otherType` lists the alternative renderings the service has for the book;
    -- one carrying `translateStatus` is the machine translation the reader offers.
    -- (`otherType` 列出服务端为这本书准备的其它呈现方式；带 `translateStatus` 的那项就是阅读器
    --  提供的机器翻译)
    translatable = (function()
      for _, other in ipairs(type(book_info.otherType) == "table" and book_info.otherType or {}) do
        if type(other) == "table" and other.translateStatus ~= nil and other.showType then
          return true
        end
      end
      return false
    end)(),
  }
end

---@param book table
---@param state table
---@return table book
function ReaderState.apply_to_book(book, state)
  local current_chapter = state.current_chapter or {}
  local progress = state.progress or {}
  book.chapter_uid = current_chapter.chapterUid or progress.chapterUid or book.chapter_uid
  book.chapter_idx = tonumber(current_chapter.chapterIdx or progress.chapterIdx)
    or tonumber(book.chapter_idx)
  book.chapter_offset = tonumber(current_chapter.chapterOffset or progress.chapterOffset)
    or tonumber(book.chapter_offset)
    or 0
  book.progress = tonumber(progress.progress) or tonumber(book.progress) or 0
  book.summary = progress.summary or book.summary or ""
  return book
end

return ReaderState
