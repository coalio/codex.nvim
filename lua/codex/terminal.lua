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
local picker_ns = vim.api.nvim_create_namespace 'codex.session_picker'
local autoscroll = {
  attached_buf = nil,
  line_count = nil,
  pending = false,
  timer = nil,
}
local attach_autoscroll
local picker_title = 'Codex Sessions'

local function active_session()
  if type(state.active_session) == 'function' then
    return state.active_session()
  end
  return nil
end

local function ensure_session(opts)
  if type(state.ensure_session) == 'function' then
    return state.ensure_session(opts)
  end
  return nil
end

local function sync_active_session()
  if type(state.sync_active_session) == 'function' then
    return state.sync_active_session()
  end
  return nil
end

local function session_requested(session)
  if session then
    return session.requested == true
  end
  return M.requested == true
end

local function session_remote(session)
  return session and session.remote or M.remote
end

local function session_pending_submits(session)
  return session and session.pending_submits or M.pending_submits
end

local function session_pending_inserts(session)
  return session and session.pending_inserts or M.pending_inserts
end

local function set_session_buf(session, buf)
  if session then
    session.buf = buf
    sync_active_session()
  else
    state.buf = buf
  end
end

local function set_session_job(session, job)
  if session then
    session.job = job
    sync_active_session()
  else
    state.job = job
  end
end

local function session_buf(session)
  return session and session.buf or state.buf
end

local function session_job(session)
  return session and session.job or state.job
end

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

local function picker_enabled(config)
  local picker = config and config.session_picker
  return picker == nil or picker.enabled ~= false
end

local function picker_width(config)
  local picker = config and config.session_picker or {}
  local width = tonumber(picker.width) or 24
  width = math.max(1, math.floor(width))
  if state.picker_expanded then
    return width
  end
  return math.max(5, math.min(width, #('[+] ' .. picker_title)))
end

local function content_width(config)
  return math.max(1, math.floor(vim.o.columns * config.width))
end

local function open_window(config, cwd)
  local width = content_width(config)
  local height = math.floor(vim.o.lines * config.height)
  local row = math.floor((vim.o.lines - height) / 2)
  local picker_extra = picker_enabled(config) and picker_width(config) or 0
  local col = math.floor((vim.o.columns - width - picker_extra) / 2)
  col = math.max(0, col)

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
  vim.api.nvim_win_set_width(win, content_width(config))
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

local function close_picker()
  if state.picker_win and vim.api.nvim_win_is_valid(state.picker_win) then
    pcall(vim.api.nvim_win_close, state.picker_win, true)
  end
  state.picker_win = nil
end

local function ensure_picker_buf()
  if state.picker_buf and vim.api.nvim_buf_is_valid(state.picker_buf) then
    return state.picker_buf
  end

  local buf = vim.api.nvim_create_buf(false, false)
  state.picker_buf = buf
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'hide')
  vim.api.nvim_buf_set_option(buf, 'swapfile', false)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'filetype', 'codex-sessions')
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  vim.api.nvim_buf_set_keymap(buf, 'n', '<CR>', [[<cmd>lua require('codex.terminal').select_session_at_cursor()<CR>]], {
    noremap = true,
    silent = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<LeftMouse>', [[<cmd>lua require('codex.terminal').select_session_at_mouse()<CR>]], {
    noremap = true,
    silent = true,
  })
  for _, lhs in ipairs { 'v', 'V', '<C-v>', '<LeftDrag>', '<S-LeftMouse>' } do
    vim.api.nvim_buf_set_keymap(buf, 'n', lhs, '<Nop>', { noremap = true, silent = true })
  end
  for _, lhs in ipairs { '<LeftDrag>', '<S-LeftMouse>' } do
    vim.api.nvim_buf_set_keymap(buf, 'x', lhs, '<Nop>', { noremap = true, silent = true })
  end
  return buf
end

local function configure_picker_window(win, config)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  pcall(vim.api.nvim_win_set_width, win, picker_width(config))
  pcall(vim.api.nvim_win_set_option, win, 'number', false)
  pcall(vim.api.nvim_win_set_option, win, 'relativenumber', false)
  pcall(vim.api.nvim_win_set_option, win, 'signcolumn', 'no')
  pcall(vim.api.nvim_win_set_option, win, 'foldcolumn', '0')
  pcall(vim.api.nvim_win_set_option, win, 'wrap', false)
  pcall(vim.api.nvim_win_set_option, win, 'sidescrolloff', 0)
  pcall(vim.api.nvim_win_set_option, win, 'sidescroll', 1)
  pcall(vim.api.nvim_win_set_option, win, 'list', false)
  pcall(vim.api.nvim_win_set_option, win, 'cursorline', false)
  pcall(vim.api.nvim_win_set_option, win, 'winfixwidth', true)
  pcall(vim.api.nvim_win_set_option, win, 'statuscolumn', '')
  pcall(vim.api.nvim_win_set_option, win, 'winhighlight', '')
