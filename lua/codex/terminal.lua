local installer = require 'codex.installer'
local prompt_builder = require 'codex.prompt'
local state = require 'codex.state'
local util = require 'codex.util'

local M = {
  config = nil,
  remote = nil,
  cwd = nil,
  requested = false,
  pending_submits = {},
  pending_inserts = {},
}

local auto_scroll_delay_ms = 5000
local autoscroll = {
  attached_buf = nil,
  line_count = nil,
  pending = false,
  timer = nil,
}
local attach_autoscroll

function M.setup(config)
  M.config = config

  local group = vim.api.nvim_create_augroup('CodexTerminalAutoscroll', { clear = true })
  vim.api.nvim_create_autocmd('WinLeave', {
    group = group,
    callback = function(args)
      if state.buf and args.buf == state.buf and state.win and vim.api.nvim_win_is_valid(state.win) then
        M.schedule_autoscroll(true, true)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter', 'TermEnter' }, {
    group = group,
    callback = function()
      if state.win and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_get_current_win() == state.win then
        M.cancel_autoscroll()
      end
    end,
  })
end

local function configure_terminal_window(win, cwd)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  pcall(vim.api.nvim_win_set_option, win, 'wrap', true)
  pcall(vim.api.nvim_win_set_option, win, 'sidescrolloff', 0)
  if cwd and cwd ~= '' then
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd('lcd ' .. vim.fn.fnameescape(cwd))
    end)
  end
end

local function create_clean_buf(config)
  local buf = vim.api.nvim_create_buf(false, false)

  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'hide')
  vim.api.nvim_buf_set_option(buf, 'swapfile', false)
  vim.api.nvim_buf_set_option(buf, 'filetype', 'codex')

  if config.keymaps.quit then
    local quit_cmd = [[<cmd>lua require('codex').close()<CR>]]
    vim.api.nvim_buf_set_keymap(buf, 't', config.keymaps.quit, [[<C-\><C-n>]] .. quit_cmd, { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(buf, 'n', config.keymaps.quit, quit_cmd, { noremap = true, silent = true })
  end
  vim.api.nvim_buf_set_keymap(buf, 't', '<CR>', [[<C-\><C-n><cmd>lua require('codex.terminal').submit()<CR>]], {
    noremap = true,
    silent = true,
  })

  if attach_autoscroll then
    attach_autoscroll(buf)
  end

  return buf
end

local function open_window(config, cwd)
  local width = math.floor(vim.o.columns * config.width)
  local height = math.floor(vim.o.lines * config.height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local styles = {
    single = {
      { '┌', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '┐', 'FloatBorder' },
      { '│', 'FloatBorder' },
      { '┘', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '└', 'FloatBorder' },
      { '│', 'FloatBorder' },
    },
    double = {
      { '╔', 'FloatBorder' },
      { '═', 'FloatBorder' },
      { '╗', 'FloatBorder' },
      { '║', 'FloatBorder' },
      { '╝', 'FloatBorder' },
      { '═', 'FloatBorder' },
      { '╚', 'FloatBorder' },
      { '║', 'FloatBorder' },
    },
    rounded = {
      { '╭', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '╮', 'FloatBorder' },
      { '│', 'FloatBorder' },
      { '╯', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '╰', 'FloatBorder' },
      { '│', 'FloatBorder' },
    },
    none = nil,
  }

  local border = type(config.border) == 'string' and styles[config.border] or config.border

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = border,
  })
  configure_terminal_window(state.win, cwd)
end

local function open_panel(config, cwd)
  vim.cmd 'botright vertical split'
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, state.buf)
  vim.api.nvim_win_set_width(win, math.floor(vim.o.columns * config.width))
  state.win = win
  configure_terminal_window(state.win, cwd)
end

local function current_win()
  local ok, win = pcall(vim.api.nvim_get_current_win)
  if ok then
    return win
  end
  return nil
end

local function codex_focused()
  return state.win and vim.api.nvim_win_is_valid(state.win) and current_win() == state.win
end

local function visible_bottom_line(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  local ok, line = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.line 'w$'
  end)
  if not ok then
    return nil
  end
  return tonumber(line)
end

local function near_bottom(win, line_count)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return false
  end

  local last_visible = visible_bottom_line(win)
  if not last_visible then
    return false
  end

  line_count = line_count or vim.api.nvim_buf_line_count(state.buf)
  local page_distance = math.max(1, vim.api.nvim_win_get_height(win))
  return math.max(0, line_count - last_visible) <= page_distance
