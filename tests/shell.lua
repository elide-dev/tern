-- Unit tests for plugin/lib/shell.luau, the command-line parser. Run: lua tests/shell.lua
local here = string.match(arg[0], "^(.*)/[^/]*$") or "."
local shell = dofile(here .. "/../plugin/lib/shell.luau")

local failures = 0
local function check(line, command, subject, compound)
  local got_command, got_subject, got_compound = shell.elide(line)
  if got_command ~= command or got_subject ~= subject or (got_command and got_compound ~= compound) then
    failures = failures + 1
    print(
      string.format(
        "FAIL %q: got %s, %s, %s; want %s, %s, %s",
        line,
        tostring(got_command),
        tostring(got_subject),
        tostring(got_compound),
        tostring(command),
        tostring(subject),
        tostring(compound)
      )
    )
  end
end

check("elide build", "build", nil, false)
check("elide test src/a.test.ts", "test", "src/a.test.ts", false)
check("  /usr/local/bin/elide   build  ", "build", nil, false)
check("FOO=1 BAR=2 elide install", "install", nil, false)
check("elide serve", nil)
check("cd app && elide build", nil)
check("echo elide build", nil)
-- Issue #3: the shell's status is not the command's past a control operator.
check("elide build | cat", "build", nil, true)
check("elide build|cat", "build", nil, true)
check("elide build; echo done", "build", nil, true)
check("elide build || true", "build", nil, true)
check("elide build && echo ok", "build", nil, true)
check("elide build &", "build", nil, true)
check("elide test a.ts\necho", "test", "a.ts", true)
-- Quoted operators are words; redirections are not operators.
check("elide test 'a|b.ts'", "test", "a|b.ts", false)
check('elide test "a;b.ts"', "test", "a;b.ts", false)
check("elide test a\\&b.ts", "test", "a&b.ts", false)
check("elide test 'it''s.ts'", "test", "its.ts", false)
check('elide test "say \\"hi\\".ts"', "test", 'say "hi".ts', false)
check("elide build 2>&1", "build", nil, false)
check("elide build > build.log", "build", nil, false)
check("elide build >>build.log 2>/dev/null", "build", nil, false)
check("elide build &> build.log", "build", nil, false)
check("elide test < input a.ts", "test", "a.ts", false)
check("elide build 2>&1 | tee log", "build", nil, true)
-- Global options taking a value as the next word.
check("elide -p ../app build", "build", nil, false)
check("elide --project ../app build", "build", nil, false)
check("elide --project=../app build", "build", nil, false)
check("elide --env-file .env test a.ts", "test", "a.ts", false)
check("elide -q build", "build", nil, false)
check("elide --timeout 30s -X key=v run main.ts", "run", "main.ts", false)
check("elide --progress=json install", "install", nil, false)
check("elide build -p app", "build", nil, false)

if failures > 0 then
  print("FAIL " .. failures .. " shell parser case(s)")
  os.exit(1)
end
print("PASS shell parser")