end

local function clip_picker_text(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return text:sub(-width)
end

local function align_picker_line(text, config)
  local width = picker_width(config)
  text = clip_picker_text(text, width)
  local padding = math.max(0, width - vim.fn.strdisplaywidth(text))
  return string.rep(' ', padding) .. text
end

local function render_picker()
  if not state.picker_buf or not vim.api.nvim_buf_is_valid(state.picker_buf) then
    return
  end

  local toggle = state.picker_expanded and '[-]' or '[+]'
  local lines = { align_picker_line(toggle .. ' ' .. picker_title, M.config), '' }
  state.picker_line_sessions = {}
  state.picker_line_actions = {
    [1] = 'toggle',
  }
  for _, id in ipairs(state.session_order or {}) do
    local session = state.sessions and state.sessions[id] or nil
    local name = session and session.name or ('session-' .. tostring(id))
    local label = state.picker_expanded and ('%s (%d)'):format(name, id) or ('(%d)'):format(id)
    table.insert(lines, align_picker_line(' ' .. label .. ' ', M.config))
    state.picker_line_sessions[#lines] = id
  end

  local was_modifiable = vim.api.nvim_buf_get_option(state.picker_buf, 'modifiable')
  vim.api.nvim_buf_set_option(state.picker_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(state.picker_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.picker_buf, picker_ns, 0, -1)
  vim.cmd 'highlight! link CodexSessionTitle Normal'
  vim.cmd 'highlight! link CodexSessionActive TabLineSel'
  vim.cmd 'highlight! link CodexSessionInactive Normal'
  vim.api.nvim_buf_add_highlight(state.picker_buf, picker_ns, 'CodexSessionTitle', 0, 0, -1)
  local active_line = 1
  for line, id in pairs(state.picker_line_sessions) do
    local group = id == state.active_session_id and 'CodexSessionActive' or 'CodexSessionInactive'
    if id == state.active_session_id then
      active_line = line
      vim.api.nvim_buf_set_extmark(state.picker_buf, picker_ns, line - 1, 0, {
        line_hl_group = group,
      })
    end
    vim.api.nvim_buf_add_highlight(state.picker_buf, picker_ns, group, line - 1, 0, -1)
  end
  vim.api.nvim_buf_set_option(state.picker_buf, 'modifiable', was_modifiable)

  if state.picker_win and vim.api.nvim_win_is_valid(state.picker_win) then
    pcall(vim.api.nvim_win_set_cursor, state.picker_win, { active_line, 0 })
    pcall(vim.api.nvim_win_call, state.picker_win, function()
      local view = vim.fn.winsaveview()
      view.leftcol = 0
      view.col = 0
      vim.fn.winrestview(view)
    end)
  end
end

local function open_float_picker(config)
  local buf = ensure_picker_buf()
  if state.picker_win and vim.api.nvim_win_is_valid(state.picker_win) then
    vim.api.nvim_win_set_buf(state.picker_win, buf)
    configure_picker_window(state.picker_win, config)
    return
  end

  local ok, win_config = pcall(vim.api.nvim_win_get_config, state.win)
  if not ok or not win_config or win_config.relative == '' then
    return
  end

  local border_offset = config.border == 'none' and 0 or 2
  state.picker_win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    width = picker_width(config),
    height = win_config.height,
    row = win_config.row,
    col = win_config.col + win_config.width + border_offset,
    style = 'minimal',
  })
  configure_picker_window(state.picker_win, config)
end

local function open_panel_picker(config)
  local buf = ensure_picker_buf()
  if state.picker_win and vim.api.nvim_win_is_valid(state.picker_win) then
    vim.api.nvim_win_set_buf(state.picker_win, buf)
    configure_picker_window(state.picker_win, config)
    return
  end

  local restore_to = current_win()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return
  end
  vim.api.nvim_set_current_win(state.win)
  vim.cmd(('rightbelow vertical %dsplit'):format(picker_width(config)))
  state.picker_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.picker_win, buf)
  configure_picker_window(state.picker_win, config)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
  end
  if restore_to and restore_to ~= state.picker_win and vim.api.nvim_win_is_valid(restore_to) then
    vim.api.nvim_set_current_win(restore_to)
  end
