-- Pure helpers for the `elide.source` block: UTF-16 line offsets for the `editor` node, coverage and
-- breakpoint merging, scrolling and command ids. No `tern` calls, and only the subset Luau shares with
-- Lua 5.4, so `tests/source.lua` runs under plain `lua`.

local M = {}

-- Files above this are refused rather than sent whole as one editor text.
M.MAX_BYTES = 512 * 1024

local LANGS = {
  js = "javascript",
  mjs = "javascript",
  cjs = "javascript",
  ts = "typescript",
  mts = "typescript",
  cts = "typescript",
  py = "python",
  kt = "kotlin",
  kts = "kotlin",
  java = "java",
}

-- Sources the project debugger launches (JavaScript, TypeScript, Python).
local DEBUGGABLE = { js = true, mjs = true, cjs = true, ts = true, mts = true, cts = true, py = true }

function M.extension(path)
  return string.lower(string.match(path, "%.([%w]+)$") or "")
end

function M.lang(path)
  return LANGS[M.extension(path)]
end

function M.debuggable(path)
  return DEBUGGABLE[M.extension(path)] == true
end

-- Whether a source file is a test file, which the debugger launches in `test` mode.
function M.test_file(path)
  local name = string.match(path, "([^/]+)$") or path
  return string.find(name, "%.test%.[%w]+$") ~= nil
    or string.find(name, "%.spec%.[%w]+$") ~= nil
    or string.find(name, "^test_.+%.py$") ~= nil
end

-- UTF-16 code units in a UTF-8 string: one per character, two for those above U+FFFF (4-byte
-- sequences). Stray continuation bytes count as nothing; callers reject invalid UTF-8 first.
function M.units(s)
  local n = 0
  for i = 1, #s do
    local b = string.byte(s, i)
    if b < 0x80 or b >= 0xC0 then
      n = n + 1
      if b >= 0xF0 then
        n = n + 1
      end
    end
  end
  return n
end

-- Whether `s` is UTF-8 text without NUL bytes (binary files are refused).
function M.text(s)
  return utf8.len(s) ~= nil and string.find(s, "\0", 1, true) == nil
end

