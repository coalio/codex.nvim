local M = {}

function M.bootstrap_trouble()
  local trouble_path = vim.fn.stdpath 'data' .. '/lazy/trouble.nvim'
  if vim.fn.isdirectory(trouble_path) == 1 then
    vim.opt.runtimepath:append(trouble_path)
    package.path = trouble_path .. '/lua/?.lua;' .. trouble_path .. '/lua/?/init.lua;' .. package.path
  end
end

return M
