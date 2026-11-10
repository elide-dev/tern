-- Saved snapshots and live sessions share a helper lease. Live input belongs to a
-- browser pane: native image nodes expose zoom, not pointer coordinates.
local ui = tern.ui
local source = require("./source")
local links = require("./links")
local blocks = {}
local MAX_IMAGES = 32
local MAX_PNG = 8 * 1024 * 1024
local MAX_GALLERY = 64 * 1024 * 1024
local TERMINAL = { ready = true, error = true, cancelled = true }

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

local function cancel(state)
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

local function finish_job(state, cx, job)
  pcall(tern.fs.remove, job)
  if state.timer then
    state.timer:cancel()
    state.timer = nil
  end
  state.job, state.cancelling, state.restoring, state.url = nil, nil, nil, nil
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
    local progress = status(job)
    if state.restoring and tern.fs.exists(job .. "/done") then
      state.phase, state.message = "idle", "Previous renderer stopped. Rebuild to preview the saved file."
      finish_job(state, cx, job)
      return
    end
    if state.restoring and tern.now() - state.restored_at >= 20 then
      -- A killed helper cannot publish done. Its expired lease and PID-checked workspace
      -- lock make another explicit attempt safe; do not remove a possibly live job here.
      state.job, state.cancelling, state.restoring = nil, nil, nil
      state.phase, state.message =
        "idle", "Previous helper did not report exit. Rebuild checks that its workspace lock is released."
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
    cx:render()
    watch(state, cx)
  end)
end

local function configured_path(value)
  return string.sub(value, 1, 1) == "/" and value or tern.plugin.dir .. "/" .. value
end

local function images(state, cx, result, job)
  local total = 0
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
      table.insert(state.images, card)
    end
  end
end

local function start(state, cx, mode)
  if state.job or state.invalid or not alive(state) then
    return
  end
  state.images, state.log, state.url, state.opened = {}, "", nil, nil
  state.mode = mode or "snapshot"
  state.phase, state.message = "starting", state.mode == "live" and "Building live previews…" or "Building saved-file snapshots…"
  local job = tern.plugin.data .. "/compose-jobs/" .. source.uuid(math.random)
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
    if state.mode == "live" and type(config.compose_komodo) == "string" and config.compose_komodo ~= "" then
      table.insert(argv, "--komodo")
      table.insert(argv, configured_path(config.compose_komodo))
    end
    tern.fs.mkdir(job)
    tern.fs.write(job .. "/lease", "alive\n")
    state.job = job
    cx:save()
    tern.process.run(argv, { cwd = state.root }, function(result)
      if not alive(state) then
        close(state)
        pcall(tern.fs.remove, job)
        return
      end
      state.images = {}
      state.log = string.sub(result.stderr or "", -8192)
      local decoded, response = pcall(tern.json.decode, result.stdout or "")
      if state.cancelling then
        state.phase, state.message = "cancelled", "Preview cancelled. Rebuild to try again."
      elseif decoded and type(response) == "table" and TERMINAL[response.phase] then
        state.phase, state.message = response.phase, text(response.message)
        if response.phase == "ready" and result.status == 0 then
          local loaded, load_error = pcall(images, state, cx, response, job)
          if not loaded then
            state.images = {}
            state.phase, state.message = "error", text(tostring(load_error))
          end
        elseif response.phase == "ready" then
          state.phase, state.message = "error", "Preview helper exited unsuccessfully."
        end
      else
        state.phase, state.message = "error", "Preview helper failed (exit " .. tostring(result.status) .. ")."
      end
      finish_job(state, cx, job)
    end)
    watch(state, cx)
  end)
  if not ok then
    state.phase, state.message = "error", text(tostring(problem))
    finish_job(state, cx, job)
  end
  cx:render()
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
      message = "Saved-file snapshots. Rebuild compiles and executes this project's preview code from disk.",
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
        state.message = "Restored without rebuilding; waiting for the previous renderer to stop…"
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
        ui.button(
          "Rebuild",
          {
            key = "rebuild",
            role = "compose-rebuild",
            disabled = state.job ~= nil or state.invalid,
            actions = { click = "rebuild" },
          }
        ),
        ui.button("Live preview", {
          key = "live",
          role = "compose-live",
          disabled = state.job ~= nil or state.invalid,
          actions = { click = "live" },
        }),
        ui.button(
          "Cancel",
          {
            key = "cancel",
            role = "compose-cancel",
            disabled = state.job == nil or state.cancelling,
            actions = { click = "cancel" },
          }
        ),
        ui.button(
          "Open source",
          { key = "source", role = "compose-source", disabled = state.invalid, actions = { click = "source" } }
        ),
        ui.button("Close", { key = "close", role = "compose-close", actions = { click = "close" } }),
      }),
      ui.el(
        "div",
        {
          key = "snapshot",
          role = "compose-snapshot",
          text = state.mode == "live"
            and "Live input runs in a browser pane. Saved source refreshes automatically; cancel before rebuilding resources."
            or "Saved-file snapshots · Live preview runs interactive compositions in a browser pane.",
        }
      ),
      ui.el("div", { key = "path", role = "compose-path", text = state.path }),
      ui.el("div", { key = "status", role = "compose-status", text = state.phase .. ": " .. state.message }),
      ui.node("col", { key = "gallery", role = "compose-gallery", gap = "md" }, cards),
    }
    if state.log ~= "" then
      table.insert(children, ui.el("pre", { key = "log", role = "compose-log", text = state.log }))
    end
    return { main = ui.node("col", { role = "compose-preview", gap = "md", grow = 1 }, children) }
  end,
  event = function(state, event, cx)
    if event.ev ~= "action" then
      return
    end
    if event.act == "rebuild" then
      start(state, cx)
    elseif event.act == "live" then
      start(state, cx, "live")
    elseif event.act == "cancel" then
      cancel(state)
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

return {}