-- Logical lines of `text`, split on "\n" as the editor splits them: each line's UTF-16 start offset
-- and length. The empty line after a trailing newline is not counted: the editor draws none.
function M.index(text)
  local starts, lengths = {}, {}
  local offset, position = 0, 1
  while true do
    local newline = string.find(text, "\n", position, true)
    local stop = newline and newline - 1 or #text
    local length = M.units(string.sub(text, position, stop))
    starts[#starts + 1] = offset
    lengths[#lengths + 1] = length
    if not newline or (newline == #text and #starts > 0) then
      break
    end
    offset = offset + length + 1
    position = newline + 1
  end
  return { starts = starts, lengths = lengths, count = #starts }
end

-- `line` right-aligned to `width` digits.
function M.number(line, width)
  local digits = tostring(line)
  return string.rep(" ", width - #digits) .. digits
end

-- Zero-based top line keeping one-based `caret` among `visible` lines of `count`.
function M.scroll(top, caret, visible, count)
  if caret - 1 < top then
    top = caret - 1
  elseif caret - 1 >= top + visible then
    top = caret - visible
  end
  return math.max(0, math.min(top, math.max(0, count - visible)))
end

-- `path` relative to `root`, or nil when it is not inside it.
function M.relative(path, root)
  if type(root) == "string" and root ~= "" and string.sub(path, 1, #root + 1) == root .. "/" then
    return string.sub(path, #root + 2)
  end
  return nil
end

-- Whether a path the broker reported (relative to the project, or absolute under any of `roots`,
-- such as the given and the canonical root) names this file.
function M.same(candidate, path, relative, roots)
  if type(candidate) ~= "string" then
    return false
  end
  if candidate == path or candidate == relative then
    return true
  end
  for _, root in ipairs(roots) do
    if type(root) == "string" and candidate == root .. "/" .. relative then
      return true
    end
  end
  return false
end

-- Line states a coverage page names in `state`; any other named state is treated as unmeasured, so
-- a newer producer's states never break an older block.
local LINE_STATES = { covered = true, uncovered = true, partial = true, inferred = true }

-- Measured coverage lines (`{line, covered, branches?, state?}`) as per-line marks, plus the covered
-- and measured counts. A covered line with fewer covered than total branches is `partial`.
-- `inferred` lines (closers, blanks and comment-only lines that inherit their block's coverage) are
-- marked but not counted.
function M.coverage(entries)
  local marks, covered, total = {}, 0, 0
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and type(entry.line) == "number" and not marks[entry.line] then
      local named = type(entry.state) == "string" and entry.state or nil
      local branches = type(entry.branches) == "table" and entry.branches or nil
      if named == "inferred" then
        marks[entry.line] = { state = "inferred" }
      elseif not named or LINE_STATES[named] then
        local state = "uncovered"
        if entry.covered or named == "covered" or named == "partial" then
          covered = covered + 1
          state = "covered"
          if
            named == "partial"
            or (branches and (branches.total or 0) > 0 and (branches.covered or 0) < branches.total)
          then
            state = "partial"
          end
        end
        total = total + 1
        marks[entry.line] = { state = state, branches = branches }
      end
    end
  end
  return marks, covered, total
end

-- Whole percent, rounded down so an incomplete file never reads 100%.
function M.percent(covered, total)
  if total <= 0 then
    return nil
  end
  return math.floor(covered * 100 / total)
end

-- Toggles `line` in a sorted list of breakpoint lines; returns the new list and whether it was added.
function M.toggle(lines, line)
  local out, found = {}, false
  for _, existing in ipairs(lines) do
    if existing == line then
      found = true
    else
      out[#out + 1] = existing
    end
  end
  if not found then
    out[#out + 1] = line
    table.sort(out)
  end
  return out, not found
end

-- Percent-encodes a path for a `file://` URL.
function M.file_url(path, line)
  local encoded = string.gsub(path, "[^%w%-%._~/]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return "file://" .. encoded .. (line and ("#L" .. line) or "")
end

-- A version 4 UUID from `random(lo, hi)` (math.random), for broker command ids.
function M.uuid(random)
  local hex = "0123456789abcdef"
  return (
    string.gsub("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx", "[xy]", function(c)
      local v = c == "x" and random(0, 15) or random(8, 11)
      return string.sub(hex, v + 1, v + 1)
    end)
  )
end

local COMMENTS = { javascript = "//", typescript = "//", kotlin = "//", python = "#" }

-- The line comment prefix for `path`'s language.
function M.comment(path)
  return COMMENTS[M.lang(path) or ""]
end

-- `s` (valid UTF-8) as UTF-16BE bytes: the encoding coverage artifacts digest source identity in.
function M.utf16be(s)
  local out = {}
  local function unit(u)
    out[#out + 1] = string.char(math.floor(u / 256), u % 256)
  end
  for _, cp in utf8.codes(s) do
    if cp >= 0x10000 then
      local v = cp - 0x10000
      unit(0xD800 + math.floor(v / 1024))
      unit(0xDC00 + v % 1024)
    else
      unit(cp)
    end
  end
  return table.concat(out)
end

-- A short fingerprint of `text` (its length and a rolling hash), to tell whether the disk still holds
-- the text an unsaved draft was based on.
function M.digest(text)
  local h = 0
  for i = 1, #text do
    h = (h * 31 + string.byte(text, i)) % 4294967291
  end
  return string.format("%d:%d", #text, h)
end

-- What to do with an unsaved draft restored after a reload or restart: "apply" it when the disk still
-- holds the text it was based on, "conflict" when the disk changed since (or the base is unknown), so
-- the block asks instead of saving the draft over newer contents; "none" without a draft.
function M.restore_plan(draft, base, disk_digest)
  if type(draft) ~= "string" then
    return "none"
  end
  return base == disk_digest and "apply" or "conflict"
end

-- Current line -> line of `base` (the text a measurement was taken on), through their common leading
-- and trailing lines; lines in the changed middle map to false (no mark until the next measurement).
function M.line_map(base, current)
  local head = 0
  while head < #base and head < #current and base[head + 1] == current[head + 1] do
    head = head + 1
  end
  local tail = 0
  while tail < #base - head and tail < #current - head and base[#base - tail] == current[#current - tail] do
    tail = tail + 1
  end
  local map = {}
  for i = 1, #current do
    if i <= head then
      map[i] = i
    elseif i > #current - tail then
      map[i] = i - #current + #base
    else
      map[i] = false
    end
  end
  return map
end

return M
