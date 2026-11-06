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

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("PASS: source helpers")
