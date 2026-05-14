local M = {
  name = 'getCurrentSelection',
  description = 'Get the current text selection in Neovim',
  input_schema = {
    type = 'object',
    additionalProperties = false,
  },
}

function M.handler()
  local selection = require 'codex.selection'
  selection.update_selection()
  local current = selection.get_latest_selection()
  if not current then
    return { success = false, message = 'No active editor selection' }
  end
  current.success = true
  return current
end

return M
