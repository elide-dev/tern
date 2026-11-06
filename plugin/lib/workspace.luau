local M = {}
local ui = tern.ui
local entries = {}

local function key(cx, pane)
  return "workspace:" .. cx:window_key() .. ":" .. tostring(pane)
end

local function button(label, action, icon)
  return ui.button(label, { icon = icon, role = "project-" .. action, variant = "quiet", actions = { click = action } })
end

function M.install(actions)
  tern.on("canvas_action", function(event, cx)
    local workspace = entries[event.pane] or tern.kv.get(key(cx, event.pane))
    if not workspace then
      return false
    end
    entries[event.pane] = workspace
    local context = workspace.context
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
        local pane = actions[event.act](cx, context, target)
        if pane then
          workspace.results[event.act] = pane
          tern.kv.set(key(cx, event.pane), workspace)
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
  local controls = ui.row({
    button("Build", "build", "build"),
    button("Test", "test", "play"),
    button("Run", "run", "play"),
    button("REPL", "repl", "terminal"),
    button("Serve files", "serve", "server"),
    button("Files", "files", "folder"),
  })
  controls.p = { role = "project-actions", wrap = true, gap = "sm" }
  local pane, problem = cx.canvas:open({
    title = context.name or "Project",
    about = "Project actions for " .. context.root,
    view = controls,
    target = editor,
    dir = "up",
    ratio = 0.12,
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
