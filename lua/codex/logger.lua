local M = {}

local title = 'codex.nvim'

function M.info(...)
  vim.notify(table.concat(vim.tbl_map(tostring, { ... }), ' '), vim.log.levels.INFO, { title = title })
end

function M.warn(...)
  vim.notify(table.concat(vim.tbl_map(tostring, { ... }), ' '), vim.log.levels.WARN, { title = title })
end

function M.error(...)
  vim.notify(table.concat(vim.tbl_map(tostring, { ... }), ' '), vim.log.levels.ERROR, { title = title })
end

function M.debug(...)
  if vim.g.codex_nvim_debug then
    vim.notify(table.concat(vim.tbl_map(tostring, { ... }), ' '), vim.log.levels.DEBUG, { title = title })
  end
end

return M
