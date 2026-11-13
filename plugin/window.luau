local diagnostics = require("./lib/diagnostics")
local links = require("./lib/links")
local project = require("./lib/project")
local source = require("./lib/source")
local workspace = require("./lib/workspace")
local android = require("./lib/android")
local loopback = require("./lib/loopback")

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

android.install(configuration, path, runtime_path)

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
        -- Cache only a clean exit; a timeout (status -1) or crash is probed again next time.
        if result.status == 0 then
          supports_tern[runtime] = string.find(result.stdout or "", "[\r\n]%s+tern%s+") ~= nil
        end
        if current and supports_tern[runtime] == nil then
          current:toast("error", "Could not probe the runtime; try again.", runtime)
          if opened then
            opened(current, nil)
          end
          return
        end
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

local function quote(value)
  return "'" .. string.gsub(value, "'", "'\"'\"'") .. "'"
end

-- Keeps a failed program's pane open with its output readable: Tern's exit dialog would cover
-- it. Enter closes the pane; a clean exit closes it at once, as usual.
local HOLD = '"$@"; status=$?; [ "$status" -eq 0 ] && exit 0; '
  .. 'printf "\\n\\033[2mExited with status %d. Press Enter to close.\\033[0m" "$status"; read -r _; exit 0'

local function terminal(cx, argv, cwd, target, hold, dir)
  local command = {}
  for _, value in argv do
    table.insert(command, quote(value))
  end
  local line = table.concat(command, " ")
  if hold then
    line = "/bin/sh -c " .. quote(HOLD) .. " elide " .. line
  end
  local spec = { cwd = cwd, command = "exec " .. line }
  local pane
  if target then
    if not cx.session:pane(target) then
      return nil
    end
    pane = cx.layout:split(target, dir or "right", spec, { focus = true })
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
  -- The broker accepts only a complete SDK, and the runtime reports a missing one without its path.
  local sdk = path(config.sdk)
  if not tern.fs.exists(sdk .. "/embedder.json") then
    cx:toast("error", "No embedded SDK at the `sdk` path in plugin/config.json.", sdk)
    return
  end
  local broker = path(config.broker or "../dist/elide-tern-broker")
  if not tern.fs.exists(broker) then
    cx:toast("error", "No broker at the `broker` path in plugin/config.json; run `make build`.", broker)
    return
  end
  context = context or project.current(cx)
  local state = config.state or (tern.plugin.data .. "/repl")
  if context then
    state = config.state and (config.state .. "-" .. context.session_key)
      or (tern.plugin.data .. "/p/" .. context.session_key)
  end
  local argv = launcher(config, "repl")
  table.insert(argv, broker)
  table.insert(argv, sdk)
  table.insert(argv, state)
  table.insert(argv, language)
  return host(cx, config, "repl", argv, function(current, command)
    return terminal(current, command, context and context.root, target, true)
  end, opened)
end

-- Whether `<runtime> <command>` takes `--surface=inline|screen|auto`, by runtime and command:
-- `elide test|build|run --help` list the option on runtimes that have it.
local surface_support = {}

-- Runs `run(cx, supported, later)` once `<runtime> <command> --surface` support is known;
-- returns false while the help is read, else what `run` returns. `later` is true when `run` is
-- called from the probe's callback, where its result reaches no caller.
local function with_surface(cx, runtime, command, run)
  local key = runtime .. "\0" .. command
  if surface_support[key] ~= nil then
    return run(cx, surface_support[key])
  end
  local ok = pcall(function()
    tern.process.run(
      { runtime, "--ignore-version", "--no-color", command, "--help" },
      { timeout_ms = 15000 },
      function(result, current)
        local text = "\n" .. (result.stdout or "") .. "\n" .. (result.stderr or "")
        -- An option line (`  --surface <MODE>  …`), not a mention in prose.
        local supported = result.status == 0 and string.find(text, "\n%s+%-%-surface[%s=<%[]") ~= nil
        -- Only a clean exit answers for good; a timeout or crash is asked again next time.
        if result.status == 0 then
          surface_support[key] = supported
        end
        if current then
          run(current, supported, true)
        end
      end
    )
  end)
  if not ok then
    return run(cx, false)
  end
  return false
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
    if type(config[kind]) == "string" then
      return host(cx, config, kind, { path(config[kind]), runtime, subject }, function(current, command)
        return terminal(current, command, cwd, target)
      end, opened)
    end
    -- Tests outside a project get the full page (`--surface=screen`) when the runtime takes
    -- it; bare `elide test` under Tern draws inline, and older runtimes get no flag.
    local function start(current, screen, later)
      local argv = { runtime, "--ignore-version", kind }
      if screen then
        table.insert(argv, "--surface=screen")
      end
      table.insert(argv, subject)
      local pane = host(current, config, kind, argv, function(fresh, command)
        return terminal(fresh, command, cwd, target)
      end, opened)
      if later and pane ~= false and opened then
        opened(current, pane)
      end
      return pane
    end
    if kind ~= "test" then
      return start(cx, false)
    end
    return with_surface(cx, runtime, "test", start)
  end
