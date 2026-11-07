-- Compiler diagnostics in text output and in `elide build` reports, for the build lens and the
-- source block's Diagnostics overlay. Mirrors the runtime's parser (Elide
-- crates/cli/src/building/diagnostics.rs) on the same samples: javac, kotlinc (plain, with
-- `[NAME]` codes, and Gradle-style `e:`/`w:` with file URLs) and Elide's own
-- `error: tool: message` / `In file:` / numbered-excerpt rendering, with the builder's
-- `[249ms] ` elapsed-time prefixes. Pure (no `tern` calls) and kept to the subset Luau shares
-- with Lua 5.4, so `tests/diagnostics.lua` runs under plain `lua`.

local M = {}

-- The runtime's bounds: diagnostics kept per run, message bytes, excerpt lines, notes per list.
M.KEPT = 500
local MESSAGE_LIMIT = 4096
local EXCERPT_LINES = 12
local NOTES = 16
local NOTE_LIMIT = 1024
-- Compilers print short headers; a `path:line: severity:` header is looked for only this far
-- into a line, so a long line of other output (minified JSON) costs one pass, not a quadratic one.
local HEADER_LIMIT = 4096

local SEVERITIES = { error = "error", e = "error", warning = "warning", w = "warning" }
for _, word in ipairs({ "note", "info", "hint", "i" }) do
  SEVERITIES[word] = "note"
end
local RANK = { error = 1, warning = 2, note = 3 }

local SUGGESTIONS = {
  "help:",
  "hint:",
  "suggestion:",
  "did you mean",
  "recompile with",
  "consider ",
  "try ",
  "use ",
  "add ",
  "remove ",
  "replace ",
}

local function trim(s)
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function clip(text, limit)
  if #text <= limit then
    return text
  end
  local cut = limit
  -- Back off continuation bytes so the cut lands on a character boundary.
  while cut > 0 do
    local byte = string.byte(text, cut + 1)
    if not byte or byte < 0x80 or byte >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return string.sub(text, 1, cut) .. "…"
end

-- Removes CSI sequences and OSC strings (terminated by BEL or ST).
function M.plain(line)
  line = string.gsub(line, "\27%][^\7\27]*\7", "")
  line = string.gsub(line, "\27%][^\27]*\27\\", "")
  line = string.gsub(line, "\27%[[\48-\63]*[\32-\47]*[\64-\126]", "")
  return line
end

-- Drops the builder's `[ 1.0s] ` / `[249ms] ` elapsed-time prefix.
function M.unstamped(line)
  local stamp, tail = string.match(line, "^%[([^%]]*)%] (.*)$")
  if stamp and #stamp <= 10 and string.find(stamp, "^[%d%.%sms h]*$") then
    return tail
  end
  return line
end

-- javac's trailing `3 errors` / `1 warning`, and kotlinc's `0 errors, 2 warnings.`
function M.summary(line)
  line = string.gsub(trim(line), "%.+$", "")
  local count, word = string.match(line, "^(%d+)%s+([%a,]+)")
  if not count then
    return false
  end
  word = string.gsub(word, ",$", "")
  return word == "error" or word == "errors" or word == "warning" or word == "warnings"
end

-- A leading `[code] ` (javac lint categories, kotlinc diagnostic names).
local function code_of(message)
  local code, tail = string.match(message, "^%[([%w_%-%.]+)%] (.*)$")
  if code then
    return code, tail
  end
  return nil, message
end

-- A leading `tool: ` naming the compiler (`javac: …`), split off.
local function tool_of(message)
  local tool, rest = string.match(message, "^([%l%d%-_%.]+): (.*)$")
  if tool and #tool <= 24 then
    return tool, rest
  end
  return nil, message
end

