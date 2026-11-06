-- Host half: command lenses over ordinary `elide` invocations in a plain terminal.
-- Elide's own interactive surfaces negotiate the Tern Surface Protocol themselves;
-- lenses only cover commands whose output is machine-readable text.

-- Output beyond these bounds stays raw: a tree of that size is not browsable anyway.
local MAX_LINES = 20000
local MAX_BYTES = 4 * 1024 * 1024

-- Diagnostic cards and TAP rows shown before the "… N more" line, as the built-in lenses cap theirs.
local MAX_DIAGNOSTICS = 200
local MAX_ROWS = 5000

local ui = tern.ui

local function buffer()
  return { lines = {}, bytes = 0, truncated = false }
end

-- Keeps a line unless the bounds are reached; afterwards the lens shows raw output.
local function collect(state, l)
  if state.truncated then
    return
  end
  if #state.lines >= MAX_LINES or state.bytes + #l.text + 1 > MAX_BYTES then
    state.truncated = true
    return
  end
  table.insert(state.lines, l.text)
  state.bytes += #l.text + 1
end

-- JSON output (`elide project export`, `--json` reporters) as a native tree.
tern.lens.define("json", {
  open = function()
    return buffer()
  end,
  line = collect,
  finish = function() end,
  view = function(state)
    if state.truncated then
      return nil
    end
    return tern.parse.json_tree(table.concat(state.lines, "\n"))
  end,
})

local SEVERITIES = {
  error = "error",
  fatal = "error",
  warning = "warning",
  warn = "warning",
  note = "note",
  info = "note",
  help = "help",
}

-- `severity[code]: message` or `severity: message`, as compilers print after a location.
local function severity_message(text)
  local word, code, message = string.match(text, "^%s*(%a+)%[([^%]]+)%]:%s*(.+)$")
  if not word then
    word, message = string.match(text, "^%s*(%a+):%s*(.+)$")
  end
  local severity = word and SEVERITIES[string.lower(word)]
  if not severity then
    return nil
  end
  return severity, code, message
end

-- Elide's builder: `[ 7.2s] error: javac: ';' expected`, then `In file: path:line:col` and a
-- numbered excerpt (`→4 │ code`). Compilers' own `path:line:col: error: message` lines too.
local function diagnostics(lines)
  local found, pending = {}, nil
  local function close()
    if pending then
      if #pending.excerpt > 0 then
        pending.diag.snippet = { pending.first, table.concat(pending.excerpt, "\n") }
      end
      table.insert(found, pending.diag)
      pending = nil
    end
  end
  for _, text in lines do
    local file = string.match(text, "^%s*In file:%s*(.+)$")
    local number, source = string.match(text, "^%s*[^%d%s]*%s*(%d+) │ ?(.*)$")
    if pending and file then
      local path, line, col = tern.parse.location(file)
      pending.diag.path, pending.diag.line, pending.diag.col = path, line, col
    elseif pending and pending.diag.path and #pending.excerpt == 0 and string.find(text, "^%s*$") then
      -- The builder leaves a blank line between the location and its excerpt.
    elseif pending and number and pending.diag.path then
      pending.first = pending.first or tonumber(number)
      table.insert(pending.excerpt, source)
    else
      close()
      local path, line, col = tern.parse.location(text)
      local rest = path and string.match(text, "^.-:%d+:?%d*:%s*(.*)$")
      local severity, code, message = severity_message(rest or "")
      if path and severity then
        table.insert(
          found,
          { severity = severity, code = code, message = message, path = path, line = line, col = col }
        )
      else
        severity, code, message = severity_message(string.gsub(text, "^%s*%[[^%]]*%]", "", 1))
        if severity and severity ~= "help" then
          pending = { diag = { severity = severity, code = code, message = message }, excerpt = {} }
        end
      end
    end
  end
  close()
  return found
end

