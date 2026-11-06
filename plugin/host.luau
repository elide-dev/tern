-- Host half: command lenses over ordinary `elide` invocations in a plain terminal.
-- Elide's own interactive surfaces negotiate the Tern Surface Protocol themselves;
-- lenses only cover commands whose output is machine-readable text.

-- Output beyond these bounds stays raw: a tree of that size is not browsable anyway.
local MAX_LINES = 20000
local MAX_BYTES = 4 * 1024 * 1024

-- JSON output (`elide project export`, `--json` reporters) as a native tree.
tern.lens.define("json", {
  open = function()
    return { lines = {}, bytes = 0, truncated = false }
  end,
  line = function(state, l)
    if state.truncated then
      return
    end
    if #state.lines >= MAX_LINES or state.bytes + #l.text > MAX_BYTES then
      state.truncated = true
      return
    end
    table.insert(state.lines, l.text)
    state.bytes += #l.text + 1
  end,
  finish = function() end,
  view = function(state)
    if state.truncated then
      return nil
    end
    return tern.parse.json_tree(table.concat(state.lines, "\n"))
  end,
})
