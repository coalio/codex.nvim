local approvals = require 'codex.approvals'
local app_process = require 'codex.app_server_process'
local editor = require 'codex.editor'
local jsonrpc = require 'codex.jsonrpc'
local logger = require 'codex.logger'
local selection = require 'codex.selection'
local state = require 'codex.state'
local terminal = require 'codex.terminal'
local tools = require 'codex.tools'
local ui = require 'codex.ui'
local util = require 'codex.util'
local ws_rpc = require 'codex.ws_rpc'

local M = {
  config = nil,
  version = '0.1.0',
  ready_callbacks = {},
  starting = false,
}

local function build_cmd(config)
  local cmd = util.normalize_cmd(config.cmd)
  table.insert(cmd, 'app-server')
  if config.app_server.listen then
    table.insert(cmd, '--listen')
    table.insert(cmd, config.app_server.listen)
  end
  for _, feature in ipairs(config.app_server.enable_features or {}) do
    table.insert(cmd, '--enable')
    table.insert(cmd, feature)
  end
  return cmd
end

local function terminal_ui()
  return M.config and M.config.app_server and M.config.app_server.ui == 'terminal'
end

local function text_item(text)
  return {
    type = 'text',
    text = text,
    text_elements = {},
  }
end

local function context_label(item)
  if item.line_start and item.line_end then
    return ('%s:%d-%d'):format(item.name or item.path, item.line_start + 1, item.line_end + 1)
  end
  return item.label or item.name or item.path
end

local function build_input(prompt, opts)
  opts = opts or {}
  local pending = vim.deepcopy(state.app.pending_context or {})
  local context_items = {}
  local input = {}
  local text = prompt or ''
  local prefixes = {}

  local sel = opts.selection
  if sel and not sel.selection.isEmpty then
    local start_line = sel.selection.start.line
    local end_line = sel.selection['end'].line
    local name = util.relative_path(sel.filePath)
    table.insert(pending, {
      type = 'mention',
      name = name,
      path = sel.filePath,
      label = ('%s:%d-%d'):format(name, start_line + 1, end_line + 1),
      line_start = start_line,
      line_end = end_line,
    })
    text = text
      .. ('\n\nSelected lines from %s:%d-%d:\n```text\n%s\n```'):format(name, start_line + 1, end_line + 1, sel.text or '')
  elseif M.config.include_active_buffer_context then
    local active = editor.active()
    local description = editor.describe(active)
    if active and description then
      table.insert(pending, {
        type = 'mention',
        name = active.name,
        path = active.path,
        label = active.name,
      })
      text = text .. '\n\n' .. description
    end
  end

  for _, item in ipairs(pending) do
    if item.type == 'mention' or item.type == 'skill' then
      table.insert(input, {
        type = item.type,
        name = item.name,
        path = item.path,
      })
      table.insert(context_items, item)
      if item.path and item.path:match '^app://' then
        table.insert(prefixes, '$' .. item.path:gsub('^app://', ''))
      elseif item.type == 'skill' then
        table.insert(prefixes, '$' .. item.name)
      end
    end
  end

  if #prefixes > 0 then
    text = table.concat(prefixes, ' ') .. ' ' .. text
  end

  table.insert(input, 1, text_item(text))
  state.app.pending_context = {}

  return input, context_items
end

local function editor_instructions()
  if not M.config.app_server.editor_instructions then
    return nil
  end
  if type(M.config.app_server.editor_instructions) == 'string' then
    return M.config.app_server.editor_instructions
  end
  return table.concat({
    'You are connected to Neovim through codex.nvim.',
    'The dynamic tools in the nvim namespace expose the active editor, latest selection, open buffers, diagnostics, dirty state, saves, file opening, and diff review.',
    'When a request depends on the current file, selected lines, open buffers, or diagnostics, inspect that Neovim state with the nvim tools before assuming context.',
  }, ' ')
end

local function flush_ready(ok, err)
  local callbacks = M.ready_callbacks
  M.ready_callbacks = {}
  for _, cb in ipairs(callbacks) do
    cb(ok, err)
  end
end

