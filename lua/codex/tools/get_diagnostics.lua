local M = {
  name = 'getDiagnostics',
  description = 'Get language diagnostics from Neovim',
  input_schema = {
    type = 'object',
    properties = {
      uri = { type = 'string', description = 'Optional file URI or path to get diagnostics for' },
    },
    additionalProperties = false,
  },
}

function M.handler(params)
  if not vim.diagnostic or not vim.diagnostic.get then
    return { success = false, message = 'Diagnostics are not available' }
  end

  local diagnostics
  if params.uri and params.uri ~= '' then
    local path = params.uri:sub(1, 7) == 'file://' and vim.uri_to_fname(params.uri) or params.uri
    local bufnr = vim.fn.bufnr(path)
    if bufnr == -1 then
      return { success = false, message = 'File is not open: ' .. path }
    end
    diagnostics = vim.diagnostic.get(bufnr)
  else
    diagnostics = vim.diagnostic.get(nil)
  end

  local result = {}
  for _, diagnostic in ipairs(diagnostics) do
    local path = vim.api.nvim_buf_get_name(diagnostic.bufnr)
    if path and path ~= '' then
      table.insert(result, {
        filePath = path,
        line = diagnostic.lnum + 1,
        character = diagnostic.col + 1,
        severity = diagnostic.severity,
        message = diagnostic.message,
        source = diagnostic.source,
      })
    end
  end

  return { success = true, diagnostics = result }
end

return M
