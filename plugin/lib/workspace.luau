local source = require("./source")
local opening = {}
local M = {}
local ui = tern.ui
local entries = {}

local function key(cx, pane)
  return "workspace:" .. cx:window_key() .. ":" .. tostring(pane)
end

local function editor_in(cx, workspace, tab)
  local editor = cx.session:pane(workspace.editor)
  if editor and editor.kind == "file" and editor.tab == tab and not editor.parked then
    return editor
  end
  for index = #(workspace.retained or {}), 1, -1 do
    local previous = cx.session:pane(workspace.retained[index])
    if not previous then
      table.remove(workspace.retained, index)
    elseif previous.kind == "file" and previous.tab == tab and not previous.parked then
      workspace.editor = previous.pane
      table.remove(workspace.retained, index)
      return previous
    end
  end
  return nil
end

local function button(label, action, icon)
  return ui.button("", {
    icon = icon,
    title = label,
    aria = label,
    role = "project-" .. action,
    variant = "quiet",
    actions = { click = action },
  })
end

local function separator()
  return ui.el("span", { role = "project-separator", attrs = { ["aria-hidden"] = "true" } })
end

-- The toolbar for the file the workspace editor shows (`nil` when none): Source appears
-- only for a file the source block shows; Debug names the file it would launch, else it
-- opens the debugger's target picker.
local function controls(context, file)
  local debug_title = if file and source.debuggable(file)
    then "Debug " .. (string.match(file, "([^/]+)$") or file)
    else "Open debugger"
  local tools = {
    button("Open REPL", "repl", "terminal"),
    button("Serve project files", "serve", "server"),
    button("Show project files", "files", "folder"),
  }
  if file and source.lang(file) then
    table.insert(tools, 1, button("Source", "source", "file"))
  end
  return ui.node("row", { role = "project-actions", gap = "md", aria = "Project toolbar" }, {
    ui.el("span", { role = "project-name", text = context.name or "Project", title = context.root }),
    separator(),
    ui.node("buttons", { variant = "toolbar", label = "Build and execution", role = "project-execution" }, {
      button("Build project", "build", "wrench"),
      button("Run tests", "test", "play"),
      button("Run project", "run", "run"),
      button(debug_title, "debug", "bug"),
    }),
    ui.node("row", { grow = 1 }),
    separator(),
    ui.node("buttons", { variant = "toolbar", label = "Project tools", role = "project-tools" }, tools),
  })
end

-- The file the workspace's editor shows, or nil.
local function editor_file(cx, workspace)
  local read = workspace.editor
    and cx.session:pane(workspace.editor)
    and cx.session:read(workspace.editor, { lines = 1, max_chars = 1 })
  return type(read) == "table" and type(read.path) == "string" and read.path or nil
end

-- Redraws a workspace's toolbar when the editor's file changed since the last draw.
local function render(cx, pane, workspace, force)
  local file = editor_file(cx, workspace)
  if force or workspace.shown ~= (file or "") then
    workspace.shown = file or ""
    cx.canvas:set(pane, { view = controls(workspace.context, file) })
  end
end

