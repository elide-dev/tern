local links = require("./lib/links")
local project = require("./lib/project")
local workspace = require("./lib/workspace")

local function path(value)
  if string.sub(value, 1, 1) == "/" then
    return value
  end
  return tern.plugin.dir .. "/" .. value
end

local function configuration(cx)
  local ok, config = pcall(function()
    return tern.json.decode(tern.fs.read(tern.plugin.dir .. "/config.json", 65536))
  end)
  if ok and type(config) == "table" then
    return config
  end
  if cx then
    cx:toast("error", "Configure plugin/config.json before launching a runtime.")
  end
  return nil
end

local function local_host(cx)
  if cx.hosts:current().kind == "local" then
    return true
  end
  cx:toast("error", "Configure a runtime launcher on this host before opening a remote session.")
  return false
end

local function runtime_path(config)
  local runtime = config.runtime or "elide"
  if string.find(runtime, "/") and string.sub(runtime, 1, 1) ~= "/" then
    runtime = path(runtime)
  end
  return runtime
end

-- The argv prefix that hosts a broker-backed surface (repl, project, debug): an explicit
-- per-surface launcher from config, or the runtime's own `elide tern <kind>` host.
local function launcher(config, kind)
  if type(config[kind]) == "string" then
    return { path(config[kind]) }
  end
  return { runtime_path(config), "--ignore-version", "tern", kind }
end

-- Whether a runtime executable supports `elide tern`, by path. An older runtime would
-- otherwise resolve `tern` as a project script and run something unrelated.
local supports_tern = {}

-- Runs `open(cx, argv)` once the runtime is known to host surfaces. Explicit launcher
-- overrides skip the probe. Returns false while pending, then calls `opened`.
local function host(cx, config, kind, argv, open, opened)
  if type(config[kind]) == "string" then
    return open(cx, argv)
  end
  local runtime = argv[1]
  local known = supports_tern[runtime]
  if known == true then
    return open(cx, argv)
  elseif known == false then
    cx:toast("error", "The configured runtime has no `elide tern`; update it or set a launcher in plugin/config.json.")
    return nil
  end
  local ok, problem = pcall(function()
    tern.process.run(
      { runtime, "--ignore-version", "--no-color", "--help-all" },
      { timeout_ms = 15000 },
      function(result, current)
        supports_tern[runtime] = result.status == 0 and string.find(result.stdout or "", "[\r\n]%s+tern%s+") ~= nil
        if current then
          local pane = host(current, config, kind, argv, open)
          if opened then
            opened(current, pane)
          end
        end
      end
    )
  end)
  if not ok then
    cx:toast("error", "Could not probe the runtime: " .. tostring(problem))
    return nil
  end
  return false
end

require("./lib/agents").install(configuration, path, project)

local function terminal(cx, argv, cwd, target)
  local command = {}
  for _, value in argv do
    table.insert(command, "'" .. string.gsub(value, "'", "'\"'\"'") .. "'")
  end
  local spec = { cwd = cwd, command = "exec " .. table.concat(command, " ") }
  local pane
  if target then
    if not cx.session:pane(target) then
      return nil
    end
    pane = cx.layout:split(target, "right", spec, { focus = true })
  else
    pane = cx.layout:new_tab(spec)
  end
  if not pane then
    cx:toast("error", "Could not open the panel.")
  end
  return pane
end

local function launch(cx, language, context, target, opened)
  if not local_host(cx) then
    return
  end
  local config = configuration(cx)
  if not config then
    return
  end
  if type(config.sdk) ~= "string" then
    cx:toast("error", "Set the embedded SDK directory in plugin/config.json.")
    return
  end
  context = context or project.current(cx)
  local state = config.state or (tern.plugin.data .. "/repl")
  if context then
    state = config.state and (config.state .. "-" .. context.session_key)
      or (tern.plugin.data .. "/p/" .. context.session_key)
  end
  local argv = launcher(config, "repl")
  table.insert(argv, path(config.broker or "../dist/elide-tern-broker"))
  table.insert(argv, path(config.sdk))
  table.insert(argv, state)
  table.insert(argv, language)
  return host(cx, config, "repl", argv, function(current, command)
    return terminal(current, command, context and context.root, target)
  end, opened)
