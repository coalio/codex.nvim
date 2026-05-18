local util = require 'codex.util'
local logger = require 'codex.logger'

local Client = {}
Client.__index = Client

function Client.new(opts)
  return setmetatable({
    cmd = opts.cmd,
    cwd = opts.cwd,
    env = opts.env,
    on_notification = opts.on_notification,
    on_request = opts.on_request,
    on_exit = opts.on_exit,
    on_stderr = opts.on_stderr,
    next_id = 0,
    callbacks = {},
    job = nil,
    partial = '',
  }, Client)
end

function Client:start()
  if self.job then
    return true
  end

  local job = vim.fn.jobstart(self.cmd, {
    cwd = self.cwd,
    env = self.env,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      self:_on_stdout(data)
    end,
    on_stderr = function(_, data)
      self:_on_stderr(data)
    end,
    on_exit = function(_, code)
      self.job = nil
      vim.schedule(function()
        if self.on_exit then
          self.on_exit(code)
        end
      end)
    end,
  })

  if job <= 0 then
    return false, 'failed to start job'
  end

  self.job = job
  return true
end

function Client:stop()
  if not self.job then
    return
  end
  pcall(vim.fn.jobstop, self.job)
  self.job = nil
end

function Client:is_running()
  return self.job ~= nil
end

function Client:_on_stdout(data)
  if not data then
    return
  end

  for i, chunk in ipairs(data) do
    if i == 1 then
      chunk = self.partial .. chunk
    end

    if i < #data then
      self.partial = ''
      self:_handle_line(chunk)
    else
      self.partial = chunk
    end
  end
end

function Client:_on_stderr(data)
  if not data then
    return
  end
  for _, line in ipairs(data) do
    if line ~= '' then
      if self.on_stderr then
        vim.schedule(function()
          self.on_stderr(line)
        end)
      else
        logger.debug('app-server stderr:', line)
      end
    end
  end
end

function Client:_handle_line(line)
  if line == '' then
    return
  end

  local ok, msg = pcall(util.json_decode, line)
  if not ok then
    logger.warn('Failed to parse app-server message:', msg)
    return
  end

  vim.schedule(function()
    self:_dispatch(msg)
  end)
end

function Client:_dispatch(msg)
  if msg.id ~= nil and (msg.result ~= nil or msg.error ~= nil) and not msg.method then
    local cb = self.callbacks[msg.id]
    self.callbacks[msg.id] = nil
    if cb then
      cb(msg.error, msg.result, msg)
    end
    return
  end

  if msg.method and msg.id ~= nil then
    if self.on_request then
      self.on_request(msg, function(result, err)
        self:respond(msg.id, result, err)
      end)
    else
      self:respond(msg.id, nil, { code = -32601, message = 'Method not found' })
    end
    return
  end

  if msg.method and self.on_notification then
    self.on_notification(msg)
  end
end

function Client:send(message)
  if not self.job then
    return false, 'app-server is not running'
  end

  local ok, encoded = pcall(util.json_encode, message)
  if not ok then
    return false, encoded
  end

  vim.fn.chansend(self.job, encoded .. '\n')
  return true
end

function Client:notify(method, params)
  return self:send { method = method, params = params or {} }
end

function Client:request(method, params, callback)
  self.next_id = self.next_id + 1
  local id = self.next_id
  if callback then
    self.callbacks[id] = callback
  end

  local message = { method = method, id = id }
  if params ~= nil then
    message.params = params
  end

  local ok, err = self:send(message)
  if not ok then
    self.callbacks[id] = nil
    if callback then
      callback({ code = -32000, message = err }, nil)
    end
    return nil, err
  end

  return id
end

function Client:respond(id, result, err)
  if err then
    return self:send { id = id, error = err }
  end
  return self:send { id = id, result = result or {} }
end

return {
  new = Client.new,
}
