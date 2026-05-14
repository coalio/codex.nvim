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
      'codex.prompt',
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
    package.loaded['codex.prompt'] = nil
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
    eq('', sent_prompt)
    assert(sent_opts and sent_opts.selection, 'selection should be sent')
    eq(false, sent_opts.submit)
    eq('beta\ngamma', sent_opts.selection.text)

    vim.ui.input = original_input
  end)

  it('captures active-buffer context before opening the terminal pane', function()
    require('codex').setup {
      backend = 'app_server',
      cmd = 'echo',
      autoinstall = false,
      app_server = { ui = 'terminal' },
    }

    vim.cmd 'enew'
    vim.api.nvim_buf_set_name(0, '/tmp/codex-active-context.lua')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local value = 1' })
    vim.api.nvim_buf_set_option(0, 'modified', false)

    local app_server = require 'codex.app_server'
    local terminal = require 'codex.terminal'
    local captured_opts

    terminal.open_placeholder = function()
      vim.cmd 'enew!'
      vim.api.nvim_buf_set_option(0, 'filetype', 'codex')
    end
    terminal.is_requested = function()
      return true
    end
    app_server.start = function(callback)
      callback(true)
    end
    app_server.send = function(_, opts)
      captured_opts = opts
    end

    require('codex').send('Explain this file')

    assert(captured_opts and captured_opts.active_context, 'active context should be captured before terminal focus changes')
    eq('/tmp/codex-active-context.lua', captured_opts.active_context.path)
    assert(captured_opts.active_description:match 'codex%-active%-context%.lua', 'active description should refer to the original buffer')
  end)

  it('opens the terminal TUI against a remote app-server', function()
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
    package.loaded['codex.prompt'] = nil
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

    terminal.open_placeholder()
    terminal.open_remote('ws://127.0.0.1:45555', 'thread-123')

    assert(received_cmd, 'termopen should be called')
    eq('codex', received_cmd[1])
    eq('--remote', received_cmd[2])
    assert(vim.tbl_contains(received_cmd, '--remote'), 'remote flag missing')
    assert(vim.tbl_contains(received_cmd, 'ws://127.0.0.1:45555'), 'remote url missing')
    assert(not vim.tbl_contains(received_cmd, 'resume'), 'remote TUI should not use resume')
    assert(not vim.tbl_contains(received_cmd, 'thread-123'), 'remote TUI should not resume app-server thread ids')

    vim.fn = original_fn
  end)

  it('inserts selected file references into the remote terminal prompt', function()
    local original_fn = vim.fn
    local received_cmd
    local sent = {}

    vim.fn = setmetatable({
      executable = function()
        return 1
      end,
      termopen = function(cmd, opts)
        received_cmd = cmd
        assert(type(opts.on_exit) == 'function', 'termopen should receive on_exit')
        return 654
      end,
      chansend = function(_, text)
        table.insert(sent, text)
        return #text
      end,
    }, { __index = original_fn })

    package.loaded['codex.state'] = nil
    package.loaded['codex.prompt'] = nil
    package.loaded['codex.terminal'] = nil
    local terminal = require 'codex.terminal'
    terminal.setup {
      cmd = 'codex',
      autoinstall = false,
      keymaps = {},
      width = 0.8,
      height = 0.8,
      border = 'single',
      panel = false,
      use_buffer = false,
      include_active_buffer_context = false,
    }

    terminal.open_placeholder()
    terminal.insert('', {
      selection = {
        filePath = '/tmp/example.lua',
        text = 'print("hi")',
        selection = {
          isEmpty = false,
          start = { line = 4, character = 0 },
          ['end'] = { line = 4, character = 11 },
        },
      },
    })
    terminal.open_remote('ws://127.0.0.1:45555')

    assert(received_cmd, 'termopen should be called')
    eq(3, #received_cmd)
    assert(not vim.tbl_contains(received_cmd, 'print("hi")'), 'remote command should not receive selected source text')
    vim.wait(1000, function()
      return #sent > 0
    end, 10)
    local pasted = table.concat(sent, '')
    assert(pasted:match '@/tmp/example%.lua#L5', 'terminal insert should use compact file-line reference')
    assert(not pasted:match 'print%("hi"%)', 'terminal insert should not include selected source text')

    vim.fn = original_fn
  end)

  it('formats submitted selections as compact references without source snippets', function()
    package.loaded['codex.state'] = nil
    package.loaded['codex.prompt'] = nil
    local prompt = require 'codex.prompt'
    local text = prompt.terminal('Explain this', {
      selection = {
        filePath = '/tmp/example.lua',
        text = 'print("hi")',
        selection = {
          isEmpty = false,
          start = { line = 4, character = 0 },
          ['end'] = { line = 6, character = 11 },
        },
      },
    }, { include_active_buffer_context = false })

    assert(text:match 'Explain this', 'prompt should include user text')
    assert(text:match '@/tmp/example%.lua#L5%-L7', 'prompt should include compact line reference')
    assert(not text:match 'print%("hi"%)', 'prompt should not include selected source text')
  end)

  it('does not reuse a dirty buffer for terminal startup', function()
    local original_fn = vim.fn
    local old_buf = vim.api.nvim_create_buf(false, false)
    local start_buf
    vim.api.nvim_buf_set_lines(old_buf, 0, -1, false, { 'stale exited terminal output' })

    vim.fn = setmetatable({
      executable = function()
        return 1
      end,
      termopen = function(_, opts)
        start_buf = vim.api.nvim_get_current_buf()
        if type(opts.on_exit) == 'function' then
          vim.defer_fn(function()
            opts.on_exit(0)
          end, 10)
        end
        return 789
      end,
    }, { __index = original_fn })

    package.loaded['codex.state'] = nil
    package.loaded['codex.terminal'] = nil
    local state = require 'codex.state'
    local terminal = require 'codex.terminal'
    state.buf = old_buf
    terminal.setup {
      cmd = 'codex',
      autoinstall = false,
      keymaps = {},
      width = 0.8,
      height = 0.8,
      border = 'single',
      panel = false,
      use_buffer = false,
    }

    terminal.open_placeholder()
    terminal.open_remote('ws://127.0.0.1:45555', 'session-123')

    assert(start_buf and start_buf ~= old_buf, 'terminal should start in a fresh buffer')
    assert(not vim.api.nvim_buf_get_option(start_buf, 'modified'), 'terminal start buffer should be unmodified')

    vim.fn = original_fn
  end)
end)
