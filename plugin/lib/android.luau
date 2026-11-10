local ui = tern.ui
local source = require("./source")
local M = {}
local entries = {}
local configuration, plugin_path, runtime_path
local refresh

local function key(cx, pane)
  return "android:" .. cx:window_key() .. ":" .. tostring(pane)
end

local function alive(cx, state)
  return not state.closed and (not state.pane or cx.session:pane(state.pane) ~= nil)
end

local function button(label, action, disabled)
  return ui.button(label, { role = "android-" .. action, disabled = disabled, actions = { click = action } })
end

local function render(cx, state)
  if not state.pane or not alive(cx, state) then
    return
  end
  local disabled = state.busy or state.failed
  local rows = {}
  for index, avd in state.avds or {} do
    table.insert(rows, ui.node("col", { role = "android-device", gap = "sm" }, {
      ui.el("strong", { text = avd.name }),
      ui.el("div", { text = avd.state .. (avd.serial and (" · " .. avd.serial) or "") }),
      ui.node("row", { gap = "sm" }, {
        button("Start", "start-" .. index, disabled or avd.serial ~= nil),
        button("Stop", "stop-" .. index, disabled or avd.serial == nil),
        button("View", "view-" .. index, disabled or avd.serial == nil or state.mirror ~= nil),
        button("Delete…", "delete-" .. index, disabled or avd.serial ~= nil),
      }),
    }))
  end
  if #rows == 0 and not state.busy and not state.failed then
    table.insert(rows, ui.el("div", { text = "No virtual devices. Create one from an installed system image." }))
  end
  local controls = {
    button("Refresh", "refresh", state.busy),
    button("Create AVD…", "create", disabled),
  }
  if state.project and state.project.avd then
    table.insert(controls, button("Create configured AVD", "configured", disabled))
  end
  cx.canvas:set(state.pane, { view = ui.node("col", { role = "android-manager", gap = "md" }, {
    ui.el("strong", { text = state.context and "Project Android devices" or "Android Virtual Devices" }),
    ui.el("div", { text = state.context and state.context.root or "Standalone SDK management" }),
    ui.node("row", { gap = "sm" }, controls),
    ui.el("div", { role = "android-status", text = state.message or "Loading devices…" }),
    ui.el("div", { role = "android-sdk", text = state.sdk and ("SDK: " .. state.sdk) or "" }),
    ui.node("col", { gap = "md" }, rows),
    ui.el("div", { text = "Start opens the emulator window; View mirrors it in a browser pane. Closing either pane leaves the device running." }),
  }) })
end

local function command_args(state, command, arguments)
  local config = configuration() or {}
  local argv = { plugin_path(config.android or "../dist/elide-tern-android"), command, "--json" }
  if config.android_sdk then
    table.insert(argv, "--sdk")
    table.insert(argv, plugin_path(config.android_sdk))
  end
  if state.context then
    table.insert(argv, "--root")
    table.insert(argv, state.context.root)
    table.insert(argv, "--runtime")
    table.insert(argv, runtime_path(config))
  end
  for _, argument in arguments or {} do
    table.insert(argv, argument)
  end
  return argv
end

local function request(cx, state, command, arguments, callback)
  if state.busy or not alive(cx, state) then
    return
  end
  local argv = command_args(state, command, arguments)
  state.busy = true
  state.message = "Android: " .. command .. "…"
  render(cx, state)
  local function failed(current, message)
    state.busy = false
    state.failed = command == "list" or state.failed
    state.message = message
    if current and alive(current, state) then
      current:toast("error", message)
      render(current, state)
    end
  end
  local ok, problem = pcall(function()
    tern.process.run(argv, { timeout_ms = 300000 }, function(result, current)
      state.busy = false
      if not current or not alive(current, state) then
        return
      end
      local decoded, value = pcall(tern.json.decode, result.stdout or "")
      if result.status ~= 0 or not decoded or type(value) ~= "table" then
        if command == "list" and decoded and type(value) == "table" and type(value.projects) == "table" then
          local items = {}
          for _, member in value.projects do
            table.insert(items, { label = member.name .. " · " .. member.root, value = member.root })
          end
          state.failed, state.message = true, "Select an Android project to manage."
          render(current, state)
          current:pick({ placeholder = "Android workspace member", items = items }):next(function(item, err, fresh)
            if fresh and item and alive(fresh, state) then
              state.context = { root = item.value }
              if state.pane then
                tern.kv.set(key(fresh, state.pane), { context = state.context })
              end
              refresh(fresh, state)
            elseif fresh and err then
              fresh:toast("error", err)
            end
          end)
          return
        end
        local message = decoded and type(value) == "table" and value.error
        failed(current, tostring(message or result.stderr or "Android helper failed; rebuild or configure the helper."))
        return
      end
      state.message = value.message or "Ready"
      callback(current, value)
    end)
  end)
  if not ok then
    failed(cx, tostring(problem))
  end
end

refresh = function(cx, state, message)
  request(cx, state, "list", {}, function(current, value)
    state.sdk, state.avds, state.project = value.sdk, value.avds or {}, value.project
    state.failed = false
    state.message = message or "Ready"
    if value.warnings and #value.warnings > 0 then
      state.message ..= "\n" .. table.concat(value.warnings, "\n")
    end
    render(current, state)
  end)