function M.install(actions)
  tern.css(
    "workspace-toolbar",
    [[
    [data-role="project-actions"] {
      position: absolute; top: 50%; transform: translateY(-50%);
      width: 100%; height: 36px; max-height: 100%; min-height: 0; gap: 10px; flex-wrap: nowrap; align-items: center;
      overflow-x: auto; overflow-y: hidden; font-family: system-ui, sans-serif;
    }
    [data-role="project-name"] {
      min-width: 48px; max-width: 220px; overflow: hidden; text-overflow: ellipsis;
      white-space: nowrap; font-size: 12px; font-weight: 600; color: var(--t1);
    }
    [data-role="project-separator"] { width: 1px; height: 18px; flex-shrink: 0; background: var(--l2); }
    [data-role="project-actions"] .sf-buttons {
      background: transparent; padding: 0; gap: 3px; flex-shrink: 0; align-self: center;
    }
    [data-role="project-actions"] .sf-button { border-radius: 6px; }
    .sf-main [data-role="project-actions"] .sf-button[data-role="project-run"] { color: var(--ok); }
    .sf-main [data-role="project-actions"] .sf-button[data-role="project-debug"] { color: var(--accent-ink); }
  ]]
  )
  local function refresh(cx)
    for _, canvas in cx.canvas:list() do
      if canvas.owner == tern.plugin.id then
        local workspace = entries[canvas.pane] or tern.kv.get(key(cx, canvas.pane))
        if workspace and workspace.context then
          entries[canvas.pane] = workspace
          render(cx, canvas.pane, workspace, true)
        end
      end
    end
  end
  -- Follows the editor's file without a timer: these events fire when it can change.
  local function follow(_, cx)
    -- Only panes that are still this plugin's canvases: a recorded id can outlive its canvas.
    for _, canvas in cx.canvas:list() do
      local workspace = canvas.owner == tern.plugin.id and entries[canvas.pane]
      if workspace then
        render(cx, canvas.pane, workspace, false)
      end
    end
  end
  for _, event in { "focus", "title" } do
    tern.on(event, follow)
  end
  tern.on("window_start", refresh)
  -- Reloading an existing window does not emit window_start, so the toolbars are redrawn from a
  -- timer. A timer scheduled while the plugin loads does not wake an idle window (a headless one can
  -- sleep until some other input arrives), so wake it: `tern.chrome.refresh` redraws the chrome on
  -- the next frame, which runs the due timer.
  tern.timer(0, refresh)
  pcall(tern.chrome.refresh)
  tern.route.open(function(request, cx)
    if request.origin ~= "files" or (request.how ~= "default" and request.how ~= "glimpse") then
      return nil
    end
    local host = cx.hosts:current()
    if host.kind ~= "local" or (request.host ~= "local" and request.host ~= host.name) then
      return nil
    end
    local focused = cx.session:focused()
    local tab = focused and cx.session:tab_of(focused)
    if not tab then
      return nil
    end
    for _, canvas in cx.canvas:list() do
      if canvas.owner == tern.plugin.id and cx.session:tab_of(canvas.pane) == tab then
        local workspace = entries[canvas.pane] or tern.kv.get(key(cx, canvas.pane))
        if workspace and request.path:sub(1, #workspace.context.root + 1) == workspace.context.root .. "/" then
          local editor = editor_in(cx, workspace, tab)
          if not editor then
            return nil
          end
          local current = cx.session:read(workspace.editor, { lines = 1, max_chars = 1 })
          if type(current) ~= "table" or current.kind ~= "file" or current.dirty == nil then
            return nil
          end
          cx.layout:focus(workspace.editor)
          if current.path == request.path and not request.line then
            return { handled = true }
          end
          local previous = workspace.editor
          -- Native overlays retain unsaved buffers and restore them when the new document closes.
          workspace.editor = cx.docs:open(request.path, {
            how = current.dirty and "over" or "replace",
            line = request.line,
          })
          if current.dirty and workspace.editor ~= previous then
            workspace.retained = workspace.retained or {}
            table.insert(workspace.retained, previous)
          end
          entries[canvas.pane] = workspace
          tern.kv.set(key(cx, canvas.pane), workspace)
          -- The editor reports its new file once the open lands; redraw the toolbar then.
          local toolbar = canvas.pane
          tern.timer(100, function(current)
            if current and entries[toolbar] == workspace then
              for _, open in current.canvas:list() do
                if open.pane == toolbar and open.owner == tern.plugin.id then
                  render(current, toolbar, workspace, false)
                end
              end
            end
          end)
          return { handled = true }
        end
      end
    end
    return nil
  end)
  tern.on("canvas_action", function(event, cx)
    local workspace = entries[event.pane] or tern.kv.get(key(cx, event.pane))
    if not workspace then
      return false
    end
    entries[event.pane] = workspace
    local context = workspace.context
    editor_in(cx, workspace, cx.session:tab_of(event.pane))
    local target = workspace.editor
    if not cx.session:pane(target) then
      target = cx.session:pane(workspace.terminal) and workspace.terminal or event.pane
    end
    if event.act == "files" then
      cx:open(context.root)
    elseif event.act == "manifest" then
      cx.docs:open(context.root .. "/elide.pkl", { how = "beside" })
    elseif actions[event.act] then
      local previous = workspace.results[event.act]
      if previous and cx.session:pane(previous) then
        cx.layout:focus(previous)
      else
        local pending = key(cx, event.pane) .. ":" .. event.act
        if opening[pending] then
          return true
        end
        opening[pending] = true
        local function opened(current, pane)
          opening[pending] = nil
          if pane and current.session:pane(event.pane) then
            workspace.results[event.act] = pane
            tern.kv.set(key(current, event.pane), workspace)
          end
        end
        local pane = actions[event.act](cx, context, target, opened)
        if pane ~= false then
          opened(cx, pane)
        end
      end
    else
      return false
    end
    return true
  end)
  tern.on("pane_closed", function(event, cx)
    if entries[event.pane] or tern.kv.get(key(cx, event.pane)) then
      entries[event.pane] = nil
      tern.kv.set(key(cx, event.pane), nil)
    end
  end)
end

function M.open(context, cx)
  if not context or cx.hosts:current().kind ~= "local" then
    cx:toast("info", "Open a local project directory first.")
    return
  end
  for _, canvas in cx.canvas:list() do
    if canvas.owner == tern.plugin.id then
      local existing = entries[canvas.pane] or tern.kv.get(key(cx, canvas.pane))
      if existing and existing.context.root == context.root then
        editor_in(cx, existing, cx.session:tab_of(canvas.pane))
        entries[canvas.pane] = existing
        tern.kv.set(key(cx, canvas.pane), existing)
        render(cx, canvas.pane, existing, true)
        cx:open(context.root)
        cx.layout:focus(cx.session:pane(existing.editor) and existing.editor or canvas.pane)
        return
      end
    end
  end
  cx:open(context.root)
  local editor = cx.docs:open(context.root .. "/elide.pkl", { how = "tab" })
  local terminal = cx.layout:split(editor, "down", { cwd = context.root }, { focus = false })
  if not terminal then
    cx:toast("error", "Could not open the project terminal.")
    return
  end
  cx.layout:resize(editor, "down", 12)
  local pane, problem = cx.canvas:open({
    title = context.name or "Project",
    about = "Project actions for " .. context.root,
    view = controls(context),
    target = editor,
    dir = "up",
    ratio = 0.08,
    focus = false,
  })
  if not pane then
    cx:toast("error", problem or "Could not open project actions.")
    return
  end
  local workspace = { context = context, editor = editor, terminal = terminal, results = {} }
  entries[pane] = workspace
  tern.kv.set(key(cx, pane), workspace)
  local tab = cx.session:tab_of(editor)
  if tab then
    cx.layout:name_tab(tab, context.name or "Project")
  end
  cx.layout:focus(editor)
end

return M
