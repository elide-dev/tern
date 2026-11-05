local M = {}

function M.request(request, callback)
  local ok, config = pcall(function()
    return tern.json.decode(tern.fs.read(tern.plugin.dir .. "/config.json"))
  end)
  if not ok or type(config) ~= "table" or type(config.sdk) ~= "string" then
    callback(nil, "Configure plugin/config.json with the extracted Elide SDK directory.")
    return
  end
  if request.op == "open" then
    request.sdk = config.sdk
  end
  local binary = config.broker or "../dist/elide-tern-broker"
  if string.sub(binary, 1, 1) ~= "/" then
    binary = tern.plugin.dir .. "/" .. binary
  end
  local state = config.state or (tern.plugin.data .. "/broker")
  local started, failure = pcall(function()
    tern.process.run({ binary, "request", state }, {
      stdin = tern.json.encode(request),
      timeout_ms = 20000,
    }, function(result)
      if result.status ~= 0 then
        callback(nil, result.stderr ~= "" and result.stderr or "Broker request failed or timed out.")
        return
      end
      local parsed, response = pcall(tern.json.decode, result.stdout)
      if not parsed or type(response) ~= "table" then
        callback(nil, "Invalid broker response.")
      elseif not response.ok then
        callback(nil, response.error)
      else
        callback(response.result, nil)
      end
    end)
  end)
  if not started then
    callback(nil, tostring(failure))
  end
end

return M
