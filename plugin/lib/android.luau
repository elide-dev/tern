local ui = tern.ui
local M = {}
local entries = {}
-- Device panes by serial: `{pane, name, physical}`, kept in kv so a plugin reload still knows them.
-- Each window keeps its own (pane ids are per window): `DISPLAYS .. ":" .. window key`.
local displays = {}
local DISPLAYS = "android:displays"
local configuration, plugin_path, runtime_path
local refresh

local function key(cx, pane)
  return "android:" .. cx:window_key() .. ":" .. tostring(pane)
end

local function alive(cx, state)
  return not state.closed and (not state.pane or cx.session:pane(state.pane) ~= nil)
end

-- A quiet icon-only button, as in Tern's own toolbars; `title` is its tooltip and accessible name.
local function button(icon, title, action, disabled, busy)
  return ui.button("", {
    icon = icon,
    title = title,
    variant = "quiet",
    role = "android-" .. action,
    disabled = disabled,
    busy = busy,
    actions = { click = action },
  })
end

-- One device row: kind icon, name and state, actions.
local function device_row(icon, kind, name, detail, running, actions)
  return ui.node("row", { role = "android-device", gap = "md" }, {
    ui.node("icon", { role = "android-device-kind", name = icon, title = kind, aria = { label = kind } }),
    ui.node("col", { role = "android-device-info", gap = "sm", grow = 1 }, {
      ui.el("strong", { text = name, role = "android-device-name" }),
      ui.el("div", { role = running and "android-running" or "android-stopped", text = detail }),
    }),
    ui.node("row", { role = "android-device-actions", gap = "xs" }, actions),
  })
end

-- What an attached device's adb state means for mirroring it.
local DEVICE_STATES = {
  device = "connected",
  unauthorized = "unauthorized · allow USB debugging on the device",
  offline = "offline · reconnect it",
}

