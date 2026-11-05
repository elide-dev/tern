local records = {}
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
end

function M.status(pane)
  local record = records[pane.pane]
  if local_host and record and record.project then
    return { { text = record.project.name or "Project", icon = "folder", command = "plugin.elide.project" } }
  end
  return nil
end

return M
