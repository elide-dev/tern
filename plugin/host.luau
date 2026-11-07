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
local parser = require("./lib/diagnostics")

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

-- Compiler output (`elide build`, `elide javac`, `elide kotlinc`) as diagnostic cards grouped
-- by file, each with an `elide://source` link; raw output when nothing parses. The parser is
-- shared with the source block's Diagnostics overlay and mirrors the runtime's.
-- A path as the lens shows it: relative to the command's directory when it lies inside it.
local function shown_path(path, cwd)
  if path and cwd and cwd ~= "" and string.sub(path, 1, #cwd + 1) == cwd .. "/" then
    return string.sub(path, #cwd + 2)
  end
  return path
end

local function diagnostic_node(d, cwd)
  local notes = {}
  for _, text in d.notes do
    table.insert(notes, text)
  end
  for _, text in d.suggestions do
    table.insert(notes, text)
  end
  local diag = {
    severity = d.severity,
    code = d.code,
    message = d.message,
    path = shown_path(d.path, cwd),
    line = d.line,
    col = d.col,
    snippet = d.excerpt and { d.excerpt.first_line, d.excerpt.text } or nil,
    notes = #notes > 0 and notes or nil,
  }
  local ok, card = pcall(ui.diagnostic, diag, cwd)
  if not ok then
    -- An excerpt the builder rejects should not cost the rest of the card.
    diag.snippet = nil
    card = ui.diagnostic(diag, cwd)
  end
  return card
end

local function count_spans(counts)
  local spans = {}
  for _, entry in { { "error", "error", "errors" }, { "warning", "warning", "warnings" }, { "note", "note", "notes" } } do
    local n = counts[entry[1]] or 0
    if n > 0 then
      table.insert(
        spans,
        ui.span("  " .. n .. " " .. (n == 1 and entry[2] or entry[3]), entry[1] == "note" and "info" or entry[1])
      )
    end
  end
  return spans
end

tern.lens.define("build", {
  open = function(run)
    local state = buffer()
    state.cwd = run.cwd
    -- Parsed as lines arrive; `view` (up to every 250 ms) reads only what is new.
    state.session = parser.session(run.cwd)
    return state
  end,
  line = function(state, l)
    local before = #state.lines
    collect(state, l)
    if #state.lines > before then
      state.session:add(l.text)
    end
  end,
  finish = function() end,
  view = function(state)
    if state.truncated then
      return nil
    end
    local kept, counts = parser.collect(state.session:result())
    if #kept == 0 then
      return nil
    end
    local phrase = parser.phrase(counts.error, counts.warning, counts.note)
    local children = {
      ui.text({ ui.span(phrase, counts.error > 0 and "error" or counts.warning > 0 and "warning" or "info") }),
    }
    local shown = 0
    for _, group in parser.by_file(kept) do
      if shown >= MAX_DIAGNOSTICS then
        break
      end
      local cards = {}
      for _, d in group.items do
        if shown >= MAX_DIAGNOSTICS then
          break
        end
        shown += 1
        table.insert(cards, diagnostic_node(d, state.cwd))
        local href = parser.link(d)
        if href then
          local name = string.match(d.path, "([^/]+)$") or d.path
          table.insert(
            cards,
            ui.text({ ui.link("Open " .. name .. (d.line and (":" .. d.line) or ""), href, "muted") })
          )
        end
      end
      local head = {
        group.path and ui.path(shown_path(group.path, state.cwd), state.cwd) or ui.span("Without a file", "muted"),
      }
      for _, span in count_spans(group.counts) do
        table.insert(head, span)
      end
      table.insert(children, ui.section(head, cards))
    end
    local hidden = #kept - shown + counts.dropped
    if hidden > 0 then
      table.insert(children, ui.overflow(hidden))
    end
    return ui.col(children)
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

-- `elide.source`: Elide's code editor block. One source file in Tern's `editor` node, edited by the
-- program (plugin/lib/buffer.luau), with coverage and debugger overlays from the shared project
-- session drawn in its gutter, end-of-line notes and decorations (docs/architecture.md, "Source
-- block"). Launch arguments: the absolute file, then optionally the project root and a line.
local broker = require("./lib/broker")
local buffer = require("./lib/buffer")
local links = require("./lib/links")
local source = require("./lib/source")

local RENEW_MS = 30000
local DEBUG_POLL_MS = 500
local RUN_POLL_MS = 1000
local DISK_POLL_MS = 2000
-- Unsaved text up to this size survives a plugin reload or daemon restart through `save`.
local MAX_DRAFT = 64 * 1024
local MAX_MATCHES = 2000
-- Tern's highlighter recolors the whole text on every change to the editor node, so its cost grows
-- faster than the file (measured per keystroke: 0.1 s at 300 lines, 0.3-0.6 s at 900, 3.5 s at
-- 2,000, over 10 s at 5,000). Larger files are shown as plain text.
local HIGHLIGHT_LINES = 600
-- Accenting the caret line's number resends the whole gutter on every line move.
local ACCENT_LINES = 2000
local OVERLAYS = { "none", "coverage", "debug", "diagnostics", "hotness" }
-- The largest build report read for the Diagnostics overlay (500 diagnostics fit well within it).
local DIAGNOSTICS_BYTES = 8 * 1024 * 1024
local DIAGNOSTIC_SIGNS = { error = "●", warning = "▲", note = "•" }
local DIAGNOSTIC_TONES = { error = "error", warning = "warning", note = "info" }
local HOTNESS_REASON = "Profiles are not source-located yet: the broker has no project_profile_page operation."
local DEBUG_WORDS = {
  starting = { "Starting", "accent" },
  running = { "Running", "accent" },
  stopped = { "Paused", "pending" },
  stopping = { "Stopping", "muted" },
  exited = { "Exited", "muted" },
  failed = { "Failed", "error" },
}
local LANG_NAMES =
  { javascript = "JavaScript", typescript = "TypeScript", python = "Python", kotlin = "Kotlin", java = "Java" }
local FIELDS = { find = "dock.find.query", go = "dock.go.line" }

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

local function identity(count)
  local map = {}
  for i = 1, count do
    map[i] = i
  end
  return map
end

-- Current line -> line of a measurement's source (overlay `name`), or nil for lines added since.
local function base_line(state, name, line)
  local map = state.buf.maps[name]
  local base = map and map[line]
  return base or nil
end

-- Measurement line -> current line, for marks the broker reports by measured line.
local function current_line(state, name, line)
  local map = state.buf.maps[name]
  if not map then
    return line
  end
  for i, base in map do
    if base == line then
      return i
    end
  end
  return nil
end

local function focus(state, cx, field)
  state.focus = field
  local id = FIELDS[field] or "main.editor"
  tern.timer(0, function()
    if alive(state) then
      cx:frame({ { "focus", id } })
    end
  end)
end

-- Scrolls the program's way once (go to line, find, a new stop): the next view sends `topline`.
local function reveal(state, line)
  state.jump = line
end

-- Project attachment ---------------------------------------------------------------------------

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
    if name ~= "disk" then
      timer:cancel()
      state.timers[name] = nil
    end
  end
  state.debug.polling = false
  cx:render()
end

local load_coverage, poll_debug, overlay_modes

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

-- Compares the artifact's measured source identity with the file on disk (sha256 of its UTF-16BE
-- text, hashed by the system's shasum/sha256sum): a mismatch marks every measured line stale.
local function check_identity(state, cx, digest, token)
  local coverage = state.coverage
  if
    type(digest) ~= "table"
    or (digest.algorithm ~= "sha256" and digest.algorithm ~= "sha256-utf16be")
    or type(digest.value) ~= "string"
  then
    return
  end
  local encoded = tern.base64.encode(source.utf16be(state.disk))
  pcall(function()
    tern.process.run({
      "/bin/sh",
      "-c",
      "base64 -d | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; }",
    }, { stdin = encoded, timeout_ms = 10000 }, function(result)
      if not alive(state) or coverage.token ~= token or result.status ~= 0 then
        return
      end
      local value = string.match(result.stdout or "", "^(%x+)")
      if value and string.lower(value) ~= string.lower(digest.value) then
        coverage.stale = true
        cx:render()
      end
    end)
  end)
end

-- Fetches this file's measured lines from the newest coverage run, paging through `next`. The marks
-- are anchored to the text on disk when they land and follow edits from there.
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
  coverage.state, coverage.run, coverage.error, coverage.stale = "loading", run.id, nil, false
  local token = {}
  coverage.token = token
  local function current()
    return alive(state) and coverage.token == token
  end
  local function broken(err)
    coverage.state, coverage.error = "error", tostring(err or "Invalid coverage page.")
    cx:render()
  end
  local function lines(file, offset, found)
    broker.project({
      op = "project_coverage_page",
      binding = state.binding,
      run = run.id,
      file = file.index,
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
        lines(file, page.next, found)
        return
      end
      coverage.marks, coverage.covered, coverage.total = source.coverage(found)
      coverage.complete = page.complete ~= false
      coverage.state = "ready"
      -- Measured against the file on disk. Marks follow later edits by line; lines whose text
      -- differs from the measured text (unsaved edits included) draw dimmed.
      coverage.lines = buffer.new(state.disk).lines
      -- Anchored to the disk text it measured; a dirty buffer's lines map through what changed.
      state.buf.maps.coverage = source.line_map(coverage.lines, state.buf.lines)
      check_identity(state, cx, file.sourceDigest, token)
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
          lines(file, 0, {})
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

local function move_to(state, line)
  local buf = state.buf
  line = math.max(1, math.min(line, #buf.lines))
  buffer.go(buf, { l = line, c = 0 }, false)
  buffer.home(buf, false)
end

local function absorb_debug(state, snap)
  local debug = state.debug
  if type(snap) ~= "table" or type(snap.debug) ~= "table" then
    debug.snap, debug.stop, debug.verified, debug.elsewhere = nil, nil, {}, nil
    return
  end
  local target = snap.debug
  if target.generation ~= debug.generation then
    -- A target launched elsewhere ran the file on disk; anchor its lines there, through any unsaved
    -- edits.
    if not debug.launched_here then
      state.buf.maps.debug = source.line_map(buffer.new(state.disk).lines, state.buf.lines)
    end
    debug.launched_here = false
  end
  debug.snap, debug.stop, debug.elsewhere = snap, nil, nil
  local frame = type(target.frames) == "table" and target.frames[1] or nil
  if target.state == "stopped" and type(frame) == "table" then
    if same(state, frame.path) then
      debug.stop = current_line(state, "debug", frame.line)
    else
      debug.elsewhere = tostring(frame.path or "?") .. ":" .. tostring(frame.line or "?")
    end
  end
  if debug.stop and target.stop_epoch ~= debug.epoch then
    move_to(state, debug.stop)
    reveal(state, debug.stop)
  end
  debug.epoch = target.stop_epoch
  local verified, requested = {}, {}
  for _, point in (type(target.breakpoints) == "table" and target.breakpoints or {}) do
    if type(point) == "table" and same(state, point.path) then
      local line = current_line(state, "debug", point.requested_line)
      if line then
        verified[line] = point
        table.insert(requested, line)
      end
    end
  end
  debug.verified = verified
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

-- Breakpoint lines in the target's coordinates (lines added since its launch have none).
local function target_lines(state)
  local lines = {}
  for _, line in state.breakpoints do
    local base = base_line(state, "debug", line)
    if base then
      table.insert(lines, base)
    end
  end
  table.sort(lines)
  return lines
end

local function launch(state, cx)
  local debug = state.debug
  if state.attach ~= "ready" or debug.launching then
    return
  end
  local points = {}
  for _, line in state.breakpoints do
    table.insert(points, { path = state.relative, line = line })
  end
  local lang = source.lang(state.path)
  local test = source.test_file(state.path) and (lang == "javascript" or lang == "typescript")
  debug.launching, debug.error, debug.launched_here = true, nil, true
  state.buf.maps.debug = identity(#state.buf.lines)
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

local function toggle_breakpoint(state, cx)
  if not source.debuggable(state.path) then
    cx:toast("info", "Debugging takes JavaScript, TypeScript or Python sources.")
    return
  end
  local line = state.buf.cursor.l
  local target = nil
  if active(state.debug) then
    target = controllable(state, cx)
    if not target then
      return
    end
    if not base_line(state, "debug", line) then
      cx:toast("info", "This line was added after the target launched; save and launch again to break on it.")
      return
    end
  end
  state.breakpoints = source.toggle(state.breakpoints, line)
  if target then
    request(state, cx, target, {
      kind = "breakpoints",
      path = state.relative,
      lines = tern.json.array(target_lines(state)),
    })
  end
end

-- Saving and the disk --------------------------------------------------------------------------

local function read(path)
  local ok, text = pcall(tern.fs.read, path, source.MAX_BYTES)
  if not ok then
    local message = tostring(text)
    local lowered = string.lower(message)
    if string.find(lowered, "large") or string.find(lowered, "exceed") or string.find(lowered, "limit") then
      return nil,
        {
          title = "File too large",
          text = "Elide source edits files up to "
            .. (source.MAX_BYTES // 1024)
            .. " KiB, the size it reads whole; open this one in Tern's editor.",
          large = true,
        }
    end
    return nil, { title = "Can't read this file", text = message }
  end
  if not source.text(text) then
    return nil,
      { title = "Not a text file", text = "Elide source edits UTF-8 text; this file is binary or another encoding." }
  end
  return text, nil
end

-- Writes the buffer. Returns true when written.
local function write(state, cx)
  local text = buffer.disk(state.buf)
  local ok, problem = pcall(tern.fs.write, state.path, text)
  if not ok then
    cx:toast("error", "Couldn't save " .. state.name, tostring(problem))
    return false
  end
  state.disk, state.missing = text, false
  buffer.mark_saved(state.buf)
  return true
end

-- ⌘S: asks before overwriting a file that changed on disk since it was loaded or saved.
local function save(state, cx)
  local current = read(state.path)
  if current and current ~= state.disk then
    state.confirm = {
      kind = "overwrite",
      title = state.name .. " changed on disk",
      text = "Saving replaces the version on disk with yours.",
      action = "Overwrite",
    }
    return
  end
  write(state, cx)
end

-- Replaces the buffer with the file on disk as one undoable step.
local function reload(state, text)
  local buf = state.buf
  local cursor = buf.cursor
  -- Only the changed middle is replaced, so breakpoints and overlay marks above and below it keep
  -- their lines.
  local edit = buffer.reload(buf, text)
  if edit then
    state.breakpoints = buffer.remap(state.breakpoints, edit)
  end
  buf.cursor = buffer.clamp(buf, cursor)
  state.disk = text
  buffer.mark_saved(buf)
end

-- Diagnostics ---------------------------------------------------------------------------------

-- Where `elide build` keeps each run's `diagnostics.json` (Elide crates/cli/src/building.rs).
local function diagnostics_dir(state)
  return state.root .. "/.dev/reports/build/tern"
end

-- The text of the line a diagnostic names, from its excerpt, or nil when the excerpt lacks it.
local function excerpt_line(d)
  local excerpt = d.excerpt
  if not excerpt or not d.line then
    return nil
  end
  local index, position = d.line - excerpt.first_line + 1, 0
  for text in string.gmatch(excerpt.text .. "\n", "([^\n]*)\n") do
    position += 1
    if position == index then
      return text
    end
  end
  return nil
end

-- This file's diagnostics by current line, built once per edit (keyed by the block's revision),
-- leaving out each one whose line no longer reads as its excerpt: edited since the build, so it
-- may be fixed. Returns `{ [line] = { d, … } }` and the live count per severity.
local function live_diagnostics(state)
  local diag = state.diag
  local map = state.buf.maps.diagnostics
  local stamp = state.revision or 0
  if diag.live and diag.live_map == map and diag.live_items == diag.items and diag.live_stamp == stamp then
    return diag.live, diag.live_counts
  end
  local inverse = {}
  if map then
    for line, base in map do
      inverse[base] = line
    end
  end
  local live, counts = {}, { error = 0, warning = 0, note = 0 }
  for _, d in diag.items or {} do
    local line = if map then inverse[d.line] else d.line
    if line and (d.wanted == nil or state.buf.lines[line] == d.wanted) then
      live[line] = live[line] or {}
      table.insert(live[line], d)
      counts[d.severity] += 1
    end
  end
  diag.live, diag.live_counts, diag.live_map, diag.live_items, diag.live_stamp = live, counts, map, diag.items, stamp
  return live, counts
end

-- Reads run `run`'s report and keeps this file's diagnostics, by line.
local function load_report(state, cx, run)
  local path = diagnostics_dir(state) .. "/" .. run .. "/diagnostics.json"
  local ok, decoded = pcall(function()
    return tern.json.decode(tern.fs.read(path, DIAGNOSTICS_BYTES))
  end)
  local report = ok and parser.report(decoded) or nil
  local diag = state.diag
  if not report then
    diag.state, diag.error = "error", "Could not read the build report " .. path
    cx:render()
    return
  end
  local items, counts = {}, { error = 0, warning = 0, note = 0 }
  for _, d in report.diagnostics do
    if d.line and same(state, d.path) then
      table.insert(items, d)
      counts[d.severity] += 1
    end
  end
  table.sort(items, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return (a.col or 0) < (b.col or 0)
  end)
  -- The build compiled the file on disk; anchor its lines there, through any unsaved edits.
  state.buf.maps.diagnostics = source.line_map(buffer.new(state.disk).lines, state.buf.lines)
  for _, d in items do
    d.wanted = excerpt_line(d)
  end
  diag.state, diag.error, diag.run, diag.report, diag.items, diag.counts = "ready", nil, run, report, items, counts
  diag.live = nil
  cx:render()
end

-- Calls `done(run)` with the newest of `runs` (run directories under `dir` that hold a report).
-- Run directories are named at random and the report has no timestamp, so this asks `ls -t`
-- (a run's directory changes when its report lands), off the block's thread.
local function newest_run(dir, runs, done)
  if #runs == 1 then
    done(runs[1])
    return
  end
  local wanted = {}
  for _, run in runs do
    wanted[run] = true
  end
  local started = pcall(function()
    tern.process.run({ "/bin/ls", "-t", dir }, { timeout_ms = 5000 }, function(result)
      for name in string.gmatch(result.stdout or "", "[^\n]+") do
        if wanted[name] then
          done(name)
          return
        end
      end
      done(runs[#runs])
    end)
  end)
  if not started then
    done(runs[#runs])
  end
end

-- Run directories still waiting for their report are looked at again on each poll, up to this
-- many (a run killed before writing one would otherwise be polled forever).
local PENDING_RUNS = 8

-- Finds the newest build report under the project and loads it when the set of reports changed.
-- One listing per poll; a run directory is checked for `diagnostics.json` when it first appears
-- and while its report is pending, not on every poll.
local function scan_diagnostics(state, cx)
  local diag = state.diag
  if not state.root or diag.scanning then
    return
  end
  local dir = diagnostics_dir(state)
  local ok, names = pcall(tern.fs.list, dir)
  diag.known = diag.known or {}
  local present, changed = {}, false
  for _, name in (ok and names or {}) do
    if string.sub(name, 1, 4) == "run-" then
      present[name] = true
      local known = diag.known[name]
      if known == nil then
        diag.pending = diag.pending or {}
        table.insert(diag.pending, name)
        diag.known[name] = false
      end
    end
  end
  for name in diag.known do
    if not present[name] then
      diag.known[name] = nil
      changed = true
    end
  end
  local pending = {}
  for _, name in diag.pending or {} do
    if present[name] and diag.known[name] == false then
      if tern.fs.exists(dir .. "/" .. name .. "/diagnostics.json") then
        diag.known[name] = true
        changed = true
      else
        table.insert(pending, name)
      end
    end
  end
  while #pending > PENDING_RUNS do
    table.remove(pending, 1)
  end
  diag.pending = pending
  if not changed and diag.scanned then
    return
  end
  diag.scanned = true
  local runs = {}
  for name, reported in diag.known do
    if reported then
      table.insert(runs, name)
    end
  end
  table.sort(runs)
  if #runs == 0 then
    if diag.report then
      state.diag = { state = "none", known = diag.known, pending = diag.pending, scanned = true }
      if state.mode == "diagnostics" then
        state.mode = "none"
      end
      cx:render()
    end
    return
  end
  diag.scanning = true
  newest_run(dir, runs, function(run)
    diag.scanning = false
    if alive(state) then
      load_report(state, cx, run)
    end
  end)
end

-- Moves the caret to the next (`dir` 1) or previous (-1) diagnostic from the caret line, wrapping.
local function step_diagnostic(state, dir)
  local items = state.diag.state == "ready" and state.diag.items or {}
  if #items == 0 then
    return
  end
  local caret = state.buf.cursor.l
  local lines = {}
  for line in live_diagnostics(state) do
    table.insert(lines, line)
  end
  table.sort(lines)
  if #lines == 0 then
    return
  end
  local target = dir > 0 and lines[1] or lines[#lines]
  if dir > 0 then
    for _, line in lines do
      if line > caret then
        target = line
        break
      end
    end
  else
    for index = #lines, 1, -1 do
      if lines[index] < caret then
        target = lines[index]
        break
      end
    end
  end
  move_to(state, target)
  reveal(state, target)
end

local function watch(state, cx)
  state.timers.disk = tern.timer(DISK_POLL_MS, function()
    state.timers.disk = nil
    if not alive(state) then
      close(state)
      return
    end
    if not tern.fs.exists(state.path) then
      if not state.missing then
        state.missing = true
        cx:render()
      end
    else
      local text = read(state.path)
      if state.missing then
        state.missing = false
        cx:render()
      end
      if text and text ~= state.disk and not state.confirm then
        if buffer.dirty(state.buf) then
          state.pending_disk = text
          state.confirm = {
            kind = "reload",
            title = state.name .. " changed on disk",
            text = "Reloading discards your unsaved changes; keep editing to save over it later.",
            action = "Reload",
          }
        else
          reload(state, text)
          cx:toast("info", "Reloaded " .. state.name .. " from disk.")
        end
        cx:render()
      end
    end
    scan_diagnostics(state, cx)
    watch(state, cx)
  end)
end

-- Runs `go` now when the buffer is saved, else after a "Save and …" confirm.
local function saved_then(state, label, go)
  if not buffer.dirty(state.buf) then
    go()
    return
  end
  state.confirm = {
    kind = "run",
    title = "Save " .. state.name .. " first?",
    text = "The project runs the file on disk, not your unsaved changes.",
    action = "Save and " .. label,
    tone = "accent",
    go = go,
  }
end

local function step(state, cx, kind)
  if kind == "continue" and not active(state.debug) then
    if not source.debuggable(state.path) then
      cx:toast("info", "Debugging takes JavaScript, TypeScript or Python sources.")
      return
    end
    saved_then(state, "launch", function()
      launch(state, cx)
    end)
    return
  end
  local target = controllable(state, cx)
  if not target then
    return
  end
  if kind == "pause" then
    if target.state ~= "running" then
      return
    end
  elseif kind ~= "stop" and target.state ~= "stopped" then
    return
  end
  request(state, cx, target, { kind = kind })
end

local function start_coverage(state, cx)
  saved_then(state, "run", function()
    run_coverage(state, cx)
  end)
end

local function confirmed(state, cx)
  local confirm = state.confirm
  state.confirm = nil
  if not confirm then
    return
  end
  if confirm.kind == "close" then
    close(state)
    cx:exit(0)
  elseif confirm.kind == "reload" then
    reload(state, state.pending_disk or state.disk)
    state.pending_disk = nil
  elseif confirm.kind == "overwrite" then
    write(state, cx)
  elseif confirm.kind == "run" then
    if write(state, cx) then
      confirm.go()
    end
  end
end

local function cancelled(state)
  local confirm = state.confirm
  state.confirm = nil
  if confirm and confirm.kind == "reload" then
    -- Keep editing: the disk version is now the one a save replaces.
    state.disk = state.pending_disk or state.disk
    state.pending_disk = nil
  end
end

-- Overlays, find and go to line ----------------------------------------------------------------

local function set_mode(state, cx, mode)
  if mode == "hotness" then
    cx:toast("info", HOTNESS_REASON)
    return
  end
  if mode == state.mode or not table.find(overlay_modes(state), mode) then
    return
  end
  state.mode = mode
  focus(state, cx, "editor")
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

local function refind(state)
  local find = state.find
  if not find then
    return
  end
  find.matches = buffer.find(state.buf, find.text, MAX_MATCHES)
  find.index = nil
end

-- Selects the next (`dir` 1) or previous match and scrolls it into view.
local function find_step(state, dir)
  local find = state.find
  if not find or #find.matches == 0 then
    return
  end
  local from = state.buf.cursor
  if dir < 0 then
    local a = buffer.selection(state.buf)
    from = a or from
  end
  local index = buffer.next_match(find.matches, from, dir)
  local match = find.matches[index]
  find.index = index
  state.buf.anchor = { l = match.l, c = match.from }
  state.buf.cursor = { l = match.l, c = match.to }
  state.buf.goal = nil
  reveal(state, match.l)
end

local function open_find(state, cx)
  local buf = state.buf
  local a, b = buffer.selection(buf)
  local text = state.find and state.find.text or ""
  if a and a.l == b.l then
    text = buffer.slice(buf, a, b)
  end
  state.find = { text = text, cursor = buffer.units(text), matches = {}, index = nil }
  state.go = nil
  refind(state)
  focus(state, cx, "find")
end

local function close_fields(state, cx)
  state.find, state.go = nil, nil
  focus(state, cx, "editor")
end

local function go_to(state, cx)
  local field = state.go
  if not field then
    return
  end
  local line, col = string.match(field.text, "^%s*(%d+)%s*:?%s*(%d*)%s*$")
  line = tonumber(line)
  if not line then
    return
  end
  local buf = state.buf
  line = math.max(1, math.min(line, #buf.lines))
  buffer.go(buf, { l = line, c = math.max(0, (tonumber(col) or 1) - 1) }, false)
  reveal(state, line)
  close_fields(state, cx)
end

-- After an edit: breakpoints follow their lines, find results follow the text.
local function edited(state, edit)
  -- Every edit, undo and redo passes here; cached views of the text key on this.
  state.revision = (state.revision or 0) + 1
  if edit then
    state.breakpoints = buffer.remap(state.breakpoints, edit)
    refind(state)
  end
end

-- View -----------------------------------------------------------------------------------------

-- Lines the editor shows: the pane's rows less the toolbar, the dock's fields and the status bar.
local function visible(state, cx)
  -- The toolbar row (it never wraps), the gaps around the editor and the status bar.
  local chrome = 5
  if state.find or state.go then
    chrome += 2
  end
  if state.confirm then
    chrome += 4
  end
  -- The stylesheet sets this editor's line height to 1.35em against the kit's 1.192 (15.5px at
  -- 13px), and maxLines counts lines of that height, so the rows available shrink by the ratio;
  -- half a line more goes to the padding above the first row.
  return math.max(4, math.floor(((cx.rows or 24) - chrome) * 1.192 / 1.35 - 0.5))
end

-- Gutter cells are `[sign 2][number][2]│[1]`: a two-cell sign column left of numbers right-aligned to the widest, so
-- every line's cell is the same width and toggling a breakpoint shifts nothing. Breakpoint lines
-- number in `error`, the paused line in `accent`, the caret line in the normal ink.
--
-- Line tints: every line carries one `mark <tone>` run on its first character at all times, `mark
-- dim` when nothing applies, so switching overlays changes tokens and never adds or removes runs (no
-- text moves). plugin/styles/source.css draws `mark dim` transparent and each tone as one band from
-- the text column to the row's edge (the run's opaque background repeated by overlapping box-shadows,
-- clipped by the scroller), fading between them. Past HIGHLIGHT_LINES only tinted lines get runs, to keep the decor small.
local function lines_view(state, starts)
  local buf = state.buf
  local count = #buf.lines
  -- The editor draws no line after a trailing newline, so neither does the gutter.
  local shown = (count > 1 and buf.lines[count] == "") and count - 1 or count
  local width = #tostring(shown)
  local gutter, virt, decor = {}, {}, {}
  local any_virt = false
  local debugging = state.mode == "debug"
  local debug = state.debug
  local points = {}
  if debugging then
    for _, line in state.breakpoints do
      points[line] = true
    end
  end
  local caret = count <= ACCENT_LINES and buf.cursor.l or nil
  local coverage = state.coverage
  local marks = state.mode == "coverage" and coverage.state == "ready" and coverage.marks or nil
  -- Diagnostics by current line (the first, most severe, leads), and their underline ranges.
  local problems, underlines = nil, {}
  if state.mode == "diagnostics" and state.diag.state == "ready" then
    problems = {}
    local rank = { error = 1, warning = 2, note = 3 }
    for line, list in live_diagnostics(state) do
      local lead = list[1]
      for _, d in list do
        if rank[d.severity] < rank[lead.severity] then
          lead = d
        end
      end
      problems[line] = { lead = lead, count = #list }
    end
  end
  local every = count <= HIGHLIGHT_LINES
  for line = 1, shown do
    -- Numbers are `dim`; the caret line's is in the normal ink (not `strong`, whose weight can widen
    -- the glyphs).
    local glyph, tone, number, note = " ", nil, line ~= caret and "dim" or nil, ""
    local tint = "dim"
    if marks then
      local base = base_line(state, "coverage", line)
      local mark = base and marks[base]
      if mark then
        local stale = coverage.stale or coverage.lines[base] ~= buf.lines[line]
        -- `inferred` lines inherit their block's coverage: the success tint at half strength.
        tint = stale and "muted"
          or (mark.state == "covered" and "success")
          or (mark.state == "inferred" and "success dim")
          or (mark.state == "partial" and "warning")
          or "error"
        if mark.state == "partial" and mark.branches and not stale then
          note = { ui.span(" " .. mark.branches.covered .. "/" .. mark.branches.total .. " branches", "muted") }
        end
      end
    elseif problems then
      local entry = problems[line]
      if entry then
        local d = entry.lead
        local mark = DIAGNOSTIC_TONES[d.severity]
        glyph, tone, number, tint = DIAGNOSTIC_SIGNS[d.severity], mark, mark, mark
        local message = string.gsub(d.message, "%s+", " ")
        if #message > 120 then
          message = string.sub(message, 1, 117) .. "…"
        end
        note = { ui.span("  " .. message, mark) }
        if entry.count > 1 then
          table.insert(note, ui.span(" +" .. (entry.count - 1), "muted"))
        end
        if d.col and d.col >= 1 then
          underlines[line] = { col = d.col, tone = mark }
        end
      end
    elseif debugging then
      if debug.stop == line then
        glyph, tone, number, tint = "▶", "accent", "accent", "accent"
        note = { ui.span(" paused", "accent") }
      elseif points[line] then
        local point = debug.verified and debug.verified[line]
        if point and not point.verified and active(debug) then
          glyph, tone, number = "○", "warning", "warning"
          note = { ui.span(" " .. (type(point.message) == "string" and point.message or "unverified"), "muted") }
        else
          glyph, tone, number, tint = "●", "error", "error", "error"
        end
      end
    end
    -- One run on the line's first character (one or two UTF-16 units); the stylesheet draws the
    -- row's band from it.
    local length = buf.lens[line]
    if length > 0 and (every or tint ~= "dim") then
      local first = string.byte(buf.lines[line], 1) >= 0xF0 and 2 or 1
      table.insert(decor, { from = starts[line], to = starts[line] + first, s = "mark " .. tint })
      -- The diagnostic's token gets Tern's dotted `typo` underline, after the band's run.
      local under = underlines[line]
      if under then
        local text = buf.lines[line]
        local word = string.match(string.sub(text, under.col), "^[%w_]+") or ""
        local from = math.max(under.col - 1, first)
        local to = math.min(under.col - 1 + math.max(#word, 1), length)
        if to > from and not string.find(string.sub(text, 1, under.col + #word), "[\128-\255]") then
          table.insert(decor, { from = starts[line] + from, to = starts[line] + to, s = "typo " .. under.tone })
        end
      end
    end
    -- As VS Code and IDEA lay it out: a two-cell sign column (the glyph and a cell of air, so a
    -- breakpoint, the paused arrow or a later marker never touches the pane edge, the digits or
    -- shifts anything), the number right-aligned to the widest, two cells of air ending in the
    -- hairline (the stylesheet borders this `muted` run) and one cell before the code: 2 + digits +
    -- 2 cells, the hairline, 1 cell.
    gutter[line] = {
      tone and ui.span(glyph, tone) or ui.span(glyph),
      ui.span(" "),
      number and ui.span(source.number(line, width), number) or ui.span(source.number(line, width)),
      ui.span("  ", "muted"),
      ui.span(" "),
    }
    virt[line] = note
    any_virt = any_virt or note ~= ""
  end
  local find = state.find
  if find and find.text ~= "" then
    for index, match in find.matches do
      table.insert(decor, {
        from = starts[match.l] + match.from,
        to = starts[match.l] + match.to,
        s = index == find.index and "mark info strong" or "mark info",
      })
    end
  end
  return gutter, any_virt and virt or nil, #decor > 0 and decor or nil, width
end

-- Whether the Coverage overlay has measured lines to draw.
local function coverage_ready(state)
  return state.mode == "coverage" and state.coverage.state == "ready"
end

-- The tone of a file's coverage percentage, shared by the badge and the status bar.
local function coverage_tone(percent)
  return percent >= 80 and "success" or percent >= 50 and "warning" or "error"
end

-- The overlay's state in words and tone, for the toolbar badge and the status bar.
local function overlay_state(state)
  if state.mode == "none" or state.mode == "hotness" then
    return nil
  end
  if state.mode == "diagnostics" then
    local diag = state.diag
    if diag.state == "error" then
      return "Report unreadable", "error", diag.error
    elseif diag.state ~= "ready" then
      return "Reading diagnostics…", "accent"
    end
    local _, counts = live_diagnostics(state)
    local phrase = parser.phrase(counts.error, counts.warning, counts.note)
    local report = diag.report
    local total = parser.phrase(report.errors, report.warnings, report.notes)
    local detail = "Latest build: "
      .. (total or "no diagnostics")
      .. (report.dropped > 0 and (", " .. report.dropped .. " not listed") or "")
    local changed = #diag.items - (counts.error + counts.warning + counts.note)
    if changed > 0 then
      detail = detail .. ". " .. changed .. " on lines edited since the build are hidden until the next build."
    end
    if not phrase then
      return "No diagnostics", "success", detail
    end
    return phrase, counts.error > 0 and "error" or counts.warning > 0 and "warning" or "info", detail
  end
  if state.attach == "attaching" or state.attach == "idle" then
    return "Attaching…", "accent", "Attaching to " .. (state.project or "the project")
  elseif state.attach == "error" then
    return "Attach failed", "error", state.attach_error
  end
  if state.mode == "coverage" then
    local coverage = state.coverage
    local s = coverage.state
    if s == "ready" then
      local percent = source.percent(coverage.covered, coverage.total)
      if not percent then
        return "No measured lines", "muted"
      end
      if coverage.stale then
        return percent .. "% · older version",
          "muted",
          "The file changed since this run measured it; its tints are muted."
      end
      return percent .. "% covered",
        coverage_tone(percent),
        coverage.covered .. " of " .. coverage.total .. " measured lines"
    elseif s == "running" then
      return "Running tests…", "accent"
    elseif s == "loading" or s == "idle" then
      return "Fetching coverage…", "accent"
    elseif s == "missing" then
      return "No coverage yet",
        "muted",
        "Run the project's tests with coverage (F5) to tint covered and uncovered lines."
    elseif s == "absent" then
      return "Not measured", "muted", "The latest coverage run measured other files."
    elseif s == "unavailable" then
      return "No coverage", "warning", coverage.message
    elseif s == "error" then
      return "Coverage failed", "error", coverage.error
    end
    return nil
  end
  local debug = state.debug
  if debug.error then
    return "Debugger error", "error", debug.error
  elseif debug.launching then
    return "Launching…", "accent", "Launching " .. tostring(state.relative)
  elseif debug.elsewhere then
    return "Paused elsewhere", "pending", debug.elsewhere
  elseif debug.snap then
    local target = debug.snap.debug
    if target.state == "stopped" then
      return debug.stop and ("Paused at " .. debug.stop) or "Paused", "pending"
    end
    local word = DEBUG_WORDS[target.state] or { tostring(target.state), "muted" }
    return word[1], word[2]
  end
  return nil
end

-- The overlays that can act here: coverage and debugging need a project, debugging a JavaScript,
-- TypeScript or Python source. Hotness stays hidden until the project session records
-- source-located profile samples.
function overlay_modes(state)
  local modes = { "none" }
  if state.root then
    table.insert(modes, "coverage")
    if source.debuggable(state.path) then
      table.insert(modes, "debug")
    end
    -- Diagnostics only once a build of this project left a report.
    if state.diag.report then
      table.insert(modes, "diagnostics")
    end
  end
  return modes
end

local function icon_button(key, label, icon, keys, act, extra)
  local props = {
    key = key,
    role = "source-btn-" .. key,
    icon = icon,
    title = label,
    aria = label,
    keys = keys,
    actions = { click = act },
  }
  for name, value in extra or {} do
    props[name] = value
  end
  return ui.button("", props)
end

-- Debug controls by context: none outside the Debug overlay, a single Launch while no target exists,
-- and the Debug surface's two wells (run control, stepping) while a target is launched, running or
-- paused.
local function debug_controls(state)
  -- Keycaps fit beside both wells only in wide panes; narrower ones keep the keys in the tooltips.
  local function caps(keys)
    return (state.cols or 200) >= 160 and keys or nil
  end
  local debug = state.debug
  if not source.debuggable(state.path) or state.attach ~= "ready" then
    return {}
  end
  if not active(debug) then
    return {
      icon_button("debug-launch", "Launch " .. state.name .. " (F5)", "play", { "f5" }, "launch", {
        variant = "primary",
        busy = debug.launching == true,
      }),
    }
  end
  local target = debug.snap.debug
  local reason = debug.snap.controller ~= "you" and "Another attachment controls this target" or nil
  local paused = target.state == "stopped"
  local busy = target.pending == true
  local step_reason = reason or (not paused and "The target is running") or nil
  return {
    ui.node("buttons", { key = "run", role = "source-debug-run", variant = "toolbar", label = "Run control" }, {
      icon_button("debug-resume", "Resume (F5)", "play", caps({ "f5" }), "continue", {
        variant = not step_reason and "primary" or nil,
        disabled = step_reason,
        busy = busy,
      }),
      icon_button("debug-pause", "Pause (F6)", "pause", caps({ "f6" }), "pause", {
        disabled = reason or (paused and "The target is already paused") or nil,
      }),
      icon_button("debug-stop", "Stop (⇧F5)", "stop", caps({ "shift", "f5" }), "stop", {
        variant = "danger",
        disabled = reason,
      }),
    }),
    ui.node("buttons", { key = "steps", role = "source-debug-steps", variant = "toolbar", label = "Stepping" }, {
      icon_button(
        "debug-next",
        "Step over (F10)",
        "redo",
        caps({ "f10" }),
        "next",
        { disabled = step_reason, busy = busy }
      ),
      icon_button("debug-step_in", "Step into (F11)", "arrow-down", caps({ "f11" }), "step_in", {
        disabled = step_reason,
        busy = busy,
      }),
      icon_button("debug-step_out", "Step out (⇧F11)", "arrow-up", caps({ "shift", "f11" }), "step_out", {
        disabled = step_reason,
        busy = busy,
      }),
    }),
  }
end

-- The keyboard menu lists only the shortcuts that act in the current state; its rows run them.
local function key_rows(state)
  local buf = state.buf
  local editing = true
  local rows = {}
  local function add(row)
    table.insert(rows, row)
  end
  add({ header = "File" })
  if buffer.dirty(buf) then
    add({ id = "save", label = "Save", icon = "save", keys = { "cmd", "S" } })
  end
  add({ id = "open", label = "Edit in Tern", icon = "open" })
  if editing then
    add({ header = "Edit" })
    if #buf.undo > 0 then
      add({ id = "undo", label = "Undo", icon = "undo", keys = { "cmd", "Z" } })
    end
    if #buf.redo > 0 then
      add({ id = "redo", label = "Redo", icon = "redo", keys = { "cmd", "shift", "Z" } })
    end
    if source.comment(state.path) then
      add({ id = "comment", label = "Toggle line comment", keys = { "cmd", "/" } })
    end
    add({ id = "line_below", label = "New line below", keys = { "cmd", "enter" } })
    add({ id = "select_all", label = "Select all", icon = "selection", keys = { "cmd", "A" } })
    add({ header = "Navigate" })
    add({ id = "find", label = "Find", icon = "search", keys = { "ctrl", "F" } })
    add({ id = "goto", label = "Go to line", icon = "hash", keys = { "ctrl", "G" } })
    add({ id = "wrap", label = "Soft wrap", icon = "corner-down-right", keys = { "alt", "Z" }, checked = state.wrap })
  end
  local modes = overlay_modes(state)
  if #modes > 1 then
    add({ header = "Overlays" })
    for index, mode in modes do
      add({
        id = "mode=" .. mode,
        label = mode == "none" and "No overlay" or (string.upper(string.sub(mode, 1, 1)) .. string.sub(mode, 2)),
        keys = { "alt", tostring(index) },
        radio = "overlay",
        checked = state.mode == mode,
      })
    end
  end
  if state.mode == "coverage" and state.attach == "ready" then
    add({ header = "Coverage" })
    add({ id = "run_coverage", label = "Run with coverage", icon = "run", keys = "F5" })
    if coverage_ready(state) then
      add({ id = "refresh", label = "Refresh coverage", icon = "repeat", keys = "F6" })
    end
  elseif state.mode == "diagnostics" and state.diag.state == "ready" and #state.diag.items > 0 then
    add({ header = "Diagnostics" })
    add({ id = "diag_next", label = "Next diagnostic", keys = "F8" })
    add({ id = "diag_prev", label = "Previous diagnostic", keys = { "shift", "F8" } })
  elseif state.mode == "debug" and state.attach == "ready" and source.debuggable(state.path) then
    add({ header = "Debug" })
    add({ id = "breakpoint", label = "Toggle breakpoint", keys = "F9" })
    if state.debug.stop then
      add({ id = "stop_line", label = "Go to the paused line", keys = "F7" })
    end
  end
  return rows
end

local function toolbar(state)
  local buf = state.buf
  local crumbs = {}
  local relative = state.relative or state.path
  local walked = state.relative and state.root or ""
  if state.project then
    table.insert(crumbs, { id = state.root, label = state.project })
  end
  for part in string.gmatch(relative, "[^/]+") do
    walked = walked .. "/" .. part
    table.insert(crumbs, { id = walked, label = part })
  end
  local dirty = buffer.dirty(buf)
  local left = {
    ui.node("breadcrumb", {
      key = "path",
      role = "source-path",
      variant = "path",
      -- The project and the file, the folders between folded into "…" so the row never wraps.
      max = 2,
      items = crumbs,
      shrink = 1,
    }),
  }
  -- The unsaved-changes dot, a little smaller than the text (the stylesheet sizes it). Its slot is
  -- always there, transparent while the file is saved, so the name and badge never move.
  local dot = ui.text({ ui.span("●", dirty and "warning" or "dim") })
  dot.p.key = "dirty"
  dot.p.role = "source-dirty"
  dot.p.title = dirty and "Unsaved changes" or nil
  table.insert(left, dot)
  -- Split panes (under about 150 columns) get a compact row: the overlay switch as icon toggles, the
  -- editor tools in the keyboard menu, and the state badge left to the status bar while the
  -- debugger's wells show.
  local narrow = (state.cols or 200) < 150
  local word, tone, detail = overlay_state(state)
  if word and not (narrow and state.mode == "debug" and active(state.debug)) then
    local badge = ui.badge(word, tone)
    badge.p.title = detail
    badge.p.key = "state"
    badge.p.role = "source-badge"
    table.insert(left, badge)
  end
  if state.missing then
    local badge = ui.badge("Deleted on disk", "error")
    badge.p.key = "missing"
    badge.p.role = "source-badge"
    table.insert(left, badge)
  end
  local right = {}
  local modes = overlay_modes(state)
  if #modes > 1 and narrow then
    -- Split panes: the overlays as a well of icon toggles, the active one `on`.
    local icons = { none = "eye-off", coverage = "list-checks", debug = "bug", diagnostics = "warn" }
    local labels = { none = "No overlay", coverage = "Coverage", debug = "Debug", diagnostics = "Diagnostics" }
    local toggles = {}
    for index, mode in modes do
      table.insert(
        toggles,
        icon_button("overlay-" .. mode, labels[mode] .. " (⌥" .. index .. ")", icons[mode], nil, "mode=" .. mode, {
          on = state.mode == mode,
        })
      )
    end
    table.insert(
      right,
      ui.node(
        "buttons",
        { key = "overlay", role = "source-overlay-toggles", variant = "toolbar", label = "Overlay" },
        toggles
      )
    )
  elseif #modes > 1 then
    local labels =
      { none = "None", coverage = "Coverage", debug = "Debug", diagnostics = "Diagnostics", hotness = "Hotness" }
    local items = {}
    for _, mode in modes do
      table.insert(items, { id = mode, label = labels[mode] })
    end
    table.insert(
      right,
      ui.node(
        "tabs",
        { key = "overlay", role = "source-overlays", variant = "segmented", active = state.mode, items = items }
      )
    )
  end
  if state.mode == "debug" then
    for _, control in debug_controls(state) do
      table.insert(right, control)
    end
  elseif state.mode == "coverage" and state.attach == "ready" then
    -- Run with coverage is the screen's primary while there is no coverage to show.
    local coverage = state.coverage
    local idle = coverage.state ~= "running" and coverage.state ~= "loading" and coverage.state ~= "idle"
    local tools = {
      icon_button("run-coverage", "Run with coverage (F5)", "run", { "f5" }, "run_coverage", {
        variant = coverage.state == "missing" and "primary" or nil,
        busy = not idle or coverage.starting == true,
      }),
    }
    if coverage_ready(state) or coverage.state == "error" then
      table.insert(tools, icon_button("refresh", "Refresh coverage (F6)", "repeat", { "f6" }, "refresh"))
    end
    table.insert(
      right,
      ui.node(
        "buttons",
        { key = "coverage", role = "source-coverage-tools", variant = "toolbar", label = "Coverage" },
        tools
      )
    )
  end
  if state.mode ~= "none" and state.attach == "error" then
    table.insert(right, icon_button("retry", "Retry attaching to the project", "repeat", nil, "retry"))
  end
  local tools = {}
  -- One primary on screen: Save takes it while dirty unless an overlay shows its own.
  if dirty then
    local primary = state.mode == "none" or (state.mode == "coverage" and state.coverage.state ~= "missing")
    table.insert(
      tools,
      icon_button("save", "Save (⌘S)", "save", nil, "save", { variant = primary and "primary" or nil })
    )
  end
  if not narrow then
    table.insert(tools, icon_button("find", "Find (⌃F)", "search", nil, "find", { on = state.find ~= nil }))
    table.insert(tools, icon_button("goto", "Go to line (⌃G)", "hash", nil, "goto", { on = state.go ~= nil }))
    table.insert(tools, icon_button("wrap", "Soft wrap (⌥Z)", "corner-down-right", nil, "wrap", { on = state.wrap }))
  end
  if not narrow then
    table.insert(
      tools,
      icon_button("edit", "Edit in Tern", "open", nil, "open", { href = source.file_url(state.path, buf.cursor.l) })
    )
  end
  if #tools > 0 then
    table.insert(
      right,
      ui.node("buttons", { key = "tools", role = "source-tools", variant = "toolbar", label = "Editor" }, tools)
    )
  end
  table.insert(
    right,
    ui.node("menu", {
      key = "keys",
      role = "source-keys",
      icon = "keyboard",
      title = "Keyboard shortcuts",
      trigger = "quiet",
      align = "end",
      variant = "dense",
      items = key_rows(state),
    })
  )
  return ui.node("row", {
    key = "head",
    role = "source-toolbar",
    justify = "between",
    align = "center",
    gap = "sm",
    -- No wrap: the row's height never changes (Save appearing, a longer badge, "Deleted on disk");
    -- the breadcrumb shrinks and folds its folders instead.
  }, {
    ui.node("row", { key = "start", gap = "sm", align = "center", shrink = 1 }, left),
    ui.node("row", { key = "end", gap = "sm", align = "center" }, right),
  })
end

local function confirm_strip(state)
  local confirm = state.confirm
  local tone = confirm.tone or "error"
  return ui.card(confirm.title, {
    ui.node("row", { key = "end", gap = "sm" }, {
      ui.button("Cancel", { key = "cancel", variant = "quiet", keys = { "esc" }, actions = { click = "cancel" } }),
      ui.button(confirm.action, {
        key = "go",
        role = "source-confirm",
        variant = tone == "error" and "danger" or "primary",
        keys = { "enter" },
        actions = { click = "confirm" },
      }),
    }),
    ui.text({ ui.span(confirm.text, "muted") }),
  }, { key = "confirm", role = "source-confirm-strip", tone = tone, ["end"] = "dock.confirm.end" })
end

local function find_row(state)
  local find = state.find
  local count = #find.matches
  local summary = ""
  if find.text ~= "" then
    if count == 0 then
      summary = "No matches"
    else
      local total = count >= MAX_MATCHES and (count .. "+") or tostring(count)
      summary = (find.index and (find.index .. " of ") or "") .. total .. (count == 1 and " match" or " matches")
    end
  end
  return ui.node("row", { key = "find", role = "source-find", gap = "sm", align = "center" }, {
    ui.node("input", {
      key = "query",
      role = "source-find-input",
      icon = "search",
      placeholder = "Find",
      text = find.text,
      cursor = find.cursor,
      grow = 1,
    }),
    ui.text({ ui.span(summary, count == 0 and find.text ~= "" and "warning" or "muted") }),
    ui.node("buttons", { key = "nav", variant = "toolbar", label = "Matches" }, {
      icon_button("find-prev", "Previous match (⇧Enter)", "arrow-up", { "shift", "enter" }, "find_prev"),
      icon_button("find-next", "Next match (Enter)", "arrow-down", { "enter" }, "find_next"),
    }),
    ui.button("Done", { key = "close", variant = "quiet", keys = { "esc" }, actions = { click = "close_fields" } }),
  })
end

local function go_row(state)
  local field = state.go
  return ui.node("row", { key = "go", role = "source-go", gap = "sm", align = "center" }, {
    ui.node("input", {
      key = "line",
      role = "source-go-input",
      icon = "hash",
      placeholder = "Line or line:column, 1–" .. #state.buf.lines,
      text = field.text,
      cursor = field.cursor,
      grow = 1,
    }),
    ui.button("Go", { key = "go", keys = { "enter" }, actions = { click = "go" } }),
    ui.button("Cancel", { key = "close", variant = "quiet", keys = { "esc" }, actions = { click = "close_fields" } }),
  })
end

local function status_bar(state)
  local buf = state.buf
  local segs = {
    ui.node("seg", {
      key = "path",
      spans = { ui.span(state.relative or state.path, "path") },
      title = state.path,
      min = { w = "12ch" },
      priority = 5,
    }),
  }
  local word, tone, detail = overlay_state(state)
  if word then
    table.insert(
      segs,
      ui.node("seg", {
        key = "overlay",
        role = "source-overlay-state",
        side = "right",
        text = string.match(word, "^(%d+%%) covered$") and ("Coverage " .. string.match(word, "^(%d+%%)")) or word,
        tone = tone,
        title = detail,
        priority = 4,
      })
    )
  end
  table.insert(
    segs,
    ui.node("seg", {
      key = "pos",
      role = "source-position",
      side = "right",
      text = "Ln " .. buf.cursor.l .. ", Col " .. (buf.cursor.c + 1),
      priority = 8,
    })
  )
  local a, b = buffer.selection(buf)
  if a then
    table.insert(
      segs,
      ui.node("seg", {
        key = "selection",
        role = "source-selection",
        side = "right",
        text = buffer.units(buffer.slice(buf, a, b)) .. " selected",
        priority = 6,
      })
    )
  end
  local language = LANG_NAMES[state.lang or ""] or "Plain text"
  local plain = state.lang and #buf.lines > HIGHLIGHT_LINES
  table.insert(
    segs,
    ui.node("seg", {
      key = "lang",
      role = "source-lang",
      side = "right",
      text = plain and (language .. " · no highlighting") or language,
      title = plain
          and ("Files over " .. HIGHLIGHT_LINES .. " lines are not highlighted: Tern recolors the whole text on every edit.")
        or nil,
      priority = 3,
    })
  )
  table.insert(
    segs,
    ui.node("seg", {
      key = "indent",
      side = "right",
      text = state.unit == "\t" and "Tabs" or ("Spaces: " .. #state.unit),
      priority = 1,
    })
  )
  table.insert(
    segs,
    ui.node("seg", { key = "eol", side = "right", text = buf.ending == "\r\n" and "CRLF" or "LF", priority = 2 })
  )
  if buffer.dirty(buf) then
    table.insert(
      segs,
      ui.node("seg", {
        key = "dirty",
        role = "source-modified",
        side = "right",
        text = "Modified",
        tone = "warning",
        priority = 7,
      })
    )
  end
  return ui.node("status", { key = "bar", role = "source-status" }, segs)
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
        ui.button("Open in Tern's editor", {
          key = "edit",
          icon = "file",
          href = source.file_url(state.path),
          actions = { click = "open" },
        }),
      }),
    }),
  }
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

-- Rows of the keyboard menu and toolbar buttons without their own handler.
local function menu_action(state, cx, act, value)
  local buf = state.buf
  if act == "undo" then
    edited(state, buffer.undo(buf))
  elseif act == "redo" then
    edited(state, buffer.redo(buf))
  elseif act == "comment" then
    local prefix = source.comment(state.path)
    if prefix then
      edited(state, buffer.comment(buf, prefix))
    end
  elseif act == "line_below" then
    edited(state, buffer.line_below(buf))
  elseif act == "select_all" then
    buffer.select_all(buf)
  elseif act == "find" then
    open_find(state, cx)
  elseif act == "goto" then
    state.go, state.find = { text = "", cursor = 0 }, nil
    focus(state, cx, "go")
  elseif act == "mode" and value then
    set_mode(state, cx, value)
  elseif act == "diag_next" or act == "diag_prev" then
    step_diagnostic(state, act == "diag_next" and 1 or -1)
  elseif act == "breakpoint" then
    toggle_breakpoint(state, cx)
  elseif act == "stop_line" and state.debug.stop then
    move_to(state, state.debug.stop)
    reveal(state, state.debug.stop)
  end
end

-- Keys --------------------------------------------------------------------------------------------

local function field_keys(state, cx, key)
  local name = key.name
  local field = state.focus == "find" and state.find or state.go
  if name == "escape" then
    close_fields(state, cx)
  elseif name == "enter" then
    if state.focus == "find" then
      find_step(state, key.shift and -1 or 1)
    else
      go_to(state, cx)
    end
  elseif name == "paste" then
    buffer.field_key(field, { name = "paste", text = string.gsub(key.text or "", "[\r\n].*", "") })
    if state.focus == "find" then
      refind(state)
    end
  elseif buffer.field_key(field, key) then
    if state.focus == "find" then
      refind(state)
      if #state.find.matches > 0 then
        find_step(state, 1)
      end
    end
  else
    return false
  end
  return true
end

-- Keys the editor leaves to the program. `cmd` is ⌘ on macOS and Ctrl on other keyboards.
local function editor_keys(state, cx, key, cmd)
  local buf = state.buf
  local name = key.name
  local shift = key.shift
  local word = key.alt or (key.ctrl and not key.meta)
  if name == "paste" then
    edited(state, buffer.insert(buf, string.gsub(key.text or "", "\r\n", "\n"), "paste"))
  elseif name == "enter" then
    if cmd then
      edited(state, buffer.line_below(buf))
    else
      edited(state, buffer.newline(buf, state.unit))
    end
  elseif name == "tab" then
    edited(state, shift and buffer.outdent(buf, state.unit) or buffer.indent(buf, state.unit))
  elseif name == "backspace" or name == "delete" then
    edited(state, buffer.delete(buf, name == "backspace" and -1 or 1, word, key.meta, state.unit))
  elseif name == "left" or name == "right" then
    local dir = name == "left" and -1 or 1
    if key.meta then
      if dir < 0 then
        buffer.home(buf, shift)
      else
        buffer.line_end(buf, shift)
      end
    else
      buffer.horizontal(buf, dir, shift, word)
    end
  elseif name == "up" or name == "down" then
    local dir = name == "up" and -1 or 1
    if key.meta then
      buffer.go(buf, dir < 0 and { l = 1, c = 0 } or { l = #buf.lines, c = buf.lens[#buf.lines] }, shift)
    else
      buffer.vertical(buf, dir, shift)
    end
  elseif name == "home" or name == "end" then
    if key.ctrl or key.meta then
      buffer.go(buf, name == "home" and { l = 1, c = 0 } or { l = #buf.lines, c = buf.lens[#buf.lines] }, shift)
    elseif name == "home" then
      buffer.home(buf, shift)
    else
      buffer.line_end(buf, shift)
    end
  elseif name == "page_up" or name == "page_down" then
    buffer.vertical(buf, (name == "page_up" and -1 or 1) * (visible(state, cx) - 1), shift)
  elseif cmd and name == "a" then
    buffer.select_all(buf)
  elseif cmd and name == "/" then
    local prefix = source.comment(state.path)
    if not prefix then
      return false
    end
    edited(state, buffer.comment(buf, prefix))
  elseif cmd and (name == "c" or name == "x") then
    local a, b = buffer.selection(buf)
    if not a then
      a, b = { l = buf.cursor.l, c = 0 }, { l = buf.cursor.l, c = buf.lens[buf.cursor.l] }
      cx:copy(buffer.slice(buf, a, b) .. "\n")
      if name == "x" then
        local last = #buf.lines
        local stop = buf.cursor.l < last and { l = buf.cursor.l + 1, c = 0 } or b
        edited(state, buffer.replace(buf, a, stop, "", "delete"))
      end
    else
      cx:copy(buffer.slice(buf, a, b))
      if name == "x" then
        edited(state, buffer.insert(buf, "", "delete"))
      end
    end
    return name == "x"
  elseif key.text and key.text ~= "" and not key.ctrl and not key.meta then
    edited(state, buffer.insert(buf, key.text, "type"))
  else
    return false
  end
  return true
end

local function overlay_keys(state, cx, key)
  local name = key.name
  if state.mode == "diagnostics" then
    if name ~= "f8" or state.diag.state ~= "ready" or #state.diag.items == 0 then
      return false
    end
    step_diagnostic(state, key.shift and -1 or 1)
    return true
  end
  if state.mode == "coverage" and state.attach == "ready" then
    if name == "f5" then
      start_coverage(state, cx)
    elseif name == "f6" and coverage_ready(state) then
      load_coverage(state, cx, true)
    else
      return false
    end
    return true
  end
  if state.mode == "debug" and state.attach == "ready" and source.debuggable(state.path) then
    local live = active(state.debug)
    if name ~= "f9" and name ~= "f5" and not live then
      return false
    end
    if name == "f9" then
      toggle_breakpoint(state, cx)
    elseif name == "f5" then
      step(state, cx, key.shift and "stop" or "continue")
    elseif name == "f10" then
      step(state, cx, "next")
    elseif name == "f11" then
      step(state, cx, key.shift and "step_out" or "step_in")
    elseif name == "f6" then
      step(state, cx, "pause")
    elseif name == "f7" and state.debug.stop then
      move_to(state, state.debug.stop)
      reveal(state, state.debug.stop)
    else
      return false
    end
    return true
  end
  return false
end

local function key_handler(state, key, cx)
  if state.problem then
    return false
  end
  local name = key.name
  local cmd = key.meta or (key.ctrl and not key.alt and name ~= "g" and name ~= "y")
  if state.confirm then
    if name == "enter" then
      confirmed(state, cx)
    elseif name == "escape" then
      cancelled(state)
    else
      return false
    end
    return true
  end
  if cmd and name == "s" then
    save(state, cx)
  elseif cmd and name == "f" then
    open_find(state, cx)
  elseif key.ctrl and name == "g" then
    state.go = { text = "", cursor = 0 }
    state.find = nil
    focus(state, cx, "go")
  elseif key.alt and not key.meta and (name == "z" or name == "Ω") then
    state.wrap = not state.wrap
  elseif key.alt and not key.meta and string.find(name, "^[1-4]$") then
    local modes = overlay_modes(state)
    set_mode(state, cx, modes[tonumber(name)] or state.mode)
  elseif (cmd and name == "z" and not key.shift) and state.focus == "editor" then
    edited(state, buffer.undo(state.buf))
  elseif ((cmd and name == "z" and key.shift) or (key.ctrl and name == "y")) and state.focus == "editor" then
    edited(state, buffer.redo(state.buf))
  elseif string.find(name, "^f%d+$") then
    return overlay_keys(state, cx, key)
  elseif state.focus ~= "editor" then
    return field_keys(state, cx, key)
  elseif name == "escape" then
    if state.mode ~= "none" then
      set_mode(state, cx, "none")
    elseif buffer.dirty(state.buf) then
      state.confirm = {
        kind = "close",
        title = "Close " .. state.name .. " without saving?",
        text = "Your unsaved changes are lost.",
        action = "Discard",
      }
    else
      close(state)
      cx:exit(0)
    end
  else
    return editor_keys(state, cx, key, cmd)
  end
  return true
end

-- The block ---------------------------------------------------------------------------------------

tern.block.define("source", {
  font = "sans",
  features = { "edit", "undo" },
  init = function(cx, args, saved)
    local path = args[1] or ""
    if string.sub(path, 1, 1) ~= "/" and cx.cwd then
      path = cx.cwd .. "/" .. path
    end
    -- Callers pass absolute paths; anything else (a relative path with no cwd, `.` or `..`
    -- segments) is refused here rather than resolved by the file system.
    local given = path
    path = links.absolute(path) or ""
    local root = args[2] and links.absolute(args[2])
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
      wrap = saved.wrap == true,
      focus = "editor",
      breakpoints = {},
      attach = "idle",
      coverage = { state = "idle" },
      debug = { verified = {} },
      diag = { state = "none" },
      timers = {},
    }
    for _, line in (type(saved.breakpoints) == "table" and saved.breakpoints or {}) do
      if type(line) == "number" then
        table.insert(state.breakpoints, line)
      end
    end
    table.sort(state.breakpoints)
    local text, problem
    if path == "" then
      state.path, state.name = given, string.match(given, "([^/]+)$") or given
      problem = {
        title = "Not an absolute path",
        text = "Elide source opens absolute paths without . or .. segments: " .. given,
      }
    else
      text, problem = read(path)
    end
    state.problem, state.disk = problem, text or ""
    state.buf = buffer.new(state.disk)
    state.unit = buffer.unit(state.buf, state.lang == "python" and 4 or 2)
    blocks[cx.pane] = state
    if problem then
      return state
    end
    -- An unsaved draft from before a reload or restart comes back as one undoable edit. When the
    -- file changed on disk since the draft's base, the block asks (reload or keep editing) instead
    -- of letting a later save overwrite the newer contents unprompted.
    if type(saved.draft) == "string" and saved.draft ~= buffer.text(state.buf) and source.text(saved.draft) then
      local plan = source.restore_plan(saved.draft, saved.draft_base, source.digest(state.disk))
      local last = #state.buf.lines
      buffer.replace(state.buf, { l = 1, c = 0 }, { l = last, c = state.buf.lens[last] }, saved.draft, "draft")
      if plan == "conflict" then
        state.pending_disk = state.disk
        state.confirm = {
          kind = "reload",
          title = state.name .. " changed on disk since your unsaved changes",
          text = "They are restored here. Reloading replaces them with the version on disk; keep editing to save over it.",
          action = "Reload",
        }
      end
    end
    local line = tonumber(args[3]) or saved.line or 1
    move_to(state, line)
    if line > 1 then
      reveal(state, state.buf.cursor.l)
    end
    attach(state, cx)
    scan_diagnostics(state, cx)
    watch(state, cx)
    focus(state, cx, "editor")
    return state
  end,
  title = function(state)
    return state.name .. (state.buf and buffer.dirty(state.buf) and " ●" or "")
  end,
  view = function(state, cx)
    if state.problem then
      return problem_view(state)
    end
    local buf = state.buf
    local starts = buffer.starts(buf)
    state.cols = cx.cols
    local gutter, virt, decor, digits = lines_view(state, starts)
    local children = { toolbar(state) }
    -- Transient and empty states live in the toolbar badge and the status bar, never in a node
    -- above the editor, so nothing reflows the code.
    local top = nil
    if state.jump then
      -- Program moves put the line a few rows below the top; afterwards Tern follows the caret.
      top = math.max(0, state.jump - 4)
      state.jump = nil
    end
    local a = buffer.selection(buf)
    do
      table.insert(
        children,
        ui.node("editor", {
          key = "editor",
          -- `digits-N`, the digit count of the last line number, lets the harness find this editor.
          role = "source-editor digits-" .. digits,
          aria = state.name,
          grow = 1,
          text = buffer.text(buf),
          cursor = buffer.offset(buf, buf.cursor),
          anchor = a and buffer.offset(buf, buf.anchor) or nil,
          -- Even `highlight = false` keeps part of the cost, so large files drop `lang` entirely.
          lang = #buf.lines <= HIGHLIGHT_LINES and state.lang or nil,
          nowrap = not state.wrap,
          maxLines = visible(state, cx),
          topline = top,
          gutter = gutter,
          virt = virt,
          decor = decor,
        })
      )
    end
    local dock = {}
    if state.confirm then
      table.insert(dock, confirm_strip(state))
    end
    if state.find then
      table.insert(dock, find_row(state))
    elseif state.go then
      table.insert(dock, go_row(state))
    end
    table.insert(dock, status_bar(state))
    return {
      main = ui.node("col", { gap = "none", grow = 1 }, children),
      dock = ui.node("col", { gap = "none" }, dock),
    }
  end,
  key = key_handler,
  event = function(state, ev, cx)
    if state.problem then
      if ev.ev == "action" and ev.act == "open" then
        cx:open(source.file_url(state.path))
      end
      return
    end
    if ev.ev == "edit" then
      if ev.id == "main.editor" then
        local result = buffer.apply(state.buf, ev)
        if result then
          edited(state, result)
        end
      elseif ev.id == FIELDS.find and state.find then
        buffer.field_edit(state.find, ev)
        refind(state)
      elseif ev.id == FIELDS.go and state.go then
        buffer.field_edit(state.go, ev)
      end
    elseif ev.ev == "undo" then
      if ev.id == "main.editor" then
        edited(state, buffer.undo(state.buf))
      end
    elseif ev.ev == "focus" then
      if ev.id == FIELDS.find and state.find then
        focus(state, cx, "find")
      elseif ev.id == FIELDS.go and state.go then
        focus(state, cx, "go")
      else
        focus(state, cx, "editor")
      end
    elseif ev.ev == "select" and ev.id == "main.head.end.overlay" then
      set_mode(state, cx, ev.item)
    elseif ev.ev == "select" and ev.id == "main.head.start.path" and type(ev.item) == "string" then
      cx:open(ev.item)
    elseif ev.ev == "action" then
      local act = ev.act
      if act == "open" then
        cx:open(source.file_url(state.path, state.buf.cursor.l))
      elseif act == "save" then
        save(state, cx)
      elseif act == "confirm" then
        confirmed(state, cx)
      elseif act == "cancel" then
        cancelled(state)
      elseif act == "find_next" or act == "find_prev" then
        find_step(state, act == "find_next" and 1 or -1)
      elseif act == "close_fields" then
        close_fields(state, cx)
      elseif act == "go" then
        go_to(state, cx)
      elseif act == "wrap" then
        state.wrap = not state.wrap
      elseif act == "retry" then
        attach(state, cx)
      elseif act == "refresh" then
        load_coverage(state, cx, true)
      elseif act == "run_coverage" then
        start_coverage(state, cx)
      elseif act == "launch" then
        step(state, cx, "continue")
      elseif
        act == "continue"
        or act == "next"
        or act == "step_in"
        or act == "step_out"
        or act == "stop"
        or act == "pause"
      then
        step(state, cx, act)
      else
        menu_action(state, cx, act, ev.value)
      end
    end
  end,
  save = function(state)
    if not state.buf then
      return nil
    end
    local text = buffer.text(state.buf)
    local draft = buffer.dirty(state.buf) and #text <= MAX_DRAFT and text or nil
    -- The draft's base (the disk text it edits), recomputed only when that text changes.
    if draft and state.digest_of ~= state.disk then
      state.digest, state.digest_of = source.digest(state.disk), state.disk
    end
    return {
      mode = state.mode,
      wrap = state.wrap,
      line = state.buf.cursor.l,
      breakpoints = tern.json.array(state.breakpoints),
      draft = draft,
      draft_base = draft and state.digest or nil,
    }
  end,
})