end

-- Launches the debugger for `context.root`; `file` names the source to debug, else the
-- focused file block's file when it is debuggable (extensions in any case, as the source block).
local function launch_debug(cx, context, target, opened, file)
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
  if file then
    if not source.debuggable(file) then
      cx:toast("info", "Debugging takes JavaScript, TypeScript or Python sources.", file)
      return
    end
    table.insert(argv, file)
    return host(cx, config, "debug", argv, function(current, command)
      return terminal(current, command, context.root, target)
    end, opened)
  end
  local pane = target or cx.session:focused()
  local read = pane and cx.session:read(pane, { lines = 1, max_chars = 1 })
  if type(read) == "table" and type(read.path) == "string" then
    if source.debuggable(read.path) then
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

-- Opens `<runtime> <command>` (build, run) for the project right of `target`: the command's full
-- page when the runtime's `<command> --help` lists `--surface`, else its plain output.
-- `options.args` follow the command, and `options.cwd` replaces the project root.
local function runtime_action(cx, context, command, target, opened, options)
  if not local_host(cx) then
    return
  end
  local config = configuration(cx)
  if not config then
    return
  end
  local runtime = runtime_path(config)
  options = options or {}
  return with_surface(cx, runtime, command, function(current, screen, later)
    local argv = { runtime, "--ignore-version", command }
    if screen then
      table.insert(argv, "--surface=screen")
    end
    for _, value in options.args or {} do
      table.insert(argv, value)
    end
    local pane = terminal(current, argv, options.cwd or context.root, target)
    if later and opened then
      opened(current, pane)
    end
    return pane
  end)
end

-- Run: the Run page for the project, right of the workspace's bottom terminal (`bottom`) when it
-- is open, else right of `target`. An Android project first gets its device plan and deploys
-- with `--device` or `--emulator` (the embedded emulator Tern starts), so Elide starts no
-- emulator of its own. The page opens first and shows the build; once the build is done, the
-- device pane opens beside the editor (`target`), in the place of the open Compose previews.
local function run_project(cx, context, target, opened, bottom)
  local below = bottom or target
  if not android.declared(context.root) then
    return runtime_action(cx, context, "run", below, opened)
  end
  android.run_device(cx, context, function(current, device)
    if device == false then
      opened(current, nil)
      return
    end
    if not device then
      local pane = runtime_action(current, context, "run", below, opened)
      if pane ~= false then
        opened(current, pane)
      end
      return
    end
    -- Armed before the split: Tern can abort this hook as the split returns.
    if device.display then
      device.beside = target
      android.follow(current, device)
    end
    local pane = runtime_action(current, context, "run", below, function(fresh, page)
      android.followed(fresh, page)
      opened(fresh, page)
    end, { args = device.args, cwd = device.root })
    if pane ~= false then
      android.followed(current, pane)
      opened(current, pane)
    end
  end)
  return false
end

-- Opens the `elide.source` block on `path` (absolute, inside `root`), beside `target` or the
-- focused pane. Returns its pane, or nil with a toast.
local function open_source(cx, path, root, line, target)
  if not source.lang(path) then
    cx:toast("info", "Elide source shows JavaScript, TypeScript, Python, Kotlin and Java files.", path)
    return nil
  end
  local args = { path, root or "" }
  if line then
    table.insert(args, tostring(line))
  end
  local pane = cx:new_block("elide.source", args, "beside", target and { target = target } or nil)
  if not pane then
    cx:toast("error", "Could not open Elide source.")
  end
  return pane
end

-- The file shown in `pane` when it is a saved source file inside `root`, else nil.
local function source_in(cx, pane, root)
  local read = pane and cx.session:read(pane, { lines = 1, max_chars = 1 })
  if type(read) == "table" and type(read.path) == "string" and links.within(read.path, root) then
    return read.path
  end
  return nil
