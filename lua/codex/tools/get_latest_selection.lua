local M = {
  name = 'getLatestSelection',
  description = 'Get the most recently tracked text selection in Neovim',
  input_schema = {
    type = 'object',
    additionalProperties = false,
  },
}

function M.handler()
  local current = require('codex.selection').get_latest_selection()
  if not current then
    return { success = false, message = 'No selection available' }
  end
  return current
end

return M
