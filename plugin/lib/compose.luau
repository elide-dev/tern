-- Editor previews and live sessions share a helper lease. Live input belongs to a browser
-- view: native image nodes expose zoom, not pointer coordinates. That view opens over this
-- pane while the session runs (window.luau's compose-live route) and closes when it ends.
local ui = tern.ui
local source = require("./source")
local links = require("./links")
local blocks = {}
local MAX_IMAGES = 32
local MAX_PNG = 8 * 1024 * 1024
local MAX_GALLERY = 64 * 1024 * 1024
local TERMINAL = { ready = true, error = true, cancelled = true }
-- Busy phases: their label and the step of STEPS they work on (none while stopping).
local PROGRESS = {
  starting = { label = "Starting previews…", step = 1 },
  resolving = { label = "Loading project…", step = 1 },
  waiting = { label = "Waiting for workspace build…", step = 1 },
  runtime = { label = "Preparing renderer…", step = 2 },
  building = { label = "Building preview inputs…", step = 3 },
  refreshing = { label = "Updating previews…", step = 4 },
  rendering = { label = "Rendering previews…", step = 4 },
  cancelling = { label = "Stopping previews…" },
}
local STEPS = { "Project", "Renderer", "Build", "Render" }
local images, request
local documents = {}
local documents_revision = 0
local documents_timer

local function text(value, limit)
  return type(value) == "string" and string.sub(value, 1, limit or 2048) or ""
end

-- Sets the phase, advancing the progress steps. Steps only move forward while busy: live mode
-- starts its language server ("runtime") after the build, which must not undo the Build step.
local function advance(state, phase, message)
  local step = PROGRESS[phase] and PROGRESS[phase].step
  local busy = PROGRESS[state.phase] and PROGRESS[state.phase].step and state.step
  state.step = if step and busy then math.max(busy, step) else step
  state.phase, state.message = phase, message
end

local function alive(state)
  if state.closed then
    return false
  end
  for _, pane in tern.pane.list() do
    if pane.pane == state.pane then
      return true
    end
  end
  return false
end

local function publish_documents(state, job)
  local latest = {}
  for _, draft in documents do
    if links.within(draft.file, state.root) then
      local previous = latest[draft.file]
      if not previous or previous.revision < draft.revision then
        latest[draft.file] = draft
      end
    end
  end
  local encoded = {}
  for file, draft in latest do
    table.insert(encoded, tern.json.encode({ file = file, text = draft.text }))
  end
  -- Encode the array explicitly: an empty Luau table otherwise becomes {}.
  -- The helper retries partial JSON from writes through the host filesystem API.
  tern.fs.write(job .. "/documents.json", '{"documents":[' .. table.concat(encoded, ",") .. "]}")
  state.documents_revision = documents_revision
end

local function document(pane, file, content)
  file = links.absolute(file)
  if not file or (source.extension(file) ~= "kt" and source.extension(file) ~= "java") then
    content = nil
  end
  local previous = documents[pane]
  if (content == nil and previous == nil) or (previous and previous.file == file and previous.text == content) then
    return
  end
  documents_revision += 1
  documents[pane] = type(content) == "string" and { file = file, text = content, revision = documents_revision } or nil
  if documents_timer then
    documents_timer:cancel()
  end
  documents_timer = tern.timer(200, function()
    documents_timer = nil
    for _, state in blocks do
      if state.job and not state.cancelling and alive(state) then
        pcall(publish_documents, state, state.job)
      end
    end
  end)
end

-- The `port/token` route of a live session's loopback page, nil for any other URL.
local function live_route(url)
  local port, token = string.match(url or "", "^http://127%.0%.0%.1:(%d+)/(%x+)/$")
  if port and #token == 64 and tonumber(port) >= 1 and tonumber(port) <= 65535 then
    return port .. "/" .. token
  end
  return nil
end

-- Shows the live session's page over this pane; saved so a reload can close it.
local function show_live(state, cx)
  local route = live_route(state.url)
  if route then
    state.browser = route
    cx:save()
    cx:open("elide://compose-live/" .. state.pane .. "/" .. route)
  end
end

-- Closes the live page shown over this pane, bringing the pane back.
local function hide_live(state, cx)
  local route = state.browser
  state.browser = nil
  if route then
    pcall(function()
      cx:open("elide://compose-live/" .. state.pane .. "/" .. route .. "/close")
    end)
  end
end

local function cancel(state)
  state.pending_mode = nil
  if state.job then
    pcall(tern.fs.write, state.job .. "/cancel", "cancel\n")
    state.cancelling = true
    state.phase, state.message = "cancelling", "Waiting for the renderer to exit."
  end
end

local function close(state)
  if state.closed then
    return
  end
  cancel(state)
  state.closed = true
  blocks[state.pane] = nil
  if state.timer then
    state.timer:cancel()
    state.timer = nil
  end
  if state.awaiting_documents then
    pcall(tern.fs.remove, state.job)
    state.job, state.awaiting_documents = nil, nil
  end
end

tern.on("pane_exited", function(event)
  local state = blocks[event.pane]
  if state then
    close(state)
  end
end)

local function status(job)
  local ok, value = pcall(function()
    return tern.json.decode(tern.fs.read(job .. "/status.json", 8192))
  end)
  return ok and type(value) == "table" and value or nil
end

local function gallery(state, cx, job)
  local ok, result = pcall(function()
    return tern.json.decode(tern.fs.read(job .. "/gallery.json", 1024 * 1024))
  end)
  if
    not ok
    or type(result) ~= "table"
    or type(result.revision) ~= "number"
    or result.revision ~= math.floor(result.revision)
    or result.revision <= (state.revision or 0)
    or result.revision == math.huge
    or (result.phase ~= "ready" and result.phase ~= "error")
  then
    return
  end
  if result.phase == "ready" and type(result.images) ~= "table" then
    return
  end
  state.phase, state.message = result.phase, text(result.message)
  if result.phase == "ready" then
    local loaded, cards = pcall(images, state, cx, result, job)
    if not loaded then
      state.phase, state.message = "error", text(tostring(cards))
      return
    end
    state.images = cards
  end
  state.revision = result.revision
  pcall(tern.fs.write, job .. "/gallery-ack", tostring(result.revision))
end

local function finish_job(state, cx, job)
  pcall(tern.fs.remove, job)
  if state.timer then
    state.timer:cancel()
    state.timer = nil
  end
  hide_live(state, cx)
  state.job, state.cancelling, state.restoring, state.url = nil, nil, nil, nil
  state.awaiting_documents = nil
  if alive(state) then
    cx:save()
    cx:render()
  end
end

local function watch(state, cx)
  state.timer = tern.timer(1000, function()
    state.timer = nil
    if not alive(state) then
      hide_live(state, cx)
      close(state)
      return
    end
    local job = state.job
    if not job then
      return
    end
    if state.restoring then
      -- Reload cancels the previous session: close its page so this pane shows again.
      hide_live(state, cx)
    end
    if not state.cancelling then
      local ok = pcall(tern.fs.write, job .. "/lease", "alive\n")
      if not ok then
        cancel(state)
        state.message = "Could not renew the preview lease; cancelling."
      end
    end
    if not state.cancelling then
      pcall(function()
        cx:open("elide://compose-documents/" .. string.match(job, "([^/]+)$"))
      end)
    end
    local progress = status(job)
    local root = progress and links.absolute(progress.root)
    if not state.cancelling and root and root ~= state.root and links.within(state.path, root) then
      local registered =
        pcall(tern.fs.write, job .. "/registration.json", tern.json.encode({ pane = state.pane, root = root }))
      if registered then
        state.root, state.documents_revision = root, nil
        pcall(publish_documents, state, job)
        pcall(function()
          cx:open("elide://compose-documents/" .. string.match(job, "([^/]+)$"))
        end)
      end
    end
    if not state.cancelling and not documents_timer and state.documents_revision ~= documents_revision then
      pcall(publish_documents, state, job)
    end
    if state.restoring and tern.fs.exists(job .. "/done") then
      state.phase, state.message = "idle", "Previous renderer stopped."
      finish_job(state, cx, job)
      return
    end
    if state.restoring and tern.now() - state.restored_at >= 20 then
      -- A killed helper cannot publish done. Its expired lease and PID-checked workspace
      -- lock make another explicit attempt safe; do not remove a possibly live job here.
      state.job, state.cancelling, state.restoring = nil, nil, nil
      state.phase, state.message = "idle", "The previous renderer did not report its exit."
      cx:save()
      cx:render()
      return
    end
    if progress and not state.cancelling then
      advance(state, text(progress.phase, 64), text(progress.message))
      if state.mode == "live" and live_route(progress.url) then
        state.url = progress.url
        if not state.opened then
          state.opened = true
          show_live(state, cx)
        end
      end
      -- Toolbar buttons of the live page, each carried out once.
      local asked = progress.request
      if
        state.mode == "live"
        and type(asked) == "table"
        and type(asked.id) == "number"
        and asked.id > (state.asked or 0)
      then
        state.asked = asked.id
        if asked.action == "snapshot" then
          request(state, cx, "snapshot")
        elseif asked.action == "source" then
          cx:open(source.file_url(state.path))
        elseif asked.action == "close" then
          hide_live(state, cx)
          close(state)
          cx:exit(0)
          return
        end
      end
    end
    if state.mode == "snapshot" and not state.cancelling then
      gallery(state, cx, job)
    end
    cx:render()
    watch(state, cx)
  end)
end

local function configured_path(value)
  return string.sub(value, 1, 1) == "/" and value or tern.plugin.dir .. "/" .. value
end

images = function(state, cx, result, job)
  local cards, total = {}, 0
  for index, image in ipairs(type(result.images) == "table" and result.images or {}) do
    if index > MAX_IMAGES then
      state.message ..= " Gallery limited to " .. MAX_IMAGES .. " cards."
      break
    end
    if type(image) == "table" then
      local card = {
        name = text(image.name, 256),
        detail = text(image.detail),
        error = text(image.error),
      }
      if card.name == "" then
        card.name = "Preview " .. index
      end
      local file = image.file
      if card.error == "" and type(file) == "string" then
        local ok, problem = pcall(function()
          if not string.match(file, "^[%w_.%-]+%.png$") or string.find(file, "..", 1, true) then
            error("Invalid preview image filename.")
          end
          local bytes = tern.fs.read(job .. "/" .. file, MAX_PNG)
          if string.sub(bytes, 1, 8) ~= "\137PNG\r\n\26\n" then
            error("Preview is not a PNG image.")
          end
          total += #bytes
          if total > MAX_GALLERY then
            error("Preview gallery exceeds 64 MiB.")
          end
          card.blob = cx:blob(bytes, "image/png")
          card.width = type(image.width) == "number" and math.clamp(image.width, 1, 4096) or nil
          card.height = type(image.height) == "number" and math.clamp(image.height, 1, 4096) or nil
        end)
        if not ok then
          card.error = text(tostring(problem))
        end
      elseif card.error == "" then
        card.error = "The renderer returned no image for this preview."
      end
      table.insert(cards, card)
    end
  end
  return cards
end

local function start(state, cx, mode)
  if state.job or state.invalid or not alive(state) then
    return
  end
  state.log, state.url, state.opened, state.revision, state.details = "", nil, nil, nil, false
  state.asked = nil
  state.mode = mode or "snapshot"
  state.step = nil
  advance(state, "starting", "")
  local id = source.uuid(math.random)
  local job = tern.plugin.data .. "/compose-jobs/" .. id
  local ok, problem = pcall(function()
    local config = tern.json.decode(tern.fs.read(tern.plugin.dir .. "/config.json", 65536))
    local runtime = config.runtime or "elide"
    if string.find(runtime, "/") and string.sub(runtime, 1, 1) ~= "/" then
      runtime = configured_path(runtime)
    end
    local argv = {
      configured_path(config.compose or "../dist/elide-tern-compose"),
      "--runtime",
      runtime,
      "--root",
      state.root,
      "--file",
      state.path,
      "--job",
      job,
      "--cache",
      configured_path(config.compose_cache or (tern.plugin.data .. "/compose-cache")),
      "--lease",
      job .. "/lease",
      "--mode",
      state.mode,
    }
    if type(config.compose_java) == "string" and config.compose_java ~= "" then
      local java = config.compose_java
      if string.find(java, "/") and string.sub(java, 1, 1) ~= "/" then
        java = configured_path(java)
      end
      table.insert(argv, "--java")
      table.insert(argv, java)
    end
    if type(config.compose_komodo) == "string" and config.compose_komodo ~= "" then
      table.insert(argv, "--komodo")
      table.insert(argv, configured_path(config.compose_komodo))
    end
    tern.fs.mkdir(job)
    tern.fs.write(job .. "/lease", "alive\n")
    publish_documents(state, job)
    tern.fs.write(job .. "/registration.json", tern.json.encode({ pane = state.pane, root = state.root }))
    state.job = job
    cx:save()
    local function complete()
      local pending = state.pending_mode
      state.pending_mode = nil
      finish_job(state, cx, job)
      if pending then
        start(state, cx, pending)
      end
    end
    local function launch()
      state.awaiting_documents = nil
      tern.fs.write(job .. "/lease", "alive\n")
      publish_documents(state, job)
      tern.process.run(argv, { cwd = state.root }, function(result)
        if not alive(state) then
          close(state)
          pcall(tern.fs.remove, job)
          return
        end
        state.log = string.sub(result.stderr or "", -8192)
        local decoded, response = pcall(tern.json.decode, result.stdout or "")
        if state.cancelling then
          state.phase, state.message = "cancelled", "Preview cancelled."
        elseif decoded and type(response) == "table" and TERMINAL[response.phase] then
          state.phase, state.message = response.phase, text(response.message)
          if response.phase == "ready" and result.status == 0 then
            if state.mode == "snapshot" then
              gallery(state, cx, job)
            end
          elseif response.phase == "ready" then
            state.phase, state.message = "error", "Preview helper exited unsuccessfully."
          end
        else
          state.phase, state.message = "error", "Preview helper failed (exit " .. tostring(result.status) .. ")."
        end
        complete()
      end)
      watch(state, cx)
    end
    local started, requested = tern.now(), nil
    state.awaiting_documents = true
    local function await_documents()
      state.timer = nil
      if not alive(state) then
        close(state)
        return
      end
      if state.job ~= job then
        return
      end
      if state.cancelling then
        state.phase, state.message = "cancelled", "Preview cancelled."
        complete()
        return
      end
      if tern.fs.exists(job .. "/native-documents.json") then
        local launched, launch_error = pcall(launch)
        if not launched then
          state.phase, state.message = "error", text(tostring(launch_error))
          complete()
        end
        return
      end
      local now = tern.now()
      if now - started >= 20 then
        state.phase, state.message = "error", "Could not capture native editor drafts. Refresh to try again."
        complete()
        return
      end
      if not requested or now - requested >= 2 then
        requested = now
        pcall(function()
          cx:open("elide://compose-documents/" .. id)
        end)
      end
      state.timer = tern.timer(100, await_documents)
    end
    await_documents()
  end)
  if not ok then
    state.phase, state.message = "error", text(tostring(problem))
    finish_job(state, cx, job)
  end
  cx:render()
end

request = function(state, cx, mode)
  if state.invalid or state.cancelling or not alive(state) then
    return
  end
  if not state.job then
    start(state, cx, mode)
  elseif state.mode ~= mode then
    hide_live(state, cx)
    cancel(state)
    state.pending_mode = mode
    state.message = "Switching preview mode…"
    cx:render()
  elseif mode == "snapshot" then
    local ok, problem = pcall(tern.fs.write, state.job .. "/refresh", source.uuid(math.random))
    if ok then
      advance(state, "refreshing", "")
    else
      state.phase, state.message = "error", text(tostring(problem))
    end
    cx:render()
  else
    -- The live page was closed while its session runs: show it again.
    show_live(state, cx)
  end
end

-- View ------------------------------------------------------------------------------------------

-- A quiet icon-only button, as in the device manager; `title` is its tooltip and accessible name.
local function button(icon, title, action, props)
  local spec = {
    key = action,
    icon = icon,
    title = title,
    aria = title,
    variant = "quiet",
    role = "compose-" .. action,
    actions = { click = action },
  }
  for name, value in props or {} do
    spec[name] = value
  end
  return ui.button("", spec)
end

local function icon(name, role)
  return ui.node("icon", { name = name, role = role })
end

local function separator()
  return ui.el("span", { role = "compose-separator", attrs = { ["aria-hidden"] = "true" } })
end

-- The file, then the mode toggles, the renderer's controls and the pane's.
local function toolbar(state)
  local mode = state.mode or "snapshot"
  local blocked = state.invalid or state.cancelling
  local relative = state.path
  if state.root ~= "" and string.sub(state.path, 1, #state.root + 1) == state.root .. "/" then
    relative = string.sub(state.path, #state.root + 2)
  end
  local refresh = blocked or (state.job and mode == "live" and "Refresh from the live preview") or nil
  return ui.node("row", { key = "toolbar", role = "compose-toolbar", gap = "md" }, {
    icon("mi-kotlin", "compose-file-icon"),
    ui.node("col", { role = "compose-file", grow = 1 }, {
      ui.el("strong", { role = "compose-file-name", text = state.name, title = state.path }),
      ui.el("div", { role = "compose-path", text = relative, title = state.path }),
    }),
    ui.node("buttons", { variant = "toolbar", label = "Preview mode", role = "compose-modes" }, {
      button("image", "Snapshot previews", "snapshot", { on = mode == "snapshot", disabled = blocked }),
      button("hand", "Interactive live preview", "live", { on = mode == "live", disabled = blocked }),
    }),
    separator(),
    ui.node("buttons", { variant = "toolbar", label = "Renderer", role = "compose-renderer" }, {
      button("refresh", state.job and "Refresh previews" or "Start previews", "refresh", { disabled = refresh }),
      button("stop", "Stop renderer", "cancel", { disabled = state.job == nil or state.cancelling }),
    }),
    separator(),
    ui.node("buttons", { variant = "toolbar", label = "Pane", role = "compose-pane" }, {
      button("file-code", "Open source", "source", { disabled = state.invalid }),
      button("x", "Close preview", "close"),
    }),
  })
end

-- The busy phase's bar, the steps it went through and the renderer's latest line.
local function progress_view(state, progress)
  local children = { ui.progress(nil, progress.label) }
  if progress.step then
    local current = state.step or progress.step
    local steps = {}
    for index, label in STEPS do
      local role = if index < current
        then "compose-step-done"
        elseif index == current then "compose-step-active"
        else "compose-step"
      table.insert(
        steps,
        ui.node("row", { role = role, gap = "xs" }, {
          if index < current then icon("check", "compose-step-icon") else ui.el("span", { role = "compose-step-dot" }),
          ui.el("span", { text = label }),
        })
      )
    end
    table.insert(children, ui.node("row", { role = "compose-steps", gap = "lg" }, steps))
  end
  local latest = string.match(state.message, "([^\n]*)\n*$") or ""
  if latest ~= "" then
    table.insert(children, ui.el("div", { role = "compose-activity", text = latest, title = state.message }))
  end
  return ui.node("col", { key = "status", role = "compose-progress", gap = "sm" }, children)
end

-- A failure: its first line, the rest (compiler output) in a terminal well, and the helper's
-- output, once it exited, behind a toggle.
local function problem_view(state)
  local headline, rest = string.match(state.message, "^([^\n]*)\n+(.-)%s*$")
  local body = {
    ui.node("row", { role = "compose-problem-head", gap = "sm" }, {
      icon("warn", "compose-problem-icon"),
      ui.node("col", { grow = 1 }, {
        ui.el("strong", { text = if state.invalid then "Cannot preview this file" else "Preview failed" }),
        ui.el("div", { role = "compose-problem-message", text = headline or state.message }),
      }),
    }),
  }
  if rest and rest ~= "" then
    table.insert(body, ui.node("col", { role = "compose-output" }, { ui.ansi(rest) }))
  end
  if state.log ~= "" then
    table.insert(
      body,
      ui.button(if state.details then "Hide output" else "Show output", {
        key = "output",
        icon = "terminal",
        size = "sm",
        variant = "quiet",
        role = "compose-output-toggle",
        on = state.details,
        actions = { click = "output" },
      })
    )
    if state.details then
      table.insert(body, ui.node("col", { key = "log", role = "compose-output" }, { ui.ansi(state.log) }))
    end
  end
  return ui.node("col", { key = "status", role = "compose-problem", gap = "sm" }, body)
end

-- A running session whose page is not over this pane: before it opens, or after it closed.
local function live_view(state)
  return ui.node("row", { key = "status", role = "compose-notice", gap = "sm" }, {
    icon("hand", "compose-notice-icon"),
    ui.node("col", { grow = 1 }, {
      ui.el("strong", { text = "Live preview running" }),
      ui.el("div", { role = "compose-hint", text = state.message }),
    }),
    ui.button("Show live preview", {
      key = "show",
      icon = "hand",
      size = "sm",
      role = "compose-show-live",
      actions = { click = "live" },
    }),
  })
end

-- No renderer: a stopped or new session. Without cards it fills the pane.
local function notice_view(state, empty)
  return ui.node(if empty then "col" else "row", {
    key = "status",
    role = if empty then "compose-empty" else "compose-notice",
    gap = "sm",
  }, {
    icon(if empty then "eye" else "info", "compose-notice-icon"),
    ui.el("div", { role = "compose-notice-text", text = state.message }),
    ui.button("Start previews", {
      key = "start",
      icon = "play",
      variant = if empty then "primary" else "default",
      size = if empty then nil else "sm",
      role = "compose-start",
      actions = { click = "refresh" },
    }),
  })
end

-- The snapshot's cards; dimmed (`stale`) while a newer one renders.
local function gallery_view(state, stale)
  local cards = {}
  for index, card in ipairs(state.images) do
    local failed = card.error ~= ""
    local head = { ui.el("strong", { text = card.name, role = "compose-card-name" }) }
    if card.detail ~= "" then
      table.insert(head, ui.el("div", { text = card.detail, role = "compose-card-detail" }))
    end
    local children = {
      ui.node("row", { role = "compose-card-head", gap = "sm" }, {
        icon(if failed then "x-circle" else "image", "compose-card-icon"),
        ui.node("col", { grow = 1 }, head),
      }),
    }
    if card.blob then
      table.insert(
        children,
        ui.node("image", {
          key = "image",
          role = "compose-image",
          blob = card.blob,
          alt = card.name,
          w = card.width,
          h = card.height,
          max = { h = "30lines" },
        })
      )
    end
    if failed then
      table.insert(children, ui.el("div", { text = card.error, role = "compose-card-error" }))
    end
    table.insert(
      cards,
      ui.node("col", {
        key = "card-" .. index,
        role = if failed then "compose-card-failed" else "compose-card",
        gap = "sm",
      }, children)
    )
  end
  return ui.node("row", {
    key = "gallery",
    role = if stale then "compose-gallery-stale" else "compose-gallery",
    gap = "md",
  }, cards)
end

tern.block.define("compose", {
  font = "sans",
  init = function(cx, args, saved)
    local path, root = links.absolute(args[1]), links.absolute(args[2])
    local state = {
      pane = cx.pane,
      path = path or "",
      root = root or "",
      name = path and string.match(path, "([^/]+)$") or "Compose",
      phase = "idle",
      message = "Previews run this project's code with your permissions.",
      images = {},
      log = "",
    }
    blocks[cx.pane] = state
    if not path or not root or not links.within(path, root) or source.extension(path) ~= "kt" then
      state.invalid = true
      state.phase, state.message = "error", "Open a saved Kotlin (.kt) file inside a local project."
    elseif type(saved) == "table" and type(saved.job) == "string" then
      -- A reload must neither execute code nor race the previous helper's build outputs.
      local prefix = tern.plugin.data .. "/compose-jobs/"
      if
        string.sub(saved.job, 1, #prefix) == prefix and string.match(string.sub(saved.job, #prefix + 1), "^[%x%-]+$")
      then
        state.job, state.restoring, state.restored_at = saved.job, true, tern.now()
        if type(saved.browser) == "string" then
          state.browser = live_route("http://127.0.0.1:" .. saved.browser .. "/")
        end
        cancel(state)
        state.message = "Stopping previous renderer…"
        watch(state, cx)
      end
    elseif saved == nil then
      state.timer = tern.timer(0, function()
        state.timer = nil
        start(state, cx)
      end)
    end
    return state
  end,
  title = function(state)
    return "Compose · " .. state.name
  end,
  view = function(state)
    local children = { toolbar(state) }
    local progress = PROGRESS[state.phase]
    local live = state.mode == "live" and state.job ~= nil
    if progress then
      table.insert(children, progress_view(state, progress))
    elseif state.phase == "error" then
      table.insert(children, problem_view(state))
    elseif live then
      table.insert(children, live_view(state))
    elseif state.job == nil then
      table.insert(children, notice_view(state, #state.images == 0))
    elseif state.message ~= "" then
      table.insert(
        children,
        ui.node("row", { key = "status", role = "compose-ready", gap = "sm" }, {
          icon("check", "compose-ready-icon"),
          ui.el("span", { text = state.message }),
        })
      )
    end
    -- A live session draws its cards in its page; the native gallery is the snapshot's.
    if not live and #state.images > 0 then
      table.insert(children, gallery_view(state, progress ~= nil))
    end
    return { main = ui.node("col", { role = "compose-preview", gap = "md", grow = 1 }, children) }
  end,
  event = function(state, event, cx)
    if event.ev ~= "action" then
      return
    end
    if event.act == "snapshot" then
      -- The pressed mode toggle does nothing; Refresh renders the snapshot again.
      if not (state.job and state.mode == "snapshot") then
        request(state, cx, "snapshot")
      end
    elseif event.act == "live" then
      request(state, cx, "live")
    elseif event.act == "refresh" then
      request(state, cx, state.mode or "snapshot")
    elseif event.act == "cancel" then
      hide_live(state, cx)
      cancel(state)
      cx:render()
    elseif event.act == "output" then
      state.details = not state.details
      cx:render()
    elseif event.act == "source" and not state.invalid then
      cx:open(source.file_url(state.path))
    elseif event.act == "close" then
      hide_live(state, cx)
      close(state)
      cx:exit(0)
    end
  end,
  save = function(state)
    return { job = state.job, browser = state.browser }
  end,
})

return { document = document }
