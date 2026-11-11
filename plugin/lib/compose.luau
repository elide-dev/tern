-- A Compose preview pane owns one session of its workspace's preview service
-- (`elide-tern-compose open`, which starts `serve` when none runs). The session's loopback page
-- draws the previews and takes their input: native image nodes expose zoom, not pointer
-- coordinates. That page opens over this pane while the session runs (window.luau's
-- compose-live route) and closes with it. The pane long-polls the session for the page's
-- requests and posts the dirty Elide editors of the workspace to it.
local ui = tern.ui
local source = require("./source")
local links = require("./links")
local loopback = require("./loopback")
local blocks = {}
local documents = {}
local documents_revision = 0

-- Job directories of the snapshot helper this service replaced.
pcall(tern.fs.remove, tern.plugin.data .. "/compose-jobs")

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

-- The newest dirty text of `file` across Elide editors, nil when none is dirty.
local function latest_text(file)
  local newest
  for _, draft in documents do
    if draft.file == file and (not newest or newest.revision < draft.revision) then
      newest = draft
    end
  end
  return newest and newest.text
end

-- Posts the queued editor texts (`false`: the editor no longer differs from the file), one
-- request at a time; texts queued meanwhile go out when it returns.
local function post_documents(state)
  if state.posting or not state.url or next(state.queued) == nil then
    return
  end
  local entries = {}
  for file, content in state.queued do
    table.insert(
      entries,
      '{"file":'
        .. tern.json.encode(file)
        .. ',"text":'
        .. (if content then tern.json.encode(content) else "null")
        .. "}"
    )
  end
  state.queued = {}
  state.posting = true
  local url = state.url
  loopback.request(
    url .. "documents",
    '{"origin":"host","replace":false,"documents":[' .. table.concat(entries, ",") .. "]}",
    10000,
    function()
      state.posting = false
      if state.url == url then
        post_documents(state)
      end
    end
  )
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
  local changed = {}
  if previous then
    changed[previous.file] = true
  end
  if documents[pane] then
    changed[file] = true
  end
  for _, state in blocks do
    if (state.url or state.starting) and not state.closed then
      for changed_file in changed do
        if links.within(changed_file, state.root) then
          state.queued[changed_file] = latest_text(changed_file) or false
        end
      end
      post_documents(state)
    end
  end
end

-- The `port/token` route of a session's loopback page, nil for any other URL.
local function live_route(url)
  local port, token = string.match(url or "", "^http://127%.0%.0%.1:(%d+)/(%x+)/$")
  if port and #token == 64 and tonumber(port) >= 1 and tonumber(port) <= 65535 then
    return port .. "/" .. token
  end
  return nil
end

-- Shows the session's page over this pane.
local function show_live(state, cx)
  local route = live_route(state.url)
  if route then
    state.browser = route
    cx:open("elide://compose-live/" .. state.pane .. "/" .. route)
  end
end

-- Closes the page shown over this pane, bringing the pane back.
local function hide_live(state, cx)
  local route = state.browser
  state.browser = nil
  if route then
    pcall(function()
      cx:open("elide://compose-live/" .. state.pane .. "/" .. route .. "/close")
    end)
  end
end

-- Ends this pane's session; the service stays warm for the next preview.
local function close(state)
  if state.closed then
    return
  end
  state.closed = true
  blocks[state.pane] = nil
  if state.url then
    loopback.request(state.url .. "close", "", 5000, function() end)
    state.url = nil
  end
end

tern.on("pane_exited", function(event)
  local state = blocks[event.pane]
  if state then
    close(state)
  end
end)

-- The service is gone (Stop renderer, keep-alive expiry, a crash): the pane offers a restart.
local function stopped(state, cx)
  hide_live(state, cx)
  state.url, state.posting, state.queued = nil, false, {}
  state.phase, state.message = "idle", "Preview stopped."
  cx:save()
  cx:render()
end