end

local function mutate(cx, state, command, arguments)
  request(cx, state, command, arguments, function(current, value)
    current:toast("info", value.message or "Android operation completed.")
    if state.pane then
      refresh(current, state, value.message)
    end
  end)
end

local function mirror(cx, state, avd)
  if state.mirror or not avd.serial then
    return
  end
  local job = tern.plugin.data .. "/android-views/" .. source.uuid(math.random)
  local session = { job = job }
  local function cancel()
    pcall(tern.fs.write, job .. "/cancel", "cancel\n")
    if session.timer then
      session.timer:cancel()
      session.timer = nil
    end
  end
  session.cancel = cancel
  local ok, problem = pcall(function()
    tern.fs.mkdir(job)
    tern.fs.write(job .. "/lease", "alive\n")
    state.mirror = session
    state.message = "Opening " .. avd.name .. " mirror…"
    render(cx, state)
    local argv = command_args(state, "view", { "--serial", avd.serial, "--name", avd.name, "--job", job })
    tern.process.run(argv, {}, function(result, current)
      cancel()
      pcall(tern.fs.remove, job)
      if state.mirror == session then
        state.mirror = nil
      end
      if current and alive(current, state) then
        state.message = result.status == 0 and "Mirror disconnected; emulator left running."
          or string.sub(result.stderr or "Android mirror failed.", -4096)
        render(current, state)
      end
    end)
    local started = tern.now()
    local function watch(current)
      session.timer = nil
      if not current or not alive(current, state) or state.mirror ~= session then
        cancel()
        return
      end
      local renewed = pcall(tern.fs.write, job .. "/lease", "alive\n")
      if not renewed then
        cancel()
        return
      end
      if not session.opened then
        local decoded, value = pcall(function()
          return tern.json.decode(tern.fs.read(job .. "/view.json", 8192))
        end)
        local port, token
        if decoded and type(value) == "table" and type(value.url) == "string" then
          port, token = string.match(value.url, "^http://127%.0%.0%.1:(%d+)/(%x+)/$")
        end
        if port and #token == 64 and tonumber(port) >= 1 and tonumber(port) <= 65535 then
          session.opened = true
          current.browser:call({ op = "open", owner = state.pane, how = "beside", url = value.url })
            :next(function(result, err, fresh)
              if err or (result and result.error) then
                cancel()
                if fresh then
                  fresh:toast("error", "Could not open Android mirror.", tostring(err or result.error.message))
                end
              end
            end)
          state.message = "Mirroring " .. avd.name .. ". Disconnect in the browser to close the mirror."
          render(current, state)
        elseif tern.now() - started > 45000 then
          cancel()
          state.message = "Android mirror did not become ready."
          render(current, state)
          return
        end
      end
      session.timer = tern.timer(1000, watch)
    end
    session.timer = tern.timer(100, watch)
  end)
  if not ok then
    cancel()
    state.mirror = nil
    state.message = tostring(problem)
    cx:toast("error", state.message)
    render(cx, state)
  end
end

local function selected(cx, state, command, avd)
  if command == "view" then
    mirror(cx, state, avd)
    return
  end
  local arguments = { "--name", avd.name }
  if command == "stop" and avd.serial then
    table.insert(arguments, "--serial")
    table.insert(arguments, avd.serial)
  end
  if command ~= "delete" then
    mutate(cx, state, command, arguments)
    return
  end
  cx:pick({ placeholder = "Delete " .. avd.name .. " and all its data?", items = {
    { label = "Cancel", value = "cancel" },
    { label = "Delete " .. avd.name, value = "delete" },
  } }):next(function(item, err, current)
    if current and item and item.value == "delete" and alive(current, state) then
      table.insert(arguments, "--yes")
      mutate(current, state, "delete", arguments)
    elseif current and err then
      current:toast("error", err)
    end
  end)
end

local function create(cx, state)
  request(cx, state, "images", {}, function(current, value)
    render(current, state)
    local items = {}
    for _, image in value.images or {} do
      table.insert(items, { label = image.id, value = image.id })
    end
    if #items == 0 then
      current:toast("info", "No installed system images. Install one with Android Studio or sdkmanager first.")
      return
    end
    current:pick({ placeholder = "Installed Android system image", items = items }):next(function(image, err, fresh)
      if err and fresh then
        fresh:toast("error", err)
      elseif image and fresh and alive(fresh, state) then
        request(fresh, state, "profiles", {}, function(profiles_cx, profiles)
          render(profiles_cx, state)
          local devices = {}
          for _, profile in profiles.profiles or {} do
            table.insert(devices, { label = profile.name or profile.id, value = profile.id })
          end
          profiles_cx:pick({ placeholder = "AVD hardware profile", items = devices }):next(function(device, device_err, next_cx)
            if device_err and next_cx then
              next_cx:toast("error", device_err)
            elseif device and next_cx and alive(next_cx, state) then
              next_cx:prompt({ placeholder = "AVD name (letters, digits, dot, dash, underscore)", value = "", action = "create" })
                :next(function(name, name_err, final)
                  if name_err and final then
                    final:toast("error", name_err)
                  elseif final and name and name ~= "" and alive(final, state) then
                    local arguments = { "--name", name, "--image", image.value }
                    if device.value ~= "" then
                      table.insert(arguments, "--device")
                      table.insert(arguments, device.value)
                    end
                    mutate(final, state, "create", arguments)
                  end
                end)
            end
          end)
        end)
      end
    end)
  end)