end

local function launch_job(cx, kind, subject, cwd, target, opened)
  if not local_host(cx) then
    return
  end
  local config = configuration(cx)
  if not config then
    return
  end
  local runtime = runtime_path(config)
  if kind == "test" and cwd then
    local argv = launcher(config, "project")
    table.insert(argv, path(config.broker or "../dist/elide-tern-broker"))
    table.insert(
      argv,
      config.project_state or (config.state and (config.state .. "-projects")) or (tern.plugin.data .. "/projects")
    )
    table.insert(argv, runtime)
    table.insert(argv, cwd)
    if subject then
      table.insert(argv, subject)
    end
    return host(cx, config, "project", argv, function(current, command)
      return terminal(current, command, cwd, target)
    end, opened)
  else
    -- `elide test` and `elide serve` negotiate their own surfaces; an explicit launcher
    -- override still receives the runtime and subject.
    local argv
    if type(config[kind]) == "string" then
      argv = { path(config[kind]), runtime, subject }
    else
      argv = { runtime, "--ignore-version", kind, subject }
    end
    return host(cx, config, kind, argv, function(current, command)
      return terminal(current, command, cwd, target)
    end, opened)
  end
end

local DEBUGGABLE = { js = true, mjs = true, cjs = true, ts = true, mts = true, cts = true, py = true }

-- Launches the debugger for `context.root`; `source` names the file to debug, else the
-- focused file block's file when it is debuggable.
local function launch_debug(cx, context, target, opened, source)
  if not local_host(cx) or not context then
    return
  end
  local config = configuration(cx)
  if not config then
    return
  end
  local runtime = runtime_path(config)
  local argv = launcher(config, "debug")
  table.insert(argv, path(config.broker or "../dist/elide-tern-broker"))
  table.insert(
    argv,
    config.project_state or (config.state and (config.state .. "-projects")) or (tern.plugin.data .. "/projects")
  )
  table.insert(argv, runtime)
  table.insert(argv, context.root)
  if source then
    if not DEBUGGABLE[string.match(source, "%.([%w]+)$") or ""] then
      cx:toast("info", "Debugging takes JavaScript, TypeScript or Python sources.", source)
      return
    end
    table.insert(argv, source)
    return host(cx, config, "debug", argv, function(current, command)
      return terminal(current, command, context.root, target)
    end, opened)
  end
  local pane = target or cx.session:focused()
  local read = pane and cx.session:read(pane, { lines = 1, max_chars = 1 })
  if type(read) == "table" and type(read.path) == "string" then
    if DEBUGGABLE[string.match(read.path, "%.([%w]+)$") or ""] then
      if read.dirty then
        cx:toast("info", "Save this file before debugging.")
        return
      end
      table.insert(argv, read.path)
    end
  end
  return host(cx, config, "debug", argv, function(current, command)
    return terminal(current, command, context.root, target)
  end, opened)
end

local function runtime_action(cx, context, command, target)
  if not local_host(cx) then
    return
  end
  local config = configuration(cx)
  if not config then
    return
  end
  return terminal(cx, { runtime_path(config), command }, context.root, target)
end

workspace.install({
  debug = launch_debug,
  build = function(cx, context, target)
    return runtime_action(cx, context, "build", target)
  end,
  run = function(cx, context, target)
    return runtime_action(cx, context, "run", target)
  end,
  test = function(cx, context, target, opened)
    return launch_job(cx, "test", context.root, context.root, target, opened)
  end,
  repl = function(cx, context, target, opened)
    return launch(cx, "js", context, target, opened)
  end,
  serve = function(cx, context, target, opened)
    return launch_job(cx, "serve", context.root, context.root, target, opened)
  end,
})

local function view_tests(context, cx)
  if not context then
    cx:toast("info", "Open a local project directory first.")
    return
  end
  launch_job(cx, "test", nil, context.root)
