local function new_app_context()
  return {
    thread_id = nil,
    session_id = nil,
    active_turn_id = nil,
    running = false,
    terminal_opened = false,
    pending_sends = {},
    pending_injections = {},
    pending_context = {},
    items = {},
  }
end

local adjectives = {
  'brave',
  'binary',
  'quiet',
  'rapid',
  'steady',
  'clever',
  'silver',
  'bright',
  'nimble',
  'patient',
  'cosmic',
  'lucid',
  'fuzzy',
  'golden',
  'hidden',
  'polar',
}

local nouns = {
  'squid',
  'bird',
  'comet',
  'pixel',
  'river',
  'signal',
  'vector',
  'orbit',
  'ember',
  'matrix',
  'kernel',
  'cursor',
  'lambda',
  'cipher',
  'rocket',
  'quartz',
}

local random_seeded = false

local M = {
  buf = nil,
  win = nil,
  job = nil,
  picker_buf = nil,
  picker_win = nil,
  picker_line_sessions = {},
  picker_line_actions = {},
  picker_expanded = false,

  sessions = {},
  session_order = {},
  active_session_id = nil,
  pending_thread_session_ids = {},

  app = {
    client = nil,
    server_job = nil,
    listen_url = nil,
    port = nil,
    cwd = nil,
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

M.new_app_context = new_app_context

local function lowest_available_session_id()
  local id = 1
  while M.sessions[id] do
    id = id + 1
  end
  return id
end

local function sort_session_order()
  table.sort(M.session_order, function(a, b)
    return a < b
  end)
end

local function session_name(id)
  if not random_seeded then
    local seed = os.time()
    if vim and vim.loop and vim.loop.hrtime then
      seed = seed + (vim.loop.hrtime() % 2147483647)
    end
    math.randomseed(seed)
    random_seeded = true
  end
  local adjective = adjectives[math.random(#adjectives)]
  local noun = nouns[math.random(#nouns)]
  local candidate = adjective .. '-' .. noun
  for _, session in pairs(M.sessions) do
    if session.name == candidate then
      return candidate .. '-' .. tostring(id)
    end
  end
  return candidate
end

local function remove_ordered_session(id)
  for index, session_id in ipairs(M.session_order) do
    if session_id == id then
      table.remove(M.session_order, index)
      return
    end
  end
end

function M.active_session()
  if not M.active_session_id then
    return nil
  end
  return M.sessions[M.active_session_id]
end

function M.has_sessions()
  return #M.session_order > 0
end

function M.sync_active_session()
  local session = M.active_session()
  if session then
    M.buf = session.buf
    M.job = session.job
  else
    M.buf = nil
    M.job = nil
  end
  return session
end

function M.create_session(opts)
  opts = opts or {}
  local id = opts.id and tonumber(opts.id) or lowest_available_session_id()
  if not id or id < 1 then
    return nil
  end

  if M.sessions[id] then
    M.active_session_id = id
    return M.sync_active_session()
  end

  local session = {
    id = id,
    name = opts.name or session_name(id),
    buf = nil,
    job = nil,
    cwd = nil,
    requested = false,
    remote = nil,
    pending_submits = {},
    pending_inserts = {},
    yolo = opts.yolo == true,
    app = new_app_context(),
  }
  M.sessions[id] = session
  table.insert(M.session_order, id)
  sort_session_order()
  M.active_session_id = id
  return M.sync_active_session()
end

function M.ensure_session(opts)
  return M.active_session() or M.create_session(opts)
end

function M.activate_session(id)
  id = tonumber(id)
  if not id or not M.sessions[id] then
    return nil
  end
  M.active_session_id = id
  return M.sync_active_session()
end

function M.remove_session(id)
  id = tonumber(id)
  if not id or not M.sessions[id] then
    return nil
  end

  local removed = M.sessions[id]
  M.sessions[id] = nil
  remove_ordered_session(id)
  for index = #M.pending_thread_session_ids, 1, -1 do
    if M.pending_thread_session_ids[index] == id then
      table.remove(M.pending_thread_session_ids, index)
    end
  end

  if M.active_session_id == id then
    M.active_session_id = M.session_order[1]
  end

  M.sync_active_session()
  return removed
end

function M.app_context(session)
  session = session or M.active_session()
  if session and session.app then
    return session.app
  end
  return M.app
end

function M.find_session_by_thread(thread_id)
  if not thread_id then
    return nil
  end
  for _, id in ipairs(M.session_order) do
    local session = M.sessions[id]
    if session and session.app and session.app.thread_id == thread_id then
      return session
    end
  end
  return nil
end

function M.queue_thread_session(session)
  if not session then
    return
  end
  for _, id in ipairs(M.pending_thread_session_ids) do
    if id == session.id then
      return
    end
  end
  table.insert(M.pending_thread_session_ids, session.id)
end

function M.claim_thread_session(thread_id)
  local existing = M.find_session_by_thread(thread_id)
  if existing then
    return existing
  end

  while #M.pending_thread_session_ids > 0 do
    local id = table.remove(M.pending_thread_session_ids, 1)
    local session = M.sessions[id]
    if session and session.app and not session.app.thread_id then
      return session
    end
  end

  return M.active_session()
end

function M.clear_session_app(session)
  local ctx = M.app_context(session)
  ctx.thread_id = nil
  ctx.session_id = nil
  ctx.active_turn_id = nil
  ctx.running = false
  ctx.terminal_opened = false
  ctx.pending_sends = {}
  ctx.pending_injections = {}
  ctx.pending_context = {}
  ctx.items = {}
end

return M
