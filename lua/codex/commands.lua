local app_server = require 'codex.app_server'
local logger = require 'codex.logger'
local selection = require 'codex.selection'
local ui = require 'codex.ui'
local util = require 'codex.util'

local M = {}

local config
local api

local function current_range_selection(opts)
  if opts and opts.range and opts.range > 0 then
    return selection.get_range_selection(opts.line1, opts.line2)
  end

  selection.update_selection()
  local latest = selection.get_latest_selection()
  if latest and not latest.selection.isEmpty then
    return latest
  end
  return nil
end

local function send_with_prompt(opts)
  local args = opts and opts.args or ''
  local range_selection = current_range_selection(opts)

  local function do_send(prompt)
    if prompt == nil then
      return
    end
    api.send(prompt, { selection = range_selection })
  end

  if args and args ~= '' then
    do_send(args)
  elseif range_selection then
    do_send(config.selection_prompt)
  else
    vim.ui.input({ prompt = 'Codex prompt: ' }, do_send)
  end
end

local function select_model()
  app_server.list_models(function(models, err)
    if err then
      logger.error('model/list failed:', err.message or util.text_content(err))
      return
    end
    vim.ui.select(models or {}, {
      prompt = 'Select Codex model:',
      format_item = function(model)
        local label = model.displayName or model.id or model.model
        if model.defaultReasoningEffort then
          label = label .. ' (' .. model.defaultReasoningEffort .. ')'
        end
        return label
      end,
    }, function(choice)
      if not choice then
        return
      end
      config.model = choice.model or choice.id
      logger.info('Selected model:', config.model)
    end)
  end)
end

local function select_app()
  app_server.list_apps(function(apps, err)
    if err then
      logger.error('app/list failed:', err.message or util.text_content(err))
      return
    end
    vim.ui.select(apps or {}, {
      prompt = 'Add Codex app:',
      format_item = function(app)
        local suffix = app.isEnabled == false and ' (disabled)' or ''
        return (app.name or app.id) .. suffix
      end,
    }, function(choice)
      if choice then
        app_server.add_app(choice)
      end
    end)
  end)
end

local function select_skill()
  app_server.list_skills(function(skills, err)
    if err then
      logger.error('skills/list failed:', err.message or util.text_content(err))
      return
    end
    vim.ui.select(skills or {}, {
      prompt = 'Add Codex skill:',
      format_item = function(skill)
        return skill.name .. (skill.description and (' - ' .. skill.description) or '')
      end,
    }, function(choice)
      if choice then
        app_server.add_skill(choice)
      end
    end)
  end)
end

local function show_mcp()
  app_server.list_mcp(function(servers, err)
    if err then
      logger.error('mcpServerStatus/list failed:', err.message or util.text_content(err))
      return
    end

    ui.open()
    ui.append_block('MCP servers:')
    for _, server in ipairs(servers or {}) do
      local tools_count = 0
      for _ in pairs(server.tools or {}) do
        tools_count = tools_count + 1
      end
      ui.append(('%s (%s, %d tools)'):format(server.name, server.authStatus or 'unknown', tools_count))
      local names = {}
      for name in pairs(server.tools or {}) do
        table.insert(names, name)
      end
      table.sort(names)
      if #names > 0 then
        ui.append('  ' .. table.concat(names, ', '))
      end
    end
  end)
end

local function add_context(opts)
  local args = vim.split(opts.args or '', '%s+', { trimempty = true })
  local path = args[1]
  if not path or path == '' then
    local sel = current_range_selection(opts)
    if sel then
      app_server.add_selection(sel)
    else
      logger.warn 'No file or selection to add'
    end
    return
  end
  local start_line = args[2] and tonumber(args[2]) or nil
  local end_line = args[3] and tonumber(args[3]) or start_line
  app_server.add_file(path, start_line and (start_line - 1) or nil, end_line and (end_line - 1) or nil)
end

function M.setup(active_config, active_api)
  config = active_config
  api = active_api

  vim.api.nvim_create_user_command('Codex', function(opts)
    if (opts.args and opts.args ~= '') or (opts.range and opts.range > 0) then
      send_with_prompt(opts)
    else
      api.toggle()
    end
  end, { desc = 'Toggle Codex or send a prompt', nargs = '*', range = true })

  vim.api.nvim_create_user_command('CodexToggle', function()
    api.toggle()
  end, { desc = 'Toggle Codex window' })

  vim.api.nvim_create_user_command('CodexSend', send_with_prompt, { desc = 'Send prompt or selected range to Codex', nargs = '*', range = true })
  vim.api.nvim_create_user_command('CodexAdd', add_context, { desc = 'Add file, directory, or selection as Codex context', nargs = '*', complete = 'file', range = true })

  vim.api.nvim_create_user_command('CodexNew', function()
    app_server.new_thread()
  end, { desc = 'Start a fresh Codex thread' })

  vim.api.nvim_create_user_command('CodexStop', function()
    app_server.stop()
  end, { desc = 'Stop Codex app-server' })

  vim.api.nvim_create_user_command('CodexInterrupt', function()
    app_server.interrupt()
  end, { desc = 'Interrupt the active Codex turn' })

  vim.api.nvim_create_user_command('CodexSelectModel', select_model, { desc = 'Select a Codex model from app-server' })
  vim.api.nvim_create_user_command('CodexApps', select_app, { desc = 'Add a Codex app connector to the next prompt' })
  vim.api.nvim_create_user_command('CodexSkills', select_skill, { desc = 'Add a Codex skill to the next prompt' })
  vim.api.nvim_create_user_command('CodexMcp', show_mcp, { desc = 'Show Codex MCP server and tool status' })
  vim.api.nvim_create_user_command('CodexReloadMcp', function()
    app_server.reload_mcp(function(ok, err)
      if ok then
        logger.info 'Reloaded Codex MCP configuration'
      else
        logger.error('MCP reload failed:', err and (err.message or util.text_content(err)) or 'unknown error')
      end
    end)
  end, { desc = 'Reload Codex MCP server configuration' })
end

return M
