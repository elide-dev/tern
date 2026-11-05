local M = {}

function M.install(configuration, path, project)
  if not tern.carly then
    return
  end

  local function request(body, cx, call)
    local config = configuration(cx)
    if not config then
      call:fail("Configure the project runtime first.")
      return
    end
    if cx.hosts:current().kind ~= "local" then
      call:fail("Project services are available on local hosts only.")
      return
    end
    if body.op == "project_attach" then
      local runtime = config.runtime or "elide"
      if string.find(runtime, "/") and string.sub(runtime, 1, 1) ~= "/" then
        runtime = path(runtime)
      end
      body.runtime = runtime
    end
    local state = config.project_state
      or (config.state and (config.state .. "-projects"))
      or (tern.plugin.data .. "/projects")
    local pending = call:wait(20000)
    local ok, problem = pcall(function()
      tern.process.run({ path(config.broker or "../dist/elide-tern-broker"), "request", state }, {
        stdin = tern.json.encode(body),
        timeout_ms = 18000,
      }, function(result)
        if call.cancelled then
          return
        end
        if result.status ~= 0 then
          call:fail("Project request failed: " .. string.sub(result.stderr, 1, 1024))
          return
        end
        local decoded, response = pcall(tern.json.decode, result.stdout)
        if not decoded or type(response) ~= "table" then
          call:fail("Invalid project response")
        elseif not response.ok then
          call:fail(response.error or "Project request failed")
        else
          call:reply(response.result)
        end
      end)
    end)
    if not ok then
      call:fail(tostring(problem))
    end
    return pending
  end

  tern.carly.context(function(cx)
    local context = project.cached(cx)
    if context then
      return "Active project: "
        .. context.root
        .. ". Use plugins.elide.project_open with this explicit root; retain its binding for later test operations."
    end
    return nil
  end)
  tern.carly.export("project_open", {
    sig = "project_open(root: string) -> binding",
    doc = "Attach to an explicit absolute project root. Retain {session, epoch, lease}; focus changes do not retarget it. No manifest evaluation. Lease expires after 60 seconds without requests; reopen to reattach.",
  }, function(root, cx, call)
    return request({ op = "project_attach", root = root }, cx, call)
  end)
  tern.carly.export("project_read", {
    sig = "project_read(binding: table) -> snapshot",
    doc = "Read bounded shared test state and renew this attachment. Includes run handles, counts, report paths and at most two failure previews per run. This is the same state shown in native Tests.",
  }, function(binding, cx, call)
    return request({ op = "project_summary", binding = binding }, cx, call)
  end)
  tern.carly.export("test_run", {
    sig = "test_run(binding: table, subject: string, command: string) -> {run: string}",
    doc = "Start project-owned tests. Supply a new UUID command for each intentional run; reuse it only to retry the same subject after a lost response. Subject is confined to the project. The run survives view/tool closure; poll project_read or use test_cancel.",
  }, function(binding, subject, command, cx, call)
    return request({ op = "project_test", binding = binding, subject = subject, command = command }, cx, call)
  end)
  tern.carly.export("test_cancel", {
    sig = "test_cancel(binding: table, run: string) -> table",
    doc = "Request cancellation of the identified project test run. Read project_read until the run is terminal; an acknowledgement does not mean teardown has finished.",
  }, function(binding, run, cx, call)
    return request({ op = "project_cancel", binding = binding, run = run }, cx, call)
  end)
  tern.carly.export("project_close", {
    sig = "project_close(binding: table) -> table",
    doc = "Release this attachment. Running tests continue to completion or their deadline; use test_cancel to stop a run explicitly.",
  }, function(binding, cx, call)
    return request({ op = "project_detach", binding = binding }, cx, call)
  end)
end

return M
