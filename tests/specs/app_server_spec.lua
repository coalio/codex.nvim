local eq = assert.equals

describe('codex app-server support', function()
  local original_cwd
  local original_fn

  before_each(function()
    original_cwd = vim.fn.getcwd()
    original_fn = vim.fn
  end)

  after_each(function()
    if original_fn then
      vim.fn = original_fn
    end
    if original_cwd then
      vim.cmd('cd ' .. vim.fn.fnameescape(original_cwd))
    end
  end)

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

  it('restarts the websocket app-server when the Neovim cwd changes', function()
    package.loaded['codex.state'] = nil
    package.loaded['codex.app_server_process'] = nil
    local state = require 'codex.state'
    local app_process = require 'codex.app_server_process'
    local starts = {}
    local stopped = {}
    local exits = {}
    local first_dir = '/tmp/codex-nvim-workspace-one'
    local second_dir = '/tmp/codex-nvim-workspace-two'
    vim.fn.mkdir(first_dir, 'p')
    vim.fn.mkdir(second_dir, 'p')

    vim.fn = setmetatable({
      jobstart = function(cmd, opts)
        local job = 101 + #starts
        table.insert(starts, { cmd = cmd, cwd = opts.cwd, job = job })
        exits[job] = opts.on_exit
        return job
      end,
      jobstop = function(job)
        table.insert(stopped, job)
      end,
    }, { __index = original_fn })

    local config = {
      cmd = { 'codex' },
      app_server = {
        port_range = { min = 45000, max = 45999 },
        enable_features = {},
      },
    }

    vim.cmd('cd ' .. vim.fn.fnameescape(first_dir))
    app_process.start(config, function(ok)
      assert(ok, 'first app-server start should succeed')
    end)
    app_process.start(config, function(ok)
      assert(ok, 'same-cwd app-server reuse should succeed')
    end)

    vim.cmd('cd ' .. vim.fn.fnameescape(second_dir))
    app_process.start(config, function(ok)
      assert(ok, 'second app-server start should succeed')
    end)

    eq(2, #starts)
    eq(first_dir, starts[1].cwd)
    eq(second_dir, starts[2].cwd)
    eq(1, #stopped)
    eq(101, stopped[1])
    eq(second_dir, state.app.cwd)
    exits[101](101, 0)
    eq(102, state.app.server_job)
    eq(second_dir, state.app.cwd)

    app_process.stop()
  end)
end)
