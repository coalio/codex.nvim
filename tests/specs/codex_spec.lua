-- tests/codex_spec.lua
-- luacheck: globals describe it assert eq
-- luacheck: ignore a            -- “a” is imported but unused
local a = require 'plenary.async.tests'
local eq = assert.equals

describe('codex.nvim', function()
  before_each(function()
    for _, module in ipairs {
      'codex',
      'codex.app_server',
      'codex.commands',
      'codex.config',
      'codex.selection',
      'codex.state',
      'codex.terminal',
      'codex.ui',
    } do
      package.loaded[module] = nil
    end
    vim.cmd 'set noswapfile' -- prevent side effects
    vim.cmd 'silent! bwipeout!' -- close any open codex windows
  end)

  it('loads the module', function()
    local ok, codex = pcall(require, 'codex')
    assert(ok, 'codex module failed to load')
    assert(codex.open, 'codex.open missing')
    assert(codex.close, 'codex.close missing')
    assert(codex.toggle, 'codex.toggle missing')
  end)

  it('creates Codex commands', function()
    require('codex').setup { backend = 'terminal', keymaps = {} }

    local cmds = vim.api.nvim_get_commands {}
    assert(cmds['Codex'], 'Codex command not found')
    assert(cmds['CodexToggle'], 'CodexToggle command not found')
    assert(cmds['CodexSend'], 'CodexSend command not found')
    assert(cmds['CodexMcp'], 'CodexMcp command not found')
  end)

  it('opens a floating terminal window', function()
    require('codex').setup { backend = 'terminal', cmd = { 'echo', 'test' } }
    require('codex').open()

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local ft = vim.api.nvim_buf_get_option(buf, 'filetype')
    eq(ft, 'codex')

    require('codex').close()
  end)

  it('toggles the window', function()
    require('codex').setup { backend = 'terminal', cmd = { 'echo', 'test' } }

    require('codex').toggle()
    local win1 = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win1)

    assert(vim.api.nvim_win_is_valid(win1), 'Codex window should be open')

    -- Optional: manually mark it clean
    vim.api.nvim_buf_set_option(buf, 'modified', false)

    require('codex').toggle()

    local ok, _ = pcall(vim.api.nvim_win_get_buf, win1)
    assert(not ok, 'Codex window should be closed')
  end)

  it('shows statusline only when job is active but window is not', function()
    require('codex').setup { backend = 'terminal', cmd = { 'sleep', '1000' } }
    require('codex').open()

    vim.wait(500, function()
      return require('codex.state').job ~= nil
    end, 10)

    require('codex').close()
    local status = require('codex').statusline()
    eq(status, '[Codex]')

    local job = require('codex.state').job
    if job then
      vim.fn.jobstop(job)
      require('codex.state').job = nil
    end
  end)

  it('passes -m <model> to termopen when configured', function()
    local original_fn = vim.fn
    local termopen_called = false
    local received_cmd = {}

    -- Mock vim.fn with proxy
    vim.fn = setmetatable({
      termopen = function(cmd, opts)
        termopen_called = true
        received_cmd = cmd
        if type(opts.on_exit) == 'function' then
          vim.defer_fn(function()
            opts.on_exit(0)
          end, 10)
        end
        return 123
      end,
    }, { __index = original_fn })

    -- Reload module fresh
    package.loaded['codex'] = nil
    package.loaded['codex.state'] = nil
    package.loaded['codex.terminal'] = nil
    local codex = require 'codex'

    codex.setup {
      backend = 'terminal',
      cmd = 'codex',
      model = 'o3-mini',
    }

    codex.open()

    vim.wait(500, function()
      return termopen_called
    end, 10)

    assert(termopen_called, 'termopen should be called')
    assert(type(received_cmd) == 'table', 'cmd should be passed as a list')
    assert(vim.tbl_contains(received_cmd, '-m'), 'should include -m flag')
    assert(vim.tbl_contains(received_cmd, 'o3-mini'), 'should include specified model name')

    -- Restore original
    vim.fn = original_fn
  end)

  it('sends visual ranges without asking for an extra prompt', function()
    local sent_prompt
    local sent_opts
    local input_called = false
    local original_input = vim.ui.input
    vim.ui.input = function()
      input_called = true
    end

    require('codex.commands').setup({
      selection_prompt = 'Use selected context',
      app_server = { ui = 'terminal' },
    }, {
      send = function(prompt, opts)
        sent_prompt = prompt
        sent_opts = opts
      end,
    })

    vim.cmd 'enew'
    vim.api.nvim_buf_set_name(0, '/tmp/codex-command-selection.lua')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'alpha', 'beta', 'gamma' })
    vim.cmd '2,3CodexSend'

    assert(not input_called, 'visual/range send should not call vim.ui.input')
    eq('Use selected context', sent_prompt)
    assert(sent_opts and sent_opts.selection, 'selection should be sent')
    eq('beta\ngamma', sent_opts.selection.text)

    vim.ui.input = original_input
  end)

  it('opens the terminal TUI against a remote app-server thread', function()
    local original_fn = vim.fn
    local received_cmd

    vim.fn = setmetatable({
      executable = function()
        return 1
      end,
      termopen = function(cmd, opts)
        received_cmd = cmd
        if type(opts.on_exit) == 'function' then
          vim.defer_fn(function()
            opts.on_exit(0)
          end, 10)
        end
        return 456
      end,
    }, { __index = original_fn })

    package.loaded['codex.state'] = nil
    package.loaded['codex.terminal'] = nil
    local terminal = require 'codex.terminal'
    terminal.setup {
      cmd = 'codex',
      model = 'gpt-test',
      autoinstall = false,
      keymaps = {},
      width = 0.8,
      height = 0.8,
      border = 'single',
      panel = false,
      use_buffer = false,
    }

    terminal.open_remote('ws://127.0.0.1:45555', 'thread-123')

    assert(received_cmd, 'termopen should be called')
    eq('codex', received_cmd[1])
    eq('resume', received_cmd[2])
    assert(vim.tbl_contains(received_cmd, '--remote'), 'remote flag missing')
    assert(vim.tbl_contains(received_cmd, 'ws://127.0.0.1:45555'), 'remote url missing')
    assert(vim.tbl_contains(received_cmd, 'thread-123'), 'thread id missing')

    vim.fn = original_fn
  end)
end)