local function is_suggestion(note)
  local lower = string.lower(note)
  for _, prefix in ipairs(SUGGESTIONS) do
    if string.sub(lower, 1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local function positive(text)
  if not text or not string.find(text, "^%d+$") then
    return nil
  end
  local n = tonumber(text)
  if n and n > 0 and n < 4294967296 then
    return n
  end
  return nil
end

-- `path:line[:col]`, the path possibly a `file://` URL.
function M.location(text)
  local rest, last = string.match(text, "^(.*):([^:]*)$")
  local last_number = positive(last)
  if not rest or not last_number then
    return nil
  end
  local path, line = string.match(rest, "^(.*):([^:]*)$")
  local line_number = positive(line)
  if path and line_number and path ~= "" then
    return path, line_number, last_number
  end
  if rest == "" then
    return nil
  end
  return rest, last_number, nil
end

local function unescape(path)
  return (string.gsub(path, "%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

-- A path as reported, absolute against `base` (a `file://` URL as its path). The runtime also
-- canonicalizes paths that exist; callers that can resolve symlinks do so themselves.
function M.resolve(path, base)
  local url = string.match(path, "^file://(/.*)$")
  if url then
    path = unescape(url)
  end
  if string.sub(path, 1, 1) ~= "/" and base and base ~= "" then
    path = (string.gsub(base, "/+$", "")) .. "/" .. (string.gsub(path, "^%./", ""))
  end
  return path
end

local function new(severity, message)
  local code, rest = code_of(trim(message))
  return { severity = severity, code = code, message = rest, notes = {}, suggestions = {} }
end

local function note(diagnostic, line)
  line = trim(line)
  if line == "" then
    return
  end
  table.insert(is_suggestion(line) and diagnostic.suggestions or diagnostic.notes, line)
end

local function extension(path)
  return string.match(path, "%.([%w]+)$")
end

-- A numbered excerpt line of Elide's rendering: `→5 │ text`, ` 3 │ text`.
local function snippet_line(line)
  local gutter, text = string.match(line, "^(.-)│(.*)$")
  if not gutter then
    return nil
  end
  local number = positive(string.match(gutter, "^%s*[^%d%s]*%s*(%d+)%s*$"))
  if not number then
    return nil
  end
  return number, (string.gsub(text, "^ ", "", 1))
end

-- A diagnostic header and what follows it ("elide", "source" or "none").
local function header(line, base)
  -- Elide: `error: kotlinc: message`.
  local word, rest = string.match(line, "^(%a+): (.*)$")
  if word and #word > 1 and SEVERITIES[word] then
    local tool, message = tool_of(rest)
    local diagnostic = new(SEVERITIES[word], message)
    diagnostic.tool = tool
    return diagnostic, "elide"
  end
  -- Gradle-style kotlinc: `e: file:///a/B.kt:6:19 message`.
  if word and #word == 1 and SEVERITIES[word] then
    local at, message = string.match(rest, "^(%S+) (.*)$")
    local path, number, col
    if at then
      path, number, col = M.location(at)
    end
    local diagnostic
    if path then
      diagnostic = new(SEVERITIES[word], message)
      diagnostic.path, diagnostic.line, diagnostic.col = M.resolve(path, base), number, col
    else
      diagnostic = new(SEVERITIES[word], rest)
    end
    diagnostic.tool = "kotlinc"
    return diagnostic, "none"
  end
  -- javac and plain kotlinc: `path:line[:col]: severity: message`. Only a `": "` followed by a
  -- severity word is a candidate, and only then is the text before it read as a location.
  local from = 1
  while from <= HEADER_LIMIT do
    local at = string.find(line, ": ", from, true)
    if not at or at > HEADER_LIMIT then
      return nil
    end
    local _, last, named = string.find(line, "^(%a+): ", at + 2)
    local path, number, col
    if named and #named > 1 and SEVERITIES[named] then
      path, number, col = M.location(string.sub(line, 1, at - 1))
    end
    if path and extension(path) then
      local diagnostic = new(SEVERITIES[named], string.sub(line, last + 1))
      local ext = extension(path)
      diagnostic.tool = (ext == "java" and "javac") or ((ext == "kt" or ext == "kts") and "kotlinc") or nil
      diagnostic.path, diagnostic.line, diagnostic.col = M.resolve(path, base), number, col
      return diagnostic, "source"
    end
    from = at + 2
  end
  return nil
end

-- The `In file:` line, notes, and the numbered excerpt after an Elide header.
local function elide_body(lines, at, base, diagnostic)
  local file = lines[at] and string.match(lines[at], "^In file: (.*)$")
  if file then
    at = at + 1
    local path, number, col = M.location(trim(file))
    if path then
      diagnostic.path, diagnostic.line, diagnostic.col = M.resolve(path, base), number, col
    else
      diagnostic.path = M.resolve(trim(file), base)
    end
  end
  while lines[at] do
    local line = lines[at]
    if trim(line) == "" or snippet_line(line) or header(line, base) then
      break
    end
    note(diagnostic, line)
    at = at + 1
  end
  if lines[at] and trim(lines[at]) == "" and lines[at + 1] and snippet_line(lines[at + 1]) then
    at = at + 1
  end
  local first, text = nil, {}
  while lines[at] do
    local number, source = snippet_line(lines[at])
    if number then
      first = first or number
      table.insert(text, source)
    elseif not string.find(lines[at], "│", 1, true) then
      break
    end
    -- An elision row (` · │`) ends nothing; it carries no line.
    at = at + 1
  end
  if first then
    diagnostic.excerpt = { first_line = first, text = table.concat(text, "\n") }
  end
  return at
end

-- The source line, caret line and indented notes after a javac or kotlinc header.
local function source_body(lines, at, diagnostic)
  local source, marks = lines[at], lines[at + 1]
  if source and marks and string.find(marks, "^%s*[%^~]+%s*$") then
    if diagnostic.line then
      diagnostic.excerpt = { first_line = diagnostic.line, text = source }
    end
    if not diagnostic.col then
      local caret = string.find(marks, "^", 1, true)
      diagnostic.col = utf8.len(string.sub(marks, 1, caret - 1)) + 1
    end
    at = at + 2
  end
  while lines[at] and string.find(lines[at], "^%s") and trim(lines[at]) ~= "" do
    note(diagnostic, lines[at])
    at = at + 1
  end
  return at
end

local function bound(diagnostic)
  diagnostic.message = clip(diagnostic.message, MESSAGE_LIMIT)
  local excerpt = diagnostic.excerpt
  if excerpt then
    local kept, count = {}, 0
    for line in string.gmatch(excerpt.text .. "\n", "([^\n]*)\n") do
      count = count + 1
      if count > EXCERPT_LINES then
        break
      end
      table.insert(kept, line)
    end
    excerpt.text = clip(table.concat(kept, "\n"), MESSAGE_LIMIT)
  end
  for _, list in ipairs({ diagnostic.notes, diagnostic.suggestions }) do
    for index = #list, NOTES + 1, -1 do
      table.remove(list, index)
    end
    for index, text in ipairs(list) do
      list[index] = clip(text, NOTE_LIMIT)
    end
  end
  return diagnostic
end

-- Every diagnostic in a compiler's or Elide's text output (a string or a list of lines), with
-- relative paths resolved against `base`.
-- A line of compiler or Elide output with escapes and the builder's time stamp removed.
function M.clean(line)
  return M.plain(M.unstamped(M.plain((string.gsub(line, "\r$", "")))))
end

-- Diagnostics whose headers start at or after `from` in cleaned `lines`, each with the index of
-- the line it starts on.
local function parse_from(lines, base, from)
  local found, starts, at = {}, {}, from
  while at <= #lines do
    local start = at
    local line = string.gsub(lines[at], "%s+$", "")
    at = at + 1
    local closing = string.match(line, "^Note: (.*)$")
    if closing then
      -- javac's closing notes: `Note: Bad.java uses unchecked …`, then how to see more.
      local diagnostic = new("note", closing)
      diagnostic.tool = "javac"
      while lines[at] and string.match(lines[at], "^Note: ") do
        note(diagnostic, string.sub(lines[at], 7))
        at = at + 1
      end
      table.insert(found, bound(diagnostic))
      table.insert(starts, start)
    elseif not M.summary(line) then
      local diagnostic, follow = header(line, base)
      if diagnostic then
        if follow == "elide" then
          at = elide_body(lines, at, base, diagnostic)
        elseif follow == "source" then
          at = source_body(lines, at, diagnostic)
        end
        table.insert(found, bound(diagnostic))
        table.insert(starts, start)
      end
    end
  end
  return found, starts
end

-- Every diagnostic in a compiler's or Elide's text output (a string or a list of lines), with
-- relative paths resolved against `base`.
function M.parse(text, base)
  local lines = {}
  if type(text) == "table" then
    for index, line in ipairs(text) do
      lines[index] = M.clean(line)
    end
  else
    for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
      table.insert(lines, M.clean(line))
    end
  end
  return (parse_from(lines, base, 1))
end

-- An incremental parse for a lens: `add` lines as they arrive, `result` the diagnostics so far.
-- Each `result` reads only lines from where the last diagnostic started (its body may still be
-- growing), so a long output is parsed about once, not once per view.
local Session = {}
Session.__index = Session

function M.session(base)
  return setmetatable({ base = base, lines = {}, found = {}, starts = {}, resume = 1 }, Session)
end

function Session:add(line)
  table.insert(self.lines, M.clean(line))
end

function Session:result()
  if self.resume <= #self.lines then
    -- Drop what started at or after the resume point and read it again with the new lines.
    while #self.starts > 0 and self.starts[#self.starts] >= self.resume do
      table.remove(self.starts)
      table.remove(self.found)
    end
    local found, starts = parse_from(self.lines, self.base, self.resume)
    for index, diagnostic in ipairs(found) do
      table.insert(self.found, diagnostic)
      table.insert(self.starts, starts[index])
    end
    self.resume = #starts > 0 and starts[#starts] or #self.lines + 1
  end
  return self.found
end

-- Diagnostics without repeats, kept up to KEPT, with exact counts past it.
function M.collect(list)
  local seen, kept = {}, {}
  local counts = { error = 0, warning = 0, note = 0, dropped = 0 }
  for _, d in ipairs(list) do
    local identity = table.concat({
      d.severity,
      d.path or "",
      tostring(d.line or ""),
      tostring(d.col or ""),
      d.code or "",
      d.message,
    }, "\0")
    if not seen[identity] then
      seen[identity] = true
      counts[d.severity] = counts[d.severity] + 1
      if #kept < M.KEPT then
        table.insert(kept, d)
      else
        counts.dropped = counts.dropped + 1
      end
    end
  end
  return kept, counts
end

-- Diagnostics grouped by file: files with errors first, then warnings, then notes, ties in
-- first-seen order; each file's by line, column and severity; those without a file last.
function M.by_file(list)
  local groups, index = {}, {}
  for _, d in ipairs(list) do
    local key = d.path or "\0"
    local group = index[key]
    if not group then
      group = { path = d.path, items = {}, order = #groups + 1, counts = { error = 0, warning = 0, note = 0 } }
      index[key] = group
      table.insert(groups, group)
    end
    table.insert(group.items, d)
    group.counts[d.severity] = group.counts[d.severity] + 1
  end
  for _, group in ipairs(groups) do
    for position, d in ipairs(group.items) do
      d._order = position
    end
    table.sort(group.items, function(a, b)
      local la, lb = a.line or math.huge, b.line or math.huge
      if la ~= lb then
        return la < lb
      end
      local ca, cb = a.col or 0, b.col or 0
      if ca ~= cb then
        return ca < cb
      end
      if RANK[a.severity] ~= RANK[b.severity] then
        return RANK[a.severity] < RANK[b.severity]
      end
      return a._order < b._order
    end)
    for _, d in ipairs(group.items) do
      d._order = nil
    end
    local worst = 4
    for _, d in ipairs(group.items) do
      worst = math.min(worst, RANK[d.severity])
    end
    group.worst = worst
  end
  table.sort(groups, function(a, b)
    local na, nb = a.path == nil, b.path == nil
    if na ~= nb then
      return nb
    end
    if a.worst ~= b.worst then
      return a.worst < b.worst
    end
    return a.order < b.order
  end)
  for _, group in ipairs(groups) do
    group.order, group.worst = nil, nil
  end
  return groups
end

-- "3 errors, 1 warning" (notes only when nothing else is counted); nil for none.
function M.phrase(errors, warnings, notes)
  local parts = {}
  local function add(count, one, many)
    if count and count > 0 then
      table.insert(parts, count .. " " .. (count == 1 and one or many))
    end
  end
  add(errors, "error", "errors")
  add(warnings, "warning", "warnings")
  if #parts == 0 then
    add(notes, "note", "notes")
  end
  return #parts > 0 and table.concat(parts, ", ") or nil
end

-- A decoded `diagnostics.json` (version 1) as `{ diagnostics, errors, warnings, notes, dropped,
-- outcome }`, or nil when it is not one. Unknown severities are dropped; unknown fields ignored.
function M.report(decoded)
  if type(decoded) ~= "table" or type(decoded.diagnostics) ~= "table" then
    return nil
  end
  local list = {}
  for _, d in ipairs(decoded.diagnostics) do
    -- The runtime keeps at most KEPT; a larger report is not trusted to be small.
    if #list >= M.KEPT then
      break
    end
    if type(d) == "table" and RANK[d.severity] and type(d.message) == "string" then
      local excerpt = d.excerpt
      if type(excerpt) ~= "table" or type(excerpt.text) ~= "string" or type(excerpt.first_line) ~= "number" then
        excerpt = nil
      end
      table.insert(list, {
        severity = d.severity,
        tool = type(d.tool) == "string" and d.tool or nil,
        path = type(d.path) == "string" and d.path or nil,
        line = type(d.line) == "number" and d.line or nil,
        col = type(d.col) == "number" and d.col or nil,
        code = type(d.code) == "string" and d.code or nil,
        message = d.message,
        excerpt = excerpt,
        notes = type(d.notes) == "table" and d.notes or {},
        suggestions = type(d.suggestions) == "table" and d.suggestions or {},
      })
    end
  end
  local function count(key)
    return type(decoded[key]) == "number" and decoded[key] or nil
  end
  return {
    diagnostics = list,
    errors = count("errors"),
    warnings = count("warnings"),
    notes = count("notes"),
    dropped = count("dropped") or 0,
    outcome = type(decoded.outcome) == "string" and decoded.outcome or nil,
    -- When the run finished (unix ms), and how many repeats the counts may include.
    finished_ms = count("finished_ms"),
    unfiltered = count("unfiltered") or 0,
  }
end

-- The run directory named by the runtime's `latest` pointer (`.dev/reports/build/tern/latest`),
-- or nil when it is missing or not a run name: it becomes part of a path, so nothing else passes.
function M.latest(text)
  if type(text) ~= "string" then
    return nil
  end
  local name = string.match(text, "^%s*(.-)%s*$")
  if name and string.find(name, "^run%-[%w_%-]+$") then
    return name
  end
  return nil
end

-- The run with the newest `finished_ms` among `{ run, finished_ms? }` entries, or nil when none
-- has one (reports from runtimes before the field).
function M.newest_finished(entries)
  local best, at = nil, nil
  for _, entry in ipairs(entries) do
    if type(entry.finished_ms) == "number" and (not at or entry.finished_ms > at) then
      best, at = entry.run, entry.finished_ms
    end
  end
  return best
end

-- `elide://source?path=…&line=N&col=M` for a diagnostic with an absolute path (percent-encoding
-- what the link parser decodes), or nil.
function M.link(d)
  if type(d.path) ~= "string" or string.sub(d.path, 1, 1) ~= "/" then
    return nil
  end
  local path = string.gsub(d.path, "[^%w/%._%-~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  local url = "elide://source?path=" .. path
  if d.line then
    url = url .. "&line=" .. math.floor(d.line)
    if d.col then
      url = url .. "&col=" .. math.floor(d.col)
    end
  end
  return url
end

return M
