vim.cmd 'set rtp+=.'
vim.cmd 'set rtp+=./plenary.nvim' -- if using as a submodule or symlinked
local trouble_path = vim.fn.stdpath 'data' .. '/lazy/trouble.nvim'
if vim.fn.isdirectory(trouble_path) == 1 then
  vim.opt.runtimepath:append(trouble_path)
  package.path = trouble_path .. '/lua/?.lua;' .. trouble_path .. '/lua/?/init.lua;' .. package.path
end
pcall(require, 'plugin.codex') -- triggers plugin/gh_dash.lua
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.stdpath 'data' .. '/site/pack/deps/start/plenary.nvim')
