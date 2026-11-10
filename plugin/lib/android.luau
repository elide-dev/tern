local ui = tern.ui
local M = {}
local entries = {}
local displays = {}
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
    local running = avd.serial ~= nil
    local actions = running
        and { button("Show", "show-" .. index, disabled), button("Stop", "stop-" .. index, disabled) }
      or { button("Start", "start-" .. index, disabled), button("Delete…", "delete-" .. index, disabled) }
    table.insert(
      rows,
      ui.node("row", { role = "android-device", gap = "md" }, {
        ui.node("col", { role = "android-device-info", gap = "sm", grow = 1 }, {
          ui.el("strong", { text = avd.name, role = "android-device-name" }),
          ui.el("div", {
            role = running and "android-running" or "android-stopped",
            text = avd.state .. (avd.serial and (" · " .. avd.serial) or ""),
          }),
        }),
        ui.node("row", { role = "android-device-actions", gap = "sm" }, actions),
      })
    )
  end
  if #rows == 0 and not state.busy and not state.failed then
    table.insert(rows, ui.el("div", { text = "No virtual devices. Create one from an installed system image." }))
  end
  local controls = {
    button("Refresh", "refresh", state.busy),
    button("Create AVD…", "create", disabled),
  }
  local configured_exists = false
  for _, avd in state.avds or {} do
    configured_exists = configured_exists or (state.project ~= nil and avd.name == state.project.avd)
  end
  if state.project and state.project.avd and not configured_exists then
    table.insert(controls, button("Create " .. state.project.avd, "configured", disabled))
  end
  cx.canvas:set(state.pane, {
    view = ui.node("col", { role = "android-manager", gap = "md" }, {
      ui.el("strong", { role = "android-heading", text = "Android devices" }),
      ui.el("div", { role = "android-context", text = state.context and state.context.root or "Local Android SDK" }),
      ui.node("row", { role = "android-toolbar", gap = "sm" }, controls),
      ui.el("div", { role = "android-status", text = state.message or "Loading devices…" }),
      ui.node("col", { gap = "sm" }, rows),
      ui.el(
        "div",
        { role = "android-note", text = "Closing a device pane leaves the emulator running. Stop shuts it down." }
      ),
      ui.el("div", { role = "android-sdk", text = state.sdk and ("SDK · " .. state.sdk) or "" }),
    }),
  })
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

-- The device's pane: a terminal running the helper's display. Returns the pane id.
local function show(cx, state, avd)
  if not avd.serial then
    return nil
  end
  local title = avd.name .. " · " .. avd.serial
  local pane = displays[avd.serial]
  local info = pane and cx.session:pane(pane)
  if not info or info.exited ~= nil then
    pane = nil
    -- A plugin reload forgets `displays`; the display titles its pane after the device.
    for _, candidate in cx.session:panes() do
      if candidate.title == title and candidate.exited == nil then
        pane = candidate.pane
        break
      end
    end
  end
  if pane then
    displays[avd.serial] = pane
    cx.layout:focus(pane)
    return pane
  end
  local argv = {
    plugin_path((configuration() or {}).android or "../dist/elide-tern-android"),
    "display",
    "--serial",
    avd.serial,
    "--name",
    avd.name,
  }
  local command = {}
  for _, value in argv do
    table.insert(command, "'" .. string.gsub(value, "'", "'\"'\"'") .. "'")
  end
  local spec = { command = "exec " .. table.concat(command, " ") }
  local target = if state.pane and cx.session:pane(state.pane) then state.pane else cx.session:focused()
  if target then
    pane = cx.layout:split(target, "right", spec, { focus = true })
  else
    pane = cx.layout:new_tab(spec)
  end
  if not pane then
    cx:toast("error", "Could not open " .. avd.name .. ".")
    return nil
  end
  displays[avd.serial] = pane
  return pane
end

