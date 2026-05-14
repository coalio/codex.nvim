local logger = require 'codex.logger'
local util = require 'codex.util'

local bit = bit
local uv = vim.loop

local Client = {}
Client.__index = Client

local OPCODE_TEXT = 0x1
local OPCODE_CLOSE = 0x8
local OPCODE_PING = 0x9
local OPCODE_PONG = 0xA

local function random_key()
  local bytes = {}
  math.randomseed(os.time() + vim.fn.getpid())
  for i = 1, 16 do
    bytes[i] = string.char(math.random(0, 255))
  end
  if vim.base64 and vim.base64.encode then
    return vim.base64.encode(table.concat(bytes))
  end
  return 'dGhlIHNhbXBsZSBub25jZQ=='
end

local function parse_url(url)
  local host, port = tostring(url or ''):match '^ws://([^:/]+):(%d+)'
  if not host then
    return nil, nil, 'only ws://host:port URLs are supported'
  end
  return host, tonumber(port), nil
end

local function apply_mask(payload, mask)
  local out = {}
  local m1, m2, m3, m4 = mask:byte(1, 4)
  local masks = { m1, m2, m3, m4 }
  for i = 1, #payload do
    out[i] = string.char(bit.bxor(payload:byte(i), masks[((i - 1) % 4) + 1]))
  end
  return table.concat(out)
end

local function u16(num)
  return string.char(math.floor(num / 256), num % 256)
end

local function u64(num)
  local bytes = {}
  for i = 8, 1, -1 do
    bytes[i] = num % 256
    num = math.floor(num / 256)
  end
  return string.char(unpack(bytes))
end

local function make_frame(opcode, payload)
  payload = payload or ''
  local len = #payload
  local header = { string.char(0x80 + opcode) }
  if len < 126 then
    table.insert(header, string.char(0x80 + len))
  elseif len < 65536 then
    table.insert(header, string.char(0x80 + 126))
    table.insert(header, u16(len))
  else
    table.insert(header, string.char(0x80 + 127))
    table.insert(header, u64(len))
  end
  local mask = string.char(math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255))
  table.insert(header, mask)
  table.insert(header, apply_mask(payload, mask))
  return table.concat(header)
end

local function read_u16(data, pos)
  return data:byte(pos) * 256 + data:byte(pos + 1)
end

local function read_u64(data, pos)
  local num = 0
  for i = 0, 7 do
    num = (num * 256) + data:byte(pos + i)
  end
  return num
end

local function parse_frame(data)
  if #data < 2 then
    return nil, 0
  end

  local b1, b2 = data:byte(1, 2)
  local opcode = b1 % 16
  local masked = math.floor(b2 / 128) == 1
  local len = b2 % 128
  local pos = 3

  if len == 126 then
    if #data < 4 then
      return nil, 0
    end
    len = read_u16(data, pos)
    pos = pos + 2
  elseif len == 127 then
    if #data < 10 then
      return nil, 0
    end
    len = read_u64(data, pos)
    pos = pos + 8
  end

  local mask
  if masked then
    if #data < pos + 3 then
      return nil, 0
    end
    mask = data:sub(pos, pos + 3)
    pos = pos + 4
  end

  if #data < pos + len - 1 then
    return nil, 0
  end

  local payload = data:sub(pos, pos + len - 1)
  if masked and mask then
    payload = apply_mask(payload, mask)
  end

  return { opcode = opcode, payload = payload }, pos + len - 1
end

function Client.new(opts)
  local host, port, err = parse_url(opts.url)
  return setmetatable({
    url = opts.url,
    host = host,
    port = port,
    parse_error = err,
    on_notification = opts.on_notification,
    on_request = opts.on_request,
    on_exit = opts.on_exit,
    next_id = 0,
    callbacks = {},
    tcp = nil,
    connected = false,
    handshaking = false,
    buffer = '',
  }, Client)
end

function Client:start(callback)
  callback = callback or function() end
  if self.connected then
    callback(true)
    return true
  end
  if self.parse_error then
    callback(false, self.parse_error)
    return false, self.parse_error
  end

  local tcp = uv.new_tcp()
  if not tcp then
    callback(false, 'failed to create tcp handle')
    return false, 'failed to create tcp handle'
  end
  self.tcp = tcp
  self.handshaking = true

  tcp:connect(self.host, self.port, function(err)
    if err then
      self:stop()
      vim.schedule(function()
        callback(false, err)
      end)
      return
    end

    local request = table.concat({
      'GET / HTTP/1.1',
      ('Host: %s:%d'):format(self.host, self.port),
      'Upgrade: websocket',
      'Connection: Upgrade',
      'Sec-WebSocket-Key: ' .. random_key(),
      'Sec-WebSocket-Version: 13',
      '',
      '',
    }, '\r\n')

    tcp:write(request)
    tcp:read_start(function(read_err, chunk)
      if read_err then
        logger.warn('websocket read error:', read_err)
        self:stop()
        return
      end
      if not chunk then
        self:stop()
        return
      end
      self:_on_data(chunk, callback)
    end)
  end)

  return true
end

function Client:stop()
  if self.tcp then
    local tcp = self.tcp
    self.tcp = nil
    pcall(function()
      tcp:read_stop()
    end)
    if not tcp:is_closing() then
      pcall(function()
        tcp:write(make_frame(OPCODE_CLOSE, ''))
      end)
      tcp:close()
    end
  end
  local was_connected = self.connected
  self.connected = false
  self.handshaking = false
  self.buffer = ''
  if was_connected and self.on_exit then
    vim.schedule(function()
      self.on_exit(0)
    end)
  end
end

function Client:is_running()
  return self.connected
end

function Client:_on_data(chunk, callback)
  self.buffer = self.buffer .. chunk

  if self.handshaking then
    local header_end = self.buffer:find('\r\n\r\n', 1, true)
    if not header_end then
      return
    end
    local headers = self.buffer:sub(1, header_end + 3)
    if not headers:match '^HTTP/1%.1 101' then
      self:stop()
      vim.schedule(function()
        callback(false, 'websocket upgrade failed')
      end)
      return
    end
    self.buffer = self.buffer:sub(header_end + 4)
    self.handshaking = false
    self.connected = true
    vim.schedule(function()
      callback(true)
    end)
  end

  while #self.buffer > 0 do
    local frame, consumed = parse_frame(self.buffer)
    if not frame then
      break
    end
    self.buffer = self.buffer:sub(consumed + 1)
    if frame.opcode == OPCODE_TEXT then
      self:_handle_text(frame.payload)
    elseif frame.opcode == OPCODE_PING then
      self:_write_frame(OPCODE_PONG, frame.payload)
    elseif frame.opcode == OPCODE_CLOSE then
      self:stop()
      break
    end
  end
end

function Client:_handle_text(text)
  local ok, msg = pcall(util.json_decode, text)
  if not ok then
    logger.warn('Failed to parse app-server websocket message:', msg)
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

function Client:_write_frame(opcode, payload)
  if not self.tcp or not self.connected then
    return false, 'websocket is not connected'
  end
  self.tcp:write(make_frame(opcode, payload or ''))
  return true
end

function Client:send(message)
  if not self.connected then
    return false, 'websocket is not connected'
  end
  local ok, encoded = pcall(util.json_encode, message)
  if not ok then
    return false, encoded
  end
  return self:_write_frame(OPCODE_TEXT, encoded)
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
