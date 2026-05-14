local M = {
  name = 'getOpenEditors',
  description = 'Get the list of currently open file buffers',
  input_schema = {
    type = 'object',
    additionalProperties = false,
  },
}

function M.handler()
  local tabs = {}
  local current = vim.api.nvim_get_current_buf()
  local latest_selection = require('codex.selection').get_latest_selection()

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.fn.buflisted(bufnr) == 1 then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path and path ~= '' and not path:match '^term://' then
        local ft = vim.api.nvim_buf_get_option(bufnr, 'filetype')
        local item = {
          uri = 'file://' .. path,
          fileName = path,
          label = vim.fn.fnamemodify(path, ':t'),
          languageId = ft ~= '' and ft or 'plaintext',
          lineCount = vim.api.nvim_buf_line_count(bufnr),
          isActive = bufnr == current,
          isDirty = vim.api.nvim_buf_get_option(bufnr, 'modified'),
          isUntitled = false,
          isPinned = false,
          isPreview = false,
        }
        if bufnr == current and latest_selection and latest_selection.selection then
          item.selection = latest_selection.selection
        end
        table.insert(tabs, item)
      end
    end
  end

  return { tabs = tabs }
end

return M
