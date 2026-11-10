-- Editor previews and live sessions share a helper lease. Live input belongs
-- to a browser pane: native image nodes expose zoom, not pointer coordinates.
local ui = tern.ui
local source = require("./source")
local links = require("./links")
local blocks = {}
local MAX_IMAGES = 32
local MAX_PNG = 8 * 1024 * 1024
local MAX_GALLERY = 64 * 1024 * 1024
local TERMINAL = { ready = true, error = true, cancelled = true }
local PROGRESS = {
  starting = "Starting previews…",
  resolving = "Loading project…",
  waiting = "Waiting for workspace build…",
  runtime = "Preparing renderer…",
  building = "Building preview inputs…",
  refreshing = "Updating previews…",
  rendering = "Rendering previews…",
  cancelling = "Stopping previews…",
}
local images
local documents = {}
local documents_revision = 0
local documents_timer

local function text(value, limit)
  return type(value) == "string" and string.sub(value, 1, limit or 2048) or ""
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

local function cancel(state)
  state.pending_mode = nil
  if state.job then
    pcall(tern.fs.write, state.job .. "/cancel", "cancel\n")
    state.cancelling = true
    state.phase, state.message = "cancelling", "Cancelling; waiting for the renderer to exit…"
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
      close(state)
      return
    end
    local job = state.job
    if not job then
      return
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
      state.phase, state.message = "idle", "Renderer stopped. Refresh to restart."
      finish_job(state, cx, job)
      return
    end
    if state.restoring and tern.now() - state.restored_at >= 20 then
      -- A killed helper cannot publish done. Its expired lease and PID-checked workspace
      -- lock make another explicit attempt safe; do not remove a possibly live job here.
      state.job, state.cancelling, state.restoring = nil, nil, nil
      state.phase, state.message = "idle", "Renderer did not report exit. Refresh to retry."
      cx:save()
      cx:render()
      return
    end
    if progress and not state.cancelling then
      state.phase = text(progress.phase, 64)
      state.message = text(progress.message)
      if state.mode == "live" and type(progress.url) == "string" then
        local port, token = string.match(progress.url, "^http://127%.0%.0%.1:(%d+)/(%x+)/$")
        if port and #token == 64 and tonumber(port) >= 1 and tonumber(port) <= 65535 then
          state.url = progress.url
          if not state.opened then
            state.opened = true
            cx:open("elide://compose-live/" .. port .. "/" .. token)
          end
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
  state.mode = mode or "snapshot"
  state.phase, state.message =
    "starting", state.mode == "live" and "Building live previews…" or "Starting editor previews…"
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

local function request(state, cx, mode)
  if state.invalid or state.cancelling or not alive(state) then
    return
  end
  if not state.job then
    start(state, cx, mode)
  elseif state.mode ~= mode then
    cancel(state)
    state.pending_mode = mode
    state.message = "Switching preview mode…"
    cx:render()
  elseif mode == "snapshot" then
    local ok, problem = pcall(tern.fs.write, state.job .. "/refresh", source.uuid(math.random))
    if ok then
      state.phase, state.message = "refreshing", "Refreshing editor sources…"
    else
      state.phase, state.message = "error", text(tostring(problem))
    end
    cx:render()
  end
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
      message = "Refresh to start previews. Preview code runs with your permissions.",
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
    local progress = PROGRESS[state.phase]
    local cards = {}
    for index, card in ipairs(state.images) do
      local children = {
        ui.el("strong", { text = card.name, role = "compose-card-name" }),
        ui.el("div", { text = card.detail, role = "compose-card-detail" }),
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
      if card.error ~= "" then
        table.insert(children, ui.el("div", { text = card.error, role = "compose-card-error" }))
      end
      table.insert(cards, ui.node("col", { key = "card-" .. index, role = "compose-card", gap = "sm" }, children))
    end
    local children = {
      ui.node("row", { key = "controls", role = "compose-controls", gap = "sm" }, {
        ui.button("Refresh", {
          key = "rebuild",
          role = "compose-rebuild",
          disabled = state.cancelling or state.invalid,
          actions = { click = "rebuild" },
        }),
        ui.button("Live preview", {
          key = "live",
          role = "compose-live",
          disabled = state.cancelling or state.invalid or (state.job ~= nil and state.mode == "live"),
          actions = { click = "live" },
        }),
        ui.button("Cancel", {
          key = "cancel",
          role = "compose-cancel",
          disabled = state.job == nil or state.cancelling,
          actions = { click = "cancel" },
        }),
        ui.button(
          "Open source",
          { key = "source", role = "compose-source", disabled = state.invalid, actions = { click = "source" } }
        ),
        ui.button("Close", { key = "close", role = "compose-close", actions = { click = "close" } }),
      }),
      ui.node("col", { key = "status", role = "compose-status", gap = "sm" }, {
        progress and ui.progress(nil, progress) or ui.el("div", {
          role = state.phase == "error" and "compose-card-error" or "compose-summary",
          text = state.message,
        }),
      }),
      ui.el("div", { key = "path", role = "compose-path", text = state.path }),
      ui.node("col", { key = "gallery", role = "compose-gallery", gap = "md" }, cards),
    }
    if (progress and state.message ~= "") or state.log ~= "" then
      table.insert(
        children,
        ui.button(state.details and "Hide details" or "Show details", {
          key = "details",
          role = "compose-details",
          actions = { click = "details" },
        })
      )
      if state.details then
        local detail = progress and state.message or ""
        if state.log ~= "" then
          detail ..= (detail ~= "" and "\n" or "") .. state.log
        end
        table.insert(children, ui.el("pre", { key = "log", role = "compose-log", text = detail }))
      end
    end
    return { main = ui.node("col", { role = "compose-preview", gap = "md", grow = 1 }, children) }
  end,
  event = function(state, event, cx)
    if event.ev ~= "action" then
      return
    end
    if event.act == "rebuild" then
      request(state, cx, "snapshot")
    elseif event.act == "live" then
      request(state, cx, "live")
    elseif event.act == "cancel" then
      cancel(state)
      cx:render()
    elseif event.act == "details" then
      state.details = not state.details
      cx:render()
    elseif event.act == "source" and not state.invalid then
      cx:open(source.file_url(state.path))
    elseif event.act == "close" then
      close(state)
      cx:exit(0)
    end
  end,
  save = function(state)
    return { job = state.job }
  end,
})

return { document = document }