end

-- Window and host VMs do not share buffers: only this window can read native editors, including
-- their dirty text. Each open Compose page registers its session here; the dirty Kotlin/Java
-- editors of the session's workspace are posted to it.
local native_sessions = {}
local native_roots = {}
local native_busy = false
local native_ticker
local NATIVE_FILE_BYTES = 8 * 1024 * 1024
local NATIVE_TOTAL_BYTES = 32 * 1024 * 1024

local function native_active(session, cx)
  return cx.session:pane(session.pane) ~= nil
end

local function native_dirty(cx, pane, root)
  local value = cx.session:read(pane, { lines = 1, max_chars = 1 })
  if type(value) ~= "table" or value.kind ~= "file" or not value.dirty then
    return nil
  end
  local host = cx.hosts:current()
  if value.host ~= host.id then
    return nil
  end
  local file = links.absolute(value.path)
  if not file or string.find(file, "%c") or not links.within(file, root) then
    return nil
  end
  local extension = source.extension(file)
  return (extension == "kt" or extension == "java") and file or nil
end

local function publish_native(root, documents, problem, cx)
  local previous = native_roots[root]
  local changed = not previous or previous.problem ~= problem
  if not changed then
    for file, content in documents do
      if previous.documents[file] ~= content then
        changed = true
        break
      end
    end
    if not changed then
      for file in previous.documents do
        if documents[file] == nil then
          changed = true
          break
        end
      end
    end
  end
  local snapshot = previous
  if changed then
    snapshot = { documents = documents, problem = problem }
    native_roots[root] = snapshot
  end
  local body
  for url, session in native_sessions do
    if session.root == root and session.snapshot ~= snapshot and not session.posting then
      if not body then
        local entries = {}
        if not problem then
          for file, content in snapshot.documents do
            table.insert(entries, tern.json.encode({ file = file, text = content }))
          end
        end
        body = '{"origin":"native","replace":true,"documents":['
          .. table.concat(entries, ",")
          .. "]"
          .. (problem and (',"error":' .. tern.json.encode(problem)) or "")
          .. "}"
      end
      -- One post per session in flight; a newer snapshot goes out on the next poll.
      session.posting = true
      loopback.request(url .. "documents", body, 10000, function(status)
        session.posting = false
        if status == 200 then
          session.snapshot = snapshot
        elseif status == 404 or status == 410 or status == 0 then
          native_sessions[url] = nil
        end
      end)
    end
  end
end

local function poll_native(cx)
  if native_busy then
    return
  end
  -- docs:read resolves against the current host. Never ask a remote host for a
  -- local preview's source; switching back resumes its synchronization.
  if not cx or cx.hosts:current().kind ~= "local" then
    return
  end
  native_busy = true
  local roots, seen = {}, {}
  for url, session in native_sessions do
    if not native_active(session, cx) then
      native_sessions[url] = nil
    elseif not seen[session.root] then
      seen[session.root] = true
      table.insert(roots, session.root)
    end
  end
  for root in native_roots do
    if not seen[root] then
      native_roots[root] = nil
    end
  end
  local root_index = 0
  local next_root
  next_root = function(current)
    root_index += 1
    local root = roots[root_index]
    if not root or not current or current.hosts:current().kind ~= "local" then
      native_busy = false
      return
    end
    local queue, files = {}, {}
    for _, pane in current.session:panes() do
      if pane.kind == "file" then
        local file = native_dirty(current, pane.pane, root)
        if file and not files[file] then
          files[file] = pane.pane
          table.insert(queue, file)
        end
      end
    end
    local documents, total, index = {}, 0, 0
    local next_file
    local function finish(fresh, problem)
      -- A save or close while an async read was pending must remove the overlay.
      for file in documents do
        if native_dirty(fresh, files[file], root) ~= file then
          documents[file] = nil
        end
      end
      publish_native(root, documents, problem, fresh)
      next_root(fresh)
    end
    next_file = function(fresh)
      if not fresh or fresh.hosts:current().kind ~= "local" then
        native_busy = false
        return
      end
      index += 1
      local file = queue[index]
      if not file then
        finish(fresh)
        return
      end
      if native_dirty(fresh, files[file], root) ~= file then
        next_file(fresh)
        return
      end
      -- No native edit event or buffer revision is exposed by the documented API.
      -- Read only dirty Kotlin/Java buffers, one async read at a time, once per
      -- completed polling cycle. session:read is capped/truncated; docs:read is exact.
      local ok, problem = pcall(function()
        fresh.docs:read(file):next(function(content, err, latest)
          if not latest or latest.hosts:current().kind ~= "local" then
            native_busy = false
            return
          end
          if native_dirty(latest, files[file], root) ~= file then
            next_file(latest)
          elseif err or type(content) ~= "string" then
            finish(latest, "Could not read native editor " .. file .. ": " .. tostring(err or "no text returned"))
          elseif #content > NATIVE_FILE_BYTES or total + #content > NATIVE_TOTAL_BYTES then
            finish(latest, "Native editor previews allow 8 MiB per file and 32 MiB total.")
          else
            documents[file] = content
            total += #content
            next_file(latest)
          end
        end)
      end)
      if not ok then
        finish(fresh, "Could not read native editor " .. file .. ": " .. tostring(problem))
      end
    end
    next_file(current)
  end
  next_root(cx)
