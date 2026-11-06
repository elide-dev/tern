-- Unit tests for plugin/lib/links.luau, the pure `elide://` parser. Run: lua tests/links.lua
local here = string.match(arg[0], "^(.*)/[^/]*$") or "."
local links = dofile(here .. "/../plugin/lib/links.luau")

local failures = 0
local function check(name, actual, expected)
  local function show(value)
    if type(value) ~= "table" then
      return tostring(value)
    end
    local keys = {}
    for key in pairs(value) do
      table.insert(keys, key)
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
      table.insert(parts, key .. "=" .. tostring(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  if show(actual) ~= show(expected) then
    failures = failures + 1
    print("FAIL " .. name .. ": got " .. show(actual) .. ", want " .. show(expected))
  end
end

local p = links.parse
check("source", p("elide://source?path=/p/a.js&line=2&col=5"), { action = "source", path = "/p/a.js", line = 2, col = 5 })
check("source no line", p("elide://source?path=/p/a.js"), { action = "source", path = "/p/a.js" })
check("source root", p("elide://source?root=/p&path=/p/src/a.js&line=1"), {
  action = "source",
  root = "/p",
  path = "/p/src/a.js",
  line = 1,
})
check("scheme case", p("ELIDE://source?path=/p/a.js"), { action = "source", path = "/p/a.js" })
check("slash before query", p("elide://source/?path=/p/a.js"), { action = "source", path = "/p/a.js" })
check(
  "percent",
  p("elide://source?path=/p/Workspace%27s%20%CE%BB/a%2Bb.js"),
  { action = "source", path = "/p/Workspace's λ/a+b.js" }
)
check("plus literal", p("elide://source?path=/p/a+b.js"), { action = "source", path = "/p/a+b.js" })
check("unknown key ignored", p("elide://source?path=/p/a.js&v=2"), { action = "source", path = "/p/a.js" })
check("debug", p("elide://debug?root=/p&path=/p/main.js&line=3"), {
  action = "debug",
  root = "/p",
  path = "/p/main.js",
  line = 3,
})
check("tests", p("elide://tests?root=/p/"), { action = "tests", root = "/p" })

check("other scheme", p("https://example.com/?path=/p/a.js"), nil)
check("file scheme", p("file:///p/a.js"), nil)
check("unknown action", p("elide://trace?id=1"), nil)
check("no query", p("elide://tests"), nil)
check("fragment", p("elide://source?path=/p/a.js#x"), nil)
check("relative path", p("elide://source?path=a.js"), nil)
check("dotdot", p("elide://source?path=/p/../etc/passwd"), nil)
check("encoded dotdot", p("elide://source?path=/p/%2E%2E/etc/passwd"), nil)
check("dot", p("elide://source?path=/p/./a.js"), nil)
check("double slash", p("elide://source?path=/p//a.js"), nil)
check("root slash only", p("elide://tests?root=/"), nil)
check("outside root", p("elide://debug?root=/p&path=/q/main.js"), nil)
check("sibling prefix", p("elide://debug?root=/p&path=/pq/main.js"), nil)
check("root itself", p("elide://source?root=/p&path=/p"), nil)
check("debug without root", p("elide://debug?path=/p/main.js"), nil)
check("tests without root", p("elide://tests?path=/p"), nil)
check("bad escape", p("elide://source?path=/p/%zz.js"), nil)
check("truncated escape", p("elide://source?path=/p/a%4"), nil)
check("nul", p("elide://source?path=/p/a%00.js"), nil)
check("newline", p("elide://source?path=/p/a%0A.js"), nil)
check("duplicate", p("elide://source?path=/p/a.js&path=/etc/passwd"), nil)
check("no value", p("elide://source?path"), nil)
check("zero line", p("elide://source?path=/p/a.js&line=0"), nil)
check("negative line", p("elide://source?path=/p/a.js&line=-1"), nil)
check("text line", p("elide://source?path=/p/a.js&line=two"), nil)
check("huge line", p("elide://source?path=/p/a.js&line=99999999999"), nil)
check("col without line", p("elide://source?path=/p/a.js&col=2"), nil)
check("empty path", p("elide://source?path="), nil)
check("not a string", p(nil), nil)
check("too long", p("elide://source?path=/" .. string.rep("a", 9000)), nil)

check("within", links.within("/p/a", "/p"), true)
check("within prefix", links.within("/pa", "/p"), false)

if failures > 0 then
  print("FAIL " .. failures .. " link parser case(s)")
  os.exit(1)
end
print("PASS link parser")
