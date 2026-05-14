local util = require 'codex.util'

local M = {
  name = 'getWorkspaceFolders',
  description = 'Get workspace folders currently open in Neovim',
  input_schema = {
    type = 'object',
    additionalProperties = false,
  },
}

function M.handler()
  local cwd = util.cwd()
  local folders = {
    {
      name = vim.fn.fnamemodify(cwd, ':t'),
      uri = 'file://' .. cwd,
      path = cwd,
    },
  }

  local clients = {}
  if vim.lsp and vim.lsp.get_active_clients then
    clients = vim.lsp.get_active_clients()
  end

  for _, client in ipairs(clients) do
    for _, folder in ipairs(client.workspace_folders or {}) do
      local path = vim.uri_to_fname(folder.uri)
      local seen = false
      for _, existing in ipairs(folders) do
        if existing.path == path then
          seen = true
          break
        end
      end
      if not seen then
        table.insert(folders, {
          name = folder.name or vim.fn.fnamemodify(path, ':t'),
          uri = folder.uri,
          path = path,
        })
      end
    end
  end

  return { success = true, folders = folders, rootPath = cwd }
end

return M