-- `elide build`: compile errors and warnings as diagnostic cards; raw output when none parse.
tern.lens.define("build", {
  open = function(run)
    local state = buffer()
    state.cwd = run.cwd
    return state
  end,
  line = collect,
  finish = function() end,
  view = function(state)
    if state.truncated then
      return nil
    end
    local found = diagnostics(state.lines)
    if #found == 0 then
      return nil
    end
    local cards = {}
    for index, diag in found do
      if index > MAX_DIAGNOSTICS then
        table.insert(cards, ui.overflow(#found - MAX_DIAGNOSTICS))
        break
      end
      local ok, card = pcall(ui.diagnostic, diag, state.cwd)
      if not ok then
        -- An excerpt the builder rejects should not cost the rest of the card.
        diag.snippet = nil
        card = ui.diagnostic(diag, state.cwd)
      end
      table.insert(cards, card)
    end
    return ui.col(cards)
  end,
})

-- `elide test --reporter=tap`: a summary and one row per top-level `ok`/`not ok` line, with the
-- failure message from the YAML block below a failing test.
tern.lens.define("tap", {
  open = function()
    return { rows = {}, hidden = 0, passed = 0, failed = 0, skipped = 0, took = nil, yaml = false, last = nil }
  end,
  line = function(state, l)
    local text = l.text
    local status = if string.sub(text, 1, 7) == "not ok " then "not ok" else "ok"
    local number, rest = string.match(text, "^" .. status .. "%s+(%d+)%s*%-?%s*(.*)$")
    if number then
      local name, directive = string.match(rest, "^(.-)%s*#%s*(.*)$")
      name = name or rest
      local word = directive and string.upper(string.match(directive, "^(%a+)") or "")
      local outcome = if word == "SKIP" or word == "TODO"
        then "skipped"
        elseif status == "ok" then "passed"
        else "failed"
      state[outcome] += 1
      state.yaml, state.last = false, nil
      if #state.rows >= MAX_ROWS then
        state.hidden += 1
        return
      end
      local row = { number = number, name = name, outcome = outcome, detail = directive or "" }
      table.insert(state.rows, row)
      state.last = row
    elseif string.match(text, "^%s+%-%-%-%s*$") then
      state.yaml = state.last ~= nil
    elseif string.match(text, "^%s+%.%.%.%s*$") then
      state.yaml = false
    elseif state.yaml and state.last and state.last.outcome == "failed" and state.last.detail == "" then
      local message = string.match(text, "^%s+message:%s*(.+)$")
      if message then
        local ok, decoded = pcall(tern.json.decode, message)
        message = if ok and type(decoded) == "string" then decoded else message
        state.last.detail = string.match(message, "^%s*([^\n]*)") or message
      end
    else
      state.took = string.match(text, "%(([%d.]+m?s)%)%s*$") or state.took
    end
  end,
  finish = function() end,
  view = function(state)
    local total = state.passed + state.failed + state.skipped
    if total == 0 then
      return nil
    end
    local tones = { passed = "success", failed = "error", skipped = "muted" }
    local words = { passed = "ok", failed = "not ok", skipped = "skip" }
    local rows = {}
    for _, row in state.rows do
      table.insert(rows, {
        id = "t" .. row.number,
        cells = {
          { ui.span(row.number, "num") },
          { badge = { text = words[row.outcome], tone = tones[row.outcome] } },
          { ui.span(row.name) },
          { ui.span(row.detail, "muted") },
        },
      })
    end
    local view = {
      ui.test_summary(state.passed, state.failed, state.skipped, state.took),
      ui.table({
        { id = "n", head = "#", align = "end", mono = true, priority = 1 },
        { id = "status", head = "Status", priority = 3 },
        { id = "name", head = "Test", grow = 1, priority = 4, truncate = "end" },
        { id = "detail", head = "Detail", priority = 2, truncate = "end" },
      }, rows),
    }
    if state.hidden > 0 then
      table.insert(view, ui.overflow(state.hidden))
    end
    return ui.col(view)
  end,
})

-- `elide.source`: a read-only view of one source file in Tern's `editor` node, with coverage and
-- debugger overlays from the shared project session (docs/architecture.md, "Source block").
-- Launch arguments: the absolute file, then optionally the project root and a one-based line.
local broker = require("./lib/broker")
local source = require("./lib/source")

local RENEW_MS = 30000
local DEBUG_POLL_MS = 500
local RUN_POLL_MS = 1000
local OVERLAYS = { "none", "coverage", "debug", "hotness" }
local HOTNESS_REASON = "Profiles are not source-located yet: the broker has no project_profile_page operation."
local SIGNS = {
  covered = { "●", "success" },
  uncovered = { "●", "error" },
  partial = { "◐", "warning" },
}
local DEBUG_WORDS = {
  starting = { "Starting", "accent" },
  running = { "Running", "accent" },
  stopped = { "Paused", "pending" },
  stopping = { "Stopping", "muted" },
  exited = { "Exited", "muted" },
  failed = { "Failed", "error" },
}

math.randomseed(math.floor(tern.now() * 1000) % 2147483647)

-- Blocks by pane, so `pane_exited` can detach them.
local blocks = {}

local function running(pane)
  for _, info in tern.pane.list() do
    if info.pane == pane then
      return true
    end
  end
  return false
end

local function alive(state)
  return not state.closed and running(state.pane)
end

-- Stops background work and releases the project attachment; a debug target this block controls
-- gets the broker's 30-second takeover grace before it is stopped.
local function close(state)
  if state.closed then
    return
  end
  state.closed = true
  blocks[state.pane] = nil
  for _, timer in state.timers do
    timer:cancel()
  end
  state.timers = {}
  if state.binding then
    broker.project({ op = "project_detach", binding = state.binding }, function() end)
    state.binding = nil
  end
end

tern.on("pane_exited", function(ev)
  local state = blocks[ev.pane]
  if state then
    close(state)
  end
end)

-- A command operation under docs/protocol.md's retry contract: one UUID per intent, and the same
-- UUID and exact payload again only when no response arrived.
local function command(state, body, done)
  body.command = source.uuid(math.random)
  local tries = 0
  local function attempt()
    tries += 1
    broker.project(body, function(result, err, transport)
      if not alive(state) then
        return
      end
      if err and transport and tries < 3 then
        tern.timer(250 * tries, attempt)
        return
      end
      done(result, err)
    end)
  end
  attempt()
end

local function same(state, candidate)
  return state.relative ~= nil and source.same(candidate, state.path, state.relative, { state.root, state.canonical })
end

local function absorb(state, snapshot)
  if type(snapshot) ~= "table" then
    return
  end
  state.project = snapshot.name or state.project
  state.canonical = snapshot.root or state.canonical
  state.revision = snapshot.revision
  state.runs = type(snapshot.runs) == "table" and snapshot.runs or {}
end

local function fail(state, cx, problem)
  state.attach, state.attach_error, state.binding = "error", tostring(problem or "Project request failed."), nil
  for name, timer in state.timers do
    timer:cancel()
    state.timers[name] = nil
  end
  state.debug.polling = false
  cx:render()
end

local load_coverage, poll_debug

-- Starts the active overlay's work once the project is attached.
local function enter(state, cx)
  if state.attach ~= "ready" then
    return
  end
  if state.mode == "coverage" then
    load_coverage(state, cx, false)
  elseif state.mode == "debug" then
    poll_debug(state, cx)
  end
end

local function renew(state, cx)
  state.timers.renew = tern.timer(RENEW_MS, function()
    state.timers.renew = nil
    if not alive(state) then
      close(state)
      return
    end
    if not state.binding then
      return
    end
    broker.project({ op = "project_snapshot", binding = state.binding, after = state.revision }, function(snapshot, err)
      if not alive(state) then
        close(state)
        return
      end
      if err then
        fail(state, cx, err)
        return
      end
      if type(snapshot) == "table" then
        absorb(state, snapshot)
        if state.mode == "coverage" then
          load_coverage(state, cx, false)
        end
        cx:render()
      end
      renew(state, cx)
    end)
  end)
end

local function attach(state, cx)
  if not state.root or state.closed or state.attach == "attaching" then
    return
  end
  state.attach, state.attach_error = "attaching", nil
  broker.project({ op = "project_attach", root = state.root }, function(binding, err)
    if not alive(state) then
      if type(binding) == "table" then
        broker.project({ op = "project_detach", binding = binding }, function() end)
      end
      return
    end
    if err or type(binding) ~= "table" then
      fail(state, cx, err or "Invalid attachment.")
      return
    end
    state.binding = binding
    broker.project({ op = "project_snapshot", binding = binding }, function(snapshot, problem)
      if not alive(state) then
        close(state)
        return
      end
      if problem then
        fail(state, cx, problem)
        return
      end
      absorb(state, snapshot)
      state.attach = "ready"
      renew(state, cx)
      enter(state, cx)
      cx:render()
    end)
  end)
end

-- Coverage ------------------------------------------------------------------------------------

local function coverage_run(state)
  local runs = state.runs or {}
  for index = #runs, 1, -1 do
    local run = runs[index]
    if type(run) == "table" and type(run.options) == "table" and run.options.coverage then
      return run
    end
  end
  return nil
end

-- Polls the snapshot while the coverage run started from this block (or seen running) finishes.
local function poll_run(state, cx)
  if state.timers.run then
    return
  end
  state.timers.run = tern.timer(RUN_POLL_MS, function()
    state.timers.run = nil
    if not alive(state) then
      close(state)
      return
    end
    if not state.binding or state.coverage.state ~= "running" then
      return
    end
    broker.project({ op = "project_snapshot", binding = state.binding }, function(snapshot, err)
      if not alive(state) then
        close(state)
        return
      end
      if err then
        fail(state, cx, err)
        return
      end
      absorb(state, snapshot)
      local latest = coverage_run(state)
      if latest and latest.id == state.coverage.run and not latest.running then
        state.coverage.state = "idle"
        load_coverage(state, cx, true)
      else
        poll_run(state, cx)
      end
      cx:render()
    end)
  end)
end

-- Fetches this file's measured lines from the newest coverage run, paging through `next`.
function load_coverage(state, cx, force)
  local coverage = state.coverage
  if state.attach ~= "ready" or not state.relative then
    return
  end
  local run = coverage_run(state)
  if not run then
    coverage.state, coverage.run = "missing", nil
    return
  end
  local summary = type(run.coverage) == "table" and run.coverage or {}
  if run.running or summary.state == "collecting" then
    coverage.state, coverage.run = "running", run.id
    poll_run(state, cx)
    return
  end
  if summary.state ~= "ready" and summary.state ~= "incomplete" then
    coverage.state, coverage.run = "unavailable", run.id
    coverage.message = summary.message or ("Coverage for this run is " .. tostring(summary.state or "unknown") .. ".")
    return
  end
  if not force and coverage.run == run.id and (coverage.state == "ready" or coverage.state == "loading") then
    return
  end
  coverage.state, coverage.run, coverage.error = "loading", run.id, nil
  local token = {}
  coverage.token = token
  local function current()
    return alive(state) and coverage.token == token
  end
  local function broken(err)
    coverage.state, coverage.error = "error", tostring(err or "Invalid coverage page.")
    cx:render()
  end
  local function lines(index, offset, found)
    broker.project({
      op = "project_coverage_page",
      binding = state.binding,
      run = run.id,
      file = index,
      offset = offset,
      limit = 100,
    }, function(page, err)
      if not current() then
        return
      end
      if err or type(page) ~= "table" or type(page.lines) ~= "table" then
        broken(err)
        return
      end
      for _, line in page.lines do
        table.insert(found, line)
      end
      if type(page.next) == "number" and page.next > offset then
        lines(index, page.next, found)
        return
      end
      coverage.marks, coverage.covered, coverage.total = source.coverage(found)
      coverage.complete = page.complete ~= false
      coverage.state = "ready"
      cx:render()
    end)
  end
  local function files(offset)
    broker.project({
      op = "project_coverage_page",
      binding = state.binding,
      run = run.id,
      offset = offset,
      limit = 100,
    }, function(page, err)
      if not current() then
        return
      end
      if err or type(page) ~= "table" or type(page.files) ~= "table" then
        broken(err)
        return
      end
      for _, file in page.files do
        if type(file) == "table" and same(state, file.path) and type(file.index) == "number" then
          lines(file.index, 0, {})
          return
        end
      end
      if type(page.next) == "number" and page.next > offset then
        files(page.next)
      else
        coverage.state = "absent"
        cx:render()
      end
    end)
  end
  files(0)
end

local function run_coverage(state, cx)
  local coverage = state.coverage
  if state.attach ~= "ready" or coverage.state == "running" or coverage.starting then
    return
  end
  coverage.starting = true
  command(state, {
    op = "project_test",
    binding = state.binding,
    subject = state.root,
    options = { coverage = true },
  }, function(result, err)
    coverage.starting = false
    if err or type(result) ~= "table" then
      coverage.state, coverage.error = "error", tostring(err or "Invalid test response.")
    else
      coverage.state, coverage.run = "running", result.run
      poll_run(state, cx)
    end
    cx:render()
  end)
end

-- Debugging ------------------------------------------------------------------------------------

local function active(debug)
  local snap = debug.snap
  return snap ~= nil and snap.debug.state ~= "exited" and snap.debug.state ~= "failed"
end

local function move(state, line)
  state.caret = math.max(1, math.min(line, state.index.count))
end

local function absorb_debug(state, snap)
  local debug = state.debug
  if type(snap) ~= "table" or type(snap.debug) ~= "table" then
    debug.snap, debug.stop, debug.verified, debug.elsewhere = nil, nil, {}, nil
    return
  end
  local target = snap.debug
  debug.snap, debug.stop, debug.elsewhere = snap, nil, nil
  local frame = type(target.frames) == "table" and target.frames[1] or nil
  if target.state == "stopped" and type(frame) == "table" then
    if same(state, frame.path) then
      debug.stop = frame.line
    else
      debug.elsewhere = tostring(frame.path or "?") .. ":" .. tostring(frame.line or "?")
    end
  end
  if debug.stop and target.stop_epoch ~= debug.epoch then
    move(state, debug.stop)
  end
  debug.epoch = target.stop_epoch
  local verified, requested = {}, {}
  for _, point in (type(target.breakpoints) == "table" and target.breakpoints or {}) do
    if type(point) == "table" and same(state, point.path) then
      verified[point.requested_line] = point
      table.insert(requested, point.requested_line)
    end
  end
  debug.verified = verified
  -- A new target adopts the breakpoints it reports for this file (set here, by the Debug surface
  -- or by an agent).
  if target.generation ~= debug.generation then
    debug.generation = target.generation
    if #requested > 0 then
      table.sort(requested)
      state.breakpoints = requested
    end
  end
end

function poll_debug(state, cx)
  local debug = state.debug
  if debug.polling then
    return
  end
  debug.polling = true
  local function tick()
    state.timers.debug = nil
    if not alive(state) then
      close(state)
      return
    end
    if state.mode ~= "debug" or state.attach ~= "ready" then
      debug.polling = false
      return
    end
    broker.project({ op = "project_debug_snapshot", binding = state.binding, compact = true }, function(snap, err)
      if not alive(state) then
        close(state)
        return
      end
      local before = debug.signature
      if err then
        debug.error = tostring(err)
      else
        absorb_debug(state, snap)
      end
      local target = debug.snap and debug.snap.debug
      debug.signature = table.concat({
        tostring(debug.error),
        target and tostring(target.revision) or "-",
        target and tostring(target.pending) or "-",
        debug.snap and tostring(debug.snap.controller) or "-",
      }, "|")
      if debug.signature ~= before then
        cx:render()
      end
      if state.mode == "debug" and not state.closed and state.attach == "ready" then
        state.timers.debug = tern.timer(DEBUG_POLL_MS, tick)
      else
        debug.polling = false
      end
    end)
  end
  state.timers.debug = tern.timer(0, tick)
end

local function controllable(state, cx)
  local debug = state.debug
  if not active(debug) then
    return nil
  end
  if debug.snap.controller ~= "you" then
    cx:toast("info", "Another attachment controls this target.", "Take over from the Debug panel to control it here.")
    return nil
  end
  return debug.snap.debug
end

local function request(state, cx, target, action)
  command(state, {
    op = "project_debug_request",
    binding = state.binding,
    request = { generation = target.generation, stop_epoch = target.stop_epoch, action = action },
  }, function(_, err)
    state.debug.error = err and tostring(err) or nil
    cx:render()
  end)
end

local function launch(state, cx)
  local debug = state.debug
  if not source.debuggable(state.path) then
    cx:toast("info", "Debugging takes JavaScript, TypeScript or Python sources.")
    return
  end
  if state.attach ~= "ready" or debug.launching then
    return
  end
  local points = {}
  for _, line in state.breakpoints do
    table.insert(points, { path = state.relative, line = line })
  end
  local lang = source.lang(state.path)
  local test = source.test_file(state.path) and (lang == "javascript" or lang == "typescript")
  debug.launching, debug.error = true, nil
  command(state, {
    op = "project_debug_launch",
    binding = state.binding,
    subject = state.relative,
    options = { mode = test and "test" or "run", stop_on_entry = false, breakpoints = tern.json.array(points) },
  }, function(_, err)
    debug.launching = false
    debug.error = err and tostring(err) or nil
    cx:render()
  end)
end

local function step(state, cx, kind)
  if kind == "continue" and not active(state.debug) then
    launch(state, cx)
    return
  end
  local target = controllable(state, cx)
  if not target then
    return
  end
  if kind ~= "stop" and target.state ~= "stopped" then
    return
  end
  request(state, cx, target, { kind = kind })
end

local function toggle_breakpoint(state, cx)
  if not source.debuggable(state.path) then
    cx:toast("info", "Debugging takes JavaScript, TypeScript or Python sources.")
    return
  end
  local target = nil
  if active(state.debug) then
    target = controllable(state, cx)
    if not target then
      return
    end
  end
  state.breakpoints = source.toggle(state.breakpoints, state.caret)
  if target then
    request(state, cx, target, {
      kind = "breakpoints",
      path = state.relative,
      lines = tern.json.array(state.breakpoints),
    })
  end
end

-- Overlay switching ---------------------------------------------------------------------------

local function set_mode(state, cx, mode)
  if mode == "hotness" then
    cx:toast("info", HOTNESS_REASON)
    return
  end
  if mode == state.mode or not table.find(OVERLAYS, mode) then
    return
  end
  state.mode = mode
  if mode ~= "debug" and state.timers.debug then
    state.timers.debug:cancel()
    state.timers.debug = nil
    state.debug.polling = false
  end
  if mode ~= "none" and not state.root then
    return
  end
  enter(state, cx)
end

local function cycle(state, cx, direction)
  local usable = { "none", "coverage", "debug" }
  local at = table.find(usable, state.mode) or 1
  set_mode(state, cx, usable[(at - 1 + direction) % #usable + 1])
end

-- View -----------------------------------------------------------------------------------------

local function visible(cx)
  return math.max(5, (cx.rows or 24) - 10)
end

local function lines_view(state)
  local index = state.index
  local width = #tostring(index.count)
  local gutter, virt, decor = {}, {}, {}
  local any_virt = false
  local coverage = state.coverage
  local marks = state.mode == "coverage" and coverage.state == "ready" and coverage.marks or nil
  local debugging = state.mode == "debug"
  local debug = state.debug
  local points = {}
  if debugging then
    for _, line in state.breakpoints do
      points[line] = true
    end
  end
  for line = 1, index.count do
    local glyph, tone, note = " ", nil, ""
    if marks and marks[line] then
      local mark = marks[line]
      glyph, tone = SIGNS[mark.state][1], SIGNS[mark.state][2]
      if mark.state == "partial" and mark.branches then
        note = { ui.span("  " .. mark.branches.covered .. "/" .. mark.branches.total .. " branches", "warning") }
      end
    elseif debugging then
      if debug.stop == line then
        glyph, tone = "▶", "accent"
        local reason = debug.snap and debug.snap.debug.reason
        note = { ui.span("  ◀ paused" .. (type(reason) == "string" and (" · " .. reason) or ""), "accent") }
        table.insert(decor, { from = index.starts[line], to = index.starts[line] + index.lengths[line], s = "mark" })
      elseif points[line] then
        local point = debug.verified and debug.verified[line]
        if point and not point.verified and active(debug) then
          glyph, tone = "○", "warning"
          if type(point.message) == "string" then
            note = { ui.span("  " .. point.message, "muted") }
          end
        else
          glyph, tone = "●", "error"
        end
      end
    end
    gutter[line] = {
      ui.span(source.number(line, width), line == state.caret and "accent" or "dim"),
      ui.span(" "),
      tone and ui.span(glyph, tone) or ui.span(glyph),
      ui.span(" "),
    }
    virt[line] = note
    any_virt = any_virt or note ~= ""
  end
  return gutter, any_virt and virt or nil, #decor > 0 and decor or nil
end

local function overlay_badges(state)
  local badges = {}
  if state.mode == "coverage" then
    local coverage = state.coverage
    if coverage.state == "ready" then
      local percent = source.percent(coverage.covered, coverage.total)
      if percent then
        local tone = percent >= 80 and "success" or percent >= 50 and "warning" or "error"
        table.insert(badges, ui.badge(percent .. "% covered", tone))
      else
        table.insert(badges, ui.badge("No measured lines", "muted"))
      end
      if not coverage.complete then
        table.insert(badges, ui.badge("Incomplete", "warning"))
      end
    elseif coverage.state == "running" then
      table.insert(badges, ui.badge("Running tests", "accent"))
    end
  elseif state.mode == "debug" and state.debug.snap then
    local snap = state.debug.snap
    local word = DEBUG_WORDS[snap.debug.state] or { tostring(snap.debug.state), "muted" }
    table.insert(badges, ui.badge(word[1], word[2]))
    if active(state.debug) and snap.controller ~= "you" then
      table.insert(badges, ui.badge("Observing", "muted"))
    end
  end
  for index, badge in badges do
    badge.p.key = "badge" .. index
  end
  return badges
end

local function head(state)
  -- The file name is the title; the meta adds its folders inside the project and the project.
  local facts = state.relative or state.path
  if state.project then
    facts = (facts ~= state.name and (facts .. " · ") or "") .. state.project
  end
  local right = overlay_badges(state)
  table.insert(
    right,
    ui.button("Edit in Tern", {
      key = "edit",
      role = "source-edit",
      icon = "file",
      keys = { "e" },
      title = "Open " .. state.path .. " in Tern's editor at line " .. state.caret,
      href = source.file_url(state.path, state.caret),
      actions = { click = "open" },
    })
  )
  table.insert(
    right,
    ui.node("tabs", {
      key = "overlay",
      role = "source-overlays",
      variant = "segmented",
      active = state.mode,
      items = {
        { id = "none", label = "None" },
        { id = "coverage", label = "Coverage" },
        { id = "debug", label = "Debug" },
        { id = "hotness", label = { ui.span("Hotness", "dim") }, disabled = HOTNESS_REASON },
      },
    })
  )
  -- Both halves wrap rather than overflow a narrow pane.
  local title = ui.text({ ui.span(state.name, "title"), ui.span("   " .. facts, "muted") })
  title.p.basis = "content"
  return ui.node("row", { key = "head", justify = "between", align = "center", gap = "md", wrap = true }, {
    title,
    ui.node("row", { key = "end", gap = "sm", align = "center", wrap = true }, right),
  })
end

local function error_card(title, message, act)
  return ui.card(title, {
    ui.button("Retry", { key = "end", icon = "repeat", keys = { "r" }, actions = { click = act } }),
    ui.code(message),
  }, { key = "status", role = "source-error", tone = "error", ["end"] = "main.status.end" })
end

local function inline_empty(title, text, button, tone)
  return ui.node(
    "empty",
    { key = "status", role = "source-empty", variant = "inline", frame = true, title = title, text = text, tone = tone },
    button and { button } or nil
  )
end

local function run_button(variant)
  return ui.button("Run with coverage", {
    key = "run",
    role = "source-run-coverage",
    variant = variant,
    size = "sm",
    icon = "play",
    keys = { "t" },
    actions = { click = "run_coverage" },
  })
end

local function bar(description, buttons)
  local text = ui.text(description)
  text.p.basis = "content"
  return ui.node("row", { key = "status", role = "source-bar", justify = "between", align = "center", wrap = true }, {
    text,
    ui.node("buttons", { key = "actions", label = "Overlay actions", basis = "content" }, buttons),
  })
end

local function coverage_status(state)
  local coverage = state.coverage
  if coverage.state == "missing" then
    return inline_empty(
      "No coverage yet",
      "Run the project's tests with coverage to mark covered and uncovered lines.",
      run_button("primary")
    )
  elseif coverage.state == "running" then
    return ui.node("shimmer", { key = "status", role = "source-loading", text = "Running tests with coverage…" })
  elseif coverage.state == "loading" or coverage.state == "idle" then
    return ui.node("shimmer", { key = "status", role = "source-loading", text = "Fetching coverage…" })
  elseif coverage.state == "absent" then
    return inline_empty(
      "This file wasn't measured",
      "The latest coverage run measured other files.",
      run_button("default")
    )
  elseif coverage.state == "unavailable" then
    return inline_empty("No coverage for this run", coverage.message, run_button("default"), "warning")
  elseif coverage.state == "error" then
    return error_card("Couldn't fetch coverage", coverage.error or "", "refresh")
  end
  return bar({
    ui.span("Run ", "muted"),
    ui.span(tostring(coverage.run), "mono"),
    ui.span(" · " .. coverage.covered .. " of " .. coverage.total .. " measured lines covered", "muted"),
  }, {
    ui.button("Refresh", { key = "refresh", icon = "repeat", keys = { "r" }, actions = { click = "refresh" } }),
    run_button("default"),
  })
end

local function debug_status(state)
  local debug = state.debug
  if not source.debuggable(state.path) then
    return inline_empty("Can't debug this file", "Debugging takes JavaScript, TypeScript or Python sources.")
  end
  local target = debug.snap and debug.snap.debug
  local live = active(debug)
  local description
  if debug.error then
    description = { ui.span(debug.error, "error") }
  elseif debug.launching then
    description = { ui.span("Launching " .. state.relative .. "…", "muted") }
  elseif not live then
    local count = #state.breakpoints
    description = {
      ui.span(count == 0 and "No breakpoints" or (count .. (count == 1 and " breakpoint" or " breakpoints")), "muted"),
      ui.span(" · launch runs " .. state.relative, "muted"),
    }
  elseif target.state == "stopped" then
    description = debug.stop and { ui.span("Paused at line ", "muted"), ui.span(tostring(debug.stop), "mono") }
      or { ui.span("Paused in ", "muted"), ui.span(debug.elsewhere or "another file", "mono") }
  else
    description = { ui.span((DEBUG_WORDS[target.state] or { target.state })[1], "muted") }
  end
  local buttons
  if not live then
    buttons = {
      ui.button("Launch", {
        key = "launch",
        role = "source-debug-launch",
        variant = "primary",
        icon = "bug",
        keys = { "f5" },
        busy = debug.launching,
        disabled = state.attach ~= "ready" and "Attaching to the project" or nil,
        actions = { click = "launch" },
      }),
    }
  else
    local why = nil
    if debug.snap.controller ~= "you" then
      why = "Another attachment controls this target"
    elseif target.state ~= "stopped" then
      why = "The target is not paused"
    end
    local function control(label, act, keys, icon)
      return ui.button(label, {
        key = act,
        role = "source-debug-" .. act,
        icon = icon,
        keys = keys,
        disabled = why or nil,
        busy = target.pending == true,
        actions = { click = act },
      })
    end
    buttons = {
      control("Continue", "continue", { "f5" }, "play"),
      control("Step over", "next", { "f10" }),
      control("Step in", "step_in", { "f11" }),
      control("Step out", "step_out", { "shift", "f11" }),
      ui.button("Stop", {
        key = "stop",
        role = "source-debug-stop",
        keys = { "shift", "f5" },
        disabled = debug.snap.controller ~= "you" and "Another attachment controls this target" or nil,
        actions = { click = "stop" },
      }),
    }
  end
  return bar(description, buttons)
end

local function status(state)
  if state.mode == "none" or state.mode == "hotness" then
    return nil
  end
  if not state.root then
    return inline_empty("No Elide project", "Overlays need an elide.pkl in this file's folder or a parent.")
  end
  if state.attach == "attaching" or state.attach == "idle" then
    return ui.node("shimmer", {
      key = "status",
      role = "source-loading",
      text = "Attaching to " .. (state.project or string.match(state.root, "([^/]+)$") or "the project") .. "…",
    })
  end
  if state.attach == "error" then
    return error_card("Couldn't attach to the project", state.attach_error or "", "retry")
  end
  if state.mode == "coverage" then
    return coverage_status(state)
  end
  return debug_status(state)
end

local LEGENDS = {
  none = { { { "up", "down" }, "line" }, { { "tab" }, "overlay" }, { { "e" }, "edit" }, { { "q" }, "close" } },
  coverage = {
    { { "up", "down" }, "line" },
    { { "tab" }, "overlay" },
    { { "t" }, "run with coverage" },
    { { "r" }, "refresh" },
    { { "e" }, "edit" },
    { { "esc" }, "no overlay" },
  },
  debug = {
    { { "up", "down" }, "line" },
    { { "b" }, "breakpoint" },
    { { "f5" }, "launch/continue" },
    { { "f10" }, "over" },
    { { "f11" }, "in" },
    { { "shift+f11" }, "out" },
    { { "g" }, "stop line" },
    { { "tab" }, "overlay" },
    { { "esc" }, "no overlay" },
  },
}

local function legend(state)
  local spans = {}
  for _, entry in LEGENDS[state.mode] or LEGENDS.none do
    for _, name in entry[1] do
      table.insert(spans, ui.span(name, "key"))
    end
    table.insert(spans, ui.span(" " .. entry[2] .. "  ", "muted"))
  end
  return ui.node("text", { key = "keys", role = "source-keys", spans = spans })
end

local function problem_view(state)
  return {
    main = ui.col({
      ui.node("empty", {
        key = "problem",
        role = "source-problem",
        icon = "file",
        title = state.problem.title,
        text = state.problem.text,
        grow = 1,
      }, {
        ui.button("Edit in Tern", {
          key = "edit",
          icon = "file",
          href = source.file_url(state.path),
          actions = { click = "open" },
        }),
      }),
    }),
  }
end

local function read(path)
  local ok, text = pcall(tern.fs.read, path, source.MAX_BYTES)
  if not ok then
    local message = tostring(text)
    local lowered = string.lower(message)
    if string.find(lowered, "large") or string.find(lowered, "exceed") or string.find(lowered, "limit") then
      return nil,
        {
          title = "File too large",
          text = "Elide source shows files up to " .. (source.MAX_BYTES // 1024) .. " KiB; edit it in Tern instead.",
        }
    end
    return nil, { title = "Can't read this file", text = message }
  end
  if not source.text(text) then
    return nil,
      { title = "Not a text file", text = "Elide source shows UTF-8 text; this file is binary or another encoding." }
  end
  return text, nil
end

-- The nearest folder holding elide.pkl, from the file's folder up.
local function find_root(path)
  local dir = string.match(path, "^(.*)/[^/]*$")
  for _ = 1, 64 do
    if not dir or dir == "" then
      return nil
    end
    if tern.fs.exists(dir .. "/elide.pkl") then
      return dir
    end
    dir = string.match(dir, "^(.*)/[^/]*$")
  end
  return nil
end

tern.block.define("source", {
  font = "sans",
  init = function(cx, args, saved)
    local path = args[1] or ""
    if string.sub(path, 1, 1) ~= "/" and cx.cwd then
      path = cx.cwd .. "/" .. path
    end
    local root = args[2]
    if root == "" or (root and not source.relative(path, root)) then
      root = nil
    end
    root = root or find_root(path)
    saved = type(saved) == "table" and saved or {}
    local state = {
      pane = cx.pane,
      path = path,
      name = string.match(path, "([^/]+)$") or path,
      root = root,
      relative = root and source.relative(path, root),
      project = root and string.match(root, "([^/]+)$"),
      lang = source.lang(path),
      mode = table.find(OVERLAYS, saved.mode) and saved.mode ~= "hotness" and saved.mode or "none",
      breakpoints = {},
      caret = 1,
      attach = "idle",
      coverage = { state = "idle" },
      debug = { verified = {} },
      timers = {},
    }
    for _, line in (type(saved.breakpoints) == "table" and saved.breakpoints or {}) do
      if type(line) == "number" then
        table.insert(state.breakpoints, line)
      end
    end
    table.sort(state.breakpoints)
    local text, problem = read(path)
    state.text, state.problem = text or "", problem
    state.index = source.index(state.text)
    move(state, tonumber(args[3]) or saved.caret or 1)
    state.top = source.scroll(0, state.caret, visible(cx), state.index.count)
    blocks[cx.pane] = state
    if not problem then
      attach(state, cx)
      tern.timer(0, function()
        if alive(state) then
          cx:frame({ { "focus", "main.editor" } })
        end
      end)
    end
    return state
  end,
  title = function(state)
    return state.name
  end,
  view = function(state, cx)
    if state.problem then
      return problem_view(state)
    end
    local shown = visible(cx)
    state.top = source.scroll(state.top or 0, state.caret, shown, state.index.count)
    local gutter, virt, decor = lines_view(state)
    local children = { head(state) }
    local note = status(state)
    if note then
      table.insert(children, note)
    end
    table.insert(
      children,
      ui.node("editor", {
        key = "editor",
        role = "source-editor",
        aria = state.name,
        text = state.text,
        cursor = state.index.starts[state.caret],
        readonly = true,
        lang = state.lang,
        nowrap = true,
        maxLines = shown,
        topline = state.top,
        followCursor = false,
        gutter = gutter,
        virt = virt,
        decor = decor,
      })
    )
    return {
      main = ui.node("col", { gap = "md" }, children),
      dock = ui.col({ legend(state) }),
    }
  end,
  key = function(state, key, cx)
    if key.meta or key.ctrl or key.alt or state.problem then
      return false
    end
    local name = key.name
    local page = visible(cx) - 1
    if name == "tab" then
      cycle(state, cx, key.shift and -1 or 1)
    elseif name == "up" or name == "k" then
      move(state, state.caret - 1)
    elseif name == "down" or name == "j" then
      move(state, state.caret + 1)
    elseif name == "page_up" then
      move(state, state.caret - page)
    elseif name == "page_down" then
      move(state, state.caret + page)
    elseif name == "home" then
      move(state, 1)
    elseif name == "end" then
      move(state, state.index.count)
    elseif name == "e" then
      cx:open(source.file_url(state.path, state.caret))
      return false
    elseif name == "escape" then
      if state.mode == "none" then
        return false
      end
      set_mode(state, cx, "none")
    elseif name == "q" then
      close(state)
      cx:exit(0)
    elseif name == "r" and state.attach == "error" then
      attach(state, cx)
    elseif state.mode == "coverage" and name == "r" then
      load_coverage(state, cx, true)
    elseif state.mode == "coverage" and name == "t" then
      run_coverage(state, cx)
    elseif state.mode == "debug" and state.attach == "ready" then
      if name == "b" then
        toggle_breakpoint(state, cx)
      elseif (name == "f5" and key.shift) or name == "x" then
        step(state, cx, "stop")
      elseif name == "f5" or name == "c" then
        step(state, cx, "continue")
      elseif name == "f10" or name == "n" then
        step(state, cx, "next")
      elseif (name == "f11" and key.shift) or name == "o" then
        step(state, cx, "step_out")
      elseif name == "f11" or name == "s" then
        step(state, cx, "step_in")
      elseif name == "g" and state.debug.stop then
        move(state, state.debug.stop)
      else
        return false
      end
    else
      return false
    end
    return true
  end,
  event = function(state, ev, cx)
    if ev.ev == "select" and ev.id == "main.head.end.overlay" then
      set_mode(state, cx, ev.item)
    elseif ev.ev == "focus" then
      cx:frame({ { "focus", "main.editor" } })
    elseif ev.ev == "action" then
      local act = ev.act
      if act == "open" then
        cx:open(source.file_url(state.path, state.caret))
      elseif act == "retry" then
        attach(state, cx)
      elseif act == "refresh" then
        load_coverage(state, cx, true)
      elseif act == "run_coverage" then
        run_coverage(state, cx)
      elseif act == "launch" then
        launch(state, cx)
      elseif act == "continue" or act == "next" or act == "step_in" or act == "step_out" or act == "stop" then
        step(state, cx, act)
      end
    end
  end,
  save = function(state)
    return { mode = state.mode, caret = state.caret, breakpoints = tern.json.array(state.breakpoints) }
  end,
})
