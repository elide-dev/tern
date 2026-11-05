local function quote(value)
  return "'" .. string.gsub(value, "'", "'\"'\"'") .. "'"
end

local function launch(cx, language)
  if cx.hosts:current().kind ~= "local" then
    cx:toast("error", "Configure a REPL launcher on this host before opening a remote session.")
    return
  end
  local ok, config = pcall(function()
    return tern.json.decode(tern.fs.read(tern.plugin.dir .. "/config.json"))
  end)
  if not ok or type(config) ~= "table" or type(config.sdk) ~= "string" then
    cx:toast("error", "Set the embedded SDK directory in plugin/config.json.")
    return
  end
  local function path(value)
    if string.sub(value, 1, 1) == "/" then
      return value
    end
    return tern.plugin.dir .. "/" .. value
  end
  local argv = {
    path(config.repl or "../dist/elide-tern-repl"),
    path(config.broker or "../dist/elide-tern-broker"),
    path(config.sdk),
    config.state or (tern.plugin.data .. "/repl"),
    language,
  }
  for i, value in argv do
    argv[i] = quote(value)
  end
  cx.hosts:terminal("local", { command = "exec " .. table.concat(argv, " ") })
end

tern.command({
  id = "repl",
  title = "Open REPL",
  run = function(cx)
    launch(cx, "js")
  end,
})

for _, language in { "js", "python", "kotlin" } do
  tern.command({
    id = "repl_" .. language,
    title = "Open " .. language .. " REPL",
    run = function(cx)
      launch(cx, language)
    end,
  })
end

tern.command({
  id = "serve",
  title = "Serve directory or script",
  run = function(cx)
    if cx.hosts:current().kind ~= "local" then
      cx:toast("error", "Configure a server launcher on this host before serving remotely.")
      return
    end
    local ok, config = pcall(function()
      return tern.json.decode(tern.fs.read(tern.plugin.dir .. "/config.json"))
    end)
    if not ok or type(config) ~= "table" then
      cx:toast("error", "Configure plugin/config.json before serving.")
      return
    end
    cx:prompt({ placeholder = "Directory or script path", value = ".", icon = "server", action = "serve" })
      :next(function(subject, err, current)
        if not current or not subject or subject == "" then
          return
        end
        if err then
          current:toast("error", err)
          return
        end
        local launcher = config.serve or "../dist/elide-tern-serve"
        if string.sub(launcher, 1, 1) ~= "/" then
          launcher = tern.plugin.dir .. "/" .. launcher
        end
        local runtime = config.runtime or "elide"
        if string.find(runtime, "/") and string.sub(runtime, 1, 1) ~= "/" then
          runtime = tern.plugin.dir .. "/" .. runtime
        end
        current.hosts:terminal("local", {
          command = "exec " .. quote(launcher) .. " " .. quote(runtime) .. " " .. quote(subject),
        })
      end)
  end,
})

tern.command({
  id = "test",
  title = "Run tests",
  run = function(cx)
    if cx.hosts:current().kind ~= "local" then
      cx:toast("error", "Configure a test launcher on this host before running tests remotely.")
      return
    end
    local ok, config = pcall(function()
      return tern.json.decode(tern.fs.read(tern.plugin.dir .. "/config.json"))
    end)
    if not ok or type(config) ~= "table" then
      cx:toast("error", "Configure plugin/config.json before running tests.")
      return
    end
    cx:prompt({ placeholder = "Project directory or test file", value = ".", icon = "play", action = "test" })
      :next(function(subject, err, current)
        if not current or not subject or subject == "" then
          return
        end
        if err then
          current:toast("error", err)
          return
        end
        local launcher = config.test or "../dist/elide-tern-test"
        if string.sub(launcher, 1, 1) ~= "/" then
          launcher = tern.plugin.dir .. "/" .. launcher
        end
        local runtime = config.runtime or "elide"
        if string.find(runtime, "/") and string.sub(runtime, 1, 1) ~= "/" then
          runtime = tern.plugin.dir .. "/" .. runtime
        end
        current.hosts:terminal("local", {
          command = "exec " .. quote(launcher) .. " " .. quote(runtime) .. " " .. quote(subject),
        })
      end)
  end,
})
