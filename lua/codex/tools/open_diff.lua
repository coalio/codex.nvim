local M = {
  name = 'openDiff',
  description = 'Open a Neovim diff for proposed file contents and ask whether to apply them',
  input_schema = {
    type = 'object',
    properties = {
      old_file_path = { type = 'string', description = 'Path to the original file' },
      new_file_path = { type = 'string', description = 'Path to write if accepted' },
      new_file_contents = { type = 'string', description = 'Proposed file contents' },
      tab_name = { type = 'string', description = 'Name for the diff view' },
    },
    required = { 'old_file_path', 'new_file_path', 'new_file_contents', 'tab_name' },
    additionalProperties = false,
  },
}

function M.handler(params, done)
  for _, key in ipairs { 'old_file_path', 'new_file_path', 'new_file_contents', 'tab_name' } do
    if params[key] == nil then
      error('Missing ' .. key)
    end
  end

  local old_path = vim.fn.expand(params.old_file_path)
  local new_path = vim.fn.expand(params.new_file_path)
  local temp = vim.fn.tempname()
  vim.fn.writefile(vim.split(params.new_file_contents, '\n', { plain = true }), temp)

  vim.cmd('edit ' .. vim.fn.fnameescape(old_path))
  vim.cmd 'diffthis'
  vim.cmd('rightbelow vsplit ' .. vim.fn.fnameescape(temp))
  vim.cmd 'diffthis'
  vim.api.nvim_buf_set_name(0, params.tab_name)

  vim.ui.select({ 'Accept', 'Reject' }, { prompt = 'Apply Codex diff?' }, function(choice)
    vim.cmd 'diffoff!'
    pcall(vim.fn.delete, temp)
    if choice == 'Accept' then
      vim.fn.writefile(vim.split(params.new_file_contents, '\n', { plain = true }), new_path)
      done({ result = 'FILE_SAVED', filePath = new_path }, true)
    else
      done({ result = 'DIFF_REJECTED', filePath = new_path }, true)
    end
  end)

  return { __codex_deferred = true }
end

return M