end

local function local_host(cx)
  if cx.hosts:current().kind == "local" then
    return true
  end
  cx:toast("info", "Android device management requires a local host.")
  return false
end

function M.open(cx, context, target)
  if not local_host(cx) then
    return nil
  end
  for _, canvas in cx.canvas:list() do
    local existing = canvas.owner == tern.plugin.id and (entries[canvas.pane] or tern.kv.get(key(cx, canvas.pane)))
    if existing and (existing.context and existing.context.root or "") == (context and context.root or "") then
      existing.pane = canvas.pane
      entries[canvas.pane] = existing
      cx.layout:focus(canvas.pane)
      refresh(cx, existing)
      return canvas.pane
    end
  end
  local pane, problem = cx.canvas:open({
    title = "Android devices",
    about = context and context.root or "Android Virtual Devices",
    view = ui.el("div", { text = "Loading Android devices…" }),
    target = target,
    dir = "right",
    focus = true,
  })
  if not pane then
    cx:toast("error", problem or "Could not open Android devices.")
    return nil
  end
  local state = { pane = pane, context = context }
  entries[pane] = state
  tern.kv.set(key(cx, pane), { context = context })
  refresh(cx, state)
  return pane
end

function M.install(config, path, runtime)
  configuration, plugin_path, runtime_path = config, path, runtime
  tern.css("android-manager", [[
    [data-role="android-manager"] { padding: 16px; overflow: auto; font-family: system-ui, sans-serif; }
    [data-role="android-device"] { padding: 12px; border: 1px solid var(--l2); border-radius: 6px; }
    [data-role="android-sdk"] { overflow-wrap: anywhere; color: var(--t2); }
  ]])
  tern.command({ id = "android", title = "Manage Android Virtual Devices", icon = "list", run = function(cx)
    M.open(cx)
  end })
  for _, spec in {
    { id = "create", title = "Create Android Virtual Device" },
    { id = "start", title = "Start Android Virtual Device" },
    { id = "stop", title = "Stop Android Virtual Device" },
    { id = "delete", title = "Delete Android Virtual Device" },
  } do
    tern.command({ id = "android_" .. spec.id, title = spec.title, run = function(cx)
      if not local_host(cx) then
        return
      end
      local state = {}
      if spec.id == "create" then
        create(cx, state)
        return
      end
      request(cx, state, "list", {}, function(current, value)
        local items = {}
        local devices = {}
        for _, avd in value.avds or {} do
          local running = avd.serial ~= nil
          if (spec.id == "stop" and running) or (spec.id ~= "stop" and not running) then
            local id = avd.serial or avd.name
            devices[id] = avd
            table.insert(items, { label = avd.name .. (avd.serial and (" · " .. avd.serial) or ""), value = id })
          end
        end
        if #items == 0 then
          current:toast("info", "No matching virtual devices. Open Manage Android Virtual Devices to refresh or create one.")
          return
        end
        current:pick({ placeholder = spec.title, items = items }):next(function(item, err, fresh)
          if err and fresh then
            fresh:toast("error", err)
          elseif item and fresh and devices[item.value] then
            selected(fresh, state, spec.id, devices[item.value])
          end
        end)
      end)
    end })
  end
  tern.on("canvas_action", function(event, cx)
    local state = entries[event.pane]
    if not state then
      return false
    end
    if state.busy then
      return true
    end
    if event.act == "refresh" then
      refresh(cx, state)
    elseif not state.failed then
      if event.act == "create" then
        create(cx, state)
      elseif event.act == "configured" then
        mutate(cx, state, "create", {})
      else
        local command, index = string.match(event.act, "^(%a+)%-(%d+)$")
        local avd = index and state.avds and state.avds[tonumber(index)]
        if avd and (command == "start" or command == "stop" or command == "delete" or command == "view") then
          selected(cx, state, command, avd)
        end
      end
    end
    return true
  end)
  tern.on("pane_closed", function(event, cx)
    if entries[event.pane] then
      if entries[event.pane].mirror then
        entries[event.pane].mirror.cancel()
      end
      entries[event.pane].closed = true
      entries[event.pane] = nil
    end
    tern.kv.set(key(cx, event.pane), nil)
  end)
  local function restore(cx)
    for _, canvas in cx.canvas:list() do
      local saved = canvas.owner == tern.plugin.id and tern.kv.get(key(cx, canvas.pane))
      if saved and not entries[canvas.pane] then
        saved.pane = canvas.pane
        entries[canvas.pane] = saved
        refresh(cx, saved)
      end
    end
  end
  tern.on("window_start", restore)
  tern.timer(0, restore)
  pcall(tern.chrome.refresh)
end

return M
