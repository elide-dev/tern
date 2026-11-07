-- Unit tests for plugin/lib/source.luau, the source block's pure helpers. Run: lua tests/source.lua
local here = string.match(arg[0], "^(.*)/[^/]*$") or "."
local source = dofile(here .. "/../plugin/lib/source.luau")

local failures = 0
local function check(name, actual, expected)
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. name .. ": got " .. tostring(actual) .. ", want " .. tostring(expected))
  end
end

check("ascii units", source.units("abc"), 3)
check("bmp units", source.units("λé"), 2)
check("astral units", source.units("a😀b"), 4)
local index = source.index("one\nλ😀\n")
check("line count", index.count, 2)
check("second start", index.starts[2], 4)
check("second length", index.lengths[2], 3)
check("only newline", source.index("\n").count, 1)
check("inner blank", source.index("a\n\nb").count, 3)
check("no newline", source.index("x").count, 1)
check("text ok", source.text("plain λ"), true)
check("text nul", source.text("a\0b"), false)
check("text invalid", source.text("\255\254"), false)
check("lang mjs", source.lang("/p/a.mjs"), "javascript")
check("lang kt", source.lang("/p/A.kt"), "kotlin")
check("lang none", source.lang("/p/a.txt"), nil)
check("debuggable kt", source.debuggable("/p/A.kt"), false)
check("test file", source.test_file("/p/a.test.mjs"), true)
check("not test file", source.test_file("/p/atest.mjs"), false)
check("number", source.number(7, 3), "  7")
check("scroll down", source.scroll(0, 30, 10, 100), 20)
check("scroll up", source.scroll(20, 5, 10, 100), 4)
check("scroll clamp", source.scroll(0, 3, 10, 5), 0)
check("relative", source.relative("/r/a/b.js", "/r"), "a/b.js")
check("relative outside", source.relative("/rr/b.js", "/r"), nil)
check("same relative", source.same("a/b.js", "/r/a/b.js", "a/b.js", { "/r" }), true)
check("same canonical", source.same("/private/r/a/b.js", "/r/a/b.js", "a/b.js", { "/r", "/private/r" }), true)
check("same other", source.same("/x/a/b.js", "/r/a/b.js", "a/b.js", { "/r" }), false)
local marks, covered, total = source.coverage({
  { line = 1, covered = true },
  { line = 2, covered = true, branches = { covered = 1, total = 2 } },
  { line = 5, covered = false },
})
check("covered mark", marks[1].state, "covered")
check("partial mark", marks[2].state, "partial")
check("uncovered mark", marks[5].state, "uncovered")
check("unmeasured", marks[3], nil)
check("covered count", covered, 2)
check("total count", total, 3)
-- A synthetic page with the coming `inferred` state and a state this block does not know.
local later, later_covered, later_total = source.coverage({
  { line = 1, covered = true },
  { line = 2, covered = true, state = "inferred" },
  { line = 3, covered = false, state = "uncovered" },
  { line = 4, covered = true, state = "speculative" },
})
check("inferred mark", later[2].state, "inferred")
check("inferred not counted", later_total, 2)
check("inferred not covered", later_covered, 1)
check("named uncovered", later[3].state, "uncovered")
check("unknown state unmeasured", later[4], nil)
check("percent", source.percent(2, 3), 66)
check("percent none", source.percent(0, 0), nil)
local lines, added = source.toggle({ 2, 9 }, 5)
check("toggle add", table.concat(lines, ","), "2,5,9")
check("toggle added", added, true)
lines, added = source.toggle(lines, 2)
check("toggle remove", table.concat(lines, ","), "5,9")
check("toggle removed", added, false)
check("file url", source.file_url("/p/a b'λ.js", 3), "file:///p/a%20b%27%CE%BB.js#L3")
local id = source.uuid(math.random)
check("uuid shape", string.find(id, "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x+$") ~= nil, true)
check("uuid length", #id, 36)

check("utf16be ascii", source.utf16be("A"), "\0A")
check("utf16be astral", source.utf16be("😀"), "\216\061\222\000")
check("comment js", source.comment("/p/a.ts"), "//")
check("comment py", source.comment("/p/a.py"), "#")

-- A restored draft applies only over the disk text it was based on.
check("digest stable", source.digest("abc"), source.digest("abc"))
check("digest differs", source.digest("abc") ~= source.digest("abd"), true)
check("digest length", source.digest("ab") ~= source.digest("ab\0"), true)
local base = source.digest("disk v1")
check("no draft", source.restore_plan(nil, nil, base), "none")
check("draft over its base", source.restore_plan("edited", base, base), "apply")
check("draft over newer disk", source.restore_plan("edited", base, source.digest("disk v2")), "conflict")
check("draft without a base", source.restore_plan("edited", nil, base), "conflict")

-- Buffer: UTF-16 positions, edits, undo, line maps.
local buffer = dofile(here .. "/../plugin/lib/buffer.luau")
local function key(name, extra)
  local k = { name = name, ctrl = false, alt = false, shift = false, meta = false }
  for field, value in pairs(extra or {}) do
    k[field] = value
  end
  return k
end
check("byte astral", buffer.byte("a😀b", 3), 6)
check("byte inside pair rounds down", select(2, buffer.byte("a😀b", 2)), 1)
check("column astral", buffer.column("a😀b", 6), 3)
local b = buffer.new("a😀b\nλx\n")
check("length", buffer.length(b), 8)
check("position after astral", buffer.position(b, 3).c, 3)
check("position next line", buffer.position(b, 5).l, 2)
check("offset roundtrip", buffer.offset(b, buffer.position(b, 6)), 6)
b.cursor = { l = 1, c = 1 }
buffer.horizontal(b, 1, false, false)
check("right over astral", b.cursor.c, 3)
buffer.horizontal(b, -1, true, false)
check("shift-left selects astral", buffer.slice(b, buffer.selection(b)), "😀")
buffer.insert(b, "Z")
check("typing replaces selection", b.lines[1], "aZb")
buffer.insert(b, "Y")
check("typing merges", #b.undo, 1)
buffer.undo(b)
check("undo restores astral", b.lines[1], "a😀b")
check("undo restores caret", b.cursor.c, 1)
buffer.redo(b)
check("redo", b.lines[1], "aZYb")
check("dirty after edit", buffer.dirty(b), true)
buffer.mark_saved(b)
check("clean after save", buffer.dirty(b), false)
buffer.undo(b)
check("dirty after undo past save", buffer.dirty(b), true)
buffer.redo(b)
check("clean after redo to save", buffer.dirty(b), false)

local e = buffer.new("x\n😀y")
check("edit len guard", buffer.apply(e, { from = 0, to = 0, text = "q", cursor = 1, len = 99 }), nil)
buffer.apply(e, { from = 2, to = 4, text = "", cursor = 2, len = 5 })
check("native edit deletes astral", e.lines[2], "y")
check("native caret move", buffer.apply(e, { from = 1, to = 1, text = "", cursor = 2, len = 3 }), false)
check("native caret line", e.cursor.l, 2)

local crlf = buffer.new("a\r\nb\r\n")
check("crlf lines", crlf.lines[2], "b")
check("crlf disk", buffer.disk(crlf), "a\r\nb\r\n")

local c = buffer.new("function f() {\n  return 1\n}")
c.cursor = { l = 1, c = 14 }
buffer.newline(c, "  ")
check("auto-indent after brace", c.lines[2], "  ")
check("auto-indent caret", c.cursor.c, 2)
c.cursor = { l = 3, c = 10 }
buffer.newline(c, "  ")
check("auto-indent copies", c.lines[4], "  ")
c.anchor, c.cursor = { l = 3, c = 0 }, { l = 4, c = 2 }
buffer.indent(c, "  ")
check("indent selection", c.lines[3], "    return 1")
buffer.outdent(c, "  ")
check("outdent selection", c.lines[3], "  return 1")
c.anchor, c.cursor = nil, { l = 3, c = 4 }
buffer.comment(c, "//")
check("comment", c.lines[3], "  // return 1")
check("comment keeps caret on text", c.cursor.c, 7)
buffer.comment(c, "//")
check("uncomment", c.lines[3], "  return 1")
c.cursor = { l = 3, c = 2 }
buffer.delete(c, -1, false, false, "  ")
check("backspace to indent stop", c.lines[3], "return 1")
c.cursor = { l = 3, c = 6 }
buffer.delete(c, -1, true, false, "  ")
check("word backspace", c.lines[3], " 1")
c.cursor = { l = 1, c = 0 }
buffer.horizontal(c, 1, false, true)
check("word move", c.cursor.c, 8)
buffer.line_below(c)
check("line below", c.cursor.l, 2)
buffer.select_all(c)
check("select all", buffer.slice(c, buffer.selection(c)), buffer.text(c))
check("unit spaces", buffer.unit(buffer.new("a\n    b\n  c")), "  ")
check("unit tab", buffer.unit(buffer.new("a\n\tb")), "\t")

-- Line maps follow edits: inserting above shifts, edits in place keep, deletes drop.
local m = buffer.new("one\ntwo\nthree")
m.maps.base = { 1, 2, 3 }
m.cursor = { l = 2, c = 0 }
buffer.insert(m, "new\n")
check("map shifted", m.maps.base[3], 2)
check("map inserted line", m.maps.base[2], false)
check("map kept", m.maps.base[1], 1)
m.anchor, m.cursor = { l = 3, c = 0 }, { l = 4, c = 0 }
buffer.insert(m, "")
check("map after delete", m.maps.base[3], 3)
buffer.undo(m)
check("map after undo", m.maps.base[4], 3)
local edit = { first = 2, last = 2, count = 3, tail = true }
check("translate after", buffer.translate(edit, 5), 7)
check("translate tail", buffer.translate(edit, 2), 4)
check("remap", table.concat(buffer.remap({ 1, 2, 5 }, edit), ","), "1,4,7")

local f = buffer.new("Foo foo\nfoo😀foo")
local hits = buffer.find(f, "foo")
check("find folds", #hits, 4)
check("find astral columns", hits[4].from, 5)
check("find case", #buffer.find(f, "Foo"), 1)
check("next match", buffer.next_match(hits, { l = 1, c = 1 }, 1), 2)
check("previous match wraps", buffer.next_match(hits, { l = 1, c = 0 }, -1), 4)

local field = { text = "", cursor = 0 }
buffer.field_key(field, key("1", { text = "1" }))
buffer.field_key(field, key("😀", { text = "😀" }))
check("field typing", field.text, "1😀")
check("field cursor", field.cursor, 3)
buffer.field_key(field, key("backspace"))
check("field backspace astral", field.text, "1")
check("field ignores", buffer.field_key(field, key("f5")), false)
buffer.field_edit(field, { from = 0, to = 1, text = "42", cursor = 2, len = 1 })
check("field native edit", field.text, "42")

-- Reload from disk replaces only the changed middle, so marks above and below keep their lines.
local function ten()
  local lines = {}
  for i = 1, 10 do
    lines[i] = "line " .. i
  end
  return table.concat(lines, "\n") .. "\n"
end
local function reloaded(old, new, points)
  local r = buffer.new(old)
  local edit = buffer.reload(r, new)
  return r, edit and table.concat(buffer.remap(points, edit), ",") or table.concat(points, ",")
end
local inserted_text = string.gsub(ten(), "line 5\n", "line 5\nnew\n")
local r, moved = reloaded(ten(), inserted_text, { 1, 2, 8 })
check("reload insert keeps marks above", moved, "1,2,9")
check("reload insert text", buffer.disk(r), inserted_text)
check("reload undo is the middle only", r.undo[1].inserted, "new\n")
local deleted_text = string.gsub(ten(), "line 5\n", "")
r, moved = reloaded(ten(), deleted_text, { 2, 8 })
check("reload delete keeps marks", moved, "2,7")
r, moved = reloaded(ten(), ten() .. "line 11\n", { 3, 10 })
check("reload append keeps marks", moved, "3,10")
check("reload append text", buffer.disk(r), ten() .. "line 11\n")
r, moved = reloaded(ten(), string.gsub(ten(), "line 9\nline 10\n", ""), { 3, 10 })
check("reload truncate drops the cut", moved, "3")
local same = buffer.new(ten())
check("reload unchanged is no edit", buffer.reload(same, ten()), nil)
check("reload unchanged no undo", #same.undo, 0)
local crlf_reload = buffer.new("a\nb\n")
buffer.reload(crlf_reload, "a\r\nb\r\nc\r\n")
check("reload takes the disk ending", buffer.disk(crlf_reload), "a\r\nb\r\nc\r\n")

-- Undo keeps at most MAX_UNDO_BYTES of removed and inserted text, evicting the oldest steps.
local big = buffer.new("")
local chunk = string.rep("x", 1024 * 1024)
for i = 1, 12 do
  big.cursor = { l = 1, c = 0 }
  buffer.replace(big, { l = 1, c = 0 }, { l = 1, c = big.lens[1] }, chunk .. i, "reload")
end
local held = 0
for _, entry in ipairs(big.undo) do
  held = held + #entry.removed + #entry.inserted
end
check("undo bytes bounded", held <= buffer.MAX_UNDO_BYTES, true)
check("undo keeps the newest", big.undo[#big.undo].inserted, chunk .. 12)
check("undo still has steps", #big.undo >= 3, true)

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("PASS: source helpers")