local function selected(cx, state, command, avd)
  if command == "show" then
    show(cx, state, avd)
    return
  end
  local arguments = { "--name", avd.name }
  if command == "start" then
    request(cx, state, "start", arguments, function(current, value)
      current:toast("info", value.message or "Android operation completed.")
      show(current, state, { name = value.name or avd.name, serial = value.serial })
      if state.pane then
        refresh(current, state, value.message)
      end
    end)
    return
  end
  if command == "stop" and avd.serial then
    table.insert(arguments, "--serial")
    table.insert(arguments, avd.serial)
  end
  if command ~= "delete" then
    mutate(cx, state, command, arguments)
    return
  end
  cx:pick({
    placeholder = "Delete " .. avd.name .. " and all its data?",
    items = {
      { label = "Cancel", value = "cancel" },
      { label = "Delete " .. avd.name, value = "delete" },
    },
  }):next(function(item, err, current)
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
          profiles_cx
            :pick({ placeholder = "AVD hardware profile", items = devices })
            :next(function(device, device_err, next_cx)
              if device_err and next_cx then
                next_cx:toast("error", device_err)
              elseif device and next_cx and alive(next_cx, state) then
                next_cx
                  :prompt({
                    placeholder = "AVD name (letters, digits, dot, dash, underscore)",
                    value = "",
                    action = "create",
                  })
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
  tern.css(
    "android-manager",
    [[
    [data-role="android-manager"] { padding: 20px; overflow: auto; font-family: system-ui, sans-serif; max-width: 960px; }
    [data-role="android-heading"] { font-size: 18px; font-weight: 600; }
    [data-role="android-context"], [data-role="android-sdk"], [data-role="android-note"] { overflow-wrap: anywhere; color: var(--t2); font-size: 12px; }
    [data-role="android-toolbar"] { flex-wrap: wrap; padding-bottom: 8px; border-bottom: 1px solid var(--l2); }
    [data-role="android-device"] { padding: 12px 0; border-bottom: 1px solid var(--l2); align-items: center; flex-wrap: wrap; }
    [data-role="android-device-info"] { min-width: 140px; }
    [data-role="android-device-name"] { overflow-wrap: anywhere; font-size: 13px; }
    [data-role="android-device-actions"] { flex-wrap: wrap; }
    [data-role="android-running"] { color: var(--ok); font-size: 12px; }
    [data-role="android-stopped"] { color: var(--t2); font-size: 12px; }
    [data-role="android-status"] { font-size: 12px; overflow-wrap: anywhere; }
  ]]
  )
  tern.command({
    id = "android",
    title = "Manage Android Virtual Devices",
    icon = "list",
    run = function(cx)
      M.open(cx)
    end,
  })
  for _, spec in
    {
      { id = "create", title = "Create Android Virtual Device" },
      { id = "start", title = "Start Android Virtual Device" },
      { id = "show", title = "Show Android Virtual Device" },
      { id = "stop", title = "Stop Android Virtual Device" },
      { id = "delete", title = "Delete Android Virtual Device" },
    }
  do
    tern.command({
      id = "android_" .. spec.id,
      title = spec.title,
      run = function(cx)
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
            local wants_running = spec.id == "stop" or spec.id == "show"
            if wants_running == running then
              local id = avd.serial or avd.name
              devices[id] = avd
              table.insert(items, { label = avd.name .. (avd.serial and (" · " .. avd.serial) or ""), value = id })
            end
          end
          if #items == 0 then
            current:toast(
              "info",
              "No matching virtual devices. Open Manage Android Virtual Devices to refresh or create one."
            )
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
      end,
    })
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
        if avd and (command == "start" or command == "stop" or command == "delete" or command == "show") then
          selected(cx, state, command, avd)
        end
      end
    end
    return true
  end)
  tern.on("pane_closed", function(event, cx)
    if entries[event.pane] then
      entries[event.pane].closed = true
      entries[event.pane] = nil
    end
    for serial, pane in displays do
      if pane == event.pane then
        displays[serial] = nil
      end
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