-- Carries out the page's requests, each once, until the session ends.
local function poll(state, cx)
  local url = state.url
  if not url or state.closed then
    return
  end
  loopback.request(url .. "pane?after=" .. tostring(state.asked), nil, 30000, function(status, body, _, timed_out)
    if state.url ~= url or state.closed then
      return
    end
    if not alive(state) then
      hide_live(state, cx)
      close(state)
      return
    end
    local ok, value = pcall(tern.json.decode, body)
    value = ok and type(value) == "table" and value or {}
    if status == 200 then
      if type(value.id) == "number" and value.id > state.asked then
        state.asked = value.id
        if value.action == "source" then
          cx:open(source.file_url(state.path))
        elseif value.action == "close" then
          hide_live(state, cx)
          close(state)
          cx:exit(0)
          return
        elseif value.action == "retarget" then
          local file = links.absolute(value.file)
          if file and links.within(file, state.root) and source.extension(file) == "kt" then
            state.path, state.name = file, string.match(file, "([^/]+)$")
            cx:save()
            cx:render()
          end
        end
      end
      poll(state, cx)
    elseif status == 410 and (value.ended == "retargeted" or value.ended == "page-closed") then
      -- Another preview of the workspace took the service, or the page was closed.
      hide_live(state, cx)
      close(state)
      cx:exit(0)
    elseif status == 0 and timed_out then
      poll(state, cx)
    else
      stopped(state, cx)
    end
  end)
end

local function configured_path(value)
  return string.sub(value, 1, 1) == "/" and value or tern.plugin.dir .. "/" .. value
end

