local installer = require 'codex.installer'
local state = require 'codex.state'
local util = require 'codex.util'

local M = {
  config = nil,
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

function M.open()
  local config = M.config
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

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

  if not is_buf_reusable(state.buf) then
    state.buf = create_clean_buf(config)
  end

  if config.panel then
    open_panel(config)
  else
    open_window(config)
  end

  if state.job then
    return
  end

  local cmd_args = util.normalize_cmd(config.cmd)
  if config.model then
    table.insert(cmd_args, '-m')
    table.insert(cmd_args, config.model)
  end

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
    state.job = vim.fn.termopen(cmd_args, {
      cwd = vim.loop.cwd(),
      on_exit = function()
        state.job = nil
      end,
    })
  end
end

function M.close()
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
