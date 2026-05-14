local M = {}

M.defaults = {
  backend = 'app_server', -- app_server | terminal
  keymaps = {
    toggle = nil,
    quit = '<C-q>',
    send = '<C-s>',
    interrupt = '<C-c>',
  },
  border = 'single',
  width = 0.8,
  height = 0.8,
  cmd = 'codex',
  model = nil,
  autoinstall = true,
  panel = false,
  use_buffer = false,
  track_selection = true,
  visual_demotion_delay_ms = 50,
  focus_after_send = false,
  app_server = {
    listen = 'stdio://',
    experimental = true,
    auto_start = true,
    dynamic_tools = true,
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
  assert(type(config.visual_demotion_delay_ms) == 'number' and config.visual_demotion_delay_ms >= 0, 'visual_demotion_delay_ms must be non-negative')
  assert(type(config.app_server) == 'table', 'app_server must be a table')

  return config
end

return M