local function start(state, cx)
  if state.url or state.starting or state.invalid or not alive(state) then
    return
  end
  local ok, problem = pcall(function()
    local config = tern.json.decode(tern.fs.read(tern.plugin.dir .. "/config.json", 65536))
    local runtime = config.runtime or "elide"
    if string.find(runtime, "/") and string.sub(runtime, 1, 1) ~= "/" then
      runtime = configured_path(runtime)
    end
    local keep_alive = if type(config.compose_keep_alive_minutes) == "number"
      then config.compose_keep_alive_minutes
      else 10
    local argv = {
      configured_path(config.compose or "../dist/elide-tern-compose"),
      "open",
      "--runtime",
      runtime,
      "--root",
      state.root,
      "--file",
      state.path,
      "--cache",
      configured_path(config.compose_cache or (tern.plugin.data .. "/compose-cache")),
      "--keep-alive",
      tostring(keep_alive),
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
    -- Dirty Elide editors of the project; ones that change before the session answers are queued.
    local entries, seen = {}, {}
    for _, draft in documents do
      if not seen[draft.file] and links.within(draft.file, state.root) then
        seen[draft.file] = true
        table.insert(entries, tern.json.encode({ file = draft.file, text = latest_text(draft.file) }))
      end
    end
    state.starting, state.queued = true, {}
    state.phase, state.message = "starting", ""
    tern.process.run(
      argv,
      { cwd = state.root, stdin = '{"documents":[' .. table.concat(entries, ",") .. "]}", timeout_ms = 30000 },
      function(result)
        state.starting = nil
        local decoded, response = pcall(tern.json.decode, result.stdout or "")
        response = decoded and type(response) == "table" and response or {}
        local root = links.absolute(response.root)
        if live_route(response.url) and root and links.within(state.path, root) then
          if not alive(state) then
            loopback.request(response.url .. "close", "", 5000, function() end)
            return
          end
          state.url, state.root, state.phase, state.message, state.asked = response.url, root, "live", "", 0
          cx:save()
          show_live(state, cx)
          poll(state, cx)
          post_documents(state)
        elseif not alive(state) then
          return
        else
          state.phase = "error"
          state.message = if text(response.error) ~= ""
            then text(response.error, 8192)
            else "Preview helper failed (exit " .. tostring(result.status) .. ")."
        end
        cx:render()
      end
    )
  end)
  if not ok then
    state.starting = nil
    state.phase, state.message = "error", text(tostring(problem))
  end
  cx:render()
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

-- The file, then the renderer's control and the pane's.
local function toolbar(state)
  local relative = state.path
  if state.root ~= "" and string.sub(state.path, 1, #state.root + 1) == state.root .. "/" then
    relative = string.sub(state.path, #state.root + 2)
  end
  return ui.node("row", { key = "toolbar", role = "compose-toolbar", gap = "md" }, {
    icon("mi-kotlin", "compose-file-icon"),
    ui.node("col", { role = "compose-file", grow = 1 }, {
      ui.el("strong", { role = "compose-file-name", text = state.name, title = state.path }),
      ui.el("div", { role = "compose-path", text = relative, title = state.path }),
    }),
    ui.node("buttons", { variant = "toolbar", label = "Renderer", role = "compose-renderer" }, {
      button("play", "Start previews", "refresh", {
        disabled = state.invalid or state.starting or state.url ~= nil,
      }),
    }),
    separator(),
    ui.node("buttons", { variant = "toolbar", label = "Pane", role = "compose-pane" }, {
      button("file-code", "Open source", "source", { disabled = state.invalid }),
      button("x", "Close preview", "close"),
    }),
  })
end

-- A failure: its first line, the rest (compiler or helper output) in a terminal well.
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
  return ui.node("col", { key = "status", role = "compose-problem", gap = "sm" }, body)
end

-- A running session whose page is not over this pane: before it opens.
local function live_view()
  return ui.node("row", { key = "status", role = "compose-notice", gap = "sm" }, {
    icon("hand", "compose-notice-icon"),
    ui.node("col", { grow = 1 }, {
      ui.el("strong", { text = "Live preview running" }),
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

-- No session: a stopped or new preview.
local function notice_view(state)
  return ui.node("col", { key = "status", role = "compose-empty", gap = "sm" }, {
    icon("eye", "compose-notice-icon"),
    ui.el("div", { role = "compose-notice-text", text = state.message }),
    ui.button("Start previews", {
      key = "start",
      icon = "play",
      variant = "primary",
      role = "compose-start",
      actions = { click = "refresh" },
    }),
  })
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
      queued = {},
      asked = 0,
    }
    blocks[cx.pane] = state
    if not path or not root or not links.within(path, root) or source.extension(path) ~= "kt" then
      state.invalid = true
      state.phase, state.message = "error", "Open a saved Kotlin (.kt) file inside a local project."
    elseif type(saved) == "table" and live_route(saved.url) then
      -- A reload never runs project code by itself: it ends the previous session and closes its page.
      local url = saved.url
      state.browser = live_route(url)
      state.message = "Preview stopped by plugin reload."
      tern.timer(0, function()
        hide_live(state, cx)
        loopback.request(url .. "close", "", 5000, function() end)
      end)
    elseif saved == nil then
      tern.timer(0, function()
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
    if state.phase == "starting" then
      table.insert(
        children,
        ui.node("col", { key = "status", role = "compose-progress", gap = "sm" }, {
          ui.progress(nil, "Starting previews…"),
        })
      )
    elseif state.phase == "error" then
      table.insert(children, problem_view(state))
    elseif state.phase == "live" then
      table.insert(children, live_view())
    else
      table.insert(children, notice_view(state))
    end
    return { main = ui.node("col", { role = "compose-preview", gap = "md", grow = 1 }, children) }
  end,
  event = function(state, event, cx)
    if event.ev ~= "action" then
      return
    end
    if event.act == "refresh" then
      start(state, cx)
    elseif event.act == "live" then
      show_live(state, cx)
    elseif event.act == "source" and not state.invalid then
      cx:open(source.file_url(state.path))
    elseif event.act == "close" then
      hide_live(state, cx)
      close(state)
      cx:exit(0)
    end
  end,
  save = function(state)
    return { url = state.url }
  end,
})

return { document = document }