end

local function ensure_picker(config)
  if not picker_enabled(config) or not state.has_sessions or not state.has_sessions() then
    close_picker()
    return
  end
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    close_picker()
    return
  end

  if config.panel then
    open_panel_picker(config)
  else
    open_float_picker(config)
  end
  render_picker()
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

local function launch_cwd(opts, session)
  if opts and opts.cwd then
    return opts.cwd
  end
  if session and session.cwd and (session.job or (state.win and vim.api.nvim_win_is_valid(state.win))) then
    return session.cwd
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

local function ensure_start_buf(config, session)
  local buf = session_buf(session)
  if session_job(session) then
    if not is_buf_reusable(buf) then
      set_session_buf(session, create_clean_buf(config))
    end
    return
  end

  if not is_clean_start_buf(buf) then
    set_session_buf(session, create_clean_buf(config))
  end
end

local function ensure_window(config, cwd, session)
  session = session or active_session()
  ensure_start_buf(config, session)
  sync_active_session()

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    vim.api.nvim_win_set_buf(state.win, state.buf)
    configure_terminal_window(state.win, cwd)
    ensure_picker(config)
    return
  end

  if config.panel then
    open_panel(config, cwd)
  else
    open_window(config, cwd)
  end
  ensure_picker(config)
end

local function set_message(lines)
  local config = M.config
  ensure_window(config, M.cwd, active_session())
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

local function append_launch_flags(cmd_args, config, opts, session)
  table.insert(cmd_args, '--config')
  table.insert(cmd_args, 'tui.vim_mode_default=true')
  if (session and session.yolo) or (opts and opts.yolo) or (config and config.yolo) then
    table.insert(cmd_args, '--dangerously-bypass-approvals-and-sandbox')
  end
end

local function build_cmd_args(config, remote, opts, cwd, session)
  opts = opts or {}
  local cmd_args = util.normalize_cmd(config.cmd)
  if remote and remote.url then
    if remote.resume_last then
      table.insert(cmd_args, 'resume')
      append_launch_flags(cmd_args, config, opts, session)
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
      append_launch_flags(cmd_args, config, opts, session)
      table.insert(cmd_args, '--remote')
      table.insert(cmd_args, remote.url)
      append_cwd_arg(cmd_args, cwd)
      return cmd_args
    end
  end

  if opts.resume_last then
    table.insert(cmd_args, 'resume')
    append_launch_flags(cmd_args, config, opts, session)
    table.insert(cmd_args, '--last')
  else
    append_launch_flags(cmd_args, config, opts, session)
  end
  if config.model then
    table.insert(cmd_args, '-m')
    table.insert(cmd_args, config.model)
  end
  append_cwd_arg(cmd_args, cwd)
  return cmd_args
end

local function paste_to_terminal(text, submit, session)
  session = session or active_session()
  local job = session_job(session)
  if not job or not text or text == '' then
    return false
  end

  local ok = pcall(vim.fn.chansend, job, '\027[200~' .. text .. '\027[201~')
  if not ok then
    return false
  end

  if submit then
    vim.defer_fn(function()
      local active_job = session_job(session)
      if active_job then
        pcall(vim.fn.chansend, active_job, '\r')
      end
    end, 20)
  end
  return true
end