end

local function scroll_to_bottom()
  if codex_focused() then
    return false
  end
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return false
  end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return false
  end

  local line_count = math.max(1, vim.api.nvim_buf_line_count(state.buf))
  pcall(vim.api.nvim_win_set_cursor, state.win, { line_count, 0 })
  pcall(vim.api.nvim_win_call, state.win, function()
    vim.cmd 'normal! zb'
  end)
  autoscroll.pending = false
  return true
end

function M.cancel_autoscroll()
  if autoscroll.timer then
    autoscroll.timer:stop()
    autoscroll.timer:close()
    autoscroll.timer = nil
  end
end

function M.schedule_autoscroll(check_current_position, allow_current_focus)
  if not autoscroll.pending or (codex_focused() and not allow_current_focus) then
    M.cancel_autoscroll()
    return
  end

  if check_current_position and not near_bottom(state.win) then
    autoscroll.pending = false
    M.cancel_autoscroll()
    return
  end

  if autoscroll.timer then
    return
  end

  M.cancel_autoscroll()
  local timer = vim.loop.new_timer()
  autoscroll.timer = timer
  timer:start(M.__test_autoscroll_delay_ms or auto_scroll_delay_ms, 0, vim.schedule_wrap(function()
    if autoscroll.timer == timer then
      autoscroll.timer = nil
    end
    timer:stop()
    timer:close()

    if not autoscroll.pending then
      return
    end
    if codex_focused() then
      return
    end
    scroll_to_bottom()
  end))
end

local function on_terminal_lines(before_line_count)
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return
  end

  if near_bottom(state.win, before_line_count) then
    autoscroll.pending = true
    if codex_focused() then
      M.cancel_autoscroll()
    else
      M.schedule_autoscroll(false)
    end
  else
    autoscroll.pending = false
    M.cancel_autoscroll()
  end
end

attach_autoscroll = function(buf)
  if autoscroll.attached_buf == buf then
    return
  end

  autoscroll.attached_buf = buf
  autoscroll.line_count = vim.api.nvim_buf_line_count(buf)
  autoscroll.pending = false
  M.cancel_autoscroll()

  pcall(vim.api.nvim_buf_attach, buf, false, {
    on_lines = function(_, changed_buf, _, _, lastline, new_lastline)
      if changed_buf ~= state.buf then
        return
      end

      local before_line_count = autoscroll.line_count or 1
      autoscroll.line_count = math.max(1, before_line_count + (new_lastline - lastline))
      vim.schedule(function()
        if changed_buf == state.buf then
          on_terminal_lines(before_line_count)
        end
      end)
    end,
    on_detach = function(_, detached_buf)
      if autoscroll.attached_buf == detached_buf then
        autoscroll.attached_buf = nil
        autoscroll.line_count = nil
        autoscroll.pending = false
        M.cancel_autoscroll()
      end
    end,
  })
end

local function launch_cwd(opts)
  if opts and opts.cwd then
    return opts.cwd
  end
  if M.cwd and (state.job or (state.win and vim.api.nvim_win_is_valid(state.win))) then
    return M.cwd
  end
  return util.cwd()
end