local function on_notification(msg)
  local method = msg.method
  local params = msg.params or {}

  if method == 'turn/started' then
    state.app.running = true
    state.app.active_turn_id = params.turn and params.turn.id or state.app.active_turn_id
  elseif method == 'turn/completed' then
    state.app.running = false
    state.app.active_turn_id = nil
  elseif method == 'thread/started' then
    state.app.thread_id = params.thread and params.thread.id or state.app.thread_id
  elseif method == 'thread/closed' then
    if params.threadId == state.app.thread_id then
      state.app.thread_id = nil
      state.app.active_turn_id = nil
      state.app.running = false
    end
  elseif method == 'app/list/updated' then
    state.app.apps = params.data or {}
  elseif method == 'skills/changed' then
    state.app.skills = {}
  end

  if not terminal_ui() then
    ui.render_notification(msg)
  end
end

local function on_request(msg, respond)
  local method = msg.method
  local params = msg.params or {}

  if method == 'item/tool/call' then
    tools.handle(params, function(result)
      respond(result)
    end)
  elseif method == 'item/commandExecution/requestApproval' then
    approvals.command(params, respond)
  elseif method == 'item/fileChange/requestApproval' then
    approvals.file_change(params, respond)
  elseif method == 'item/tool/requestUserInput' then
    approvals.user_input(params, respond)
  elseif method == 'mcpServer/elicitation/request' then
    approvals.mcp_elicitation(params, respond)
  elseif method == 'applyPatchApproval' then
    respond({ decision = 'denied' })
  elseif method == 'execCommandApproval' then
    respond({ decision = 'denied' })
  elseif method == 'account/chatgptAuthTokens/refresh' then
    respond(nil, { code = -32601, message = 'Externally managed ChatGPT tokens are not configured by codex.nvim' })
  else
    respond(nil, { code = -32601, message = 'Unsupported server request: ' .. tostring(method) })
  end
end

local function start_thread(callback)
  if state.app.thread_id then
    callback(true)
    return
  end

  local params = {
    cwd = util.cwd(),
    serviceName = M.config.app_server.service_name,
  }
  if M.config.model then
    params.model = M.config.model
  end
  if M.config.app_server.approval_policy then
    params.approvalPolicy = M.config.app_server.approval_policy
  end
  if M.config.app_server.sandbox then
    params.sandbox = M.config.app_server.sandbox
  end
  if M.config.app_server.dynamic_tools then
    params.dynamicTools = tools.get_specs()
  end
  local instructions = editor_instructions()
  if instructions then
    params.developerInstructions = instructions
  end

  state.app.client:request('thread/start', params, function(err, result)
    if err then
      logger.error('thread/start failed:', err.message or util.text_content(err))
      callback(false, err)
      return
    end
    state.app.thread_id = result and result.thread and result.thread.id or nil
    if not state.app.thread_id then
      callback(false, { message = 'thread/start did not return a thread id' })
      return
    end
    callback(true)
  end)
end

local function connect_ws_client(listen_url, callback)
  local attempts = 0
  local max_attempts = M.config.app_server.connect_attempts or 100

  local function attempt()
    attempts = attempts + 1
    local client = ws_rpc.new {
      url = listen_url,
      on_notification = on_notification,
      on_request = on_request,
      on_exit = function()
        state.app.client = nil
        state.app.initialized = false
        state.app.thread_id = nil
        state.app.active_turn_id = nil
        state.app.running = false
        M.starting = false
      end,
    }

    client:start(function(ok, err)
      if not ok then
        client:stop()
        if attempts < max_attempts then
          vim.defer_fn(attempt, 50)
        else
          callback(false, { message = err or 'failed to connect to app-server websocket' })
        end
        return
      end

      state.app.client = client
      callback(true)
    end)
  end

  attempt()
end

local function start_websocket(callback)
  app_process.start(M.config, function(process_ok, listen_url, process_err)
    if not process_ok then
      callback(false, { message = process_err })
      return
    end

    connect_ws_client(listen_url, function(connect_ok, connect_err)
      if not connect_ok then
        callback(false, connect_err)
        return
      end

      state.app.client:request('initialize', {
        clientInfo = {
          name = 'codex_nvim',
          title = 'codex.nvim',
          version = M.version,
        },
        capabilities = {
          experimentalApi = M.config.app_server.experimental == true,
        },
      }, function(init_err)
        if init_err then
          callback(false, init_err)
          return
        end

        state.app.client:notify('initialized', {})
        state.app.initialized = true
        start_thread(callback)
      end)
    end)
  end)