function M.flush_pending(session)
  session = session or active_session()
  local pending_inserts = session_pending_inserts(session)
  local pending_submits = session_pending_submits(session)
  if not session_job(session) or (#pending_submits == 0 and #pending_inserts == 0) then
    return
  end

  if session then
    session.pending_inserts = {}
    session.pending_submits = {}
  else
    M.pending_inserts = {}
    M.pending_submits = {}
  end
  vim.defer_fn(function()
    for _, text in ipairs(pending_inserts) do
      if session_job(session) then
        paste_to_terminal(text, false, session)
      end
    end
    for _, text in ipairs(pending_submits) do
      if session_job(session) then
        paste_to_terminal(text, true, session)
      end
    end
  end, 300)
end

function M.open(opts)
  opts = opts or {}
  local config = M.config
  local session = opts.session or active_session()
  if opts.new_session or not session then
    session = state.create_session and state.create_session({ yolo = opts.yolo }) or nil
  elseif state.activate_session and session.id then
    state.activate_session(session.id)
  end
  session = session or active_session()
  local cwd = launch_cwd(opts, session)
  M.cwd = cwd
  M.requested = true
  if session then
    session.cwd = cwd
    session.requested = true
    if opts.yolo then
      session.yolo = true
    end
  end
  local restore_to = opts.focus == false and current_win() or nil

  config.cmd = util.resolve_cmd(config.cmd)
  local check_cmd = util.executable_from_cmd(config.cmd)
  if check_cmd and vim.fn.executable(check_cmd) == 0 then
    if config.autoinstall then
      installer.prompt_autoinstall(function(success)
        if success then
          M.open(opts)
        else
          if not session_buf(session) or not vim.api.nvim_buf_is_valid(session_buf(session)) then
            set_session_buf(session, create_clean_buf(config))
          end
          vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
            'Autoinstall cancelled or failed.',
            '',
            'You can install manually with:',
            '  npm install -g @openai/codex',
          })
          ensure_window(config, cwd, session)
          restore_win(restore_to)
        end
      end)
      return
    end

    if not session_buf(session) or not vim.api.nvim_buf_is_valid(session_buf(session)) then
      set_session_buf(session, create_clean_buf(config))
    end
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
      'Codex CLI not found, autoinstall disabled.',
      '',
      'Install with:',
      '  npm install -g @openai/codex',
    })
    ensure_window(config, cwd, session)
    restore_win(restore_to)
    return
  end

  ensure_window(config, cwd, session)

  if session_job(session) then
    if opts.insert then
      focus_window(true)
    end
    restore_win(restore_to)
    return
  end

  local cmd_args = build_cmd_args(config, session_remote(session), opts, cwd, session)

  if config.use_buffer then
    set_session_job(session, vim.fn.jobstart(cmd_args, {
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
        set_session_job(session, nil)
        vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { ('[Codex exit: %d]'):format(code) })
      end,
    }))
  else
    local ok, job_or_err = pcall(vim.fn.termopen, cmd_args, {
      cwd = cwd,
      env = util.codex_env(),
      on_exit = function(_, code)
        set_session_job(session, nil)
        local app_ctx = state.app_context and state.app_context(session) or state.app
        app_ctx.terminal_opened = false
        if code ~= 0 and session_remote(session) then
          app_ctx.thread_id = nil
          app_ctx.session_id = nil
          if session then
            session.remote = nil
            session.pending_submits = {}
            session.pending_inserts = {}
          else
            M.remote = nil
            M.pending_submits = {}
            M.pending_inserts = {}
          end
        end
        M.close_session(session and session.id, { from_exit = true })
      end,
    })
    if ok and type(job_or_err) == 'number' and job_or_err > 0 then
      set_session_job(session, job_or_err)
      configure_terminal_window(state.win, cwd)
      M.flush_pending(session)
      if opts.insert then
        focus_window(true)
      end
    else
      set_session_job(session, nil)
      set_session_buf(session, nil)
      set_message { 'Codex terminal failed to start.', tostring(job_or_err) }
    end
  end

  restore_win(restore_to)
end

function M.open_remote(url, thread_id, opts)
  opts = opts or {}
  local session = opts.session or active_session()
  if not session_requested(session) then
    return false
  end
  local remote = {
    url = url,
    thread_id = thread_id,
    resume_last = opts.resume_last == true,
  }
  if session then
    session.remote = remote
    if state.queue_thread_session then
      state.queue_thread_session(session)
    end
  else
    M.remote = remote
  end
  M.open(vim.tbl_extend('force', opts, { session = session }))
  return true
end

function M.send(prompt, opts)
  opts = opts or {}
  local session = opts.session or active_session()
  local text = prompt_builder.terminal(prompt, vim.tbl_extend('force', opts, {
    pending_context = state.app_context and state.app_context(session).pending_context or nil,
  }), M.config)
  if text == '' then
    return false
  end

  M.requested = true
  if session then
    session.requested = true
  end
  if paste_to_terminal(text, true, session) then
    return true
  end

  if session then
    table.insert(session.pending_submits, text)
  else
    table.insert(M.pending_submits, text)
  end
  local remote = session_remote(session)
  if remote and remote.url then
    M.open(vim.tbl_extend('force', opts, { session = session }))
  end
  return true
end

