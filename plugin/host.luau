-- Host half: command lenses over ordinary `elide` invocations in a plain terminal.
-- Elide's own interactive surfaces negotiate the Tern Surface Protocol themselves;
-- lenses only cover commands whose output is machine-readable text.

-- JSON output (`elide project export`, `--json` reporters) as a native tree.
tern.lens.define("json", {
  open = function()
    return { lines = {} }
  end,
  line = function(state, l)
    table.insert(state.lines, l.text)
  end,
  finish = function() end,
  view = function(state)
    return tern.parse.json_tree(table.concat(state.lines, "\n"))
  end,
})
