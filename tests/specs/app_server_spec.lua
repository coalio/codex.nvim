local eq = assert.equals

describe('codex app-server support', function()
  it('registers Neovim dynamic tools', function()
    package.loaded['codex.tools'] = nil
    local tools = require 'codex.tools'
    local specs = tools.get_specs()

    local names = {}
    for _, spec in ipairs(specs) do
      names[spec.name] = spec
    end

    assert(names.openFile, 'openFile tool missing')
    assert(names.getCurrentSelection, 'getCurrentSelection tool missing')
    assert(names.getDiagnostics, 'getDiagnostics tool missing')
    eq('nvim', names.openFile.namespace)
  end)

  it('tracks range selections with zero-based protocol positions', function()
    local selection = require 'codex.selection'
    vim.cmd 'enew'
    vim.api.nvim_buf_set_name(0, '/tmp/codex-selection-test.lua')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'alpha', 'beta', 'gamma' })

    local sel = selection.get_range_selection(2, 3)

    assert(sel, 'selection should be captured')
    eq('beta\ngamma', sel.text)
    eq(1, sel.selection.start.line)
    eq(2, sel.selection['end'].line)
  end)
end)
