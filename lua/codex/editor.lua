local util = require 'codex.util'

local M = {}

local function codex_buffer(bufnr)
  local ft = vim.api.nvim_buf_get_option(bufnr, 'filetype')
  local name = vim.api.nvim_buf_get_name(bufnr)
  return ft == 'codex' or (name and name:match '^codex://')
end

function M.active()
  local bufnr = vim.api.nvim_get_current_buf()
  if codex_buffer(bufnr) then
    return nil
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  if not path or path == '' or path:match '^term://' then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local filetype = vim.api.nvim_buf_get_option(bufnr, 'filetype')
  return {
    bufnr = bufnr,
    path = path,
    name = util.relative_path(path),
    cursor = {
      line = cursor[1] - 1,
      character = cursor[2],
    },
    filetype = filetype ~= '' and filetype or 'plaintext',
    modified = vim.api.nvim_buf_get_option(bufnr, 'modified'),
    line_count = vim.api.nvim_buf_line_count(bufnr),
  }
end

function M.describe(ctx)
  if not ctx then
    return nil
  end
  return table.concat({
    'Current Neovim editor:',
    ('- file: %s'):format(ctx.name or ctx.path),
    ('- cursor: line %d, column %d'):format(ctx.cursor.line + 1, ctx.cursor.character + 1),
    ('- filetype: %s'):format(ctx.filetype),
    ('- modified: %s'):format(ctx.modified and 'yes' or 'no'),
    ('- lines: %d'):format(ctx.line_count),
  }, '\n')
end

return M
