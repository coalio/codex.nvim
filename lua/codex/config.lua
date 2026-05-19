local M = {}

M.defaults = {
  backend = 'app_server', -- app_server | terminal
  keymaps = {
    toggle = '<leader>ac',
    open = '<leader>aC',
    session_new = '<leader>an',
    yolo = '<leader>ay',
    quit = '<C-q>',
    send = '<leader>as',
    interrupt = '<C-c>',
  },
  border = 'single',
  width = 0.25,
  height = 0.8,
  cmd = 'codex',
  model = nil,
  autoinstall = true,
  panel = false,
  use_buffer = false,
  track_selection = true,
  include_active_buffer_context = true,
  visual_demotion_delay_ms = 50,
  focus_after_send = false,
  selection_prompt = 'Use the selected Neovim context.',
  session_picker = {
    enabled = true,
    width = 24,
  },
  app_server = {
    ui = 'terminal', -- terminal | buffer
    listen = 'stdio://',
    port = nil,
    port_range = { min = 45000, max = 45999 },
    experimental = true,
    auto_start = true,
    dynamic_tools = true,
    open_terminal = true,
    editor_instructions = true,
    service_name = 'codex_nvim',
    approval_policy = nil,
    sandbox = nil,
    enable_features = { 'apps' },
    mcp_status_detail = 'toolsAndAuthOnly',
  },
}

local function validate_number(name, value, min, max)
  assert(type(value) == 'number', name .. ' must be a number')
  assert(value >= min and value <= max, name .. ' must be between ' .. min .. ' and ' .. max)
end

function M.apply(user_config)
  local config = vim.deepcopy(M.defaults)

  if user_config then
    config = vim.tbl_deep_extend('force', config, user_config)
  end

  assert(config.backend == 'app_server' or config.backend == 'terminal', 'backend must be app_server or terminal')
  assert(type(config.keymaps) == 'table', 'keymaps must be a table')
  assert(type(config.cmd) == 'string' or type(config.cmd) == 'table', 'cmd must be a string or list')
  validate_number('width', config.width, 0.1, 1)
  validate_number('height', config.height, 0.1, 1)
  assert(type(config.autoinstall) == 'boolean', 'autoinstall must be a boolean')
  assert(type(config.panel) == 'boolean', 'panel must be a boolean')
  assert(type(config.use_buffer) == 'boolean', 'use_buffer must be a boolean')
  assert(type(config.track_selection) == 'boolean', 'track_selection must be a boolean')
  assert(type(config.include_active_buffer_context) == 'boolean', 'include_active_buffer_context must be a boolean')
  assert(type(config.visual_demotion_delay_ms) == 'number' and config.visual_demotion_delay_ms >= 0, 'visual_demotion_delay_ms must be non-negative')
  assert(type(config.selection_prompt) == 'string', 'selection_prompt must be a string')
  assert(type(config.session_picker) == 'table', 'session_picker must be a table')
  assert(type(config.session_picker.enabled) == 'boolean', 'session_picker.enabled must be a boolean')
  assert(type(config.session_picker.width) == 'number' and config.session_picker.width >= 1, 'session_picker.width must be at least 1')
  assert(type(config.app_server) == 'table', 'app_server must be a table')
  assert(config.app_server.ui == 'terminal' or config.app_server.ui == 'buffer', 'app_server.ui must be terminal or buffer')
  assert(type(config.app_server.open_terminal) == 'boolean', 'app_server.open_terminal must be a boolean')
  assert(config.app_server.port == nil or type(config.app_server.port) == 'number', 'app_server.port must be nil or a number')
  assert(type(config.app_server.port_range) == 'table', 'app_server.port_range must be a table')
  assert(type(config.app_server.port_range.min) == 'number', 'app_server.port_range.min must be a number')
  assert(type(config.app_server.port_range.max) == 'number', 'app_server.port_range.max must be a number')
  assert(config.app_server.port_range.min > 0 and config.app_server.port_range.max <= 65535, 'app_server.port_range must use valid ports')
  assert(config.app_server.port_range.min <= config.app_server.port_range.max, 'app_server.port_range min must be <= max')

  return config
end

return M