function M.insert(prompt, opts)
  opts = opts or {}
  local session = opts.session or active_session()
  local text = prompt_builder.input_reference(prompt, opts, M.config)
  if text == '' then
    return false
  end

  M.requested = true
  if session then
    session.requested = true
  end
  if paste_to_terminal(text, false, session) then
    return true
  end

  if session then
    table.insert(session.pending_inserts, text)
  else
    table.insert(M.pending_inserts, text)
  end
  local remote = session_remote(session)
  if remote and remote.url then
    M.open(vim.tbl_extend('force', opts, { session = session }))
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
  local session = opts.session
  if not session and opts.new_session and state.create_session then
    session = state.create_session({ yolo = opts.yolo })
  end
  session = session or active_session() or ensure_session({ yolo = opts.yolo })
  if state.activate_session and session and session.id then
    state.activate_session(session.id)
  end
  local cwd = opts.cwd or util.cwd()
  M.cwd = cwd
  if session then
    session.cwd = cwd
    session.requested = true
    if opts.yolo then
      session.yolo = true
    end
  end
  local restore_to = opts.focus == false and current_win() or nil
  M.requested = true
  ensure_window(M.config, cwd, session)
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
  local session = active_session() or ensure_session()
  if session then
    session.requested = true
  end
  ensure_window(M.config, M.cwd, session)
  set_message { 'Codex failed to start.', tostring(message or 'unknown error') }
end

function M.is_requested(session)
  session = session or active_session()
  if session then
    return session.requested
  end
  return M.requested
end

function M.close()
  M.requested = false
  M.pending_submits = {}
  M.pending_inserts = {}
  local session = active_session()
  if session then
    session.requested = false
  end
  for _, id in ipairs(state.session_order or {}) do
    local entry = state.sessions and state.sessions[id] or nil
    if entry then
      entry.requested = false
    end
  end
  close_picker()
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

function M.select_session(id, opts)
  opts = opts or {}
  local session = state.activate_session and state.activate_session(tonumber(id)) or nil
  if not session then
    return false
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_buf(state.win, session.buf)
    configure_terminal_window(state.win, session.cwd)
    ensure_picker(M.config)
    if opts.focus ~= false then
      focus_window(opts.insert ~= false)
    end
  else
    M.open(vim.tbl_extend('force', opts, { session = session }))
  end
  render_picker()
  return true
end

function M.toggle_session_picker()
  state.picker_expanded = not state.picker_expanded
  ensure_picker(M.config)
  render_picker()
  return true
end

function M.select_session_at_cursor()
  if not state.picker_buf or not vim.api.nvim_buf_is_valid(state.picker_buf) then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if state.picker_line_actions and state.picker_line_actions[row] == 'toggle' then
    return M.toggle_session_picker()
  end
  local id = state.picker_line_sessions and state.picker_line_sessions[row] or nil
  if not id then
    return false
  end
  return M.select_session(id, { focus = true })
end

function M.select_session_at_mouse()
  local pos = vim.fn.getmousepos()
  if not pos or pos.winid ~= state.picker_win then
    return false
  end
  local picker_win = state.picker_win
  if state.picker_line_actions and state.picker_line_actions[pos.line] == 'toggle' then
    local ok = M.toggle_session_picker()
    if ok and picker_win and vim.api.nvim_win_is_valid(picker_win) then
      vim.api.nvim_set_current_win(picker_win)
    end
    return ok
  end
  local id = state.picker_line_sessions and state.picker_line_sessions[pos.line] or nil
  if not id then
    return false
  end
  local ok = M.select_session(id, { focus = false })
  if ok and picker_win and vim.api.nvim_win_is_valid(picker_win) then
    vim.api.nvim_set_current_win(picker_win)
  end
  return ok
end

function M.new_session(opts)
  opts = opts or {}
  local session = state.create_session and state.create_session({ yolo = opts.yolo }) or nil
  return M.open(vim.tbl_extend('force', opts, {
    new_session = false,
    session = session,
    focus = opts.focus ~= false,
    insert = opts.insert ~= false,
  }))
end

function M.yolo(opts)
  opts = opts or {}
  return M.new_session(vim.tbl_extend('force', opts, { yolo = true }))
end

function M.close_session(id, opts)
  opts = opts or {}
  local session = id and state.sessions and state.sessions[tonumber(id)] or active_session()
  if not session then
    return false
  end

  local was_active = session.id == state.active_session_id
  local old_buf = session.buf
  if session.job and not opts.from_exit then
    pcall(vim.fn.jobstop, session.job)
  end

  if state.remove_session then
    state.remove_session(session.id)
  end
  render_picker()

  local next_session = active_session()
  if was_active and next_session and state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_buf(state.win, next_session.buf)
    configure_terminal_window(state.win, next_session.cwd)
    ensure_picker(M.config)
  elseif not next_session then
    close_picker()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      pcall(vim.api.nvim_win_close, state.win, true)
    end
    state.win = nil
  else
    ensure_picker(M.config)
  end

  if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
    pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
  end

  return true
end

return M
