local M = {
  buf = nil,
  win = nil,
  job = nil,

  app = {
    client = nil,
    server_job = nil,
    listen_url = nil,
    port = nil,
    thread_id = nil,
    session_id = nil,
    active_turn_id = nil,
    running = false,
    initialized = false,
    terminal_opened = false,
    pending_sends = {},
    pending_injections = {},
    pending_context = {},
    models = {},
    apps = {},
    skills = {},
    mcp_servers = {},
    items = {},
  },
}

return M
