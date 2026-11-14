-- Unit tests for plugin/lib/broker.luau's protocol check. Run: lua tests/broker.lua
local here = string.match(arg[0], "^(.*)/[^/]*$") or "."

local failures = 0
local function check(name, ok, detail)
  if not ok then
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or ""))
  end
end

-- A fake `tern`: each process run answers from `answers` by its command word and is recorded.
local ran
local answers
_G.tern = {
  plugin = { dir = "/plugin", data = "/data" },
  fs = {
    read = function()
      return "config"
    end,
  },
  json = {
    decode = function(text)
      if text == "config" then
        return { sdk = "/sdk", broker = "/bin/broker" }
      end
      return { ok = true, result = { answer = text } }
    end,
    encode = function()
      return "{}"
    end,
  },
  process = {
    run = function(argv, _, callback)
      table.insert(ran, argv[2])
      callback(answers[argv[2]])
    end,
  },
}

local function load()
  ran, answers = {}, {}
  return dofile(here .. "/../plugin/lib/broker.luau")
end

-- A broker that speaks the plugin's protocol is asked once, then only requests run.
local broker = load()
answers.protocol = { status = 0, stdout = "1\n" }
answers.request = { status = 0, stdout = "pong" }
local results = {}
broker.request({ op = "ping" }, function(result, err)
  table.insert(results, { result = result, err = err })
end)
broker.request({ op = "ping" }, function(result, err)
  table.insert(results, { result = result, err = err })
end)
check("asked once", table.concat(ran, ",") == "protocol,request,request", table.concat(ran, ","))
check("requests answered", results[1].result and results[2].result and not results[1].err, results[1].err)

-- A broker older than the check (no `protocol` command) is refused before any request.
broker = load()
answers.protocol = { status = 1, stdout = "", stderr = "Usage: …" }
local refused
broker.request({ op = "ping" }, function(_, err)
  refused = err
end)
check("old broker refused", refused and string.find(refused, "make broker", 1, true), refused)
check("no request to an old broker", table.concat(ran, ",") == "protocol", table.concat(ran, ","))

-- Another protocol is named in the refusal.
broker = load()
answers.protocol = { status = 0, stdout = "2" }
broker.request({ op = "ping" }, function(_, err)
  refused = err
end)
check("other protocol named", refused and string.find(refused, "speaks protocol 2", 1, true), refused)

if failures > 0 then
  os.exit(1)
end
print("broker.lua: all checks passed")
