local M = {}

local shell_path_marker = '__CODEX_NVIM_EXEC__'
local executable_cache = {}

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

local function path_like(executable)
  return type(executable) == 'string' and executable:find '[/\\]' ~= nil
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function executable_path(path)
  if type(path) ~= 'string' or path == '' then
    return nil
  end
  if vim.fn.executable(path) ~= 1 then
    return nil
  end
  return path
end

local function candidate_shells()
  local shells = {}

  for _, shell in ipairs { vim.env.SHELL, vim.o.shell, '/bin/zsh', '/bin/bash', '/bin/sh' } do
    if shell and shell ~= '' and vim.fn.executable(shell) == 1 and not vim.tbl_contains(shells, shell) then
      table.insert(shells, shell)
    end
  end

  return shells
end

local function extract_marked_path(lines)
  for _, line in ipairs(lines or {}) do
    local path = tostring(line):match(shell_path_marker .. '(.+)$')
    path = path and vim.trim(path) or nil
    if path and path ~= '' and vim.fn.executable(path) == 1 then
      return path
    end
  end
end

local function shell_basename(shell)
  return vim.fn.fnamemodify(shell, ':t'):lower()
end

local function command_lookup_script(shell, executable)
  local quoted = shell_quote(executable)
  if shell_basename(shell):match 'fish' then
    return ('set -l resolved (command -v %s 2>/dev/null); and printf "\\n%s%%s\\n" $resolved'):format(quoted, shell_path_marker)
  end

  return ('resolved=$(command -v %s 2>/dev/null) && printf "\\n%s%%s\\n" "$resolved"'):format(quoted, shell_path_marker)
end

local function shell_resolve_executable(executable)
  if path_like(executable) then
    return nil
  end

  for _, shell in ipairs(candidate_shells()) do
    local script = command_lookup_script(shell, executable)
    for _, flag in ipairs { '-lc', '-ic' } do
      local ok, lines = pcall(vim.fn.systemlist, { shell, flag, script })
      if ok then
        local path = extract_marked_path(lines)
        if path then
          return path
        end
      end
    end
  end
end

function M.resolve_executable(executable)
  if executable_cache[executable] then
    return executable_cache[executable]
  end

  local path = executable_path(executable)
  if path then
    executable_cache[executable] = path
    return path
  end

  path = shell_resolve_executable(executable)
  if path then
    executable_cache[executable] = path
  end
  return path
end

function M.resolve_cmd(cmd)
  if type(cmd) == 'string' and cmd:find '%s' then
    return cmd
  end

  local resolved = M.normalize_cmd(cmd)
  local executable = M.executable_from_cmd(resolved)
  local path = executable and M.resolve_executable(executable) or nil
  if path then
    resolved[1] = path
  end
  return resolved
end

function M.command_available(executable)
  return M.resolve_executable(executable) ~= nil
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
