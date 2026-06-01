local logger = require 'codex.logger'
local state = require 'codex.state'
local util = require 'codex.util'

local M = {}

local function find_port(min_port, max_port)
  local ports = {}
  for port = min_port, max_port do
    ports[#ports + 1] = port
  end
  math.randomseed(os.time() + vim.fn.getpid())
  for i = #ports, 2, -1 do
    local j = math.random(i)
    ports[i], ports[j] = ports[j], ports[i]
  end

  for _, port in ipairs(ports) do
    local tcp = vim.loop.new_tcp()
    if tcp then
      local ok = tcp:bind('127.0.0.1', port)
      tcp:close()
      if ok then
        return port
      end
    end
  end
  return nil
end

local function build_cmd(config, listen_url)
  local cmd = util.normalize_cmd(config.cmd)
  table.insert(cmd, 'app-server')
  table.insert(cmd, '--listen')
  table.insert(cmd, listen_url)
  for _, feature in ipairs(config.app_server.enable_features or {}) do
    table.insert(cmd, '--enable')
    table.insert(cmd, feature)
  end
  return cmd
end

function M.start(config, callback)
  callback = callback or function() end
  local cwd = util.cwd()

  if state.app.server_job and state.app.listen_url then
    if state.app.cwd == cwd then
      callback(true, state.app.listen_url)
      return
    end

    M.stop()
  end

  local range = config.app_server.port_range or { min = 45000, max = 45999 }
  local port = config.app_server.port or find_port(range.min, range.max)
  if not port then
    callback(false, nil, 'no available app-server websocket port')
    return
  end

  local listen_url = ('ws://127.0.0.1:%d'):format(port)
  local cmd = build_cmd(config, listen_url)
  local job
  job = vim.fn.jobstart(cmd, {
    cwd = cwd,
    env = util.codex_env(),
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= '' then
          logger.debug(line)
        end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= '' then
          logger.debug(line)
        end
      end
    end,
    on_exit = function(exit_job, code)
      if state.app.server_job ~= exit_job and state.app.server_job ~= job then
        return
      end

      state.app.server_job = nil
      state.app.listen_url = nil
      state.app.port = nil
      state.app.cwd = nil
      logger.debug('app-server websocket exited with code', tostring(code))
    end,
  })

  if job <= 0 then
    callback(false, nil, 'failed to start app-server websocket')
    return
  end

  state.app.server_job = job
  state.app.listen_url = listen_url
  state.app.port = port
  state.app.cwd = cwd
  callback(true, listen_url)
end

function M.stop()
  if state.app.server_job then
    pcall(vim.fn.jobstop, state.app.server_job)
  end
  state.app.server_job = nil
  state.app.listen_url = nil
  state.app.port = nil
  state.app.cwd = nil
end

return M
