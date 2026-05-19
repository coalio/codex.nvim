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
      'codex.util',
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
    assert(codex.resume, 'codex.resume missing')
    assert(codex.focus, 'codex.focus missing')
  end)

  it('creates Codex commands', function()
    require('codex').setup { backend = 'terminal', keymaps = {} }

    local cmds = vim.api.nvim_get_commands {}
    assert(cmds['Codex'], 'Codex command not found')
    assert(cmds['CodexToggle'], 'CodexToggle command not found')
    assert(cmds['CodexResume'], 'CodexResume command not found')
    assert(cmds['CodexFocus'], 'CodexFocus command not found')
    assert(cmds['CodexSend'], 'CodexSend command not found')
    assert(cmds['CodexSession'], 'CodexSession command not found')
    assert(cmds['CodexYolo'], 'CodexYolo command not found')
    assert(cmds['CodexMcp'], 'CodexMcp command not found')
  end)

  it('defaults panel width to one quarter of the editor', function()
    eq(0.25, require('codex.config').defaults.width)
  end)

  it('defaults Codex launch editor environment to nvim', function()
    local original_editor = vim.env.EDITOR
    local original_visual = vim.env.VISUAL
    vim.env.EDITOR = nil
    vim.env.VISUAL = nil

    package.loaded['codex.util'] = nil
    local env = require('codex.util').codex_env()

    eq('nvim', env.EDITOR)
    eq('nvim', env.VISUAL)

    vim.env.EDITOR = original_editor
    vim.env.VISUAL = original_visual
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

  it('resolves bare commands through the user shell when Neovim PATH does not contain them', function()
    local original_fn = vim.fn
    local shell_checked = false

    vim.fn = setmetatable({
      executable = function(path)
        if path == 'codex' then
          return 0
        end
        if path == '/opt/tools/codex' then
          return 1
        end
        return original_fn.executable(path)
      end,
      systemlist = function()
        shell_checked = true
        return { '__CODEX_NVIM_EXEC__/opt/tools/codex' }
      end,
    }, { __index = original_fn })

    package.loaded['codex.util'] = nil
    local resolved = require('codex.util').resolve_cmd { 'codex', '--remote', 'ws://127.0.0.1:45555' }

    assert(shell_checked, 'shell command lookup should be attempted')
    eq('/opt/tools/codex', resolved[1])
    eq('--remote', resolved[2])
    eq('ws://127.0.0.1:45555', resolved[3])

    vim.fn = original_fn
  end)

  it('starts the terminal with a shell-resolved Codex executable', function()
    local original_fn = vim.fn
    local received_cmd

    vim.fn = setmetatable({
      executable = function(path)
        if path == 'codex' then
          return 0
        end
        if path == '/opt/tools/codex' then
          return 1
        end
        return original_fn.executable(path)
      end,
      systemlist = function()
        return { '__CODEX_NVIM_EXEC__/opt/tools/codex' }
      end,
      termopen = function(cmd, opts)
        received_cmd = cmd
        if type(opts.on_exit) == 'function' then
          vim.defer_fn(function()
            opts.on_exit(0)
          end, 10)
        end
        return 124
      end,
    }, { __index = original_fn })

    package.loaded['codex.state'] = nil
    package.loaded['codex.prompt'] = nil
    package.loaded['codex.terminal'] = nil
    package.loaded['codex.util'] = nil
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
    }

    terminal.open()

    assert(received_cmd, 'termopen should be called')
    eq('/opt/tools/codex', received_cmd[1])

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

  it('keeps editor focus when inserting a visual selection reference', function()
    require('codex').setup {
      backend = 'app_server',
      cmd = 'echo',
      autoinstall = false,
      app_server = { ui = 'terminal' },
    }

    vim.cmd 'enew'
    vim.api.nvim_buf_set_name(0, '/tmp/codex-focus-source.lua')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'alpha', 'beta' })
    vim.api.nvim_buf_set_option(0, 'modified', false)
    local original_win = vim.api.nvim_get_current_win()
    local original_buf = vim.api.nvim_get_current_buf()

    local app_server = require 'codex.app_server'
    app_server.start = function(callback)
      callback(true)
    end
    app_server.send = function() end

    require('codex').send('', {
      submit = false,
      selection = {
        filePath = '/tmp/codex-focus-source.lua',
        text = 'alpha',
        selection = {
          isEmpty = false,
          start = { line = 0, character = 0 },
          ['end'] = { line = 0, character = 5 },
        },
      },
    })

    eq(original_win, vim.api.nvim_get_current_win())
    eq(original_buf, vim.api.nvim_get_current_buf())
    assert(require('codex.state').win and vim.api.nvim_win_is_valid(require('codex.state').win), 'Codex window should still be opened')
  end)

  it('opens the terminal TUI against a remote app-server', function()
    local original_fn = vim.fn
    local received_cmd
    local received_opts

    vim.fn = setmetatable({
      executable = function()
        return 1
      end,
      termopen = function(cmd, opts)
        received_cmd = cmd
        received_opts = opts
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
    assert(vim.tbl_contains(received_cmd, '--config'), 'vim mode config flag missing')
    assert(vim.tbl_contains(received_cmd, 'tui.vim_mode_default=true'), 'vim mode default override missing')
    assert(vim.tbl_contains(received_cmd, '--remote'), 'remote flag missing')
    assert(vim.tbl_contains(received_cmd, 'ws://127.0.0.1:45555'), 'remote url missing')
    assert(vim.tbl_contains(received_cmd, '--cd'), 'remote TUI should receive an explicit cwd')
    eq(vim.fn.getcwd(), received_cmd[#received_cmd])
    eq(vim.fn.getcwd(), received_opts.cwd)
    local expected_env = require('codex.util').codex_env()
    eq(expected_env.EDITOR, received_opts.env.EDITOR)
    eq(expected_env.VISUAL, received_opts.env.VISUAL)
    assert(not vim.tbl_contains(received_cmd, 'resume'), 'remote TUI should not use resume')
    assert(not vim.tbl_contains(received_cmd, 'thread-123'), 'remote TUI should not resume app-server thread ids')

    vim.fn = original_fn
  end)

  it('resumes the latest workspace session through the remote app-server TUI', function()
    local original_fn = vim.fn
    local received_cmd

    vim.fn = setmetatable({
      executable = function()
        return 1
      end,
      termopen = function(cmd, opts)
        received_cmd = cmd
        assert(type(opts.on_exit) == 'function', 'termopen should receive on_exit')
        return 457
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
      width = 0.25,
      height = 0.8,
      border = 'single',
      panel = false,
      use_buffer = false,
    }

    terminal.open_placeholder()
    terminal.open_remote('ws://127.0.0.1:45555', nil, { resume_last = true })

    assert(received_cmd, 'termopen should be called')
    eq('codex', received_cmd[1])
    eq('resume', received_cmd[2])
    assert(vim.tbl_contains(received_cmd, '--config'), 'vim mode config flag missing')
    assert(vim.tbl_contains(received_cmd, 'tui.vim_mode_default=true'), 'vim mode default override missing')
    assert(vim.tbl_contains(received_cmd, '--last'), 'resume should use --last')
    assert(vim.tbl_contains(received_cmd, '--remote'), 'resume should connect to the remote app-server')
    assert(vim.tbl_contains(received_cmd, 'ws://127.0.0.1:45555'), 'remote url missing')
    assert(vim.tbl_contains(received_cmd, 'gpt-test'), 'configured model should be forwarded to resume')
    assert(vim.tbl_contains(received_cmd, '--cd'), 'resume should be scoped to the Neovim cwd')
    eq(vim.fn.getcwd(), received_cmd[#received_cmd])

    vim.fn = original_fn
  end)

  it('opens numbered terminal sessions and sends to the selected session', function()
    local original_fn = vim.fn
    local next_job = 700
    local exits = {}
    local sent = {}
    local mouse_line = 3
    local function listed_empty_buffers()
      local count = 0
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if
          vim.api.nvim_buf_is_valid(bufnr)
          and vim.fn.buflisted(bufnr) == 1
          and vim.api.nvim_buf_get_name(bufnr) == ''
          and vim.api.nvim_buf_get_option(bufnr, 'buftype') == ''
        then
          count = count + 1
        end
      end
      return count
    end

    vim.fn = setmetatable({
      executable = function()
        return 1
      end,
      termopen = function(_, opts)
        next_job = next_job + 1
        exits[next_job] = opts.on_exit
        return next_job
      end,
      chansend = function(job, text)
        sent[job] = (sent[job] or '') .. text
        return #text
      end,
      getmousepos = function()
        return { winid = require('codex.state').picker_win, line = mouse_line }
      end,
    }, { __index = original_fn })

    package.loaded['codex.state'] = nil
    package.loaded['codex.prompt'] = nil
    package.loaded['codex.terminal'] = nil
    local state = require 'codex.state'
    local terminal = require 'codex.terminal'
    vim.cmd 'enew'
    vim.api.nvim_buf_set_name(0, '/tmp/codex-session-source.lua')
    local empty_buffers_before = listed_empty_buffers()
    terminal.setup {
      cmd = 'codex',
      autoinstall = false,
      keymaps = {},
      width = 0.25,
      height = 0.8,
      border = 'single',
      panel = true,
      use_buffer = false,
      include_active_buffer_context = false,
      session_picker = { enabled = true, width = 24 },
    }

    terminal.open({ new_session = true })
    local first_buf = state.buf
    local first_job = state.job

    terminal.new_session()
    local second_buf = state.buf
    local second_job = state.job

    eq(2, #state.session_order)
    eq(2, state.active_session_id)
    assert(state.picker_win and vim.api.nvim_win_is_valid(state.picker_win), 'session picker should be visible')
    local picker_lines = vim.api.nvim_buf_get_lines(state.picker_buf, 0, -1, false)
    eq(empty_buffers_before, listed_empty_buffers())
    eq('Codex Sessions', picker_lines[1])
    assert(picker_lines[3]:match '^[%w%-]+ %(1%)$', 'first session should have a named label')
    assert(picker_lines[4]:match '^[%w%-]+ %(2%)$', 'second session should have a named label')
    eq(1, state.picker_line_sessions[3])
    eq(2, state.picker_line_sessions[4])
    assert(#picker_lines[3] <= vim.api.nvim_win_get_width(state.picker_win), 'session label should fit picker width')
    eq(false, vim.api.nvim_win_get_option(state.picker_win, 'wrap'))
    eq(0, vim.api.nvim_win_get_option(state.picker_win, 'sidescrolloff'))

    local picker_ns = vim.api.nvim_get_namespaces()['codex.session_picker']
    local marks = vim.api.nvim_buf_get_extmarks(state.picker_buf, picker_ns, 0, -1, { details = true })
    local active_highlight_seen = false
    for _, mark in ipairs(marks) do
      local row = mark[2]
      local details = mark[4] or {}
      if row == 3 and (details.hl_group == 'CodexSessionActive' or details.line_hl_group == 'CodexSessionActive') then
        active_highlight_seen = true
      end
    end
    assert(active_highlight_seen, 'active session label should be highlighted')

    vim.api.nvim_set_current_win(state.picker_win)
    mouse_line = 3
    terminal.select_session_at_mouse()
    eq(1, state.active_session_id)
    eq(state.picker_win, vim.api.nvim_get_current_win())
    mouse_line = 4
    terminal.select_session_at_mouse()
    eq(2, state.active_session_id)
    eq(state.picker_win, vim.api.nvim_get_current_win())

    local picker_view = vim.api.nvim_win_call(state.picker_win, function()
      return vim.fn.winsaveview()
    end)
    eq(0, picker_view.leftcol)

    terminal.select_session(1, { focus = false })
    eq(1, state.active_session_id)
    eq(first_buf, state.buf)
    eq(first_job, state.job)
    eq(first_buf, vim.api.nvim_win_get_buf(state.win))

    terminal.send('first')
    terminal.select_session(2, { focus = false })
    terminal.send('second')

    assert(sent[first_job] and sent[first_job]:match 'first', 'first session should receive its prompt')
    assert(sent[second_job] and sent[second_job]:match 'second', 'second session should receive its prompt')
    assert(not (sent[first_job] or ''):match 'second', 'second prompt should not be sent to first session')

    exits[second_job](second_job, 0)
    eq(1, #state.session_order)
    eq(1, state.active_session_id)
    eq(first_buf, state.buf)
    eq(first_buf, vim.api.nvim_win_get_buf(state.win))

    terminal.close()
    vim.fn = original_fn
  end)

  it('launches all terminal sessions with vim mode config and supports YOLO sessions', function()
    local original_fn = vim.fn
    local received_cmds = {}

    vim.fn = setmetatable({
      executable = function()
        return 1
      end,
      termopen = function(cmd)
        table.insert(received_cmds, cmd)
        return 800 + #received_cmds
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
      width = 0.25,
      height = 0.8,
      border = 'single',
      panel = false,
      use_buffer = false,
    }

    terminal.open({ new_session = true })
    terminal.yolo()

    assert(vim.tbl_contains(received_cmds[1], '--config'), 'normal session should include --config')
    assert(vim.tbl_contains(received_cmds[1], 'tui.vim_mode_default=true'), 'normal session should enable vim mode')
    assert(vim.tbl_contains(received_cmds[2], '--config'), 'YOLO session should include --config')
    assert(vim.tbl_contains(received_cmds[2], 'tui.vim_mode_default=true'), 'YOLO session should enable vim mode')
    assert(vim.tbl_contains(received_cmds[2], '--dangerously-bypass-approvals-and-sandbox'), 'YOLO session should include bypass flag')

    terminal.close()
    vim.fn = original_fn
  end)

  it('opens panel mode as a full-height far-right split', function()
    package.loaded['codex.state'] = nil
    package.loaded['codex.prompt'] = nil
    package.loaded['codex.terminal'] = nil

    vim.cmd 'only!'
    vim.cmd 'new'
    vim.cmd 'wincmd J'
    local bottom_win = vim.api.nvim_get_current_win()
    local bottom_height = vim.api.nvim_win_get_height(bottom_win)

    local terminal = require 'codex.terminal'
    terminal.setup {
      cmd = 'codex',
      autoinstall = false,
      keymaps = {},
      width = 0.25,
      height = 0.8,
      border = 'single',
      panel = true,
      use_buffer = false,
    }

    terminal.open_placeholder()

    local codex_win = require('codex.state').win
    local pos = vim.api.nvim_win_get_position(codex_win)
    assert(pos[2] > 0, 'Codex panel should be on the right side')
    assert(vim.api.nvim_win_get_height(codex_win) > bottom_height, 'Codex panel should span the full editor height')
    assert(vim.api.nvim_win_get_width(codex_win) <= math.ceil(vim.o.columns * 0.4), 'Codex panel should not consume half the editor')
  end)

  it('keeps terminal windows wrapped to prevent horizontal side scrolling', function()
    local original_fn = vim.fn
    local source_win = vim.api.nvim_get_current_win()
    local source_wrap = vim.api.nvim_win_get_option(source_win, 'wrap')
    local source_sidescrolloff = vim.api.nvim_win_get_option(source_win, 'sidescrolloff')

    vim.api.nvim_win_set_option(source_win, 'wrap', false)
    vim.api.nvim_win_set_option(source_win, 'sidescrolloff', 12)

    vim.fn = setmetatable({
      executable = function()
        return 1
      end,
      termopen = function()
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_option(win, 'wrap', false)
        vim.api.nvim_win_set_option(win, 'sidescrolloff', 12)
        return 987
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
      width = 0.25,
      height = 0.8,
      border = 'single',
      panel = false,
      use_buffer = false,
    }

    terminal.open_placeholder()
    local codex_win = require('codex.state').win
    assert(vim.api.nvim_win_get_option(codex_win, 'wrap'), 'Codex terminal placeholder should wrap')
    eq(0, vim.api.nvim_win_get_option(codex_win, 'sidescrolloff'))

    terminal.open_remote('ws://127.0.0.1:45555')

    assert(vim.api.nvim_win_get_option(codex_win, 'wrap'), 'Codex terminal should wrap after termopen')
    eq(0, vim.api.nvim_win_get_option(codex_win, 'sidescrolloff'))

    vim.fn = original_fn
    if vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_win_set_option(source_win, 'wrap', source_wrap)
      vim.api.nvim_win_set_option(source_win, 'sidescrolloff', source_sidescrolloff)
    end
  end)

  it('auto-scrolls the terminal after new data when unfocused near the bottom', function()
    package.loaded['codex.state'] = nil
    package.loaded['codex.prompt'] = nil
    package.loaded['codex.terminal'] = nil

    local terminal = require 'codex.terminal'
    terminal.__test_autoscroll_delay_ms = 10
    terminal.setup {
      cmd = 'codex',
      autoinstall = false,
      keymaps = {},
      width = 0.25,
      height = 0.8,
      border = 'single',
      panel = false,
      use_buffer = false,
    }

    terminal.open_placeholder({ focus = false })
    local state = require 'codex.state'
    local lines = {}
    for i = 1, 40 do
      table.insert(lines, 'line ' .. i)
    end
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

    vim.wait(500, function()
      return vim.api.nvim_win_get_cursor(state.win)[1] == 40
    end, 10)

    vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { 'line 41' })

    vim.wait(500, function()
      return vim.api.nvim_win_get_cursor(state.win)[1] == 41
    end, 10)

    eq(41, vim.api.nvim_win_get_cursor(state.win)[1])
  end)

  it('does not auto-scroll the terminal while it remains focused', function()
    package.loaded['codex.state'] = nil
    package.loaded['codex.prompt'] = nil
    package.loaded['codex.terminal'] = nil

    local source_win = vim.api.nvim_get_current_win()
    local terminal = require 'codex.terminal'
    terminal.__test_autoscroll_delay_ms = 10
    terminal.setup {
      cmd = 'codex',
      autoinstall = false,
      keymaps = {},
      width = 0.25,
      height = 0.8,
      border = 'single',
      panel = false,
      use_buffer = false,
    }

    terminal.open_placeholder()
    local state = require 'codex.state'
    local lines = {}
    for i = 1, 40 do
      table.insert(lines, 'line ' .. i)
    end
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(state.win, { 40, 0 })

    vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { 'line 41' })
    vim.wait(50)

    eq(state.win, vim.api.nvim_get_current_win())
    eq(40, vim.api.nvim_win_get_cursor(state.win)[1])

    vim.api.nvim_set_current_win(source_win)

    vim.wait(500, function()
      return vim.api.nvim_win_get_cursor(state.win)[1] == 41
    end, 10)

    eq(41, vim.api.nvim_win_get_cursor(state.win)[1])
  end)

  it('does not auto-scroll the terminal when it is far from the bottom', function()
    package.loaded['codex.state'] = nil
    package.loaded['codex.prompt'] = nil
    package.loaded['codex.terminal'] = nil

    local terminal = require 'codex.terminal'
    terminal.__test_autoscroll_delay_ms = 10
    terminal.setup {
      cmd = 'codex',
      autoinstall = false,
      keymaps = {},
      width = 0.25,
      height = 0.8,
      border = 'single',
      panel = false,
      use_buffer = false,
    }

    terminal.open_placeholder({ focus = false })
    local state = require 'codex.state'
    local lines = {}
    for i = 1, 80 do
      table.insert(lines, 'line ' .. i)
    end
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

    vim.wait(500, function()
      return vim.api.nvim_win_get_cursor(state.win)[1] == 80
    end, 10)

    vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
    vim.api.nvim_win_call(state.win, function()
      vim.cmd 'normal! zt'
    end)
    vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { 'line 81' })
    vim.wait(50)

    assert(vim.api.nvim_win_get_cursor(state.win)[1] < 81, 'Codex window should not jump to the bottom')
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
    assert(vim.tbl_contains(received_cmd, '--cd'), 'remote TUI should receive an explicit cwd')
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

  it('builds hidden injection items from visible prompt references', function()
    package.loaded['codex.state'] = nil
    package.loaded['codex.prompt'] = nil
    local prompt = require 'codex.prompt'

    vim.cmd 'enew'
    vim.api.nvim_buf_set_name(0, '/tmp/codex-visible-reference.lua')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local a = 1', 'local b = 2', 'return a + b' })

    local items = prompt.injection_items_from_text('Review @/tmp/codex-visible-reference.lua#L2-L3')

    eq(1, #items)
    local text = items[1].content[1].text
    assert(text:match '@/tmp/codex%-visible%-reference%.lua#L2%-L3', 'injection should identify the referenced range')
    assert(text:match 'local b = 2\nreturn a %+ b', 'injection should include the referenced source text')
    eq(1, #prompt.references('Review @/tmp/codex-visible-\nreference.lua#L2-L3'))
    eq(1, #prompt.injection_items_from_text('Review /tmp/codex-visible-reference.lua#L1'))
    eq(1, #prompt.references('Review /tmp/codex-visible-\nreference.lua#L2-L3'))
    eq(0, #prompt.injection_items_from_text('Review /tmp/codex-visible-reference.lua'))
    eq(0, #prompt.injection_items_from_text('Review this code after removing the mention'))
  end)

  it('does not inject hidden context when only inserting a selection reference', function()
    package.loaded['codex.state'] = nil
    package.loaded['codex.app_server'] = nil
    package.loaded['codex.terminal'] = nil

    local app_server = require 'codex.app_server'
    local state = require 'codex.state'
    local terminal = require 'codex.terminal'
    local inserted
    local request_called = false

    app_server.setup({
      model = nil,
      include_active_buffer_context = false,
      app_server = {
        ui = 'terminal',
        open_terminal = false,
      },
    })
    state.app.client = {
      is_running = function()
        return true
      end,
      request = function()
        request_called = true
      end,
    }
    state.app.initialized = true
    state.app.thread_id = 'thread-1'
    terminal.insert = function(prompt_text, opts)
      inserted = { prompt = prompt_text, opts = opts }
      return true
    end
    app_server.open_terminal = function() end

    app_server.send('', {
      submit = false,
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

    assert(inserted and inserted.opts.selection, 'selection reference should be inserted into the terminal prompt')
    assert(not request_called, 'thread/inject_items should not run before the user submits the prompt')
  end)

  it('submits terminal input after injecting visible prompt references', function()
    local original_fn = vim.fn
    local sent = {}
    local injected_prompt

    vim.fn = setmetatable({
      chansend = function(_, text)
        table.insert(sent, text)
        return #text
      end,
    }, { __index = original_fn })

    package.loaded['codex.state'] = nil
    package.loaded['codex.terminal'] = nil
    package.loaded['codex.app_server'] = {
      inject_prompt_references = function(prompt_text, callback)
        injected_prompt = prompt_text
        callback()
      end,
    }

    local state = require 'codex.state'
    local terminal = require 'codex.terminal'
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
      'Previous output',
      '› Review @src/example.lua#L1-L2',
    })
    state.job = 321

    terminal.submit()

    assert(injected_prompt:match '@src/example%.lua#L1%-L2', 'submit should parse the visible terminal prompt')
    eq('\r', sent[#sent])

    vim.fn = original_fn
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
