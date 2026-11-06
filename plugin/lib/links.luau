-- Pure parser for `elide://` links (see docs/architecture.md, "elide:// links").
-- No `tern` calls: the window half checks the filesystem and acts on the result.
-- Kept to the subset Luau shares with Lua 5.4 so `tests/links.lua` runs under plain `lua`.

local M = {}

local MAX_URL = 8192
local MAX_NUMBER = 1000000000

-- Which query keys each action takes, and which it requires.
local ACTIONS = {
  source = { keys = { path = true, root = true, line = true, col = true }, required = { "path" } },
  debug = { keys = { root = true, path = true, line = true }, required = { "root", "path" } },
  tests = { keys = { root = true }, required = { "root" } },
}

-- Decodes `%XX` escapes; nil for a malformed escape or a decoded control character.
-- `+` stays a literal plus: paths may contain one, and the contract percent-encodes spaces.
function M.decode(value)
  if string.find(value, "%%[^%x]") or string.find(value, "%%%x[^%x]") or string.find(value, "%%%x?$") then
    return nil
  end
  local decoded = string.gsub(value, "%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  if string.find(decoded, "[%c]") then
    return nil
  end
  return decoded
end

-- An absolute path with no empty, `.` or `..` segments and no trailing slash, or nil.
function M.absolute(path)
  if type(path) ~= "string" or string.sub(path, 1, 1) ~= "/" or path == "/" then
    return nil
  end
  if string.sub(path, -1) == "/" then
    path = string.sub(path, 1, -2)
  end
  for segment in string.gmatch(string.sub(path, 2) .. "/", "([^/]*)/") do
    if segment == "" or segment == "." or segment == ".." then
      return nil
    end
  end
  return path
end

-- Whether `path` lies strictly inside `root` (both already through `absolute`).
function M.within(path, root)
  return string.sub(path, 1, #root + 1) == root .. "/"
end

local function number(value)
  if not string.find(value, "^%d+$") then
    return nil
  end
  local n = tonumber(value)
  if not n or n < 1 or n > MAX_NUMBER then
    return nil
  end
  return n
end

-- Parses `elide://<action>?<query>` into `{ action, root?, path?, line?, col? }`.
-- Returns nil for any other scheme, an unknown action, a malformed or duplicate query
-- value, a non-absolute path, or a `path` outside the given `root`. Unknown keys are
-- ignored so later contract versions can add some. When `root` is absent, the caller
-- must still confine `path` to a detected project root.
function M.parse(url)
  if type(url) ~= "string" or #url > MAX_URL then
    return nil
  end
  local scheme, action, query = string.match(url, "^(%a[%w+.-]*)://(%a+)/?%?([^#]*)$")
  if not scheme or string.lower(scheme) ~= "elide" then
    return nil
  end
  local spec = ACTIONS[action]
  if not spec then
    return nil
  end
  local fields = {}
  for pair in string.gmatch(query .. "&", "([^&]*)&") do
    if pair ~= "" then
      local key, raw = string.match(pair, "^([^=]+)=(.*)$")
      if not key then
        return nil
      end
      local value = M.decode(raw)
      key = M.decode(key)
      if not key or not value then
        return nil
      end
      if spec.keys[key] then
        if fields[key] ~= nil then
          return nil
        end
        fields[key] = value
      end
    end
  end
  for _, key in ipairs(spec.required) do
    if fields[key] == nil or fields[key] == "" then
      return nil
    end
  end
  local result = { action = action }
  for _, key in ipairs({ "root", "path" }) do
    if fields[key] ~= nil then
      result[key] = M.absolute(fields[key])
      if not result[key] then
        return nil
      end
    end
  end
  for _, key in ipairs({ "line", "col" }) do
    if fields[key] ~= nil then
      result[key] = number(fields[key])
      if not result[key] then
        return nil
      end
    end
  end
  if result.col and not result.line then
    return nil
  end
  if result.root and result.path and not M.within(result.path, result.root) then
    return nil
  end
  return result
end

return M
