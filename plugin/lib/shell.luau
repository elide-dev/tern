-- Pure parser for the command lines shells report to `command_started` and `command_finished`.
-- No `tern` calls. Kept to the subset Luau shares with Lua 5.4 so `tests/shell.lua` runs under
-- plain `lua`.

local M = {}

-- `elide` global options that take their value as the next word (`-p DIR`, `--env-file FILE`).
-- Options declared with `require_equals` take theirs only as `--name=value` and are not listed.
local VALUED = {}
for _, option in ipairs({
  "-D",
  "-W",
  "-X",
  "-f",
  "-m",
  "-p",
  "--debugger-host",
  "--debugger-port",
  "--env-file",
  "--error-format",
  "--flag",
  "--heap-dump",
  "--heap-dump-on-oom",
  "--insights",
  "--jfr",
  "--jfr-settings",
  "--jitdump",
  "--limit",
  "--locale",
  "--max-mem",
  "--project",
  "--properties-file",
  "--redirect-warnings",
  "--timeout",
  "--transport",
  "--use-version",
  "--vm",
}) do
  VALUED[option] = true
end

local COMMANDS = { test = true, build = true, run = true, install = true, toolchain = true }

-- The argument words of the first simple command in `line`, and whether a control operator
-- (`|`, `;`, `&`, a newline) follows it: then the status the shell reports may not be that
-- command's. Quotes and backslashes group and escape as in POSIX sh; redirections (`2>&1`,
-- `> log`, `&> log`) and their targets are dropped; nothing is expanded.
function M.words(line)
  local words, word, quote, skip = {}, nil, nil, false
  local function finish()
    if word then
      if skip then
        skip = false
      else
        table.insert(words, word)
      end
      word = nil
    end
  end
  local i, n = 1, #line
  while i <= n do
    local c = string.sub(line, i, i)
    local after = string.sub(line, i + 1, i + 1)
    if quote == "'" then
      if c == "'" then
        quote = nil
      else
        word = word .. c
      end
    elseif quote == '"' then
      if c == '"' then
        quote = nil
      elseif c == "\\" and after ~= "" and string.find('"\\$`', after, 1, true) then
        word = word .. after
        i = i + 1
      else
        word = word .. c
      end
    elseif c == "'" or c == '"' then
      quote = c
      word = word or ""
    elseif c == "\\" then
      word = (word or "") .. after
      i = i + 1
    elseif c == ">" or c == "<" or (c == "&" and after == ">") then
      -- `2>`: the digits are the redirected descriptor, not an argument.
      if word and string.find(word, "^%d+$") then
        word = nil
      end
      finish()
      while string.find(string.sub(line, i + 1, i + 1), "^[<>&|]$") do
        i = i + 1
      end
      skip = true
    elseif c == "|" or c == ";" or c == "&" or c == "\n" then
      finish()
      return words, true
    elseif string.find(c, "^%s$") then
      finish()
    else
      word = (word or "") .. c
    end
    i = i + 1
  end
  finish()
  return words, false
end

-- `elide test|build|run|install …` as a shell reported it: the subcommand, its subject words
-- joined by spaces (nil when none), and whether the line goes on past the command (see
-- `M.words`). Leading `VAR=value` assignments and global options with their values are skipped.
-- Nil for any other line.
function M.elide(line)
  local words, compound = M.words(line)
  local index = 1
  while words[index] and string.find(words[index], "^[%a_][%w_]*=") do
    index = index + 1
  end
  local program = words[index] and string.match(words[index], "([^/]+)$")
  if program ~= "elide" then
    return nil
  end
  local command, subject = nil, {}
  local position = index + 1
  while position <= #words do
    local word = words[position]
    if string.sub(word, 1, 1) == "-" then
      if VALUED[word] then
        position = position + 1
      end
    elseif command then
      table.insert(subject, word)
    else
      command = word
    end
    position = position + 1
  end
  if not COMMANDS[command] then
    return nil
  end
  return command, (#subject > 0) and table.concat(subject, " ") or nil, compound
end

return M
