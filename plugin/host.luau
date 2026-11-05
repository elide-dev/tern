local broker = require("./lib/broker")
local ui = tern.ui
local panes = {}

local function append(state, text)
  state.output = string.sub(state.output .. text .. "\n", -32768)
end

local function close(state)
  state.closed = true
  state.epoch = (state.epoch or 0) + 1
  if state.session then
    broker.request({ op = "close", session = state.session }, function() end)
    state.session = nil
  end
end

local function start(state, cx)
  state.closed = false
  local epoch = state.epoch
  state.busy = true
  broker.request({ op = "open" }, function(opened, failure)
    if state.closed or state.epoch ~= epoch then
      if opened then
        broker.request({ op = "close", session = opened.session }, function() end)
      end
      return
    end
    if failure then
      state.busy = false
      append(state, failure)
      cx:render()
      return
    end
    state.session = opened.session
    broker.request({ op = "open_kernel", session = state.session, language = state.language }, function(result, problem)
      if state.closed or state.epoch ~= epoch then
        return
      end
      state.busy = false
      if problem then
        append(state, problem)
        close(state)
      else
        state.kernel = result.kernel
        append(state, "Ready. Enter evaluates; Shift+Enter inserts a newline. Reset starts a fresh runtime.")
      end
      cx:render()
    end)
  end)
end

local function evaluate(state, cx)
  if state.busy or not state.kernel or state.closed or state.source == "" then
    return
  end
  local epoch = state.epoch
  local source = state.source
  state.source = ""
  state.busy = true
  append(state, "> " .. source)
  broker.request({
    op = "evaluate",
    session = state.session,
    kernel = state.kernel,
    language = state.language,
    source = source,
  }, function(result, failure)
    if state.closed or state.epoch ~= epoch then
      return
    end
    state.busy = false
    if failure then
      append(state, failure .. "\nIf the session expired or timed out, use Reset.")
    else
      append(state, (result.stdout or "") .. (result.stderr or "") .. (result.value or ""))
      if result.truncated then
        append(state, "[Runtime output truncated]")
      end
    end
    cx:render()
  end)
end

tern.block.define("repl", {
  init = function(cx, args, saved)
    local previous = panes[cx.pane]
    if previous then
      close(previous)
    end
    local state = { language = args[1] or (saved and saved.language) or "js", source = "", output = "", busy = false }
    panes[cx.pane] = state
    start(state, cx)
    return state
  end,
  title = function(state)
    return "REPL · " .. state.language
  end,
  view = function(state)
    return {
      main = ui.col({ ui.text(state.output), ui.text("> " .. state.source) }),
      dock = ui.row({
        ui.text(state.busy and "Running…" or state.language),
        ui.button("Evaluate", { actions = { click = "evaluate" }, disabled = state.busy or not state.kernel }),
        ui.button("Reset", { actions = { click = "reset" } }),
      }),
    }
  end,
  key = function(state, key, cx)
    if key.name == "enter" and not key.shift then
      evaluate(state, cx)
    elseif key.name == "enter" then
      state.source ..= "\n"
    elseif key.name == "backspace" then
      local offset = utf8.offset(state.source, -1)
      if offset then
        state.source = string.sub(state.source, 1, offset - 1)
      end
    elseif key.text and not key.ctrl and not key.meta then
      if #state.source + #key.text <= 262144 then
        state.source ..= key.text
      end
    else
      return false
    end
    return true
  end,
  event = function(state, event, cx)
    if event.act == "evaluate" then
      evaluate(state, cx)
    elseif event.act == "reset" then
      close(state)
      state.kernel = nil
      state.output = ""
      state.source = ""
      start(state, cx)
    end
  end,
  save = function(state)
    return { language = state.language }
  end,
})

tern.on("pane_exited", function(event)
  local state = panes[event.pane]
  if state then
    close(state)
    panes[event.pane] = nil
  end
end)