end

local function prompt_job(cx, kind, placeholder)
  if not local_host(cx) then
    return
  end
  local context = project.current(cx)
  local focused = project.context(cx)
  cx:prompt({
    placeholder = placeholder,
    value = context and context.root or (focused and focused.path or "."),
    icon = "play",
    action = kind,
  }):next(function(subject, err, current)
    if err and current then
      current:toast("error", err)
    elseif current and subject and subject ~= "" then
      launch_job(current, kind, subject, context and context.root)
    end
  end)
end

local function project_menu(context, cx)
  if not context then
    cx:toast("info", "No elide.pkl found in this directory or its parents.")
    return
  end
  cx:pick({
    placeholder = context.name or "Project",
    items = {
      { label = "Run tests", value = "test", icon = "play" },
      { label = "Open debugger", value = "debug", icon = "bug" },
      { label = "Open REPL", value = "repl", icon = "terminal" },
      { label = "Serve static files", value = "static", icon = "server" },
      { label = "Serve a script…", value = "script", icon = "server" },
      { label = "Open manifest", value = "manifest", icon = "file" },
      { label = "View test runs", value = "tests", icon = "list" },
      { label = "Open project workspace", value = "workspace", icon = "folder" },
    },
  }):next(function(item, err, current)
    if err and current then
      current:toast("error", err)
    elseif current and item then
      if item.value == "test" then
        launch_job(current, "test", context.root, context.root)
      elseif item.value == "debug" then
        launch_debug(current, context)
      elseif item.value == "repl" then
        launch(current, "js", context)
      elseif item.value == "static" then
        launch_job(current, "serve", context.root, context.root)
      elseif item.value == "manifest" then
        current:open(context.root .. "/elide.pkl")
      elseif item.value == "tests" then
        view_tests(context, current)
      elseif item.value == "workspace" then
        workspace.open(context, current)
      elseif item.value == "script" then
        current
          :prompt({ placeholder = "Script path relative to project", value = "", action = "serve" })
          :next(function(subject, problem, fresh)
            if problem and fresh then
              fresh:toast("error", problem)
            elseif fresh and subject and subject ~= "" then
              if string.sub(subject, 1, 1) ~= "/" then
                subject = context.root .. "/" .. subject
              end
              launch_job(fresh, "serve", subject, context.root)
            end
          end)
      end
    end
  end)
end

local function detect(cx, callback, explicit)
  local context = explicit or project.context(cx)
  local config = configuration()
  if context and config then
    project.probe(context, path(config.broker or "../dist/elide-tern-broker"), callback)
  elseif callback then
    cx:toast("info", "Open a local project directory first.")
  end
end

tern.command({
  id = "workspace",
  title = "Open project workspace",
  icon = "folder",
  run = function(cx)
    detect(cx, workspace.open)
  end,
})

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
    prompt_job(cx, "serve", "Directory or script path")
  end,
})
tern.command({
  id = "test",
  title = "Run tests",
  run = function(cx)
    prompt_job(cx, "test", "Project directory or test file")
  end,
})
tern.command({
  id = "project",
  title = "Project actions",
  icon = "folder",
  run = function(cx)
    detect(cx, project_menu)
  end,
})
tern.command({
  id = "debug",
  title = "Debug project source",
  icon = "bug",
  run = function(cx)
    detect(cx, function(context, current)
      if context then
        launch_debug(current, context)
      else
        current:toast("info", "Open a local project directory first.")
      end
    end)
  end,
})
tern.command({
  id = "project_tests",
  title = "View project test runs",
  run = function(cx)
    detect(cx, view_tests)
  end,
})
tern.chrome.status(project.status)
tern.chrome.tab_title(project.tab_title)
if tern.chrome.program_icon then
  tern.chrome.program_icon("elide", "bolt")
end

