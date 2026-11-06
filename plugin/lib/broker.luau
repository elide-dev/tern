local M = {}

local function configuration()
  local ok, config = pcall(function()
    return tern.json.decode(tern.fs.read(tern.plugin.dir .. "/config.json", 65536))
  end)
  if ok and type(config) == "table" then
    return config
  end
  return nil
end

local function resolve(value)
  if string.sub(value, 1, 1) == "/" then
    return value
  end
  return tern.plugin.dir .. "/" .. value
end

-- Runs one broker request against `state`; `callback(result, err, transport)` where `transport`
-- is true when no response envelope arrived (the request may or may not have run).
local function send(binary, state, request, callback)
  local started, failure = pcall(function()
    tern.process.run({ binary, "request", state }, {
      stdin = tern.json.encode(request),
      timeout_ms = 20000,
    }, function(result)
      if result.status ~= 0 then
        callback(nil, result.stderr ~= "" and result.stderr or "Broker request failed or timed out.", true)
        return
      end
      local parsed, response = pcall(tern.json.decode, result.stdout)
      if not parsed or type(response) ~= "table" then
        callback(nil, "Invalid broker response.", true)
      elseif not response.ok then
        callback(nil, response.error, false)
      else
        callback(response.result, nil, false)
      end
    end)
  end)
  if not started then
    callback(nil, tostring(failure), true)
  end
end

function M.request(request, callback)
  local config = configuration()
  if not config or type(config.sdk) ~= "string" then
    callback(nil, "Configure plugin/config.json with the extracted Elide SDK directory.")
    return
  end
  if request.op == "open" then
    request.sdk = config.sdk
  end
  send(
    resolve(config.broker or "../dist/elide-tern-broker"),
    config.state or (tern.plugin.data .. "/broker"),
    request,
    callback
  )
end

-- Shared project operations (docs/protocol.md), on the same broker state the native project,
-- debug and agent surfaces use, so attachments see one test and debug session per project.
-- `project_attach` gets the configured runtime filled in.
function M.project(request, callback)
  local config = configuration()
  if not config then
    callback(nil, "Configure plugin/config.json before attaching to a project.", false)
    return
  end
  if request.op == "project_attach" then
    local runtime = config.runtime or "elide"
    if string.find(runtime, "/") then
      runtime = resolve(runtime)
    end
    request.runtime = runtime
  end
  send(
    resolve(config.broker or "../dist/elide-tern-broker"),
    config.project_state or (config.state and (config.state .. "-projects")) or (tern.plugin.data .. "/projects"),
    request,
    callback
  )
end

return M