end

function M.setup(config, version)
  M.config = config
  M.version = version or M.version
  tools.register_all()
end

function M.start(callback)
  callback = callback or function() end

  if state.app.client and state.app.client:is_running() and state.app.initialized then
    if state.app.thread_id then
      callback(true)
    else
      start_thread(callback)
    end
    return
  end

  table.insert(M.ready_callbacks, callback)
  if M.starting then
    return
  end
  M.starting = true

  if terminal_ui() then
    start_websocket(function(ok, err)
      M.starting = false
      flush_ready(ok, err)
    end)
    return
  end

  local client = jsonrpc.new {
    cmd = build_cmd(M.config),
    cwd = util.cwd(),
    on_notification = on_notification,
    on_request = on_request,
    on_stderr = function(line)
      logger.debug(line)
    end,
    on_exit = function(code)
      state.app.client = nil
      state.app.initialized = false
      state.app.thread_id = nil
      state.app.active_turn_id = nil
      state.app.running = false
      M.starting = false
      ui.append(('app-server exited with code %s'):format(tostring(code)))
    end,
  }

  state.app.client = client
  local ok, err = client:start()
  if not ok then
    M.starting = false
    flush_ready(false, err)
    return
  end

  client:request('initialize', {
    clientInfo = {
      name = 'codex_nvim',
      title = 'codex.nvim',
      version = M.version,
    },
    capabilities = {
      experimentalApi = M.config.app_server.experimental == true,
    },
  }, function(init_err)
    if init_err then
      M.starting = false
      flush_ready(false, init_err)
      return
    end

    client:notify('initialized', {})
    state.app.initialized = true

    start_thread(function(thread_ok, thread_err)
      M.starting = false
      flush_ready(thread_ok, thread_err)
    end)
  end)
end

function M.stop()
  if state.app.client then
    state.app.client:stop()
  end
  app_process.stop()
  state.app.client = nil
  state.app.server_job = nil
  state.app.listen_url = nil
  state.app.port = nil
  state.app.initialized = false
  state.app.thread_id = nil
  state.app.active_turn_id = nil
  state.app.running = false
  state.app.terminal_opened = false
end

function M.new_thread(callback)
  state.app.thread_id = nil
  state.app.active_turn_id = nil
  state.app.running = false
  state.app.items = {}
  if not terminal_ui() then
    ui.clear()
  end
  M.start(function(ok, err)
    if callback then
      callback(ok, err)
    end
  end)
end

function M.send(prompt, opts)
  opts = opts or {}
  prompt = prompt or ''
  if prompt == '' and not opts.selection then
    logger.warn 'Nothing to send'
    return
  end

  M.start(function(ok, err)
    if not ok then
      logger.error('app-server is not ready:', err and (err.message or util.text_content(err)) or 'unknown error')
      return
    end

    local input, display_context = build_input(prompt, opts)
    if terminal_ui() then
      M.open_terminal()
    else
      ui.render_user_input(prompt, display_context)
    end

    if state.app.running and state.app.active_turn_id then
      state.app.client:request('turn/steer', {
        threadId = state.app.thread_id,
        input = input,
        expectedTurnId = state.app.active_turn_id,
      }, function(req_err)
        if req_err then
          logger.error('turn/steer failed:', req_err.message or util.text_content(req_err))
        end
      end)
      return
    end

    state.app.client:request('turn/start', {
      threadId = state.app.thread_id,
      input = input,
      cwd = util.cwd(),
      model = M.config.model,
    }, function(req_err, result)
      if req_err then
        state.app.running = false
        logger.error('turn/start failed:', req_err.message or util.text_content(req_err))
        return
      end
      state.app.running = true
      state.app.active_turn_id = result and result.turn and result.turn.id or state.app.active_turn_id
    end)
  end)
end

