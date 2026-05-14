local M = {
  name = 'saveDocument',
  description = 'Save an open document',
  input_schema = {
    type = 'object',
    properties = {
      filePath = { type = 'string', description = 'Path to the file to save' },
    },
    required = { 'filePath' },
    additionalProperties = false,
  },
}

function M.handler(params)
  if not params.filePath then
    error 'Missing filePath'
  end
  local bufnr = vim.fn.bufnr(params.filePath)
  if bufnr == -1 then
    return { success = false, message = 'Document not open: ' .. params.filePath }
  end

  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd 'write'
  end)

  if not ok then
    return { success = false, message = tostring(err), filePath = params.filePath }
  end

  return { success = true, saved = true, filePath = params.filePath }
end

return M