local function restore_win(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
end

local function focus_window(insert)
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return false
  end
  vim.api.nvim_set_current_win(state.win)
  if insert and state.job then
    vim.cmd 'startinsert'
  end
  return true
end

local function is_buf_reusable(buf)
  return type(buf) == 'number' and vim.api.nvim_buf_is_valid(buf)
end

local function is_clean_start_buf(buf)
  if not is_buf_reusable(buf) then
    return false
  end
  if vim.api.nvim_buf_get_option(buf, 'modified') then
    return false
  end
  return vim.api.nvim_buf_get_option(buf, 'buftype') == ''
end

local function ensure_start_buf(config)
  if state.job then
    if not is_buf_reusable(state.buf) then
      state.buf = create_clean_buf(config)
    end
    return
  end

  if not is_clean_start_buf(state.buf) then
    state.buf = create_clean_buf(config)
  end
end

local function ensure_window(config, cwd)
  ensure_start_buf(config)

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    vim.api.nvim_win_set_buf(state.win, state.buf)
    configure_terminal_window(state.win, cwd)
    return
  end

  if config.panel then
    open_panel(config, cwd)
  else
    open_window(config, cwd)
  end
end

local function set_message(lines)
  local config = M.config
  ensure_window(config, M.cwd)
  local was_modifiable = vim.api.nvim_buf_get_option(state.buf, 'modifiable')
  vim.api.nvim_buf_set_option(state.buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines or { '' })
  vim.api.nvim_buf_set_option(state.buf, 'modified', false)
  vim.api.nvim_buf_set_option(state.buf, 'modifiable', was_modifiable)
end

local function append_cwd_arg(cmd_args, cwd)
  if cwd and cwd ~= '' then
    table.insert(cmd_args, '--cd')
    table.insert(cmd_args, cwd)
  end
end

local function build_cmd_args(config, remote, opts, cwd)
  opts = opts or {}
  local cmd_args = util.normalize_cmd(config.cmd)
  if remote and remote.url then
    if remote.resume_last then
      table.insert(cmd_args, 'resume')
      table.insert(cmd_args, '--last')
      table.insert(cmd_args, '--remote')
      table.insert(cmd_args, remote.url)
      if config.model then
        table.insert(cmd_args, '-m')
        table.insert(cmd_args, config.model)
      end
      append_cwd_arg(cmd_args, cwd)
      return cmd_args
    else
      table.insert(cmd_args, '--remote')
      table.insert(cmd_args, remote.url)
      append_cwd_arg(cmd_args, cwd)
      return cmd_args
    end
  end

  if opts.resume_last then
    table.insert(cmd_args, 'resume')
    table.insert(cmd_args, '--last')
  end
  if config.model then
    table.insert(cmd_args, '-m')
    table.insert(cmd_args, config.model)
  end
  append_cwd_arg(cmd_args, cwd)
  return cmd_args
end

local function paste_to_terminal(text, submit)
  if not state.job or not text or text == '' then
    return false
  end

  local ok = pcall(vim.fn.chansend, state.job, '\027[200~' .. text .. '\027[201~')
  if not ok then
    return false
  end

  if submit then
    vim.defer_fn(function()
      if state.job then
        pcall(vim.fn.chansend, state.job, '\r')
      end
    end, 20)
  end
  return true
end

function M.flush_pending()
  if not state.job or (#M.pending_submits == 0 and #M.pending_inserts == 0) then
    return
  end

  local pending_inserts = M.pending_inserts
  local pending_submits = M.pending_submits
  M.pending_inserts = {}
  M.pending_submits = {}
  vim.defer_fn(function()
    for _, text in ipairs(pending_inserts) do
      if state.job then
        paste_to_terminal(text, false)
      end
    end
    for _, text in ipairs(pending_submits) do
      if state.job then
        paste_to_terminal(text, true)
      end
    end
  end, 300)
end

function M.open(opts)
  opts = opts or {}
  local config = M.config
  local cwd = launch_cwd(opts)
  M.cwd = cwd
  M.requested = true
  local restore_to = opts.focus == false and current_win() or nil

  config.cmd = util.resolve_cmd(config.cmd)
  local check_cmd = util.executable_from_cmd(config.cmd)
  if check_cmd and vim.fn.executable(check_cmd) == 0 then
    if config.autoinstall then
      installer.prompt_autoinstall(function(success)
        if success then
          M.open(opts)
        else
          if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
            state.buf = create_clean_buf(config)
          end
          vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
            'Autoinstall cancelled or failed.',
            '',
            'You can install manually with:',
            '  npm install -g @openai/codex',
          })
          if config.panel then
            open_panel(config, cwd)
          else
            open_window(config, cwd)
          end
          restore_win(restore_to)
        end
      end)
      return
    end

    if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
      state.buf = create_clean_buf(config)
    end
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
      'Codex CLI not found, autoinstall disabled.',
      '',
      'Install with:',
      '  npm install -g @openai/codex',
    })
    if config.panel then
      open_panel(config, cwd)
    else
      open_window(config, cwd)
    end
    restore_win(restore_to)
    return
  end

  ensure_window(config, cwd)

  if state.job then
    if opts.insert then
      focus_window(true)
    end
    restore_win(restore_to)
    return
  end

  local cmd_args = build_cmd_args(config, M.remote, opts, cwd)

  if config.use_buffer then
    state.job = vim.fn.jobstart(cmd_args, {
      cwd = cwd,
      env = util.codex_env(),
      stdout_buffered = true,
      on_stdout = function(_, data)
        if not data then
          return
        end
        for _, line in ipairs(data) do
          if line ~= '' then
            vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { line })
          end
        end
      end,
      on_stderr = function(_, data)
        if not data then
          return
        end
        for _, line in ipairs(data) do
          if line ~= '' then
            vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { '[ERR] ' .. line })
          end
        end
      end,
      on_exit = function(_, code)
        state.job = nil
        vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { ('[Codex exit: %d]'):format(code) })
      end,
    })
  else
    local ok, job_or_err = pcall(vim.fn.termopen, cmd_args, {
      cwd = cwd,
      env = util.codex_env(),
      on_exit = function(_, code)
        state.job = nil
        state.app.terminal_opened = false
        if code ~= 0 and M.remote then
          state.app.thread_id = nil
          state.app.session_id = nil
          M.remote = nil
          M.pending_submits = {}
          M.pending_inserts = {}
        end
      end,
    })
    if ok and type(job_or_err) == 'number' and job_or_err > 0 then
      state.job = job_or_err
      configure_terminal_window(state.win, cwd)
      M.flush_pending()
      if opts.insert then
        focus_window(true)
      end
    else
      state.job = nil
      state.buf = nil
      set_message { 'Codex terminal failed to start.', tostring(job_or_err) }
    end
  end

  restore_win(restore_to)
