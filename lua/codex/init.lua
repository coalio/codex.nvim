local app_server = require 'codex.app_server'
local commands = require 'codex.commands'
local config_module = require 'codex.config'
local editor = require 'codex.editor'
local installer = require 'codex.installer'
local logger = require 'codex.logger'
local selection = require 'codex.selection'
local state = require 'codex.state'
local terminal = require 'codex.terminal'
local ui = require 'codex.ui'
local util = require 'codex.util'

local M = {}

M.version = {
  major = 0,
  minor = 3,
  patch = 0,
  string = function(self)
    return string.format('%d.%d.%d', self.major, self.minor, self.patch)
  end,
}

local config = config_module.defaults

local function ensure_cli(callback)
  local resolved_cmd = util.resolve_cmd(config.cmd)
  local check_cmd = util.executable_from_cmd(resolved_cmd)
  if not check_cmd or vim.fn.executable(check_cmd) == 1 then
    config.cmd = resolved_cmd
    callback(true)
    return
  end

  if not config.autoinstall then
    logger.error('Codex CLI not found:', check_cmd)
    callback(false)
    return
  end

  installer.prompt_autoinstall(callback)
end

local function capture_send_opts(opts)
  local send_opts = opts and vim.deepcopy(opts) or {}
  if not send_opts.selection and config.include_active_buffer_context then
    local active = editor.active()
    send_opts.active_context = active
    send_opts.active_description = editor.describe(active)
  end
  return send_opts
end

function M.setup(user_config)
  config = config_module.apply(user_config)
  config.cmd = util.resolve_cmd(config.cmd)
  terminal.setup(config)
  ui.setup(config)
  app_server.setup(config, M.version:string())
  commands.setup(config, M)

  if config.keymaps.toggle then
    vim.api.nvim_set_keymap('n', config.keymaps.toggle, '<cmd>CodexToggle<CR>', { noremap = true, silent = true })
  end

  if config.track_selection then
    selection.enable(config.visual_demotion_delay_ms)
  end

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('CodexShutdown', { clear = true }),
    callback = function()
      app_server.stop()
    end,
  })

  if config.backend == 'app_server' and config.app_server.auto_start then
    ensure_cli(function(ok)
      if ok then
        app_server.start(function(start_ok, err)
          if not start_ok then
            logger.warn('Codex app-server did not start:', err and (err.message or util.text_content(err)) or 'unknown error')
          end
        end)
      end
    end)
  end
end

function M.open()
  if config.backend == 'terminal' then
    terminal.open()
    return
  end

  if config.app_server.ui == 'terminal' then
    terminal.open_placeholder()
  end

  ensure_cli(function(ok)
    if ok then
      if config.app_server.ui == 'terminal' then
        app_server.start(function(start_ok, err)
          if not terminal.is_requested() then
            return
          end
          if start_ok then
            app_server.open_terminal()
          else
            terminal.show_error(err and (err.message or util.text_content(err)) or 'App Server did not become ready')
          end
        end)
      else
        ui.open()
        app_server.start()
      end
    end
  end)
end

function M.resume()
  if config.backend == 'terminal' then
    terminal.open({ resume_last = true, insert = true })
    return
  end

  if config.app_server.ui ~= 'terminal' then
    M.open()
    return
  end

  terminal.open_placeholder({ focus = true })
  ensure_cli(function(ok)
    if ok then
      app_server.start(function(start_ok, err)
        if not terminal.is_requested() then
          return
        end
        if start_ok then
          app_server.open_terminal({ resume_last = true, focus = true, insert = true })
        else
          terminal.show_error(err and (err.message or util.text_content(err)) or 'App Server did not become ready')
        end
      end)
    end
  end)
end

function M.focus()
  if config.backend == 'terminal' then
    terminal.focus({ insert = true })
    return
  end

  if config.app_server.ui == 'terminal' then
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      terminal.focus({ insert = true })
      return
    end
    terminal.open_placeholder({ focus = true })
    ensure_cli(function(ok)
      if ok then
        app_server.start(function(start_ok, err)
          if not terminal.is_requested() then
            return
          end
          if start_ok then
            app_server.open_terminal({ focus = true, insert = true })
          else
            terminal.show_error(err and (err.message or util.text_content(err)) or 'App Server did not become ready')
          end
        end)
      end
    end)
    return
  end

  ui.open()
end

function M.close()
  if config.backend == 'terminal' then
    terminal.close()
  elseif config.app_server.ui == 'terminal' then
    terminal.close()
  else
    ui.close()
  end
end

function M.toggle()
  if config.backend == 'terminal' then
    terminal.toggle()
  else
    if config.app_server.ui == 'terminal' then
      if state.win and vim.api.nvim_win_is_valid(state.win) then
        terminal.close()
      else
        M.open()
      end
      return
    end
    ui.toggle()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      ensure_cli(function(ok)
        if ok then
          app_server.start()
        end
      end)
    end
  end
end

function M.send(prompt, opts)
  local send_opts = capture_send_opts(opts)
  local preserve_focus = config.backend == 'app_server' and config.app_server.ui == 'terminal' and send_opts.submit == false

  if config.backend == 'app_server' and config.app_server.ui == 'terminal' then
    terminal.open_placeholder({ focus = not preserve_focus })
  end

  ensure_cli(function(ok)
    if ok then
      if config.app_server.ui == 'terminal' then
        app_server.start(function(start_ok, err)
          if not terminal.is_requested() then
            return
          end
          if start_ok then
            app_server.send(prompt, send_opts)
          else
            terminal.show_error(err and (err.message or util.text_content(err)) or 'App Server did not become ready')
          end
        end)
        return
      end
      ui.open()
      app_server.send(prompt, send_opts)
    end
  end)
end

function M.statusline()
  if config.backend == 'terminal' then
    if state.job and not (state.win and vim.api.nvim_win_is_valid(state.win)) then
      return '[Codex]'
    end
    return ''
  end
  if state.app.running then
    return '[Codex: running]'
  elseif state.app.thread_id then
    return '[Codex]'
  end
  return ''
end

function M.status()
  return {
    function()
      return M.statusline()
    end,
    cond = function()
      return M.statusline() ~= ''
    end,
    icon = '',
    color = { fg = '#51afef' },
  }
end

function M.get_config()
  return config
end

function M._reset_for_tests()
  app_server.stop()
  selection.disable()
  state.buf = nil
  state.win = nil
  state.job = nil
  state.app = {
    client = nil,
    thread_id = nil,
    active_turn_id = nil,
    running = false,
    initialized = false,
    server_job = nil,
    listen_url = nil,
    port = nil,
    session_id = nil,
    terminal_opened = false,
    pending_sends = {},
    pending_injections = {},
    pending_context = {},
    models = {},
    apps = {},
    skills = {},
    mcp_servers = {},
    items = {},
  }
end

return setmetatable(M, {
  __call = function(_, opts)
    M.setup(opts)
  end,
})
