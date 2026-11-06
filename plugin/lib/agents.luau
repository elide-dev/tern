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
  tern.carly.export("test_cover", {
    sig = "test_cover(binding: table, subject: string, command: string) -> {run: string}",
    doc = "Run tests with coverage. Use a new UUID for an intentional run; reuse it only for the same subject and coverage option after a lost response. Poll project_read for coverage state; coverage_read reads the measured artifact.",
  }, function(binding, subject, command, cx, call)
    return request(
      { op = "project_test", binding = binding, subject = subject, command = command, options = { coverage = true } },
      cx,
      call
    )
  end)
  tern.carly.export("coverage_read", {
    sig = "coverage_read(binding: table, run: string, query: table) -> page?",
    doc = "Read immutable coverage for this run. Pass {} to list files; {file=N} reads a zero-based file index. offset defaults to 0; limit defaults to 50 (max 100). next is the next offset or null. A missing sourceDigest means source identity is unavailable, not current. Returns null while no artifact is available; inspect project_read for the reason.",
  }, function(binding, run, query, cx, call)
    if type(query) ~= "table" then
      call:fail("Coverage query must be a table.")
      return
    end
    return request({
      op = "project_coverage_page",
      binding = binding,
      run = run,
      file = query.file,
      offset = query.offset,
      limit = query.limit,
    }, cx, call)
  end)
  tern.carly.export("debug_launch", {
    sig = "debug_launch(binding: table, subject: string, command: string, options: table) -> {generation: string}",
    doc = "Launch a source file under the project guest debugger. Options: mode='run' or 'test', stop_on_entry=true, breakpoints={{path='file.js',line=5}}. Use a fresh UUID command and reuse it only to retry the same launch. This attachment owns control; closing it starts a 30-second grace before the target is stopped. Poll debug_read; launches are asynchronous.",
  }, function(binding, subject, command, options, cx, call)
    return request(
      { op = "project_debug_launch", binding = binding, subject = subject, command = command, options = options },
      cx,
      call
    )
  end)
  tern.carly.export("debug_read", {
    sig = "debug_read(binding: table) -> snapshot?",
    doc = "Read the shared debugger and renew attachment. Includes generation, stop_epoch, state, bounded stack/scopes/explicitly inspected variables, breakpoints, output, pending status and execution ownership. Values may be unavailable until explicitly inspected. Returned frame/variable handles expire at resume or restart.",
  }, function(binding, cx, call)
    return request({ op = "project_debug_snapshot", binding = binding, compact = true }, cx, call)
  end)
  tern.carly.export("debug_control", {
    sig = "debug_control(binding: table, command: string, request: table) -> table",
    doc = "Queue an operation with a new UUID command and {generation,stop_epoch,action}. Action is a table tagged kind: continue,next,step_in,step_out,pause,stop,stack(thread),scopes(frame),variables(reference,allow_side_effects),breakpoints(path,lines). Read the current snapshot first. Control and side-effect-capable inspection require ownership. Variables with allow_side_effects=true may run guest getters/display code: use only when explicitly intended. Poll debug_read for completion/error; acceptance is not completion.",
  }, function(binding, command, operation, cx, call)
    return request(
      { op = "project_debug_request", binding = binding, command = command, request = operation },
      cx,
      call
    )
  end)
  tern.carly.export("debug_takeover", {
    sig = "debug_takeover(binding: table, generation: string) -> table",
    doc = "Explicitly take execution control of this debug generation, revoking the previous attachment's queued controls. This can interrupt another user's control; invoke only when takeover is intended. Observing stacks and scopes needs no takeover.",
  }, function(binding, generation, cx, call)
    return request({ op = "project_debug_takeover", binding = binding, generation = generation }, cx, call)
  end)
  tern.carly.export("project_close", {
    sig = "project_close(binding: table) -> table",
    doc = "Release this attachment. Running tests continue to completion or their deadline; use test_cancel to stop a run explicitly. If this attachment controls a debugger, releasing it starts the 30-second takeover grace before the target stops.",
  }, function(binding, cx, call)
    return request({ op = "project_detach", binding = binding }, cx, call)
  end)
end

return M
