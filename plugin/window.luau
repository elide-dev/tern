local project = require("./lib/project")

local function quote(value)
  return "'" .. string.gsub(value, "'", "'\"'\"'") .. "'"
end

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

local function terminal(cx, argv, cwd)
  for i, value in argv do
    argv[i] = quote(value)
  end
  -- Supplying a launcher in new_tab can exhaust Tern's native-call budget.
  local pane = cx.layout:new_tab({ cwd = cwd })
  if pane then
    cx:run(pane, "exec " .. table.concat(argv, " ") .. "\r")
  end
end

local function launch(cx, language, context)
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
  terminal(cx, {
    path(config.repl or "../dist/elide-tern-repl"),
    path(config.broker or "../dist/elide-tern-broker"),
    path(config.sdk),
    state,
    language,
  }, context and context.root)
end

local function launch_job(cx, kind, subject, cwd)
  if not local_host(cx) then
    return
  end
  local config = configuration(cx)
  if not config then
    return
  end
  local runtime = config.runtime or "elide"
  if string.find(runtime, "/") and string.sub(runtime, 1, 1) ~= "/" then
    runtime = path(runtime)
  end
  if kind == "test" and cwd then
    terminal(cx, {
      path(config.project or "../dist/elide-tern-project"),
      path(config.broker or "../dist/elide-tern-broker"),
      config.project_state or (config.state and (config.state .. "-projects")) or (tern.plugin.data .. "/projects"),
      runtime,
      cwd,
      subject,
    }, cwd)
  else
    terminal(cx, { path(config[kind] or ("../dist/elide-tern-" .. kind)), runtime, subject }, cwd)
  end
end

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
      { label = "Open REPL", value = "repl", icon = "terminal" },
      { label = "Serve static files", value = "static", icon = "server" },
      { label = "Serve a script…", value = "script", icon = "server" },
      { label = "Open manifest", value = "manifest", icon = "file" },
      { label = "View test runs", value = "tests", icon = "list" },
    },
  }):next(function(item, err, current)
    if err and current then
      current:toast("error", err)
    elseif current and item then
      if item.value == "test" then
        launch_job(current, "test", context.root, context.root)
      elseif item.value == "repl" then
        launch(current, "js", context)
      elseif item.value == "static" then
        launch_job(current, "serve", context.root, context.root)
      elseif item.value == "manifest" then
        current:open(context.root .. "/elide.pkl")
      elseif item.value == "tests" then
        view_tests(context, current)
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
  id = "project_tests",
  title = "View project test runs",
  run = function(cx)
    detect(cx, view_tests)
  end,
})
tern.chrome.status(project.status)
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
