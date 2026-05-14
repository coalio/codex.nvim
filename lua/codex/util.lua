local M = {}

function M.normalize_cmd(cmd)
  if type(cmd) == 'table' then
    return vim.deepcopy(cmd)
  end
  return { cmd }
end

function M.executable_from_cmd(cmd)
  if type(cmd) == 'table' then
    return cmd[1]
  end
  if type(cmd) == 'string' and not cmd:find '%s' then
    return cmd
  end
  return nil
end

function M.cwd()
  local cwd = vim.loop.cwd()
  if cwd and cwd ~= '' then
    return cwd
  end
  return vim.fn.getcwd()
end

function M.relative_path(path)
  local cwd = M.cwd()
  if type(path) == 'string' and type(cwd) == 'string' and path:sub(1, #cwd + 1) == cwd .. '/' then
    return path:sub(#cwd + 2)
  end
  return path
end

function M.json_encode(value)
  return vim.json.encode(value)
end

function M.json_decode(value)
  return vim.json.decode(value)
end

function M.text_content(value)
  if type(value) == 'string' then
    return value
  end
  local ok, encoded = pcall(M.json_encode, value)
  if ok then
    return encoded
  end
  return tostring(value)
end

return M