local function render(cx, state)
  if not state.pane or not alive(cx, state) then
    return
  end
  local disabled = state.busy or state.failed
  local rows = {}
  for index, avd in state.avds or {} do
    local running = avd.serial ~= nil
    local actions = running
        and { button("eye", "Show", "show-" .. index, disabled), button("stop", "Stop", "stop-" .. index, disabled) }
      or {
        button("play", "Start", "start-" .. index, disabled),
        button("trash", "Delete…", "delete-" .. index, disabled),
      }
    local detail = avd.state .. (avd.serial and (" · " .. avd.serial) or "")
    table.insert(rows, device_row("mi-android", "Virtual device", avd.name, detail, running, actions))
  end
  for index, device in state.devices or {} do
    local connected = device.state == "device"
    local actions = connected and { button("eye", "Show", "mirror-" .. index, disabled) } or {}
    local detail = (DEVICE_STATES[device.state] or device.state) .. " · " .. device.serial
    table.insert(
      rows,
      device_row("smartphone", "Physical device", device.name or device.serial, detail, connected, actions)
    )
  end
  -- A one-line summary under the list: what was found, and where physical devices come from.
  local summary
  if state.avds and not state.failed then
    local running = 0
    for _, avd in state.avds do
      running += avd.serial and 1 or 0
    end
    local virtual = #state.avds == 0 and "No virtual devices"
      or (#state.avds .. (#state.avds == 1 and " virtual device" or " virtual devices"))
    if running > 0 then
      virtual ..= ", " .. running .. " running"
    end
    local attached = #(state.devices or {})
    local physical = attached == 0 and "Connect a phone with USB debugging on to show it here."
      or (attached .. (attached == 1 and " physical device connected." or " physical devices connected."))
    summary = ui.el("div", { role = "android-summary", text = virtual .. ". " .. physical })
  end
  local controls = {}
  local configured_exists = false
  for _, avd in state.avds or {} do
    configured_exists = configured_exists or (state.project ~= nil and avd.name == state.project.avd)
  end
  if state.project and state.project.avd and not configured_exists then
    table.insert(
      controls,
      button("file-plus", "Create " .. state.project.avd .. " from the project", "configured", disabled)
    )
  end
  table.insert(controls, button("plus", "Create virtual device…", "create", disabled))
  table.insert(
    controls,
    button("refresh", state.sdk and ("Refresh · SDK " .. state.sdk) or "Refresh", "refresh", state.busy, state.busy)
  )
  local header =
    { ui.node("col", { grow = 1 }, { ui.el("strong", { role = "android-heading", text = "Android devices" }) }) }
  for _, control in controls do
    table.insert(header, control)
  end
  local view = { ui.node("row", { role = "android-toolbar", gap = "xs" }, header) }
  if state.context then
    table.insert(view, ui.el("div", { role = "android-context", text = state.context.root }))
  end
  if state.message then
    table.insert(view, ui.el("div", { role = "android-status", text = state.message }))
  end
  table.insert(view, ui.node("col", { gap = "sm" }, rows))
  if summary then
    table.insert(view, summary)
  end
  cx.canvas:set(state.pane, { view = ui.node("col", { role = "android-manager", gap = "md" }, view) })
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

-- Runs the helper's `command`; `callback(current, value)` gets its JSON result. `failure(current,
-- message, value)`, when given, replaces the default failure handling (toast, `state.failed`,
-- the member picker); `value` is the helper's decoded error object, if any.
local function request(cx, state, command, arguments, callback, failure)
  if state.busy or not alive(cx, state) then
    return
  end
  local argv = command_args(state, command, arguments)
  state.busy = true
  state.message = nil
  render(cx, state)
  local function failed(current, message, value)
    if failure then
      state.busy = false
      failure(current, message, value)
      return
    end
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
        if failure then
          local message = decoded and type(value) == "table" and value.error
          failed(
            current,
            tostring(message or result.stderr or "Android helper failed; rebuild or configure the helper."),
            decoded and value or nil
          )
          return
        end
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
      state.message = nil
      callback(current, value)
    end)
  end)
  if not ok then
    failed(cx, tostring(problem))
  end
end

refresh = function(cx, state)
  request(cx, state, "list", {}, function(current, value)
    state.sdk, state.avds, state.devices, state.project =
      value.sdk, value.avds or {}, value.devices or {}, value.project
    state.failed = false
    state.message = value.warnings and #value.warnings > 0 and table.concat(value.warnings, "\n") or nil
    render(current, state)
  end)
end

local function mutate(cx, state, command, arguments)
  request(cx, state, command, arguments, function(current, value)
    current:toast("info", value.message or "Done.")
    if state.pane then
      refresh(current, state)
    end
  end)
end

-- Whether a pane is a Compose preview: the browser pane the window half opens on a session's
-- page, which it recognizes with the predicate it registers through `M.previews`.
local live_preview = function(_info): boolean
  return false
end

function M.previews(predicate)
  live_preview = predicate
end

local function is_preview(info)
  return not info.parked and live_preview(info)
end

-- The open Compose preview a device pane takes the place of: one in `tab` when given, else
-- preferably one in the current tab.
local function compose_pane(cx, tab)
  local only = tab ~= nil
  if not only then
    local focused = cx.session:focused()
    tab = focused and cx.session:tab_of(focused)
  end
  local found
  for _, info in cx.session:panes() do
    if is_preview(info) then
      if info.tab == tab then
        return info.pane
      end
      if not only then
        found = found or info.pane
      end
    end
  end
  return found
end

-- Whether a pane is a display's for `device`: a program pane titled `NAME · SERIAL`, or the
-- name (an emulator starting) or serial (a device connecting) alone until the display knows both.
-- Shells and the workspace toolbar are titled after their project, the default name of its AVD.
local function shows(info, device)
  if info.kind ~= "agent" then
    return false
  end
  local title = info.title
  if device.physical then
    return device.serial ~= nil and (title == device.serial or title == (device.name or "") .. " · " .. device.serial)
  end
  local prefix = (device.name or "") .. " · "
  return device.name ~= nil and (title == device.name or string.sub(title, 1, #prefix) == prefix)
end

local function display_key(device)
  return device.physical and device.serial or ("avd:" .. device.name)
end

local function displays_key(cx)
  return DISPLAYS .. ":" .. cx:window_key()
end

-- Records `device`'s pane, closes the panes it replaces (`closing`) and focuses it.
local function finish(cx, device, pane, closing)
  displays[display_key(device)] =
    { pane = pane, name = device.name, serial = device.serial, physical = device.physical == true }
  tern.kv.set(displays_key(cx), displays)
  for _, closed in closing do
    if closed ~= pane and cx.session:pane(closed) then
      cx.layout:close(closed)
    end
  end
  cx.layout:focus(pane)
end

-- The device pane being launched: { device, closing, before = pane ids before the split, expires }.
local launching

-- Finishes `launching` with `pane`, unless the pane existed before the split or it expired.
local function launched(cx, pane)
  local launch = launching
  if launch and not launch.before[pane] and os.clock() < launch.expires then
    launching = nil
    finish(cx, launch.device, pane, launch.closing)
  end
end

-- Opens the device's pane: a terminal running the helper's display. A running AVD is shown over
-- its emulator's gRPC endpoint, one with `start` is started there first, with its progress; a
-- physical device (`physical`) is mirrored over adb. The pane takes the place of an open Compose
-- preview, else of `replace` (the manager it was chosen in); `replace` closes either way. With
-- `previews` it takes the place of one in `target`'s tab only, and every open Compose preview
-- closes. Without a place it opens beside `target` when given, else beside the focused pane.
-- `context` is the manager's project, whose SDK a start uses.
local function show(cx, device, replace, context, target, previews)
  if not device.serial and not device.start then
    return
  end
  replace = replace and cx.session:pane(replace) and replace
  local tab = previews and target and cx.session:pane(target) and cx.session:tab_of(target) or nil
  local place = (if previews then (tab and compose_pane(cx, tab)) else compose_pane(cx)) or replace
  -- A list without holes: entries are appended below.
  local closing = {}
  if place then
    table.insert(closing, place)
  end
  if replace and replace ~= place then
    table.insert(closing, replace)
  end
  if previews then
    for _, info in cx.session:panes() do
      if is_preview(info) then
        table.insert(closing, info.pane)
      end
    end
  end
  local known = displays[display_key(device)]
  local pane = known and known.pane
  local info = pane and cx.session:pane(pane)
  if not info or info.exited ~= nil or not shows(info, device) then
    pane = nil
    -- A plugin reload forgets `displays`; the display titles its pane after the device.
    for _, candidate in cx.session:panes() do
      if candidate.exited == nil and shows(candidate, device) then
        pane = candidate.pane
        break
      end
    end
  end
  -- A view that could not open its device says so in its title (android/display.ts): a new one
  -- takes its place.
  local label = if device.physical then device.serial else device.name
  for _, candidate in (if label then cx.session:panes() else {}) do
    if candidate.kind == "agent" and candidate.title == label .. " (failed)" then
      place = place or candidate.pane
      table.insert(closing, candidate.pane)
    end
  end
  if pane then
    if place and place ~= pane then
      cx.layout:move(pane, place, "swap")
    elseif target and cx.session:pane(target) and cx.session:tab_of(pane) ~= cx.session:tab_of(target) then
      -- A device shown in another tab comes into the workspace.
      cx.layout:move(pane, target, "right")
    end
    finish(cx, device, pane, closing)
    return
  end
  local config = configuration() or {}
  local argv = { plugin_path(config.android or "../dist/elide-tern-android"), "display" }
  local function add(...)
    for _, value in { ... } do
      table.insert(argv, value)
    end
  end
  if device.physical or device.start then
    if config.android_sdk then
      add("--sdk", plugin_path(config.android_sdk))
    end
  end
  if device.physical then
    add("--serial", device.serial)
  elseif device.start then
    add("--name", device.name, "--start")
    if context then
      add("--root", context.root, "--runtime", runtime_path(config))
    end
  else
    add("--serial", device.serial, "--name", device.name)
  end
  local command = {}
  for _, value in argv do
    table.insert(command, "'" .. string.gsub(value, "'", "'\"'\"'") .. "'")
  end
  local spec = { command = "exec " .. table.concat(command, " ") }
  -- The first pane a window launches with a command waits for Tern to read the login shell's
  -- environment (a second or more for an interactive zsh), and Tern has no asynchronous split.
  -- That can outlast this hook's wall-time budget, and Tern then aborts the hook as the split
  -- returns; the new pane's `pane_created` then finishes the launch.
  local before = {}
  for _, info in cx.session:panes() do
    before[info.pane] = true
  end
  launching = { device = device, closing = closing, before = before, expires = os.clock() + 10 }
  local beside = place or (target and cx.session:pane(target) and target) or cx.session:focused()
  local pane = if beside then cx.layout:split(beside, "right", spec, { focus = true }) else cx.layout:new_tab(spec)
  if pane then
    launched(cx, pane)
  elseif launching then
    launching = nil
    cx:toast("error", "Could not open " .. (device.name or device.serial) .. ".")
  end
end

-- Asks whether to stop the emulator whose pane closed, unless it is not running.
local function offer_stop(cx, name)
  local state = {}
  request(cx, state, "list", {}, function(current, value)
    local serial
    for _, avd in value.avds or {} do
      if avd.name == name and avd.serial then
        serial = avd.serial
      end
    end
    if not serial then
      return
    end
    current
      :pick({
        -- An AVD is often named after its app: the prompt says it is the emulator.
        placeholder = "Emulator " .. name .. " is still running",
        icon = "smartphone",
        items = {
          { label = "Stop emulator " .. name, value = "stop", icon = "stop" },
          { label = "Keep the emulator running", value = "keep", icon = "play" },
        },
      })
      :next(function(item, err, fresh)
        if fresh and item and item.value == "stop" then
          request(fresh, state, "stop", { "--name", name, "--serial", serial }, function(done, result)
            done:toast("info", result.message or ("Stopped " .. name .. "."))
            for _, entry in entries do
              refresh(done, entry)
            end
          end)
        elseif fresh and err then
          fresh:toast("error", err)
        end
      end)
  end)
end

local function selected(cx, state, command, avd)
  if command == "show" then
    show(cx, avd, state.pane)
    return
  end
  if command == "start" then
    -- The device pane opens at once and shows the start's progress.
    show(cx, { name = avd.name, start = true }, state.pane, state.context)
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
    current:pick({ placeholder = "System image", items = items }):next(function(image, err, fresh)
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
            :pick({ placeholder = "Hardware profile", items = devices })
            :next(function(device, device_err, next_cx)
              if device_err and next_cx then
                next_cx:toast("error", device_err)
              elseif device and next_cx and alive(next_cx, state) then
                next_cx
                  :prompt({
                    placeholder = "Device name (letters, digits, dot, dash, underscore)",
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

-- Whether the manifest at `root`, or a workspace member's it lists, mentions Android at all: a
-- cheap filter, so projects without Android skip the helper (which evaluates the manifests with
-- the runtime). A member pattern the filter cannot follow counts as Android; the helper decides.
function M.declared(root)
  local function manifest(directory)
    local ok, text = pcall(tern.fs.read, directory .. "/elide.pkl", 1048576)
    return ok and text or nil
  end
  local text = manifest(root)
  if not text then
    return false
  end
  if string.find(text, "android", 1, true) then
    return true
  end
  local members = string.match(text, "members%s*{(.-)}")
  for member in string.gmatch(members or "", '"([^"]+)"') do
    if string.find(member, "[*?%[]") then
      return true
    end
    local inner = manifest(if string.sub(member, 1, 1) == "/" then member else root .. "/" .. member)
    if inner and string.find(inner, "android", 1, true) then
      return true
    end
  end
  return false
end

-- The Run whose device pane is armed but whose page has not opened yet: `{ plan, before = pane ids
-- before the page's split, expires }`. Once its page opens, the follow watches that page on its own
-- (`page`, and `plain`: when a page still without a surface counts as plain output), and another
-- Run can arm meanwhile.
local following

-- Opens `follow`'s device pane in the place of a Compose preview in the editor's tab
-- (`plan.beside`, set by the Run), closing every other one, else right of the editor; without
-- one, right of the page.
local function reveal(cx, follow)
  local plan = follow.plan
  if plan.display and cx.session:pane(follow.page) then
    local beside = plan.beside and cx.session:pane(plan.beside) and plan.beside or follow.page
    show(cx, plan.display, nil, plan.context, beside, true)
  end
end

-- Prepares the device an Android project's Run deploys to, by Elide's own choice of device but
-- inside Tern: one attached device (a running emulator or a phone) is used; none starts the
-- project's AVD for the embedded emulator, creating it from the project when missing; several
-- prefer the project's AVD, else ask. A workspace with several Android projects first asks which
-- one runs, offering the last one chosen there first. Calls `done(cx, plan)` once: `{ root,
-- args, display? }` (`root` is the chosen project's, `args` select the device for `elide run`,
-- `display` is the device pane `M.follow` opens once the Run page's build is done), nil when the
-- project is not Android, false when the run cannot go ahead (a toast says why, unless the user
-- cancelled). Nothing waits for a boot: the project's AVD boots while the build runs, and
-- `--emulator` makes Elide wait for it, so the Run page shows the build from its start.
function M.run_device(cx, context, done)
  if not local_host(cx) then
    done(cx, false)
    return
  end
  local state = { context = context }
  local function fail(current, message)
    if current then
      current:toast("error", "Could not prepare an Android device.", message)
      done(current, false)
    end
  end
  -- Reports the plan for `device`; `start` starts the project's AVD first. The page opens as soon
  -- as the emulator holds the AVD, before adb lists it: Elide's `--emulator` adopts an emulator
  -- holding the AVD rather than booting its own, and the device pane, which finds it by name,
  -- opens once the build is done.
  local function embed(current, device, root, project_avd, start)
    local plan = { root = root, context = state.context }
    if start then
      current:toast("info", "Starting " .. device.name .. "…")
      request(current, state, "start", { "--name", device.name, "--held" }, function(fresh)
        plan.args, plan.display = { "--emulator" }, { name = device.name, start = true }
        done(fresh, plan)
      end, fail)
      return
    end
    local display = device.embeddable and { name = device.name, serial = device.serial } or nil
    if not device.physical and device.name == project_avd then
      plan.args, plan.display = { "--emulator" }, display
      done(current, plan)
      return
    end
    -- Elide installs on a `--device` as soon as adb lists it; another emulator may still boot.
    request(current, state, "wait", { "--serial", device.serial }, function(fresh, value)
      plan.args, plan.display = { "--device=" .. value.serial }, display
      done(fresh, plan)
    end, fail)
  end
  -- The project chosen last in this workspace, kept across reloads.
  local remembered = "android:run-project:" .. context.root
  local prepare
  -- Asks which of the workspace's Android `projects` runs, the last one chosen first, then
  -- prepares its device.
  local function choose(current, projects)
    local last = tern.kv.get(remembered)
    local items = {}
    for _, member in projects do
      local path = member.root
      if string.sub(path, 1, #context.root + 1) == context.root .. "/" then
        path = string.sub(path, #context.root + 2)
      end
      -- The directory says nothing more when the project is named after it.
      local detail = if path ~= member.name then path else nil
      local item = { label = member.name, detail = detail, value = member.root, current = member.root == last }
      table.insert(items, if item.current then 1 else #items + 1, item)
    end
    current
      :pick({ placeholder = "Run which Android project?", icon = "smartphone", action = "run", items = items })
      :next(function(item, err, fresh)
        if not fresh then
          return
        end
        if not item then
          if err then
            fresh:toast("error", err)
          end
          done(fresh, false)
          return
        end
        tern.kv.set(remembered, item.value)
        state.context = { root = item.value }
        prepare(fresh)
      end)
  end
  function prepare(from)
    request(from, state, "list", {}, function(current, value)
      local project = value.project
      local candidates = {}
      for _, avd in value.avds or {} do
        if avd.serial then
          table.insert(candidates, { name = avd.name, serial = avd.serial, embeddable = avd.embeddable == true })
        end
      end
      for _, device in value.devices or {} do
        if device.state == "device" then
          table.insert(candidates, { name = device.name, serial = device.serial, physical = true })
        end
      end
      if #candidates == 0 then
        local exists = false
        for _, avd in value.avds or {} do
          exists = exists or avd.name == project.avd
        end
        if exists then
          embed(current, { name = project.avd }, project.root, project.avd, true)
        else
          current:toast("info", "Creating " .. project.avd .. " from the project…")
          request(current, state, "create", {}, function(fresh)
            embed(fresh, { name = project.avd }, project.root, project.avd, true)
          end, fail)
        end
        return
      end
      local chosen = #candidates == 1 and candidates[1] or nil
      for _, candidate in candidates do
        if not chosen and not candidate.physical and candidate.name == project.avd then
          chosen = candidate
        end
      end
      if chosen then
        embed(current, chosen, project.root, project.avd, false)
        return
      end
      local items = {}
      for _, candidate in candidates do
        local label = candidate.name and (candidate.name .. " · " .. candidate.serial) or candidate.serial
        table.insert(items, { label = label, value = candidate.serial })
      end
      current
        :pick({ placeholder = "Run " .. project.name .. " on", icon = "smartphone", items = items })
        :next(function(item, err, fresh)
          if not fresh then
            return
          end
          for _, candidate in candidates do
            if item and candidate.serial == item.value then
              embed(fresh, candidate, project.root, project.avd, false)
              return
            end
          end
          if err then
            fresh:toast("error", err)
          end
          done(fresh, false)
        end)
    end, function(current, message, value)
      if not current then
        return
      end
      if type(value) == "table" and value.code == "not-android" then
        done(current, nil)
      elseif type(value) == "table" and type(value.projects) == "table" and #value.projects > 0 then
        choose(current, value.projects)
      else
        fail(current, message)
      end
    end)
  end
  prepare(cx)
end

-- Arms `plan`'s device pane before the Run page's split; `M.followed` (or the page's
-- `pane_created`, when Tern aborted the hook at the split) starts watching the page.
function M.follow(cx, plan)
  local before = {}
  for _, info in cx.session:panes() do
    before[info.pane] = true
  end
  following = { plan = plan, before = before, expires = os.clock() + 30 }
end

-- Whether the Run page `pane` shows node `id` of its surface.
local function shown(cx, pane, id)
  return type(cx.session:surface(pane, { root = id, depth = 0 })) == "table"
end

-- Polls a Run's page until its build is done: the Run page keys its bar `program` past a finished
-- build, the program (an Android deploy) running. A page that shows a summary instead ended
-- without one, and so did a pane that closed or exited; neither gets the device pane. A runtime
-- without the page prints plain output, with nothing to wait for.
local function watch(cx, follow)
  local info = cx.session:pane(follow.page)
  if not info or info.exited ~= nil then
    return
  end
  local read = cx.session:read(follow.page, { lines = 1, max_chars = 1 })
  if type(read) == "table" and read.surface then
    if shown(cx, follow.page, "main.activity.program") then
      reveal(cx, follow)
      return
    elseif shown(cx, follow.page, "main.activity.summary") then
      return
    end
  elseif os.clock() >= follow.plain then
    reveal(cx, follow)
    return
  end
  tern.timer(500, function(current)
    if current then
      watch(current, follow)
    end
  end)
end

-- Starts watching the Run page `pane` for the armed device pane. A nil `pane` (the page did not
-- open) disarms it.
function M.followed(cx, pane)
  local follow = following
  if not follow or (pane and follow.before[pane]) then
    return
  end
  following = nil
  if not pane or os.clock() >= follow.expires then
    return
  end
  -- The Run page opens its surface as it starts; a pane still without one is plain output.
  follow.page, follow.plain = pane, os.clock() + 3
  watch(cx, follow)
end

-- Markers the helper leaves when an Elide command boots an emulator through the launcher the
-- host's spawn hook names (`start --held --announce`, android/sdk.ts `announceStart`):
-- `{ name, pane, time }`, the AVD and the pane the command ran in. However that command was
-- started (typed, wrapped, Run again, `elide build android-emulator`), the window showing the
-- pane opens the device pane beside it. A marker no window claims expires.
local STARTED = tern.plugin.data .. "/android/started"
local STARTED_SECONDS = 120

-- Shows AVD `name` beside `pane` once adb lists its emulator and it advertises a display. It
-- registers seconds after `start --held` returns, hence `tries`, two seconds apart. `sdk` is the
-- SDK the helper started it from, so the lookup asks the same adb.
local function show_started(cx, pane, name, sdk, tries)
  local arguments = {}
  if type(sdk) == "string" and not (configuration() or {}).android_sdk then
    arguments = { "--sdk", sdk }
  end
  request(cx, {}, "list", arguments, function(current, value)
    for _, avd in value.avds or {} do
      if avd.name == name and avd.serial and avd.embeddable then
        show(current, { name = name, serial = avd.serial }, nil, nil, pane, true)
        return
      end
    end
    if tries > 1 then
      tern.timer(2000, function(fresh)
        if fresh and fresh.session:pane(pane) then
          show_started(fresh, pane, name, sdk, tries - 1)
        end
      end)
    end
  end, function(current, message)
    if current then
      current:toast("error", "Could not show " .. name .. ": " .. tostring(message))
    end
  end)
end

-- Claims the markers naming a pane of this window, each second.
function M.watch_started(cx)
  if cx.hosts:current().kind == "local" and tern.fs.exists(STARTED) then
    for _, file in tern.fs.list(STARTED) do
      local path = STARTED .. "/" .. file
      if string.sub(file, -5) == ".json" then
        local ok, marker = pcall(function()
          return tern.json.decode(tern.fs.read(path, 4096))
        end)
        local valid = ok
          and type(marker) == "table"
          and type(marker.name) == "string"
          and type(marker.pane) == "number"
          and type(marker.time) == "number"
        if not valid or os.time() - marker.time > STARTED_SECONDS then
          pcall(tern.fs.remove, path)
        elseif cx.session:pane(marker.pane) then
          pcall(tern.fs.remove, path)
          show_started(cx, marker.pane, marker.name, marker.sdk, 30)
        end
      end
    end
  end
  tern.timer(1000, function(current)
    if current then
      M.watch_started(current)
    end
  end)
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
    about = context and context.root or "Device manager",
    view = ui.node("col", { role = "android-manager" }, {}),
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
    [data-role="android-manager"] { padding: 16px 20px; overflow: auto; font-family: system-ui, sans-serif; max-width: 960px; }
    [data-role="android-toolbar"] { align-items: center; padding-bottom: 8px; border-bottom: 1px solid var(--l2); }
    [data-role="android-heading"] { font-size: 15px; font-weight: 600; }
    [data-role="android-context"], [data-role="android-summary"] { overflow-wrap: anywhere; color: var(--t2); font-size: 12px; }
    [data-role="android-device"] { padding: 8px 0; border-bottom: 1px solid var(--l2); align-items: center; flex-wrap: wrap; }
    [data-role="android-device-kind"] { flex: none; color: var(--t2); }
    [data-role="android-device-info"] { min-width: 140px; }
    [data-role="android-device-name"] { overflow-wrap: anywhere; font-size: 13px; }
    [data-role="android-device-actions"] { flex-wrap: wrap; }
    [data-role="android-running"] { color: var(--ok); font-size: 12px; }
    [data-role="android-stopped"] { color: var(--t2); font-size: 12px; }
    [data-role="android-status"] { font-size: 12px; overflow-wrap: anywhere; white-space: pre-wrap; }
  ]]
  )
  tern.command({
    id = "android",
    title = "Show device manager",
    icon = "smartphone",
    run = function(cx)
      M.open(cx)
    end,
  })
  for _, spec in
    {
      { id = "create", title = "Create virtual device" },
      { id = "start", title = "Start virtual device" },
      { id = "show", title = "Show Android device" },
      { id = "stop", title = "Stop virtual device" },
      { id = "delete", title = "Delete virtual device" },
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
          if spec.id == "show" then
            for _, device in value.devices or {} do
              if device.state == "device" then
                devices[device.serial] = { name = device.name, serial = device.serial, physical = true }
                local label = device.name and (device.name .. " · " .. device.serial) or device.serial
                table.insert(items, { label = label, value = device.serial })
              end
            end
          end
          if #items == 0 then
            current:toast("info", "No matching devices. Open the device manager to refresh or create one.")
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
        local device = command == "mirror" and state.devices and state.devices[tonumber(index)]
        local avd = index and state.avds and state.avds[tonumber(index)]
        if device and device.state == "device" then
          show(cx, { name = device.name, serial = device.serial, physical = true }, state.pane)
        elseif avd and (command == "start" or command == "stop" or command == "delete" or command == "show") then
          selected(cx, state, command, avd)
        end
      end
    end
    return true
  end)
  tern.on("pane_created", function(event, cx)
    launched(cx, event.pane)
    M.followed(cx, event.pane)
  end)
  tern.on("pane_closed", function(event, cx)
    if entries[event.pane] then
      entries[event.pane].closed = true
      entries[event.pane] = nil
    end
    for id, display in displays do
      if display.pane == event.pane then
        displays[id] = nil
        tern.kv.set(displays_key(cx), displays)
        -- However the pane closed, an emulator it showed keeps running unless the user stops it.
        if not display.physical and display.name then
          offer_stop(cx, display.name)
        end
      end
    end
    tern.kv.set(key(cx, event.pane), nil)
  end)
  local function restore(cx)
    displays = tern.kv.get(displays_key(cx)) or {}
    -- Before keys were per window, every window overwrote one shared record.
    tern.kv.set(DISPLAYS, nil)
    for _, canvas in cx.canvas:list() do
      local saved = canvas.owner == tern.plugin.id and tern.kv.get(key(cx, canvas.pane))
      if saved and not entries[canvas.pane] then
        saved.pane = canvas.pane
        entries[canvas.pane] = saved
        refresh(cx, saved)
      end
    end
    -- A saved pane id this window now uses for something else is no device pane.
    for id, display in displays do
      local info = cx.session:pane(display.pane)
      if info and not shows(info, display) then
        displays[id] = nil
      end
    end
    tern.kv.set(displays_key(cx), displays)
  end
  tern.on("window_start", restore)
  tern.timer(0, restore)
  pcall(tern.chrome.refresh)
end

return M
