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
