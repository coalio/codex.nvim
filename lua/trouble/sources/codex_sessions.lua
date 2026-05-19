local Item = require 'trouble.item'

local M = {}

local function select_session(_, ctx)
  local item = ctx and ctx.item or nil
  local session_id = item and item.session_id or nil
  if not session_id then
    return
  end
  require('codex.terminal').select_session(session_id, { focus = true })
end

M.config = {
  modes = {
    codex_sessions = {
      desc = 'Codex Sessions',
      source = 'codex_sessions',
      title = false,
      events = {
        'User CodexSessionsChanged',
      },
      groups = {},
      sort = { 'session_index' },
      format = '{label}',
      auto_preview = false,
      follow = false,
      multiline = false,
      restore = false,
      keys = {
        ['<cr>'] = {
          action = select_session,
          desc = 'Select Codex session',
        },
        ['<2-leftmouse>'] = {
          action = select_session,
          desc = 'Select Codex session',
        },
      },
    },
  },
}

function M.get(cb)
  local items = {}
  for _, item in ipairs(require('codex.session_list').items()) do
    items[#items + 1] = Item.new(item)
  end
  cb(items)
end

return M