end

-- No native edit event or buffer revision is exposed, so dirty editors are read every 100 ms
-- while a session runs.
local function native_tick(cx)
  if native_ticker or next(native_sessions) == nil then
    return
  end
  native_ticker = tern.timer(100, function(fresh)
    native_ticker = nil
    if not fresh then
      return
    end
    poll_native(fresh)
    native_tick(fresh)
  end)
end

-- Open Compose pages by session URL: `{ url, pane, root, path, asked, stopped?, fragment? }`.
-- The window carries out each page's requests (open the source, close, retarget) from the
-- session's pane long-poll; a stopped page stays, and its buttons then ask through the page's URL
-- fragment. `start_preview` is set with the live pages below.
local live_pages = {}
local start_preview

-- One preview per workspace: a running one shows `file` instead of opening another pane, and a
-- stopped one starts again in its own pane.
local function open_compose(cx, file, root, target)
  if not local_host(cx) then
    return nil
  end
  file, root = links.absolute(file), links.absolute(root)
  if
    not file
    or not root
    or not links.within(file, root)
    or source.extension(file) ~= "kt"
    or not tern.fs.exists(file)
  then
    cx:toast("info", "Choose a saved Kotlin (.kt) file inside this project.")
    return nil
  end
  if not configuration(cx) then
    return nil
  end
  for url, page in live_pages do
    if links.within(file, page.root) and cx.session:pane(page.pane) then
      if page.stopped then
        start_preview(cx, file, root, nil, page)
        cx.layout:focus(page.pane)
        return page.pane
      end
      local name = string.match(file, "([^/]+)$")
      loopback.request(url .. "retarget", tern.json.encode({ file = file }), 5000, function(status, _, current)
        if not current then
          return
        end
        if status ~= 200 then
          start_preview(current, file, root, target)
          return
        end
        local focused = current.session:focused()
        if not focused or current.session:tab_of(focused) ~= current.session:tab_of(page.pane) then
          current:toast("info", "Compose preview now shows " .. name .. ".")
        end
      end)
      return page.pane
    end
  end
  start_preview(cx, file, root, target)
  return nil
end

local function prompt_compose(cx, context)
  if not local_host(cx) then
    return
  end
  if not context then
    cx:toast("info", "Open a local project directory first.")
    return
  end
  local focused = cx.session:focused()
  local file = source_in(cx, focused, context.root)
  if file and source.extension(file) == "kt" then
    open_compose(cx, file, context.root, focused)
    return
  end
  cx:prompt({
    placeholder = "Kotlin (.kt) path relative to project",
    value = "",
    icon = "file",
    action = "preview",
  }):next(function(subject, problem, fresh)
    if problem and fresh then
      fresh:toast("error", problem)
    elseif fresh and subject and subject ~= "" then
      local file = string.sub(subject, 1, 1) == "/" and subject or (context.root .. "/" .. subject)
      open_compose(fresh, file, context.root)
    end
  end)
end

