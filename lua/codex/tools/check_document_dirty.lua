local M = {
  name = 'checkDocumentDirty',
  description = 'Check whether a document has unsaved changes',
  input_schema = {
    type = 'object',
    properties = {
      filePath = { type = 'string', description = 'Path to the file to check' },
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
  return {
    success = true,
    filePath = params.filePath,
    isDirty = vim.api.nvim_buf_get_option(bufnr, 'modified'),
    isUntitled = vim.api.nvim_buf_get_name(bufnr) == '',
  }
end

return M
