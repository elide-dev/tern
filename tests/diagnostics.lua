-- Unit tests for plugin/lib/diagnostics.luau, on the same compiler samples as the runtime's
-- parser (Elide crates/cli/src/building/testdata, copied to tests/fixtures/diagnostics).
-- Run: lua tests/diagnostics.lua
local here = string.match(arg[0], "^(.*)/[^/]*$") or "."
local diagnostics = dofile(here .. "/../plugin/lib/diagnostics.luau")

local failures = 0
local function show(value)
  if type(value) ~= "table" then
    return type(value) == "string" and string.format("%q", value) or tostring(value)
  end
  local keys = {}
  for key in pairs(value) do
    table.insert(keys, key)
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, key in ipairs(keys) do
    table.insert(parts, tostring(key) .. "=" .. show(value[key]))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
local function check(name, actual, expected)
  if show(actual) ~= show(expected) then
    failures = failures + 1
    print("FAIL " .. name .. ":\n  got  " .. show(actual) .. "\n  want " .. show(expected))
  end
end
local function fixture(name)
  local file = assert(io.open(here .. "/fixtures/diagnostics/" .. name, "rb"))
  local text = file:read("a")
  file:close()
  return text
end
local function pick(list, fields)
  local out = {}
  for index, d in ipairs(list) do
    local row = {}
    for position, field in ipairs(fields) do
      row[position] = d[field] == nil and "-" or d[field]
    end
    out[index] = row
  end
  return out
end

-- javac: caret columns, lint codes, indented notes.
local javac = diagnostics.parse(fixture("javac.txt"), "/w/kt")
check("javac summary", pick(javac, { "severity", "line", "col", "code" }), {
  { "error", 5, 22, "-" },
  { "warning", 6, 5, "rawtypes" },
  { "warning", 6, 20, "rawtypes" },
  { "warning", 7, 12, "unchecked" },
  { "error", 8, 12, "-" },
  { "error", 10, 20, "-" },
})
check("javac tool", javac[1].tool, "javac")
check("javac path", javac[1].path, "/w/raw/Bad.java")
check("javac message", javac[1].message, "incompatible types: int cannot be converted to String")
check("javac excerpt", javac[1].excerpt, { first_line = 5, text = "    String s = value * 2;" })
check("javac code stripped", javac[2].message, "found raw type: List")
check("javac notes", javac[2].notes, {
  "missing type arguments for generic class List<E>",
  "where E is a type-variable:",
  "E extends Object declared in interface List",
})
check("javac symbol notes", javac[6].notes, { "symbol:   method undefinedCall()", "location: class Bad" })

-- kotlinc: plain and `[NAME]` forms; the header's column wins over the caret.
local error = diagnostics.parse(fixture("kotlinc-plain-error.txt"), "/w/raw")
check("kotlinc error", pick(error, { "severity", "path", "line", "col", "tool" }), {
  { "error", "/w/raw/Raw.kt", 6, 19, "kotlinc" },
})
check("kotlinc message", error[1].message, "initializer type mismatch: expected 'String', actual 'Int'.")
check("kotlinc excerpt", error[1].excerpt, { first_line = 6, text = "  val y: String = x" })
local warnings = diagnostics.parse(fixture("kotlinc-plain-warn.txt"), "/w/raw")
check("kotlinc warnings", pick(warnings, { "severity", "col" }), { { "warning", 11 }, { "warning", 16 } })
local named = diagnostics.parse(fixture("kotlinc-names-warn.txt"), "/w/raw")
check("kotlinc codes", pick(named, { "code" }), { { "UNNECESSARY_NOT_NULL_ASSERTION" }, { "DEPRECATION" } })
check("kotlinc named message", named[2].message, "'fun old(): Int' is deprecated. old.")

-- Gradle-style kotlinc with file URLs.
local gradle = diagnostics.parse(fixture("kotlinc-gradle-error.txt"), "/w/kt")
check("gradle error", pick(gradle, { "severity", "path", "line", "col" }), { { "error", "/w/raw/Raw.kt", 6, 19 } })
check("gradle message", gradle[1].message, "Initializer type mismatch: expected 'String', actual 'Int'.")
local gradle_warn = diagnostics.parse(fixture("kotlinc-gradle-warn.txt"), "/w/kt")
check("gradle warnings", pick(gradle_warn, { "severity", "col" }), { { "warning", 11 }, { "warning", 16 } })

