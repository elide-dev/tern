-- Requests to the Compose preview service on 127.0.0.1, from either plugin half. `cb` receives
-- the HTTP status (0 when no response arrived), the body, the window half's fresh `cx` and
-- whether the timeout ended the request.
local function request(url, body, timeout_ms, cb)
  tern.fetch(
    url,
    { method = if body then "POST" else "GET", body = body, timeout_ms = timeout_ms },
    function(result, cx)
      cb(if result.error then 0 else result.status, result.body or "", cx, result.timed_out)
    end
  )
end

return { request = request }
