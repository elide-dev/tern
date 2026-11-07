local records = {}
-- The last `elide test|build|run` each pane finished, for the status line.
local results = {}
local local_host = false
local M = {}

function M.context(cx)
  local_host = cx.hosts:current().kind == "local"
  if not local_host then
    return nil
  end
  local id = cx.session:focused()
  local pane = id and cx.session:pane(id)
  if not pane then
    return nil
  end
  local path = pane.cwd
  if pane.kind == "file" then
    local read = cx.session:read(id)
    if type(read) == "table" and read.path then
      path = read.path
    end
  end
  if not path or path == "" then
    return nil
  end
  return { pane = id, path = path }
end

function M.current(cx)
  local context = M.context(cx)
  local record = context and records[context.pane]
  return record and record.path == context.path and record.project or nil
end

function M.cached(cx)
  local record = records[cx.session:focused()]
  return local_host and record and record.project or nil
end

function M.probe(context, broker, callback)
  local previous = records[context.pane]
  if previous and previous.path == context.path and previous.pending and not callback then
    return
  end
  local record = {
    path = context.path,
    pending = true,
    project = previous and previous.path == context.path and previous.project or nil,
  }
  records[context.pane] = record
  local ok = pcall(function()
    tern.process.run({ broker, "project-root", context.path }, { timeout_ms = 2000 }, function(result, cx)
      if records[context.pane] ~= record then
        return
      end
      record.pending = false
      record.project = nil
      if result.status == 0 then
        local decoded, project = pcall(tern.json.decode, result.stdout)
        if decoded and type(project) == "table" and type(project.root) == "string" then
          record.project = project
        end
      end
      tern.chrome.refresh()
      if callback and cx then
        callback(record.project, cx)
      end
    end)
  end)
  if not ok then
    records[context.pane] = nil
  end
end

function M.remove(pane)
  records[pane] = nil
  results[pane] = nil
end

-- Roots of every project detected so far in this window, without duplicates.
function M.roots()
  local roots, seen = {}, {}
  for _, record in records do
    local root = record.project and record.project.root
    if root and not seen[root] then
      seen[root] = true
      table.insert(roots, root)
    end
  end
  return roots
end

-- Records how an `elide <command>` line ended in `pane`; the caller refreshes the chrome.
-- `detail`, when given, follows the outcome after a middle dot ("Build failed · 3 errors").
function M.finished(pane, command, status, detail)
  results[pane] = { command = command, status = status, detail = detail }
end

-- The root of the project detected for `pane`, or nil.
function M.root_of(pane)
  local record = records[pane]
  return record and record.project and record.project.root or nil
end

local OUTCOMES = {
  test = { ok = "Tests passed", failed = "Tests failed", command = "plugin.elide.project_tests" },
  build = { ok = "Built", failed = "Build failed", command = "plugin.elide.project" },
  run = { ok = "Ran", failed = "Run failed", command = "plugin.elide.project" },
}

local function outcome(pane)
  local result = results[pane]
  local labels = result and OUTCOMES[result.command]
  if not labels then
    return nil
  end
  local ok = result.status == 0
  local text = if ok then labels.ok else labels.failed
  if result.detail then
    text ..= " · " .. result.detail
  end
  return {
    text = text,
    icon = if ok then "check" else "x-circle",
    tone = if ok then "ok" else "error",
    command = labels.command,
  }
end

function M.status(pane)
  local record = records[pane.pane]
  if local_host and record and record.project then
    local segments = {
      { text = record.project.name or "Project", icon = "folder", command = "plugin.elide.project" },
      { text = "Workspace", icon = "folder", command = "plugin.elide.workspace" },
    }
    local last = outcome(pane.pane)
    if last then
      table.insert(segments, last)
    end
    return segments
  end
  return nil
end

-- Names a tab after the project its focused pane sits in; names the user gave win.
function M.tab_title(tab)
  if tab.name or not local_host then
    return nil
  end
  local record = records[tab.pane]
  local root = record and record.project and record.project.root
  if not root then
    return nil
  end
  local cwd = tab.cwd or ""
  if cwd ~= "" and cwd ~= root and string.sub(cwd, 1, #root + 1) ~= root .. "/" then
    return nil
  end
  return record.project.name or string.match(root, "([^/]+)$")
end

return M