-- Elide's rendering: snippets kept, wrapper lines and elapsed-time prefixes skipped.
local elide = diagnostics.parse(fixture("elide-kotlinc-warn.txt"), "/w/raw")
check("elide count", #elide, 2)
check("elide tool", elide[1].tool, "kotlinc")
check("elide message", elide[1].message, "Unnecessary non-null assertion (!!) on a non-null receiver of type 'Int'.")
check("elide location", pick(elide, { "path", "line", "col" })[1], { "/w/raw/Warn.kt", 7, 11 })
check("elide excerpt", elide[1].excerpt, {
  first_line = 5,
  text = "fun warn(x: Int): Int {\n  val y = x\n  return x!! + old()\n}",
})
local elide_error = diagnostics.parse(fixture("elide-kotlinc-error.txt"), "/w/raw")
check("elide error count", #elide_error, 1)
check("elide error severity", elide_error[1].severity, "error")
local build = diagnostics.parse(fixture("build-plain.txt"), "/w/kt")
check("build", pick(build, { "severity", "tool", "line" }), { { "warning", "kotlinc", 5 }, { "error", "javac", 5 } })
check("build path", build[2].path, "/w/kt/src/main/com/example/Util.java")
check("build excerpt first line", build[2].excerpt.first_line, 3)

-- javac's closing notes, with their follow-up as a suggestion.
local notes = diagnostics.parse(
  "Note: Bad.java uses unchecked or unsafe operations.\nNote: Recompile with -Xlint:unchecked for details.\n",
  "/w"
)
check("closing note", pick(notes, { "severity", "tool", "message" }), {
  { "note", "javac", "Bad.java uses unchecked or unsafe operations." },
})
check("closing note suggestion", notes[1].suggestions, { "Recompile with -Xlint:unchecked for details." })

-- Escapes, stamps and summaries.
check("plain csi", diagnostics.plain("\27[1;31merror:\27[0m x"), "error: x")
check("plain osc", diagnostics.plain("\27]8;;file:///a\27\\a.kt\27]8;;\27\\"), "a.kt")
check("unstamped", diagnostics.unstamped("[ 1.0s] error: x"), "error: x")
check("unstamped ms", diagnostics.unstamped("[249ms] warning: y"), "warning: y")
check("not a stamp", diagnostics.unstamped("[not a stamp] z"), "[not a stamp] z")
check("summary", diagnostics.summary("3 errors"), true)
check("summary kotlin", diagnostics.summary("  0 errors, 2 warnings."), true)
check("not a summary", diagnostics.summary("errors abound"), false)
check("colored javac", #diagnostics.parse("\27[1m/w/A.java:1: \27[31merror:\27[0m boom\n", "/w"), 1)

-- Collecting: repeats dropped, kept up to KEPT, counts exact past it.
local many = {}
for n = 1, diagnostics.KEPT + 10 do
  local d = { severity = "warning", path = "/w/a.kt", line = n, message = "x" }
  table.insert(many, d)
  table.insert(many, { severity = "warning", path = "/w/a.kt", line = n, message = "x" })
end
local kept, counts = diagnostics.collect(many)
check("collect kept", #kept, diagnostics.KEPT)
check("collect counts", counts, { error = 0, warning = diagnostics.KEPT + 10, note = 0, dropped = 10 })

-- Grouping: files with errors first, then first-seen; by line within a file; no file last.
local grouped = diagnostics.by_file({
  { severity = "warning", path = "/w.kt", line = 4, message = "m4" },
  { severity = "error", path = "/b.kt", line = 9, message = "m9" },
  { severity = "error", path = "/a.java", line = 3, message = "m3" },
  { severity = "error", line = 1, message = "m1" },
  { severity = "warning", path = "/b.kt", line = 2, message = "m2" },
})
local order = {}
for index, group in ipairs(grouped) do
  local lines = {}
  for position, d in ipairs(group.items) do
    lines[position] = d.line
  end
  order[index] = { group.path or "-", table.concat(lines, ",") }
end
check("groups", order, { { "/b.kt", "2,9" }, { "/a.java", "3" }, { "/w.kt", "4" }, { "-", "1" } })
check("group counts", grouped[1].counts, { error = 1, warning = 1, note = 0 })

-- A long line full of `": "` (minified JSON) is not quadratic: 256 KB parses in under 50 ms.
local long = string.rep('"k": 1, ', 32768)
local started = os.clock()
check("long line has no diagnostic", #diagnostics.parse(long, "/w"), 0)
local took = os.clock() - started
check("long line under 50 ms", took < 0.05, true)
if took >= 0.05 then
  print("  took " .. string.format("%.3f", took) .. " s")
end
-- A header past the first 4 KB of a line is not one (compilers print short headers).
check("header in a short line", #diagnostics.parse("/w/A.java:3: error: boom", "/w"), 1)

-- Incremental parsing: the same result as one parse, with only new lines read again.
local text = fixture("javac.txt")
local all = {}
for line in string.gmatch(text, "([^\n]*)\n") do
  table.insert(all, line)
end
local session = diagnostics.session("/w/kt")
for index = 1, #all do
  session:add(all[index])
  if index % 3 == 0 then
    session:result()
  end
end
check("incremental equals whole", pick(session:result(), { "severity", "line", "col", "code" }),
  pick(diagnostics.parse(text, "/w/kt"), { "severity", "line", "col", "code" }))
check("incremental keeps notes", session:result()[2].notes, javac[2].notes)

-- Reports, phrases and links.
local report = diagnostics.report({
  version = 1,
  outcome = "failure",
  errors = 3,
  warnings = 1,
  notes = 0,
  dropped = 0,
  diagnostics = {
    { severity = "error", message = "boom", path = "/p/A.java", line = 2, col = 5, excerpt = { first_line = 2, text = "x" } },
    { severity = "fatal", message = "unknown severity is dropped" },
    { severity = "warning", message = 42 },
  },
})
check("report counts", { report.errors, report.warnings, report.dropped, #report.diagnostics }, { 3, 1, 0, 1 })
check("report excerpt", report.diagnostics[1].excerpt, { first_line = 2, text = "x" })
check("not a report", diagnostics.report({ version = 1 }), nil)
local big = { version = 1, diagnostics = {} }
for n = 1, 600 do
  table.insert(big.diagnostics, { severity = "warning", message = "w" .. n, line = n })
end
check("report capped at KEPT", #diagnostics.report(big).diagnostics, diagnostics.KEPT)
check("phrase", diagnostics.phrase(3, 1, 0), "3 errors, 1 warning")
check("phrase one", diagnostics.phrase(1, 0, 2), "1 error")
check("phrase notes", diagnostics.phrase(0, 0, 2), "2 notes")
check("phrase none", diagnostics.phrase(0, 0, 0), nil)
check(
  "link",
  diagnostics.link({ path = "/p/Workspace's λ/A.java", line = 2, col = 5 }),
  "elide://source?path=/p/Workspace%27s%20%CE%BB/A.java&line=2&col=5"
)
check("no link for relative path", diagnostics.link({ path = "A.java", line = 2 }), nil)

-- The newest report: the runtime's `latest` pointer first, else the newest `finished_ms`.
check("latest name", diagnostics.latest("run-AbC123"), "run-AbC123")
check("latest with newline", diagnostics.latest("run-AbC_1-2\n"), "run-AbC_1-2")
check("latest rejects traversal", diagnostics.latest("../etc"), nil)
check("latest rejects a slash", diagnostics.latest("run-a/b"), nil)
check("latest rejects other names", diagnostics.latest("tmp-1"), nil)
check("latest rejects empty", diagnostics.latest(""), nil)
check("latest rejects nil", diagnostics.latest(nil), nil)
check("newest finished", diagnostics.newest_finished({
  { run = "run-a", finished_ms = 100 },
  { run = "run-b", finished_ms = 300 },
  { run = "run-c" },
  { run = "run-d", finished_ms = 200 },
}), "run-b")
check("no finished times", diagnostics.newest_finished({ { run = "run-a" }, { run = "run-b" } }), nil)
local timed = diagnostics.report({ version = 1, finished_ms = 1794000000000, unfiltered = 3, diagnostics = {} })
check("report times and repeats", { timed.finished_ms, timed.unfiltered }, { 1794000000000, 3 })
check("older report", { diagnostics.report({ version = 1, diagnostics = {} }).finished_ms }, {})

-- Links round-trip through the elide:// parser.
local links = dofile(here .. "/../plugin/lib/links.luau")
local parsed = links.parse(diagnostics.link({ path = "/p/Workspace's λ/A.java", line = 2, col = 5 }))
check("link parses", parsed, { action = "source", path = "/p/Workspace's λ/A.java", line = 2, col = 5 })

if failures > 0 then
  print("FAIL " .. failures .. " diagnostics case(s)")
  os.exit(1)
end
print("PASS diagnostics parser")
