-- The source block's text model: lines, a caret and selection in UTF-16 columns, edits with undo and
-- redo, and line maps that keep overlay marks on their lines across edits. Pure (no `tern` calls) and
-- limited to the subset Luau shares with Lua 5.4, so `tests/source.lua` runs it under plain `lua`.
--
-- Positions are `{l = line, c = column}`: one-based lines, zero-based columns in UTF-16 code units,
-- as the `editor` node counts offsets.

local M = {}

-- The undo history's budget for the text its steps hold.
M.MAX_UNDO_BYTES = 8 * 1024 * 1024

local function size(b)
  if b < 0x80 or (b >= 0x80 and b < 0xC0) then
    return 1
  elseif b < 0xE0 then
    return 2
  elseif b < 0xF0 then
    return 3
  end
  return 4
end

-- UTF-16 units in `s`.
function M.units(s)
  local n = 0
  for i = 1, #s do
    local b = string.byte(s, i)
    if b < 0x80 or b >= 0xC0 then
      n = n + 1
      if b >= 0xF0 then
        n = n + 1
      end
    end
  end
  return n
end

-- The byte index where UTF-16 column `col` starts in `s` (#s + 1 at or past the end), and the
-- column actually reached: an offset inside a surrogate pair rounds down to its character.
function M.byte(s, col)
  local units, i = 0, 1
  while i <= #s and units < col do
    local n = size(string.byte(s, i))
    local w = n == 4 and 2 or 1
    if units + w > col then
      break
    end
    units = units + w
    i = i + n
  end
  return i, units
end

-- The UTF-16 column of byte index `i` in `s`.
function M.column(s, i)
  return M.units(string.sub(s, 1, i - 1))
end

local function split(text)
  local parts, position = {}, 1
  while true do
    local newline = string.find(text, "\n", position, true)
    if not newline then
      parts[#parts + 1] = string.sub(text, position)
      return parts
    end
    parts[#parts + 1] = string.sub(text, position, newline - 1)
    position = newline + 1
  end
end
M.split = split

local function copy(p)
  return p and { l = p.l, c = p.c } or nil
end

local function before(a, b)
  return a.l < b.l or (a.l == b.l and a.c < b.c)
end

local function equal(a, b)
  return a.l == b.l and a.c == b.c
end

-- `text` with "\r\n" endings normalized to "\n"; also says which ending the file used.
function M.new(text)
  local ending = "\n"
  if string.find(text, "\r\n", 1, true) then
    ending = "\r\n"
    text = string.gsub(text, "\r\n", "\n")
  end
  local buf = {
    lines = split(text),
    lens = {},
    cursor = { l = 1, c = 0 },
    anchor = nil,
    goal = nil,
    undo = {},
    redo = {},
    stamp = 0,
    saved = 0,
    ending = ending,
    maps = {},
  }
  for i, line in ipairs(buf.lines) do
    buf.lens[i] = M.units(line)
  end
  return buf
end

function M.text(buf)
  return table.concat(buf.lines, "\n")
end

-- The text as it is written to disk, with the file's original line ending.
function M.disk(buf)
  return table.concat(buf.lines, buf.ending)
end

function M.length(buf)
  local n = #buf.lines - 1
  for _, len in ipairs(buf.lens) do
    n = n + len
  end
  return n
end

-- UTF-16 offset of each line's start.
function M.starts(buf)
  local starts, offset = {}, 0
  for i, len in ipairs(buf.lens) do
    starts[i] = offset
    offset = offset + len + 1
  end
  return starts
end

function M.offset(buf, p)
  local n = 0
  for i = 1, p.l - 1 do
    n = n + buf.lens[i] + 1
  end
  return n + p.c
end

-- The position of UTF-16 offset `offset`, clamped to the text.
function M.position(buf, offset)
  offset = math.max(0, offset)
  for i, len in ipairs(buf.lens) do
    if offset <= len then
      local _, c = M.byte(buf.lines[i], offset)
      return { l = i, c = c }
    end
    offset = offset - len - 1
  end
  local last = #buf.lines
  return { l = last, c = buf.lens[last] }
end

function M.clamp(buf, p)
  local l = math.max(1, math.min(p.l, #buf.lines))
  local _, c = M.byte(buf.lines[l], math.max(0, math.min(p.c, buf.lens[l])))
  return { l = l, c = c }
end

-- The selection as an ordered pair, or nil when there is none.
function M.selection(buf)
  local a = buf.anchor
  if not a or equal(a, buf.cursor) then
    return nil
  end
  if before(a, buf.cursor) then
    return copy(a), copy(buf.cursor)
  end
  return copy(buf.cursor), copy(a)
end

function M.slice(buf, a, b)
  if a.l == b.l then
    local line = buf.lines[a.l]
    return string.sub(line, (M.byte(line, a.c)), (M.byte(line, b.c)) - 1)
  end
  local parts = { string.sub(buf.lines[a.l], (M.byte(buf.lines[a.l], a.c))) }
  for i = a.l + 1, b.l - 1 do
    parts[#parts + 1] = buf.lines[i]
  end
  parts[#parts + 1] = string.sub(buf.lines[b.l], 1, (M.byte(buf.lines[b.l], b.c)) - 1)
  return table.concat(parts, "\n")
end

-- Where `text` ends when inserted at `p`.
local function finish(p, text)
  local parts = split(text)
  if #parts == 1 then
    return { l = p.l, c = p.c + M.units(text) }
  end
  return { l = p.l + #parts - 1, c = M.units(parts[#parts]) }
end

-- How an edit moved lines: old lines `first..last` became `count` new lines starting at `first`,
-- paired from the end when the edit began at a line start (inserting lines above a line, deleting
-- whole lines), else from the start. Returns the new line of old line `line`, or nil if it went.
function M.translate(edit, line)
  if line < edit.first then
    return line
  end
  if line > edit.last then
    return line + edit.count - (edit.last - edit.first + 1)
  end
  local old = edit.last - edit.first + 1
  local paired = math.min(old, edit.count)
  if edit.tail then
    local back = edit.last - line
    return back < paired and (edit.first + edit.count - 1 - back) or nil
  end
  local ahead = line - edit.first
  return ahead < paired and (edit.first + ahead) or nil
end

-- Moves a sorted list of line numbers through an edit, dropping lines that went and duplicates.
function M.remap(lines, edit)
  local out, seen = {}, {}
  for _, line in ipairs(lines) do
    local moved = M.translate(edit, line)
    if moved and not seen[moved] then
      seen[moved] = true
      out[#out + 1] = moved
    end
  end
  table.sort(out)
  return out
end

-- Replaces `a..b` with `text` without recording undo. Returns the removed text, the end of the
-- inserted text and the line movement (see `translate`).
local function splice(buf, a, b, text)
  local removed = M.slice(buf, a, b)
  local first, last = buf.lines[a.l], buf.lines[b.l]
  local prefix = string.sub(first, 1, (M.byte(first, a.c)) - 1)
  local suffix = string.sub(last, (M.byte(last, b.c)))
  local parts = split(text)
  parts[1] = prefix .. parts[1]
  parts[#parts] = parts[#parts] .. suffix
  local old = b.l - a.l + 1
  local edit = { first = a.l, last = b.l, count = #parts, tail = prefix == "" and old ~= #parts }
  if #parts == old then
    for i, part in ipairs(parts) do
      buf.lines[a.l + i - 1] = part
      buf.lens[a.l + i - 1] = M.units(part)
    end
  else
    local lines, lens = {}, {}
    for i = 1, a.l - 1 do
      lines[i], lens[i] = buf.lines[i], buf.lens[i]
    end
    for _, part in ipairs(parts) do
      lines[#lines + 1] = part
      lens[#lens + 1] = M.units(part)
    end
    for i = b.l + 1, #buf.lines do
      lines[#lines + 1], lens[#lens + 1] = buf.lines[i], buf.lens[i]
    end
    buf.lines, buf.lens = lines, lens
    for name, map in pairs(buf.maps) do
      local moved = {}
      for i = 1, #map + (#parts - old) do
        moved[i] = false
      end
      for i, base in ipairs(map) do
        local to = M.translate(edit, i)
        if to then
          moved[to] = base
        end
      end
      buf.maps[name] = moved
    end
  end
  return removed, finish(a, text), edit
end

local function stamp(buf)
  buf.stamp = buf.stamp + 1
  return buf.stamp
end

-- The stamp of the newest applied edit (0 when none): compared with `saved` for the dirty state.
local function top(buf)
  local entry = buf.undo[#buf.undo]
  return entry and entry.id or 0
end

function M.dirty(buf)
  return top(buf) ~= buf.saved
end

function M.mark_saved(buf)
  buf.saved = top(buf)
end

-- Replaces `a..b` with `text` as one undoable step and puts the caret after it. Typing merges into
-- the previous step while it continues where that one ended. Returns the line movement.
function M.replace(buf, a, b, text, kind)
  local was = { cursor = copy(buf.cursor), anchor = copy(buf.anchor) }
  local removed, stop, edit = splice(buf, a, b, text)
  local last = buf.undo[#buf.undo]
  if
    kind == "type"
    and last
    and last.kind == "type"
    and removed == ""
    and last.id ~= buf.saved
    and equal(last.stop, a)
    and not string.find(text, "[%s]")
  then
    last.inserted = last.inserted .. text
    last.stop = stop
  else
    buf.undo[#buf.undo + 1] = {
      id = stamp(buf),
      kind = kind,
      start = copy(a),
      stop = stop,
      removed = removed,
      inserted = text,
      was = was,
    }
    -- At most 1,000 steps and MAX_UNDO_BYTES of their text (a reload step holds both versions of
    -- what changed), evicting the oldest; the newest step always stays.
    local bytes = 0
    for _, entry in ipairs(buf.undo) do
      bytes = bytes + #entry.removed + #entry.inserted
    end
    while #buf.undo > 1 and (#buf.undo > 1000 or bytes > M.MAX_UNDO_BYTES) do
      local oldest = table.remove(buf.undo, 1)
      bytes = bytes - #oldest.removed - #oldest.inserted
    end
  end
  buf.redo = {}
  buf.cursor, buf.anchor, buf.goal = stop, nil, nil
  return edit
end

-- Replaces the buffer with `text` as read from disk, as one undoable step that touches only the lines
-- that differ: the common leading and trailing lines stay where they are, so marks on them keep their
-- lines and the undo entry holds only the changed middle. Takes the disk's line ending. Returns the
-- line movement, or nil when nothing changed.
function M.reload(buf, text)
  local fresh = M.new(text)
  buf.ending = fresh.ending
  local old, new = buf.lines, fresh.lines
  local head = 0
  while head < #old and head < #new and old[head + 1] == new[head + 1] do
    head = head + 1
  end
  if head == #old and head == #new then
    return nil
  end
  local tail = 0
  while tail < #old - head and tail < #new - head and old[#old - tail] == new[#new - tail] do
    tail = tail + 1
  end
  local middle = {}
  for i = head + 1, #new - tail do
    middle[#middle + 1] = new[i]
  end
  if tail > 0 then
    -- From the first changed line's start to the start of the first common trailing line.
    local text_in = #middle > 0 and (table.concat(middle, "\n") .. "\n") or ""
    return M.replace(buf, { l = head + 1, c = 0 }, { l = #old - tail + 1, c = 0 }, text_in, "reload")
  end
  if head > 0 then
    -- From the end of the last common leading line to the end of the text.
    local text_in = #middle > 0 and ("\n" .. table.concat(middle, "\n")) or ""
    return M.replace(buf, { l = head, c = buf.lens[head] }, { l = #old, c = buf.lens[#old] }, text_in, "reload")
  end
  return M.replace(buf, { l = 1, c = 0 }, { l = #old, c = buf.lens[#old] }, table.concat(new, "\n"), "reload")
end

function M.undo(buf)
  local entry = table.remove(buf.undo)
  if not entry then
    return nil
  end
  local _, _, edit = splice(buf, entry.start, entry.stop, entry.removed)
  buf.redo[#buf.redo + 1] = entry
  buf.cursor, buf.anchor, buf.goal =
    M.clamp(buf, entry.was.cursor), entry.was.anchor and M.clamp(buf, entry.was.anchor), nil
  return edit
end

function M.redo(buf)
  local entry = table.remove(buf.redo)
  if not entry then
    return nil
  end
  local _, stop, edit = splice(buf, entry.start, finish(entry.start, entry.removed), entry.inserted)
  entry.stop = stop
  buf.undo[#buf.undo + 1] = entry
  buf.cursor, buf.anchor, buf.goal = stop, nil, nil
  return edit
end

-- Replaces the selection (or inserts at the caret) with `text`.
function M.insert(buf, text, kind)
  local a, b = M.selection(buf)
  if not a then
    a, b = copy(buf.cursor), copy(buf.cursor)
  end
  return M.replace(buf, a, b, text, kind or "type")
end

-- Applies a native `edit` event (UTF-16 offsets into the whole text). Returns nil when the event was
-- computed against another text length, `false` for a caret move, else the line movement.
function M.apply(buf, ev)
  if ev.len ~= nil and ev.len ~= M.length(buf) then
    return nil
  end
  local a, b = M.position(buf, ev.from or 0), M.position(buf, ev.to or ev.from or 0)
  local text = ev.text or ""
  if before(b, a) then
    a, b = b, a
  end
  if equal(a, b) and text == "" then
    buf.cursor, buf.anchor, buf.goal = M.position(buf, ev.cursor or ev.from or 0), nil, nil
    return false
  end
  local edit = M.replace(buf, a, b, text, "edit")
  if ev.cursor then
    buf.cursor = M.position(buf, ev.cursor)
  end
  return edit
end

local function word(ch)
  return ch ~= "" and (string.find(ch, "^[%w_]") ~= nil or string.byte(ch) >= 0x80)
end

-- The character before and at column `c` of `line`.
local function around(line, c)
  local i = M.byte(line, c)
  local j = i - 1
  while j > 1 and string.byte(line, j) >= 0x80 and string.byte(line, j) < 0xC0 do
    j = j - 1
  end
  local prev = j >= 1 and string.sub(line, j, i - 1) or ""
  local nxt = i <= #line and string.sub(line, i, i + size(string.byte(line, i)) - 1) or ""
  return prev, nxt, j, i
end

-- One step left or right from `p`, by character or (with `by_word`) to the next word boundary.
function M.step(buf, p, dir, by_word)
  local l, c = p.l, p.c
  local line = buf.lines[l]
  if dir < 0 then
    if c == 0 then
      return l > 1 and { l = l - 1, c = buf.lens[l - 1] } or { l = l, c = 0 }
    end
    if not by_word then
      local _, _, j = around(line, c)
      return { l = l, c = M.column(line, j) }
    end
    while c > 0 do
      local prev = around(line, c)
      if word(prev) then
        break
      end
      c = M.column(line, select(3, around(line, c)))
    end
    while c > 0 do
      local prev, _, j = around(line, c)
      if not word(prev) then
        break
      end
      c = M.column(line, j)
    end
    return { l = l, c = c }
  end
  if c >= buf.lens[l] then
    return l < #buf.lines and { l = l + 1, c = 0 } or { l = l, c = c }
  end
  if not by_word then
    local _, nxt = around(line, c)
    return { l = l, c = c + M.units(nxt) }
  end
  while c < buf.lens[l] do
    local _, nxt = around(line, c)
    if word(nxt) then
      break
    end
    c = c + M.units(nxt)
  end
  while c < buf.lens[l] do
    local _, nxt = around(line, c)
    if not word(nxt) then
      break
    end
    c = c + M.units(nxt)
  end
  return { l = l, c = c }
end

-- Moves the caret to `p`, extending the selection when `extend`, else clearing it.
function M.go(buf, p, extend, keep_goal)
  if extend then
    buf.anchor = buf.anchor or copy(buf.cursor)
  else
    buf.anchor = nil
  end
  buf.cursor = M.clamp(buf, p)
  if not keep_goal then
    buf.goal = nil
  end
end

-- Arrow keys. Plain ←/→ over a selection collapse it to that side.
function M.horizontal(buf, dir, extend, by_word)
  local a, b = M.selection(buf)
  if a and not extend and not by_word then
    M.go(buf, dir < 0 and a or b, false)
    return
  end
  M.go(buf, M.step(buf, buf.cursor, dir, by_word), extend)
end

function M.vertical(buf, lines, extend)
  local goal = buf.goal or buf.cursor.c
  local l = math.max(1, math.min(#buf.lines, buf.cursor.l + lines))
  M.go(buf, { l = l, c = goal }, extend, true)
  buf.goal = goal
end

local function indentation(line)
  return string.match(line, "^[ \t]*")
end

-- Home goes to the first non-blank character, or to column 0 when already there.
function M.home(buf, extend)
  local line = buf.lines[buf.cursor.l]
  local first = M.units(indentation(line))
  M.go(buf, { l = buf.cursor.l, c = buf.cursor.c == first and 0 or first }, extend)
end

function M.line_end(buf, extend)
  M.go(buf, { l = buf.cursor.l, c = buf.lens[buf.cursor.l] }, extend)
end

function M.select_all(buf)
  buf.anchor = { l = 1, c = 0 }
  buf.cursor = { l = #buf.lines, c = buf.lens[#buf.lines] }
end

-- The indent unit the file uses: a tab, or the smallest run of leading spaces (2 when none).
function M.unit(buf, fallback)
  local smallest = nil
  for _, line in ipairs(buf.lines) do
    local lead = indentation(line)
    if string.sub(lead, 1, 1) == "\t" then
      return "\t"
    end
    if #lead > 0 and string.find(line, "%S") and (not smallest or #lead < smallest) then
      smallest = #lead
    end
  end
  return string.rep(" ", smallest and math.min(math.max(smallest, 2), 8) or (fallback or 2))
end

-- Enter: a newline carrying the current line's indentation, one unit more after an opening bracket
-- or a Python block colon.
function M.newline(buf, unit)
  local a = M.selection(buf) or buf.cursor
  local line = buf.lines[a.l]
  local lead = indentation(string.sub(line, 1, (M.byte(line, a.c)) - 1))
  local before_caret = string.sub(line, 1, (M.byte(line, a.c)) - 1)
  if string.find(before_caret, "[%{%[%(]%s*$") or string.find(before_caret, ":%s*$") then
    lead = lead .. unit
  end
  return M.insert(buf, "\n" .. lead, "newline")
end

-- ⌘Enter: a new line below the current one, with its indentation.
function M.line_below(buf)
  local l = buf.cursor.l
  local lead = indentation(buf.lines[l])
  local stop = { l = l, c = buf.lens[l] }
  return M.replace(buf, stop, stop, "\n" .. lead, "newline")
end

-- The line range a block operation (indent, comment) acts on.
local function block(buf)
  local a, b = M.selection(buf)
  if not a then
    return buf.cursor.l, buf.cursor.l
  end
  local last = b.l
  if b.c == 0 and b.l > a.l then
    last = b.l - 1
  end
  return a.l, last
end

-- Rewrites lines `first..last` through `fn(line) -> new line` as one undoable step, keeping the
-- selection or caret on the same text.
local function rewrite(buf, first, last, fn, kind)
  local cursor, anchor = copy(buf.cursor), copy(buf.anchor)
  local old, new = {}, {}
  for i = first, last do
    old[i] = buf.lines[i]
    new[#new + 1] = fn(buf.lines[i])
  end
  local edit = M.replace(buf, { l = first, c = 0 }, { l = last, c = buf.lens[last] }, table.concat(new, "\n"), kind)
  local function shift(p)
    if not p or p.l < first or p.l > last then
      return p
    end
    local delta = M.units(buf.lines[p.l]) - M.units(old[p.l])
    return M.clamp(buf, { l = p.l, c = math.max(0, p.c + delta) })
  end
  buf.cursor, buf.anchor = shift(cursor), shift(anchor)
  return edit
end

-- Tab: indents the selected lines, or inserts one unit at the caret.
function M.indent(buf, unit)
  local a, b = M.selection(buf)
  if not a or a.l == b.l then
    return M.insert(buf, unit, "indent")
  end
  local first, last = block(buf)
  return rewrite(buf, first, last, function(line)
    return line == "" and line or unit .. line
  end, "indent")
end

-- ⇧Tab: removes up to one unit of leading whitespace from the selected lines.
function M.outdent(buf, unit)
  local first, last = block(buf)
  local width = unit == "\t" and 1 or #unit
  return rewrite(buf, first, last, function(line)
    if string.sub(line, 1, 1) == "\t" then
      return string.sub(line, 2)
    end
    local spaces = #string.match(line, "^ *")
    return string.sub(line, math.min(spaces, width) + 1)
  end, "indent")
end

-- ⌘/: comments the selected lines out with `prefix` at their common indentation, or uncomments
-- them when every non-blank one already starts with it.
function M.comment(buf, prefix)
  local first, last = block(buf)
  local all, depth = true, nil
  for i = first, last do
    local line = buf.lines[i]
    if string.find(line, "%S") then
      local lead = indentation(line)
      depth = (not depth or #lead < depth) and #lead or depth
      if string.sub(line, #lead + 1, #lead + #prefix) ~= prefix then
        all = false
      end
    end
  end
  if not depth then
    return nil
  end
  return rewrite(buf, first, last, function(line)
    if not string.find(line, "%S") then
      return line
    end
    if all then
      local lead = indentation(line)
      local rest = string.sub(line, #lead + #prefix + 1)
      return lead .. (string.sub(rest, 1, 1) == " " and string.sub(rest, 2) or rest)
    end
    return string.sub(line, 1, depth) .. prefix .. " " .. string.sub(line, depth + 1)
  end, "comment")
end

-- Backspace and Delete: the selection, else one character (a word with `by_word`, the rest of the
-- line before the caret with `to_line`). Backspace in leading spaces removes back to the previous
-- indent stop.
function M.delete(buf, dir, by_word, to_line, unit)
  local a, b = M.selection(buf)
  if not a then
    local p = buf.cursor
    if to_line then
      a, b = { l = p.l, c = dir < 0 and 0 or p.c }, { l = p.l, c = dir < 0 and p.c or buf.lens[p.l] }
      if equal(a, b) then
        local other = M.step(buf, p, dir, false)
        a, b = dir < 0 and other or p, dir < 0 and p or other
      end
    else
      local line = buf.lines[p.l]
      local lead = indentation(line)
      if dir < 0 and not by_word and unit and unit ~= "\t" and p.c > 0 and p.c <= #lead and p.c == M.units(lead) then
        local back = (p.c - 1) % #unit + 1
        a, b = { l = p.l, c = p.c - back }, copy(p)
      else
        local other = M.step(buf, p, dir, by_word)
        a, b = dir < 0 and other or copy(p), dir < 0 and copy(p) or other
      end
    end
  end
  if equal(a, b) then
    return nil
  end
  return M.replace(buf, a, b, "", "delete")
end

-- Matches of `query` (case-insensitive unless it has a capital), at most `limit`, as
-- `{l, from, to}` UTF-16 columns per line.
function M.find(buf, query, limit)
  local found = {}
  if query == "" then
    return found
  end
  local fold = not string.find(query, "%u")
  local needle = fold and string.lower(query) or query
  for l, line in ipairs(buf.lines) do
    local hay = fold and string.lower(line) or line
    local position = 1
    while true do
      local s, e = string.find(hay, needle, position, true)
      if not s then
        break
      end
      found[#found + 1] = { l = l, from = M.column(line, s), to = M.column(line, e + 1) }
      if limit and #found >= limit then
        return found
      end
      position = e + 1
    end
  end
  return found
end

-- The first match after the caret (`dir` 1) or before it (`dir` -1), wrapping around.
function M.next_match(matches, p, dir)
  if #matches == 0 then
    return nil
  end
  if dir > 0 then
    for i, m in ipairs(matches) do
      if m.l > p.l or (m.l == p.l and m.from >= p.c) then
        return i
      end
    end
    return 1
  end
  for i = #matches, 1, -1 do
    local m = matches[i]
    if m.l < p.l or (m.l == p.l and m.to < p.c) then
      return i
    end
  end
  return #matches
end

-- A single-line field (find, go to line): `{text, cursor}` in UTF-16 units. Returns true when the
-- key changed it, false when the key is not a field key.
function M.field_key(field, key)
  local text, c = field.text, field.cursor
  local name = key.name
  if name == "backspace" then
    if c > 0 then
      local i = M.byte(text, c)
      local _, _, j = around(text, c)
      field.text = string.sub(text, 1, j - 1) .. string.sub(text, i)
      field.cursor = M.column(text, j)
    end
  elseif name == "delete" then
    local i = M.byte(text, c)
    if i <= #text then
      local n = size(string.byte(text, i))
      field.text = string.sub(text, 1, i - 1) .. string.sub(text, i + n)
    end
  elseif name == "left" then
    if c > 0 then
      local _, _, j = around(text, c)
      field.cursor = M.column(text, j)
    end
  elseif name == "right" then
    local _, nxt = around(text, c)
    field.cursor = c + M.units(nxt)
  elseif name == "home" then
    field.cursor = 0
  elseif name == "end" then
    field.cursor = M.units(text)
  elseif key.text and key.text ~= "" and not key.ctrl and not key.meta then
    local typed = string.gsub(key.text, "[\r\n]", "")
    local i = M.byte(text, c)
    field.text = string.sub(text, 1, i - 1) .. typed .. string.sub(text, i)
    field.cursor = c + M.units(typed)
  else
    return false
  end
  return true
end

-- Applies a native `edit` event to a field.
function M.field_edit(field, ev)
  if ev.len ~= nil and ev.len ~= M.units(field.text) then
    return
  end
  local text = field.text
  local i, j = M.byte(text, ev.from or 0), M.byte(text, ev.to or ev.from or 0)
  field.text = string.sub(text, 1, i - 1) .. string.gsub(ev.text or "", "[\r\n]", "") .. string.sub(text, j)
  field.cursor = ev.cursor or field.cursor
end

return M