function M.interrupt()
  if not state.app.client or not state.app.thread_id or not state.app.active_turn_id then
    logger.warn 'No active Codex turn to interrupt'
    return
  end
  state.app.client:request('turn/interrupt', {
    threadId = state.app.thread_id,
    turnId = state.app.active_turn_id,
  }, function(err)
    if err then
      logger.error('turn/interrupt failed:', err.message or util.text_content(err))
    end
  end)
end

function M.add_file(path, start_line, end_line)
  local expanded = vim.fn.expand(path)
  if vim.fn.filereadable(expanded) == 0 and vim.fn.isdirectory(expanded) == 0 then
    logger.error('Path does not exist:', expanded)
    return false
  end

  local name = util.relative_path(expanded)
  table.insert(state.app.pending_context, {
    type = 'mention',
    name = name,
    path = expanded,
    label = start_line and end_line and ('%s:%d-%d'):format(name, start_line + 1, end_line + 1) or name,
    line_start = start_line,
    line_end = end_line,
  })
  logger.info('Added Codex context:', context_label(state.app.pending_context[#state.app.pending_context]))
  return true
end

function M.open_terminal()
  if not terminal_ui() or not M.config.app_server.open_terminal then
    return
  end
  if not state.app.listen_url then
    return
  end
  terminal.open_remote(state.app.listen_url, state.app.thread_id)
  state.app.terminal_opened = true
end

function M.add_selection(sel)
  if not sel or sel.selection.isEmpty then
    logger.warn 'No selection to add'
    return false
  end
  return M.add_file(sel.filePath, sel.selection.start.line, sel.selection['end'].line)
end

function M.add_app(app)
  if not app or not app.id then
    return false
  end
  table.insert(state.app.pending_context, {
    type = 'mention',
    name = app.name or app.id,
    path = 'app://' .. app.id,
    label = '$' .. app.id,
  })
  logger.info('Added Codex app:', app.name or app.id)
  return true
end

function M.add_skill(skill)
  if not skill or not skill.name or not skill.path then
    return false
  end
  table.insert(state.app.pending_context, {
    type = 'skill',
    name = skill.name,
    path = skill.path,
    label = '$' .. skill.name,
  })
  logger.info('Added Codex skill:', skill.name)
  return true
end

local function request_all(method, params, field, callback)
  M.start(function(ok, err)
    if not ok then
      callback(nil, err)
      return
    end
    state.app.client:request(method, params, function(req_err, result)
      if req_err then
        callback(nil, req_err)
        return
      end
      callback(result and result[field] or {}, nil, result)
    end)
  end)
end

function M.list_models(callback)
  request_all('model/list', { includeHidden = false, limit = 100 }, 'data', function(models, err)
    if models then
      state.app.models = models
    end
    callback(models, err)
  end)
end

function M.list_apps(callback)
  M.start(function(ok, err)
    if not ok then
      callback(nil, err)
      return
    end
    state.app.client:request('app/list', { limit = 100, threadId = state.app.thread_id, forceRefetch = false }, function(req_err, result)
      if req_err then
        callback(nil, req_err)
        return
      end
      local apps = result and result.data or {}
      state.app.apps = apps
      callback(apps, nil)
    end)
  end)
end

function M.list_skills(callback)
  request_all('skills/list', { cwds = { util.cwd() }, forceReload = false }, 'data', function(entries, err)
    local skills = {}
    for _, entry in ipairs(entries or {}) do
      for _, skill in ipairs(entry.skills or {}) do
        if skill.enabled ~= false then
          table.insert(skills, skill)
        end
      end
    end
    state.app.skills = skills
    callback(skills, err)
  end)
end

function M.list_mcp(callback)
  request_all('mcpServerStatus/list', {
    limit = 100,
    detail = M.config.app_server.mcp_status_detail or 'toolsAndAuthOnly',
  }, 'data', function(servers, err)
    if servers then
      state.app.mcp_servers = servers
    end
    callback(servers, err)
  end)
end

function M.reload_mcp(callback)
  M.start(function(ok, err)
    if not ok then
      if callback then
        callback(false, err)
      end
      return
    end
    state.app.client:request('config/mcpServer/reload', nil, function(req_err)
      if callback then
        callback(req_err == nil, req_err)
      end
    end)
  end)
end

function M.current_selection()
  selection.update_selection()
  return selection.get_latest_selection()
end

return M
