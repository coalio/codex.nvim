local state = require 'codex.state'

local M = {
  config = nil,
  generation = 0,
  buf = nil,
  win = nil,
  last_non_list_win = nil,
}

local statuscolumn = '%@v:lua.CodexSessionListClick@%{%v:lua.CodexSessionListStatusColumn()%}%T'
local winhighlight = table.concat({
  'Normal:CodexSessionListBase',
  'NormalNC:CodexSessionListBase',
  'EndOfBuffer:CodexSessionListBase',
  'LineNr:CodexSessionListBase',
  'CursorLine:CodexSessionListBase',
  'CursorLineNr:CodexSessionListBase',
  'SignColumn:CodexSessionListBase',
  'FoldColumn:CodexSessionListBase',
}, ',')

local function highlight_with_background(groups)
  for _, group in ipairs(groups) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if ok and (hl.bg or hl.ctermbg) then
      return group
    end
  end
  return groups[#groups]
end

local function default_link(name, target)
  pcall(vim.api.nvim_set_hl, 0, name, {
    default = true,
    link = target,
  })
end

local function setup_highlights()
  default_link('CodexSessionListBase', 'Normal')
  default_link('CodexSessionListInactive', 'Comment')
  default_link('CodexSessionListActive', highlight_with_background {
    'PmenuSel',
    'Visual',
    'TabLineSel',
  })
end

local function valid_win(win)
  return type(win) == 'number' and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return type(buf) == 'number' and vim.api.nvim_buf_is_valid(buf)
end

local function current_win()
  local ok, win = pcall(vim.api.nvim_get_current_win)
  return ok and win or nil
end

local function is_list_win(win)
  return valid_win(M.win) and win == M.win
end

local function remember_window(win)
  if valid_win(win) and not is_list_win(win) then
    M.last_non_list_win = win
  end
end

local function restore_focus(win)
  if valid_win(win) then
    pcall(vim.api.nvim_set_current_win, win)
    remember_window(win)
  end
end

local function session_width(config)
  local list = config and config.session_list or {}
  local width = tonumber(list.width) or 24
  return math.max(1, math.min(math.floor(width), 7))
end

local function terminal_width(config)
  return math.max(1, math.floor(vim.o.columns * config.width))
end

local function resize_terminal(config)
  if config and config.panel and valid_win(state.win) then
    pcall(vim.api.nvim_win_set_width, state.win, terminal_width(config))
  end
end

local function session_id_at_line(line)
  line = tonumber(line)
  if not line or line < 1 then
    return nil
  end
  local id = state.session_order and state.session_order[line] or nil
  if id and state.sessions and state.sessions[id] then
    return id
  end
  return nil
end

local function label_for_line(line)
  local id = session_id_at_line(line)
  if not id then
    return ''
  end
  return ('(%d)'):format(id)
end

local function pad_label(label, width)
  if label == '' then
    return ''
  end
  if #label >= width then
    return label
  end
  local left = math.floor((width - #label) / 2)
  local right = width - #label - left
  return string.rep(' ', left) .. label .. string.rep(' ', right)
end

local function ensure_buffer()
  if valid_buf(M.buf) then
    return M.buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  M.buf = buf
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'filetype', 'codex-session-list')
  vim.api.nvim_buf_set_option(buf, 'swapfile', false)
  return buf
end

local function sync_buffer_lines()
  local buf = ensure_buffer()
  local count = math.max(1, #(state.session_order or {}))
  local lines = {}
  for index = 1, count do
    lines[index] = ''
  end

  local was_modifiable = vim.api.nvim_buf_get_option(buf, 'modifiable')
  vim.api.nvim_buf_set_option(buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modified', false)
  vim.api.nvim_buf_set_option(buf, 'modifiable', was_modifiable)
end

local function set_win_option(win, name, value)
  pcall(vim.api.nvim_set_option_value, name, value, { scope = 'local', win = win })
end

local function configure_window(win, config)
  if not valid_win(win) then
    return
  end

  local width = session_width(config)
  vim.w[win].codex_session_list = true
  if vim.fn.exists '+winfixbuf' == 1 then
    set_win_option(win, 'winfixbuf', true)
  end
  set_win_option(win, 'number', true)
  set_win_option(win, 'relativenumber', false)
  set_win_option(win, 'numberwidth', width)
  set_win_option(win, 'signcolumn', 'no')
  set_win_option(win, 'foldcolumn', '0')
  set_win_option(win, 'statuscolumn', statuscolumn)
  set_win_option(win, 'cursorline', false)
  set_win_option(win, 'cursorcolumn', false)
  set_win_option(win, 'wrap', false)
  set_win_option(win, 'sidescrolloff', 0)
  set_win_option(win, 'winfixwidth', true)
  set_win_option(win, 'winbar', '')
  set_win_option(win, 'fillchars', 'eob: ')
  set_win_option(win, 'winhighlight', winhighlight)
  pcall(vim.api.nvim_win_set_width, win, width)
end

local function float_win_opts(config)
  local ok, win_config = pcall(vim.api.nvim_win_get_config, state.win)
  if not ok or not win_config or win_config.relative == '' then
    return nil
  end

  local border_offset = config.border == 'none' and 0 or 2
  return {
    relative = 'editor',
    width = session_width(config),
    height = win_config.height,
    row = win_config.row,
    col = win_config.col + win_config.width + border_offset,
    style = 'minimal',
  }
end

local function open_window(config)
  local buf = ensure_buffer()
  if config.panel then
    return vim.api.nvim_open_win(buf, false, {
      win = state.win,
      split = 'right',
      width = session_width(config),
    })
  end

  local opts = float_win_opts(config)
  if not opts then
    return nil
  end
  return vim.api.nvim_open_win(buf, false, opts)
end

local function repair_window(config)
  if not valid_win(M.win) then
    return false
  end
  sync_buffer_lines()
  configure_window(M.win, config)
  resize_terminal(config)
  pcall(vim.cmd.redrawstatus)
  return true
end

local function close_window()
  if valid_win(M.win) then
    pcall(vim.api.nvim_win_close, M.win, true)
  end
  M.win = nil
  if valid_buf(M.buf) then
    pcall(vim.api.nvim_buf_delete, M.buf, { force = true })
  end
  M.buf = nil
end

function M.setup(config)
  M.config = config
  setup_highlights()
  local group = vim.api.nvim_create_augroup('CodexSessionList', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = setup_highlights,
  })
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      remember_window(current_win())
    end,
  })
end

function M.reset()
  M.generation = M.generation + 1
  close_window()
  M.last_non_list_win = nil
end

function M.is_open()
  return valid_win(M.win)
end

function M.close()
  M.generation = M.generation + 1
  close_window()
end

function M.refresh()
  if not M.is_open() then
    return
  end
  if not state.has_sessions or not state.has_sessions() or not valid_win(state.win) then
    M.close()
    return
  end
  repair_window(M.config)
end

function M.emit_changed()
  pcall(vim.api.nvim_exec_autocmds, 'User', {
    pattern = 'CodexSessionsChanged',
    modeline = false,
  })
  M.refresh()
end

function M.open(config, opts)
  opts = opts or {}
  config = config or M.config
  if not config or not state.has_sessions or not state.has_sessions() or not valid_win(state.win) then
    M.close()
    return nil
  end

  M.config = config
  M.generation = M.generation + 1
  local restore_to = opts.restore_win or (opts.focus == false and current_win()) or nil
  remember_window(restore_to)

  sync_buffer_lines()
  if not valid_win(M.win) then
    M.win = open_window(config)
  end
  if not valid_win(M.win) then
    return nil
  end

  repair_window(config)
  if opts.focus == false then
    restore_focus(restore_to)
  end
  return M.win
end

function M.select_line(win, line)
  if not is_list_win(win) then
    return false
  end
  local session_id = session_id_at_line(line)
  if not session_id then
    return false
  end

  local active_win = current_win()
  local restore_to = active_win and not is_list_win(active_win) and active_win or M.last_non_list_win
  if not valid_win(restore_to) and valid_win(state.win) then
    restore_to = state.win
  end

  local ok = require('codex.terminal').select_session(session_id, {
    focus = false,
    restore_win = restore_to,
  })
  if ok then
    M.refresh()
    restore_focus(restore_to)
  end
  return ok
end

function M.statuscolumn()
  local label = label_for_line(vim.v.lnum)
  if label == '' then
    return ''
  end
  local id = session_id_at_line(vim.v.lnum)
  local highlight = id == state.active_session_id and '%#CodexSessionListActive#' or '%#CodexSessionListInactive#'
  return highlight .. pad_label(label, session_width(M.config)) .. '%*'
end

function M.click()
  local pos = vim.fn.getmousepos()
  if not pos then
    return
  end
  M.select_line(pos.winid, pos.line)
end

_G.CodexSessionListStatusColumn = function()
  return require('codex.session_list').statuscolumn()
end

_G.CodexSessionListClick = function()
  return require('codex.session_list').click()
end

return M