end

function M.open_remote(url, thread_id, opts)
  if not M.requested then
    return false
  end
  M.remote = {
    url = url,
    thread_id = thread_id,
    resume_last = opts and opts.resume_last == true,
  }
  M.open(opts)
  return true
end

function M.send(prompt, opts)
  local text = prompt_builder.terminal(prompt, opts, M.config)
  if text == '' then
    return false
  end

  M.requested = true
  if paste_to_terminal(text, true) then
    return true
  end

  table.insert(M.pending_submits, text)
  if M.remote and M.remote.url then
    M.open(opts)
  end
  return true
end

function M.insert(prompt, opts)
  local text = prompt_builder.input_reference(prompt, opts, M.config)
  if text == '' then
    return false
  end

  M.requested = true
  if paste_to_terminal(text, false) then
    return true
  end

  table.insert(M.pending_inserts, text)
  if M.remote and M.remote.url then
    M.open(opts)
  end
  return true
end

local function current_prompt_text()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return ''
  end

  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local start_index
  local prompt_pattern
  for i = #lines, 1, -1 do
    local line_prompt_pattern = nil
    if lines[i]:match '^%s*>%s+' then
      line_prompt_pattern = '^%s*>%s+'
    elseif lines[i]:match '^%s*›%s+' then
      line_prompt_pattern = '^%s*›%s+'
    end
    if line_prompt_pattern then
      start_index = i
      prompt_pattern = line_prompt_pattern
      break
    end
  end

  if not start_index then
    return ''
  end

  local prompt_lines = {}
  for i = start_index, #lines do
    local line = lines[i]
    if i == start_index then
      line = line:gsub(prompt_pattern, '', 1)
    end
    table.insert(prompt_lines, line)
  end
  return table.concat(prompt_lines, '\n')
end

function M.submit()
  local prompt = current_prompt_text()

  local function send_enter()
    if state.job then
      pcall(vim.fn.chansend, state.job, '\r')
    end
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_set_current_win(state.win)
      vim.cmd 'startinsert'
    end
  end

  local ok, app_server = pcall(require, 'codex.app_server')
  if ok and type(app_server.inject_prompt_references) == 'function' then
    app_server.inject_prompt_references(prompt, send_enter)
    return
  end

  send_enter()
end

function M.open_placeholder(opts)
  opts = opts or {}
  local cwd = opts.cwd or util.cwd()
  M.cwd = cwd
  local restore_to = opts.focus == false and current_win() or nil
  M.requested = true
  ensure_window(M.config, cwd)
  if opts.insert then
    focus_window(true)
  end
  restore_win(restore_to)
end

function M.focus(opts)
  opts = opts or {}
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return focus_window(opts.insert ~= false)
  end
  M.open(vim.tbl_extend('force', opts, { focus = true }))
  return focus_window(opts.insert ~= false)
end

function M.show_error(message)
  M.requested = true
  ensure_window(M.config, M.cwd)
  set_message { 'Codex failed to start.', tostring(message or 'unknown error') }
end

function M.is_requested()
  return M.requested
end

function M.close()
  M.requested = false
  M.pending_submits = {}
  M.pending_inserts = {}
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  if not state.job then
    M.cwd = nil
  end
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

return M
