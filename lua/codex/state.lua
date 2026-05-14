local M = {
  buf = nil,
  win = nil,
  job = nil,

  app = {
    client = nil,
    thread_id = nil,
    active_turn_id = nil,
    running = false,
    initialized = false,
    pending_context = {},
    models = {},
    apps = {},
    skills = {},
    mcp_servers = {},
    items = {},
  },
}

return M