workspace.install({
  debug = launch_debug,
  android = function(cx, context, target)
    return android.open(cx, context, target)
  end,
  -- Like Source, Preview is deliberately not cached by action: a second Kotlin file of the
  -- workspace moves its running preview to that file (open_compose) instead of focusing it.
  preview = function(cx, context, target)
    local file = source_in(cx, target, context.root)
    if file then
      open_compose(cx, file, context.root, target)
    else
      cx:toast("info", "Open a saved Kotlin file in the editor first.")
    end
    return nil
  end,
  build = function(cx, context, target, opened)
    return runtime_action(cx, context, "build", target, opened)
  end,
  run = run_project,
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

-- Opens the Elide source block on the focused file, or on a path asked for relative to the project.
local function prompt_source(cx, context)
  local focused = project.context(cx)
  local file = focused and source_in(cx, focused.pane, context.root)
  if file then
    open_source(cx, file, context.root)
    return
  end
  cx:prompt({ placeholder = "Source path relative to project", value = "", icon = "file", action = "open" })
    :next(function(subject, problem, fresh)
      if problem and fresh then
        fresh:toast("error", problem)
      elseif fresh and subject and subject ~= "" then
        local path = links.absolute(string.sub(subject, 1, 1) == "/" and subject or (context.root .. "/" .. subject))
        if not path or not links.within(path, context.root) or not tern.fs.exists(path) then
          fresh:toast("info", "No such file in this project.", subject)
        else
          open_source(fresh, path, context.root)
        end
      end
    end)
end

-- Whether the project host has recorded a test run: each run keeps a `run-*` report
-- directory under the project, so a listing answers without starting a process.
local function has_runs(root)
  local ok, names = pcall(tern.fs.list, root .. "/.dev/reports/tests/tern")
  if not ok then
    return false
  end
  for _, name in names do
    if string.sub(name, 1, 4) == "run-" then
      return true
    end
  end
  return false
end

local function project_menu(context, cx)
  if not context then
    cx:toast("info", "No elide.pkl found in this directory or its parents.")
    return
  end
  local items = {
    { label = "Run tests", value = "test", icon = "play" },
    { label = "Open debugger", value = "debug", icon = "bug" },
    { label = "Open Elide source…", value = "source", icon = "file" },
    { label = "Open Compose preview", value = "compose", icon = "eye" },
    { label = "Show device manager", value = "android", icon = "smartphone" },
    { label = "Open REPL", value = "repl", icon = "terminal" },
    { label = "Serve static files", value = "static", icon = "server" },
    { label = "Serve a script…", value = "script", icon = "server" },
    { label = "Open manifest", value = "manifest", icon = "file" },
  }
  -- Test runs only once there is one to view.
  if has_runs(context.root) then
    table.insert(items, { label = "View test runs", value = "tests", icon = "list" })
  end
  table.insert(items, { label = "Open project workspace", value = "workspace", icon = "folder" })
  cx:pick({
    placeholder = context.name or "Project",
    items = items,
  }):next(function(item, err, current)
    if err and current then
      current:toast("error", err)
    elseif current and item then
      if item.value == "test" then
        launch_job(current, "test", context.root, context.root)
      elseif item.value == "debug" then
        launch_debug(current, context)
      elseif item.value == "source" then
        prompt_source(current, context)
      elseif item.value == "compose" then
        prompt_compose(current, context)
      elseif item.value == "android" then
        android.open(current, context)
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
  id = "source",
  title = "Open Elide source view",
  icon = "file",
  run = function(cx)
    detect(cx, function(context, current)
      if context then
        prompt_source(current, context)
      else
        current:toast("info", "Open a file inside an Elide project first.")
      end
    end)
  end,
})
tern.command({
  id = "compose",
  title = "Open Compose preview",
  icon = "eye",
  run = function(cx)
    if local_host(cx) then
      detect(cx, function(context, current)
        prompt_compose(current, context)
      end)
    end
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
-- Build report runs (`run-*` under the project's `.dev/reports/build/tern`) present when an
-- `elide build` line started in a pane; the one new run with a report when it finishes is that
-- build's. A directory listing and one bounded read: no process inside the 50 ms budget.
local REPORT_BYTES = 8 * 1024 * 1024
local build_runs = {}

local function report_runs(root)
  local dir = root .. "/.dev/reports/build/tern"
  local ok, names = pcall(tern.fs.list, dir)
  local runs = {}
  for _, name in (ok and names or {}) do
    if string.sub(name, 1, 4) == "run-" then
      runs[name] = true
    end
  end
  return runs, dir
end

-- "3 errors, 1 warning" from the report the build in `pane` wrote, or nil.
local function build_counts(pane)
  local before = build_runs[pane]
  build_runs[pane] = nil
  if not before then
    return nil
  end
  local runs, dir = report_runs(before.root)
  local fresh = nil
  for name in runs do
    if not before.runs[name] and tern.fs.exists(dir .. "/" .. name .. "/diagnostics.json") then
      if fresh then
        return nil
      end
      fresh = name
    end
  end
  if not fresh then
    return nil
  end
  local ok, decoded = pcall(function()
    return tern.json.decode(tern.fs.read(dir .. "/" .. fresh .. "/diagnostics.json", REPORT_BYTES))
  end)
  local report = ok and diagnostics.report(decoded) or nil
  return report and diagnostics.phrase(report.errors, report.warnings, report.notes) or nil
end

tern.on("command_started", function(ev, cx)
  local command = elide_command(ev.line)
  if command == "run" then
    android.typed_run(cx, ev.pane)
  end
  if command ~= "build" then
    return
  end
  local root = project.root_of(ev.pane)
  build_runs[ev.pane] = root and { root = root, runs = (report_runs(root)) } or nil
end)

tern.on("pane_closed", function(ev)
  build_runs[ev.pane] = nil
end)

tern.on("command_finished", function(ev, cx)
  android.typed_run_ended(ev.pane)
  local command, subject = elide_command(ev.line)
  if not command then
    return
  end
  project.finished(ev.pane, command, ev.status, command == "build" and build_counts(ev.pane) or nil)
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

-- Runs `act(cx)` for a link that names project `root`: at once when this window detected that
-- project, else only after the user confirms it in a picker naming the root. A link's text can be
-- anything (an OSC 8 hyperlink in `cat`'s output), so a root it names is not trusted on its own.
local function with_root(cx, root, act)
  if links.known(root, project.roots()) then
    return act(cx)
  end
  cx:pick({
    placeholder = "An elide:// link wants to open " .. root,
    items = {
      { label = "Open project " .. root, value = "open", icon = "warn" },
      { label = "Cancel", value = "cancel", icon = "x" },
    },
  }):next(function(item, _, current)
    if current and item and item.value == "open" then
      act(current)
    end
  end)
end

-- A Compose preview is one browser pane showing its session's loopback page, which draws the
-- preview's toolbar, startup progress, failures and the previews. Its website data profile names
-- it to styles/compose.css, which hides the browser's toolbar.
local LIVE_PROFILE = "elide-compose"
-- The sessions the host half posts its dirty Elide editors to, by window key: session URL to
-- workspace root. `this_window` is this window's key, known from the first timer's `cx`.
local SESSIONS = "compose:sessions"
local this_window

-- The `http://127.0.0.1:<port>/<token>/` session URL a page shows, nil for any other URL.
local function live_url(url)
  local base, token = string.match(url or "", "^(http://127%.0%.0%.1:%d+/(%x+)/)")
  return token and #token == 64 and base or nil
end

-- A device pane takes a preview's place.
android.previews(function(info)
  return info.kind == "browser" and live_url(info.url) ~= nil
end)

local function publish_sessions()
  if not this_window then
    return
  end
  local sessions = {}
  for url, page in live_pages do
    if not page.stopped then
      sessions[url] = page.root
    end
  end
  local all = tern.kv.get(SESSIONS)
  all = type(all) == "table" and all or {}
  all[this_window] = if next(sessions) then sessions else nil
  tern.kv.set(SESSIONS, all)
end

local function forget_page(url)
  live_pages[url] = nil
  native_sessions[url] = nil
  publish_sessions()
end

-- Ends the preview: its session, and its pane.
local function close_page(cx, page)
  forget_page(page.url)
  if not page.stopped then
    loopback.request(page.url .. "close", "", 5000, function() end)
  end
  if cx.session:pane(page.pane) then
    cx.layout:close(page.pane)
  end
end

-- The page's URL with Tern's pinned appearance (`#light`, `#dark`); otherwise the page follows
-- the system's.
local function themed(cx, url)
  local theme = cx.settings:get("theme")
  return url .. (if theme == "Light" then "#light" elseif theme == "Dark" then "#dark" else "")
end

local poll_page, watch_stopped

-- Takes over the page `block` showing session `url` of workspace `root` (previewing `file`):
-- its workspace bounds the native editors posted to it, and its requests are carried out here.
local function adopt(cx, url, block, root, file)
  native_sessions[url] = { url = url, pane = block, root = root }
  local page = {
    url = url,
    pane = block,
    root = root,
    path = if file and links.within(file, root) then file else nil,
    asked = 0,
  }
  live_pages[url] = page
  publish_sessions()
  poll_native(cx)
  native_tick(cx)
  poll_page(page)
end

-- Starts a session previewing `file` and shows its page: in `page`'s pane when given (a stopped
-- preview starting again), else beside `target`.
start_preview = function(cx, file, root, target, page)
  local config = configuration(cx)
  if not config then
    return
  end
  local keep_alive = if type(config.compose_keep_alive_minutes) == "number"
    then config.compose_keep_alive_minutes
    else 10
  local argv = launcher(config, "compose")
  for _, argument in
    {
      "open",
      "--runtime",
      runtime_path(config),
      "--root",
      root,
      "--file",
      file,
      "--cache",
      path(config.compose_cache or (tern.plugin.data .. "/compose-cache")),
      "--keep-alive",
      tostring(keep_alive),
    }
  do
    table.insert(argv, argument)
  end
  if type(config.compose_java) == "string" and config.compose_java ~= "" then
    local java = config.compose_java
    table.insert(argv, "--java")
    table.insert(argv, if string.find(java, "/") then path(java) else java)
  end
  if type(config.compose_komodo) == "string" and config.compose_komodo ~= "" then
    table.insert(argv, "--komodo")
    table.insert(argv, path(config.compose_komodo))
  end
  if not page then
    cx:toast("info", "Starting Compose previews…")
  end
  -- The host half posts its dirty Elide editors once the session is listed; this half's
  -- native editors follow through `poll_native`.
  local ok, problem = pcall(function()
    tern.process.run(argv, { cwd = root, stdin = '{"documents":[]}', timeout_ms = 30000 }, function(result, current)
      if not current then
        return
      end
      local decoded, response = pcall(tern.json.decode, result.stdout or "")
      response = decoded and type(response) == "table" and response or {}
      local url, session_root = live_url(response.url), links.absolute(response.root)
      if not url or url ~= response.url or not session_root or not links.within(file, session_root) then
        local message = type(response.error) == "string" and response.error ~= "" and response.error
          or (
            "The runtime could not start Compose previews (exit "
            .. tostring(result.status)
            .. "). They need a runtime with `elide tern compose`."
          )
        current:toast("error", "Could not start Compose previews.", string.sub(message, 1, 8192))
        if page then
          watch_stopped(page)
        end
        return
      end
      if page then
        if not current.session:pane(page.pane) then
          loopback.request(url .. "close", "", 5000, function() end)
          return
        end
        live_pages[page.url] = nil
        current.browser:call({ op = "goto", block = page.pane, url = themed(current, url) })
        adopt(current, url, page.pane, session_root, file)
        return
      end
      local owner = target and current.session:pane(target) and target or current.session:focused()
      current.browser
        :call({ op = "open", owner = owner, how = "beside", url = themed(current, url), profile = LIVE_PROFILE })
        :next(function(opened, err, latest)
          if not latest then
            return
          end
          if err or not (opened and opened.ok) then
            loopback.request(url .. "close", "", 5000, function() end)
            latest:toast(
              "error",
              "Could not open Compose preview.",
              tostring(err or (opened and opened.error and opened.error.message))
            )
            return
          end
          adopt(latest, url, opened.ok.block, session_root, file)
        end)
    end)
  end)
  if not ok then
    cx:toast("error", "Could not start Compose previews.", tostring(problem))
  end
end

-- The service stopped (Stop renderer, keep-alive expiry, a crash): the page says so and stays.
local function page_stopped(page)
  native_sessions[page.url] = nil
  page.stopped = true
  publish_sessions()
  watch_stopped(page)
end

-- A stopped page's buttons ask through its URL fragment (`#start-<n>`, `#source-<n>`,
-- `#close-<n>`, a fresh `n` per click), the service being gone; it is read every second until the
-- pane closes or starts again.
watch_stopped = function(page)
  tern.timer(1000, function(cx)
    if not cx or live_pages[page.url] ~= page then
      return
    end
    if not cx.session:pane(page.pane) then
      forget_page(page.url)
      return
    end
    cx.browser:call({ op = "state", block = page.pane }):next(function(result, _, current)
      if not current or live_pages[page.url] ~= page then
        return
      end
      local fragment = result
        and result.ok
        and type(result.ok.url) == "string"
        and string.match(result.ok.url, "#(%a+%-%d+)$")
      local ask = fragment and fragment ~= page.fragment and string.match(fragment, "^%a+")
      page.fragment = fragment or page.fragment
      if ask == "start" and page.path then
        start_preview(current, page.path, page.root, nil, page)
        return
      elseif ask == "close" then
        close_page(current, page)
        return
      elseif ask == "source" and page.path then
        current:open(source.file_url(page.path))
      end
      watch_stopped(page)
    end)
  end)
end

poll_page = function(page)
  local url = page.url
  loopback.request(url .. "pane?after=" .. tostring(page.asked), nil, 30000, function(status, body, cx, timed_out)
    if live_pages[url] ~= page then
      return
    end
    if not cx then
      forget_page(url)
      return
    end
    if not cx.session:pane(page.pane) then
      close_page(cx, page)
      return
    end
    local ok, value = pcall(tern.json.decode, body)
    value = ok and type(value) == "table" and value or {}
    if status == 200 then
      if type(value.id) == "number" and value.id > page.asked then
        page.asked = value.id
        if value.action == "source" and page.path then
          cx:open(source.file_url(page.path))
        elseif value.action == "close" then
          close_page(cx, page)
          return
        elseif value.action == "retarget" then
          local file = links.absolute(value.file)
          if file and links.within(file, page.root) and source.extension(file) == "kt" then
            page.path = file
          end
        end
      end
      poll_page(page)
    elseif
      status == 410 and (value.ended == "retargeted" or value.ended == "page-closed" or value.ended == "closed")
    then
      -- Another preview of the workspace took the service, or the session was closed.
      close_page(cx, page)
    elseif status == 0 and timed_out then
      poll_page(page)
    else
      page_stopped(page)
    end
  end)
end

-- A closed page ends its session at once, rather than after the page's reconnect grace.
tern.on("pane_closed", function(ev, cx)
  for _, page in live_pages do
    if page.pane == ev.pane then
      close_page(cx, page)
    end
  end
end)

-- A plugin reload forgets the pages this window carried (`window_start` does not run again):
-- each load takes over those still open.
tern.timer(0, function(cx)
  if not cx then
    return
  end
  this_window = cx:window_key()
  publish_sessions()
  cx.browser:call({ op = "blocks" }):next(function(result, err, current)
    if not current or err or not (result and result.ok and type(result.ok.blocks) == "table") then
      return
    end
    for _, block in result.ok.blocks do
      local url = type(block) == "table" and live_url(block.url)
      if url and type(block.block) == "number" and not live_pages[url] then
        loopback.request(url .. "info", nil, 5000, function(status, body, latest)
          local decoded, info = pcall(tern.json.decode, body)
          local root = status == 200 and decoded and type(info) == "table" and links.absolute(info.root)
          if
            latest
            and root
            and not string.find(root, "%c")
            and latest.session:pane(block.block)
            and not live_pages[url]
          then
            adopt(latest, url, block.block, root, links.absolute(info.file))
          end
        end)
      end
    end
  end)
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
  elseif target.action == "help" then
    -- `elide help <url>` resolves the link to its topic. The URL is rebuilt from the
    -- validated slug, so nothing unchecked reaches the command line.
    local config = configuration(cx)
    if config then
      terminal(
        cx,
        { runtime_path(config), "--ignore-version", "help", "elide://help?topic=" .. target.topic },
        nil,
        request.pane
      )
    end
    return { handled = true }
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
    -- The source block when the file sits in a known project and is a source it shows;
    -- otherwise Tern's own editor.
    local root = target.root
    if not root then
      for _, candidate in project.roots() do
        if links.within(target.path, candidate) and (not root or #candidate > #root) then
          root = candidate
        end
      end
    end
    if root and source.lang(target.path) and configuration() then
      local args = { target.path, root }
      if target.line then
        table.insert(args, tostring(target.line))
      end
      -- The block attaches to the project, so a root the link named must be one this window knows.
      if target.root and not links.known(target.root, project.roots()) then
        with_root(cx, target.root, function(current)
          current:new_block("elide.source", args, "beside")
        end)
        return { handled = true }
      end
      return { block = "elide.source", args = args }
    end
    cx.docs:open(target.path, { line = target.line })
  elseif target.action == "debug" then
    with_root(cx, target.root, function(current)
      launch_debug(current, { root = target.root }, nil, nil, target.path)
    end)
  elseif target.action == "tests" then
    with_root(cx, target.root, function(current)
      view_tests({ root = target.root }, current)
    end)
  end
  return { handled = true }
end)

-- `elide.pkl` chosen from the palette opens its project workspace (or focuses the open one).
-- Other palette opens stay with Tern; only Files opens are redirected into a workspace editor.
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
