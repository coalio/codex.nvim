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

function M.references(text)
  local refs = {}
  local seen = {}
  local source = tostring(text or '')

  local function collect_token(raw)
    local token = raw:gsub('[%.,;:%)%]%}]+$', '')
    local has_marker = token:sub(1, 1) == '@'
    local path, start_line, end_line = token:match '^@?(.+)#L(%d+)%-L?(%d+)$'
    if not path then
      path, start_line = token:match '^@?(.+)#L(%d+)$'
      end_line = start_line
    end

    if path and start_line then
      if
        not has_marker
        and not (
          path:match '^/'
          or path:match '^~/'
          or path:match '^%./'
          or path:match '^%.%./'
          or path:match '/'
        )
      then
        return
      end
      local key = ('%s:%s:%s'):format(path, start_line, end_line or start_line)
      if not seen[key] then
        seen[key] = true
        table.insert(refs, {
          reference = token,
          path = path,
          start_line = tonumber(start_line),
          end_line = tonumber(end_line or start_line),
        })
      end
    end
  end

  local function collect(candidate)
    for raw in candidate:gmatch '@[^%s]+#L%d+%-?L?%d*' do
      collect_token(raw)
    end
    for raw in candidate:gmatch '[%w%._~/%-][^%s]*#L%d+%-?L?%d*' do
      collect_token(raw)
    end
  end

  collect(source)
  collect(source:gsub('\r?\n%s*', ''))

  return refs
end

local function absolute_path(path)
  if not path or path == '' then
    return nil
  end
  if path:sub(1, 1) == '~' then
    return vim.fn.fnamemodify(path, ':p')
  end
  if path:sub(1, 1) == '/' then
    return vim.fn.fnamemodify(path, ':p')
  end
  return vim.fn.fnamemodify(util.cwd() .. '/' .. path, ':p')
end

local function buffer_lines(path, start_line, end_line)
  local abs = absolute_path(path)
  if not abs then
    return nil
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == abs then
      return vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    end
  end

  if vim.fn.filereadable(abs) ~= 1 then
    return nil
  end

  local lines = vim.fn.readfile(abs)
  local selected = {}
  for line = start_line, math.min(end_line, #lines) do
    table.insert(selected, lines[line])
  end
  return selected
end

function M.injection_items_from_text(text)
  local items = {}
  for _, ref in ipairs(M.references(text)) do
    local lines = buffer_lines(ref.path, ref.start_line, ref.end_line)
    if lines and #lines > 0 then
      table.insert(items, {
        type = 'message',
        role = 'user',
        content = {
          {
            type = 'input_text',
            text = ('Selected Neovim context %s:\n```text\n%s\n```'):format(ref.reference, table.concat(lines, '\n')),
          },
        },
      })
    end
  end
  return items
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
  local pending = vim.deepcopy(opts.pending_context or state.app.pending_context or {})
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

  if opts.pending_context then
    for index = #opts.pending_context, 1, -1 do
      table.remove(opts.pending_context, index)
    end
  else
    state.app.pending_context = {}
  end
  return text
end

return M