-- `elide test|build|run …` as a shell reported it: the subcommand and its subject words.
-- Leading `VAR=value` assignments are skipped; quoting is not interpreted.
local function elide_command(line)
  local words = {}
  for word in string.gmatch(line, "%S+") do
    table.insert(words, word)
  end
  local index = 1
  while words[index] and string.find(words[index], "^[%a_][%w_]*=") do
    index += 1
  end
  local program = words[index] and string.match(words[index], "([^/]+)$")
  if program ~= "elide" then
    return nil
  end
  local command, subject = nil, {}
  for position = index + 1, #words do
    local word = words[position]
    if string.sub(word, 1, 1) ~= "-" then
      if command then
        table.insert(subject, word)
      else
        command = word
      end
    end
  end
  if command ~= "test" and command ~= "build" and command ~= "run" then
    return nil
  end
  return command, if #subject > 0 then table.concat(subject, " ") else nil
end

-- No process starts here: window event handlers share a 50 ms budget.
tern.on("command_finished", function(ev, cx)
  local command, subject = elide_command(ev.line)
  if not command then
    return
  end
  project.finished(ev.pane, command, ev.status)
  tern.chrome.refresh()
  -- Statuses from 128 up are signals (an interrupt), not failing tests.
  if command == "test" and ev.status ~= 0 and ev.status < 128 then
    if not subject then
      local pane = cx.session:pane(ev.pane)
      subject = pane and pane.cwd ~= "" and pane.cwd or nil
    end
    cx:toast("error", "Tests failed", subject)
  end
end)

-- `elide://` links (contract in docs/architecture.md). Every elide:// link is claimed, so a
-- rejected one is dropped with a toast instead of reaching the system's URL handlers.
tern.route.link(function(request, cx)
  if string.lower(string.sub(request.url, 1, 8)) ~= "elide://" then
    return nil
  end
  local target = links.parse(request.url)
  local problem
  if not target then
    problem = "Ignored a malformed elide:// link."
  elseif cx.hosts:current().kind ~= "local" then
    problem = "elide:// links open on local hosts only."
  elseif target.root then
    if not tern.fs.exists(target.root .. "/elide.pkl") then
      problem = "Ignored an elide:// link whose root has no elide.pkl."
    end
  else
    local inside = false
    for _, root in project.roots() do
      if links.within(target.path, root) then
        inside = true
        break
      end
    end
    if not inside then
      problem = "Ignored an elide:// link outside a detected project."
    end
  end
  if not problem and target.path and not tern.fs.exists(target.path) then
    problem = "The linked file does not exist."
  end
  if problem then
    cx:toast("info", problem, string.sub(request.url, 1, 240))
    return { handled = true }
  end
  if target.action == "source" then
    cx.docs:open(target.path, { line = target.line })
  elseif target.action == "debug" then
    launch_debug(cx, { root = target.root }, nil, nil, target.path)
  elseif target.action == "tests" then
    view_tests({ root = target.root }, cx)
  end
  return { handled = true }
end)

-- `elide.pkl` chosen from the palette opens its project workspace (or focuses the open one).
-- Opens inside a workspace tab were already redirected to its editor by the workspace route.
tern.route.open(function(request, cx)
  if request.origin ~= "palette" or not string.find(request.path, "/elide%.pkl$") then
    return nil
  end
  local host = cx.hosts:current()
  if host.kind ~= "local" or (request.host ~= "local" and request.host ~= host.name) then
    return nil
  end
  if not configuration() then
    return nil
  end
  detect(cx, workspace.open, { pane = -1, path = string.match(request.path, "^(.*)/[^/]*$") })
  return { handled = true }
end)
tern.on("window_start", function(cx)
  detect(cx)
end)
for _, event in { "focus", "cwd", "command_finished" } do
  tern.on(event, function(_, cx)
    detect(cx)
  end)
end
tern.on("pane_closed", function(ev)
  project.remove(ev.pane)
end)
tern.files.button({
  id = "project",
  title = "Project actions",
  icon = "folder",
  run = function(files, cx)
    if local_host(cx) and files.root and (files.host == "local" or files.host == cx.hosts:current().name) then
      detect(cx, project_menu, { pane = -1, path = files.root })
    end
  end,
})
