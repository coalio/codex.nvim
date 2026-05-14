local state = require 'codex.state'
local util = require 'codex.util'

local M = {}

local function context_label(item)
  if item.line_start and item.line_end then
    return ('%s:%d-%d'):format(item.name or item.path, item.line_start + 1, item.line_end + 1)
  end
  return item.label or item.name or item.path
end

function M.terminal(prompt, opts, config)
  opts = opts or {}
  config = config or {}
  local text = prompt or ''
  local pending = vim.deepcopy(state.app.pending_context or {})
  local prefixes = {}
  local context_lines = {}

  local sel = opts.selection
  if sel and not sel.selection.isEmpty then
    local start_line = sel.selection.start.line
    local end_line = sel.selection['end'].line
    local name = util.relative_path(sel.filePath)
    text = text
      .. ('\n\nSelected lines from %s:%d-%d:\n```text\n%s\n```'):format(name, start_line + 1, end_line + 1, sel.text or '')
  elseif config.include_active_buffer_context then
    local description = opts.active_description
    if not description then
      local ok, editor = pcall(require, 'codex.editor')
      if ok then
        local active = opts.active_context or editor.active()
        description = editor.describe(active)
      end
    end
    if description then
      text = text .. '\n\n' .. description
    end
  end

  for _, item in ipairs(pending) do
    if item.path and item.path:match '^app://' then
      table.insert(prefixes, '$' .. item.path:gsub('^app://', ''))
    elseif item.type == 'skill' then
      table.insert(prefixes, '$' .. item.name)
    elseif item.path then
      table.insert(context_lines, '- ' .. context_label(item))
    end
  end

  if #prefixes > 0 then
    text = table.concat(prefixes, ' ') .. ' ' .. text
  end
  if #context_lines > 0 then
    text = text .. '\n\nAdditional Neovim context:\n' .. table.concat(context_lines, '\n')
  end

  state.app.pending_context = {}
  return text
end

return M
