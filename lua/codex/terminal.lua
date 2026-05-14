local installer = require 'codex.installer'
local prompt_builder = require 'codex.prompt'
local state = require 'codex.state'
local util = require 'codex.util'

local M = {
  config = nil,
  remote = nil,
  requested = false,
  pending_input = {},
}

function M.setup(config)
  M.config = config
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

  return buf
end

local function open_window(config)
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
end

local function open_panel(config)
  vim.cmd 'vertical rightbelow vsplit'
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, state.buf)
  vim.api.nvim_win_set_width(win, math.floor(vim.o.columns * config.width))
  state.win = win
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

local function ensure_window(config)
  ensure_start_buf(config)

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    vim.api.nvim_win_set_buf(state.win, state.buf)
    return
  end

  if config.panel then
    open_panel(config)
  else
    open_window(config)
  end
end

local function set_message(lines)
  local config = M.config
  ensure_window(config)
  local was_modifiable = vim.api.nvim_buf_get_option(state.buf, 'modifiable')
  vim.api.nvim_buf_set_option(state.buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines or { '' })
  vim.api.nvim_buf_set_option(state.buf, 'modified', false)
  vim.api.nvim_buf_set_option(state.buf, 'modifiable', was_modifiable)
end

local function build_cmd_args(config, remote)
  local cmd_args = util.normalize_cmd(config.cmd)
  if remote and remote.url then
    table.insert(cmd_args, '--remote')
    table.insert(cmd_args, remote.url)
    if #M.pending_input > 0 then
      table.insert(cmd_args, table.remove(M.pending_input, 1))
    end
    return cmd_args
  end

  if config.model then
    table.insert(cmd_args, '-m')
    table.insert(cmd_args, config.model)
  end
  return cmd_args
end

local function send_to_terminal(text)
  if not state.job or not text or text == '' then
    return false
  end

  local ok = pcall(vim.fn.chansend, state.job, '\027[200~' .. text .. '\027[201~')
  if not ok then
    return false
  end

  vim.defer_fn(function()
    if state.job then
      pcall(vim.fn.chansend, state.job, '\r')
    end
  end, 20)
  return true
end

function M.flush_pending()
  if not state.job or #M.pending_input == 0 then
    return
  end

  local pending = M.pending_input
  M.pending_input = {}
  vim.defer_fn(function()
    for _, text in ipairs(pending) do
      if state.job then
        send_to_terminal(text)
      end
    end
  end, 300)
end

function M.open()
  local config = M.config
  M.requested = true

  local check_cmd = util.executable_from_cmd(config.cmd)
  if check_cmd and vim.fn.executable(check_cmd) == 0 then
    if config.autoinstall then
      installer.prompt_autoinstall(function(success)
        if success then
          M.open()
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
            open_panel(config)
          else
            open_window(config)
          end
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
      open_panel(config)
    else
      open_window(config)
    end
    return
  end

  ensure_window(config)

  if state.job then
    return
  end

  local cmd_args = build_cmd_args(config, M.remote)

  if config.use_buffer then
    state.job = vim.fn.jobstart(cmd_args, {
      cwd = vim.loop.cwd(),
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
      cwd = vim.loop.cwd(),
      on_exit = function(_, code)
        state.job = nil
        state.app.terminal_opened = false
        if code ~= 0 and M.remote then
          state.app.thread_id = nil
          state.app.session_id = nil
          M.remote = nil
          M.pending_input = {}
        end
      end,
    })
    if ok and type(job_or_err) == 'number' and job_or_err > 0 then
      state.job = job_or_err
      M.flush_pending()
    else
      state.job = nil
      state.buf = nil
      set_message { 'Codex terminal failed to start.', tostring(job_or_err) }
    end
  end
end

function M.open_remote(url, thread_id)
  if not M.requested then
    return false
  end
  M.remote = {
    url = url,
    thread_id = thread_id,
  }
  M.open()
  return true
end

function M.send(prompt, opts)
  local text = prompt_builder.terminal(prompt, opts, M.config)
  if text == '' then
    return false
  end

  M.requested = true
  if send_to_terminal(text) then
    return true
  end

  table.insert(M.pending_input, text)
  if M.remote and M.remote.url then
    M.open()
  end
  return true
end

function M.open_placeholder()
  M.requested = true
  ensure_window(M.config)
end

function M.show_error(message)
  M.requested = true
  ensure_window(M.config)
  set_message { 'Codex failed to start.', tostring(message or 'unknown error') }
end

function M.is_requested()
  return M.requested
end

function M.close()
  M.requested = false
  M.pending_input = {}
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

return M
