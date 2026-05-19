local state = require 'codex.state'

local M = {
  config = nil,
  expanded = false,
  generation = 0,
  mode = 'codex_sessions',
  view = nil,
}

local function require_trouble()
  local ok, trouble = pcall(require, 'trouble')
  if not ok then
    error('codex.nvim requires folke/trouble.nvim for Codex session management: ' .. tostring(trouble), 0)
  end
  return trouble
end

local function valid_win(win)
  return type(win) == 'number' and vim.api.nvim_win_is_valid(win)
end

local function current_win()
  local ok, win = pcall(vim.api.nvim_get_current_win)
  return ok and win or nil
end

local function session_width(config)
  local list = config and config.session_list or {}
  local width = tonumber(list.width) or 24
  width = math.max(1, math.floor(width))
  if M.expanded then
    return width
  end
  return math.max(5, math.min(width, #'[+] (S)'))
end

local function terminal_width(config)
  return math.max(1, math.floor(vim.o.columns * config.width))
end

local function resize_terminal(config)
  if config and config.panel and valid_win(state.win) then
    pcall(vim.api.nvim_win_set_width, state.win, terminal_width(config))
  end
end

local function mark_window(win)
  if not valid_win(win) then
    return
  end

  vim.w[win].codex_session_list = true
  if vim.fn.exists '+winfixbuf' == 1 then
    pcall(vim.api.nvim_set_option_value, 'winfixbuf', true, { scope = 'local', win = win })
  end
  pcall(vim.api.nvim_set_option_value, 'number', false, { scope = 'local', win = win })
  pcall(vim.api.nvim_set_option_value, 'relativenumber', false, { scope = 'local', win = win })
  pcall(vim.api.nvim_set_option_value, 'signcolumn', 'no', { scope = 'local', win = win })
  pcall(vim.api.nvim_set_option_value, 'wrap', false, { scope = 'local', win = win })
  pcall(vim.api.nvim_set_option_value, 'sidescrolloff', 0, { scope = 'local', win = win })
  pcall(vim.api.nvim_set_option_value, 'winfixwidth', true, { scope = 'local', win = win })
end

local function restore_focus(win)
  if valid_win(win) then
    pcall(vim.api.nvim_set_current_win, win)
  end
end

local function view_window(view)
  return view and view.win and view.win.win or nil
end

local function view_is_open(view)
  local win = view_window(view)
  return valid_win(win)
end

local function session_views(open)
  local ok, view = pcall(require, 'trouble.view')
  if not ok then
    return {}
  end
  return view.get {
    mode = M.mode,
    open = open,
  }
end

local function active_view()
  if view_is_open(M.view) then
    return M.view
  end
  local views = session_views(true)
  for index = #views, 1, -1 do
    local view = views[index].view
    local win = view_window(view)
    if valid_win(win) then
      return view
    end
  end
  return nil
end

local function close_session_views(except)
  for _, entry in ipairs(session_views(false)) do
    local view = entry.view
    if view and view ~= except and view.close then
      pcall(function()
        view:close()
      end)
    end
  end
end

local function apply_view_window(view, config)
  local win = view_window(view)
  if valid_win(win) then
    mark_window(win)
    pcall(vim.api.nvim_win_set_width, win, session_width(config))
  end
  resize_terminal(config)
end

local function ensure_view_window(view)
  if view_is_open(view) or not view or not view.win or not view.win.open then
    return
  end
  if view.count and view:count() == 0 then
    return
  end
  pcall(function()
    view.win:open()
    if view.update then
      view:update()
    end
  end)
end

local function float_win_opts(config)
  local ok, win_config = pcall(vim.api.nvim_win_get_config, state.win)
  if not ok or not win_config or win_config.relative == '' then
    return nil
  end

  local border_offset = config.border == 'none' and 0 or 2
  return {
    type = 'float',
    relative = 'editor',
    size = {
      width = session_width(config),
      height = win_config.height,
    },
    position = {
      win_config.row,
      win_config.col + win_config.width + border_offset,
    },
    wo = {
      wrap = false,
      winfixwidth = true,
    },
  }
end

local function split_win_opts(config)
  return {
    type = 'split',
    relative = 'win',
    position = 'right',
    size = session_width(config),
    win = state.win,
    wo = {
      winfixbuf = true,
      winfixwidth = true,
      wrap = false,
    },
  }
end

local function window_opts(config)
  if config.panel then
    return split_win_opts(config)
  end
  return float_win_opts(config)
end

function M.setup(config)
  M.config = config
  require_trouble()
end

function M.reset()
  M.expanded = false
  M.generation = M.generation + 1
  M.view = nil
end

function M.is_open()
  return view_is_open(M.view) or require_trouble().is_open { mode = M.mode }
end

function M.close()
  require_trouble()
  M.generation = M.generation + 1
  if M.view and M.view.close then
    pcall(function()
      M.view:close()
    end)
  end
  M.view = nil
  close_session_views()
end

function M.refresh()
  require_trouble()
  if M.view and M.view.refresh then
    pcall(function()
      M.view:refresh()
    end)
  end
  require_trouble().refresh { mode = M.mode }
end

function M.emit_changed()
  pcall(vim.api.nvim_exec_autocmds, 'User', {
    pattern = 'CodexSessionsChanged',
    modeline = false,
  })
  if M.is_open() then
    M.refresh()
  end
end

function M.open(config, opts)
  opts = opts or {}
  config = config or M.config
  if not config or not state.has_sessions or not state.has_sessions() or not valid_win(state.win) then
    M.close()
    return nil
  end

  local win = window_opts(config)
  if not win then
    M.close()
    return nil
  end

  M.generation = M.generation + 1
  local generation = M.generation
  close_session_views()
  M.view = nil

  local restore_to = opts.focus == false and (opts.restore_win or current_win()) or nil
  local trouble = require_trouble()
  local view = trouble.open {
    mode = M.mode,
    auto_preview = false,
    follow = false,
    focus = opts.focus == true,
    multiline = false,
    open_no_results = true,
    refresh = true,
    restore = false,
    new = true,
    warn_no_results = false,
    win = win,
  }
  view = active_view() or view
  M.view = view

  local function repair()
    if generation ~= M.generation or view ~= M.view then
      if view and view.close then
        pcall(function()
          view:close()
        end)
      end
      return
    end
    ensure_view_window(view)
    apply_view_window(view, config)
    close_session_views(view)
    if opts.focus == false then
      restore_focus(restore_to)
    end
  end

  if view and view.wait then
    view:wait(repair)
  else
    vim.schedule(repair)
  end
  vim.defer_fn(repair, 50)
  vim.defer_fn(repair, 250)

  return view
end

function M.toggle_expanded()
  M.expanded = not M.expanded
  if M.is_open() then
    M.open(M.config, { focus = false })
  end
  M.emit_changed()
  return true
end

function M.items()
  local items = {}
  for index, id in ipairs(state.session_order or {}) do
    local session = state.sessions and state.sessions[id] or nil
    if session then
      local active = id == state.active_session_id
      local label = M.expanded and ('%s (%d)'):format(session.name or ('session-' .. tostring(id)), id) or ('(%d)'):format(id)
      table.insert(items, {
        id = 'codex-session-' .. tostring(id),
        session_id = id,
        session_index = index,
        label = label,
        active = active,
        active_marker = active and '* ' or '  ',
        filename = vim.fn.getcwd(),
        source = 'codex_sessions',
        pos = { index, 0 },
      })
    end
  end
  return items
end

return M
