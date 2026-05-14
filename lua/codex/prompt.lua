local state = require 'codex.state'
local util = require 'codex.util'

local M = {}

local function context_label(item)
  if item.line_start and item.line_end then
    return ('%s:%d-%d'):format(item.name or item.path, item.line_start + 1, item.line_end + 1)
  end
  return item.label or item.name or item.path
end

function M.selection_reference(sel)
  if not sel or not sel.filePath or not sel.selection or sel.selection.isEmpty then
    return nil
  end
  local start_line = sel.selection.start.line + 1
  local end_line = sel.selection['end'].line + 1
  local name = util.relative_path(sel.filePath)
  if start_line == end_line then
    return ('@%s#L%d'):format(name, start_line)
  end
  return ('@%s#L%d-L%d'):format(name, start_line, end_line)
end

function M.selection_injection(sel)
  local ref = M.selection_reference(sel)
  if not ref or not sel.text or sel.text == '' then
    return nil
  end
  return {
    type = 'message',
    role = 'user',
    content = {
      {
        type = 'input_text',
        text = ('Selected Neovim context %s:\n```text\n%s\n```'):format(ref, sel.text),
      },
    },
  }
end

function M.input_reference(prompt, opts, config)
  opts = opts or {}
  config = config or {}
  local text = prompt or ''
  if opts.raw then
    return text
  end
  local ref = M.selection_reference(opts.selection)

  if ref and text ~= '' then
    return ('%s %s'):format(ref, text)
  elseif ref then
    return ref .. ' '
  elseif text ~= '' then
    return text
  elseif config.include_active_buffer_context then
    local active = opts.active_context
    if not active then
      local ok, editor = pcall(require, 'codex.editor')
      if ok then
        active = editor.active()
      end
    end
    if active and active.path then
      return '@' .. util.relative_path(active.path) .. ' '
    end
  end

  return ''
end

function M.terminal(prompt, opts, config)
  opts = opts or {}
  config = config or {}
  local text = prompt or ''
  if opts.raw then
    return text
  end
  local pending = vim.deepcopy(state.app.pending_context or {})
  local prefixes = {}
  local context_lines = {}

  local sel = opts.selection
  if sel and not sel.selection.isEmpty then
    local ref = M.selection_reference(sel)
    if text == '' then
      text = ref or ''
    else
      text = text .. '\n\nSelected context: ' .. (ref or '')
    end
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
