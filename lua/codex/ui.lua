local state = require 'codex.state'
local util = require 'codex.util'

local M = {
  config = nil,
  callbacks = {},
}

local function border_for(config)
  local styles = {
    single = {
      { '┌', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '┐', 'FloatBorder' },
      { '│', 'FloatBorder' },
      { '┘', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '└', 'FloatBorder' },
      { '│', 'FloatBorder' },
    },
    double = {
      { '╔', 'FloatBorder' },
      { '═', 'FloatBorder' },
      { '╗', 'FloatBorder' },
      { '║', 'FloatBorder' },
      { '╝', 'FloatBorder' },
      { '═', 'FloatBorder' },
      { '╚', 'FloatBorder' },
      { '║', 'FloatBorder' },
    },
    rounded = {
      { '╭', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '╮', 'FloatBorder' },
      { '│', 'FloatBorder' },
      { '╯', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '╰', 'FloatBorder' },
      { '│', 'FloatBorder' },
    },
    none = nil,
  }
  return type(config.border) == 'string' and styles[config.border] or config.border
end

local function ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end

  state.buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_option(state.buf, 'bufhidden', 'hide')
  vim.api.nvim_buf_set_option(state.buf, 'swapfile', false)
  vim.api.nvim_buf_set_option(state.buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(state.buf, 'filetype', 'codex')
  vim.api.nvim_buf_set_name(state.buf, 'codex://app-server')
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { 'Codex', '' })

  return state.buf
end

local function with_modifiable(fn)
  local buf = ensure_buf()
  local was_modifiable = vim.api.nvim_buf_get_option(buf, 'modifiable')
  vim.api.nvim_buf_set_option(buf, 'modifiable', true)
  fn(buf)
  vim.api.nvim_buf_set_option(buf, 'modifiable', was_modifiable)
end

local function scroll_to_bottom()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local line_count = vim.api.nvim_buf_line_count(state.buf)
    pcall(vim.api.nvim_win_set_cursor, state.win, { line_count, 0 })
  end
end

local function split_lines(text)
  return vim.split(text or '', '\n', { plain = true })
end

function M.setup(config, callbacks)
  M.config = config
  M.callbacks = callbacks or {}
end

function M.apply_keymaps()
  local buf = ensure_buf()

  if M.config.keymaps.quit then
    vim.api.nvim_buf_set_keymap(buf, 'n', M.config.keymaps.quit, [[<cmd>lua require('codex').close()<CR>]], { noremap = true, silent = true })
  end

  if M.config.keymaps.send then
    vim.api.nvim_buf_set_keymap(buf, 'n', M.config.keymaps.send, [[<cmd>CodexSend<CR>]], { noremap = true, silent = true })
  end

  if M.config.keymaps.interrupt then
    vim.api.nvim_buf_set_keymap(buf, 'n', M.config.keymaps.interrupt, [[<cmd>CodexInterrupt<CR>]], { noremap = true, silent = true })
  end
end

function M.open()
  ensure_buf()
  M.apply_keymaps()

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  if M.config.panel then
    vim.cmd 'botright vertical split'
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, state.buf)
    vim.api.nvim_win_set_width(win, math.floor(vim.o.columns * M.config.width))
    state.win = win
    return
  end

  local width = math.floor(vim.o.columns * M.config.width)
  local height = math.floor(vim.o.lines * M.config.height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = border_for(M.config),
  })
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

function M.clear()
  with_modifiable(function(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Codex', '' })
  end)
end

function M.append(text)
  with_modifiable(function(buf)
    local lines = split_lines(text)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  end)
  scroll_to_bottom()
end

function M.append_block(title, text)
  local lines = { '', title }
  if text and text ~= '' then
    vim.list_extend(lines, split_lines(text))
  end
  M.append(table.concat(lines, '\n'))
end

function M.append_delta(item_id, delta, title)
  local app_state = state.app
  app_state.items[item_id] = app_state.items[item_id] or { rendered = false }
  local item_state = app_state.items[item_id]

  with_modifiable(function(buf)
    if not item_state.rendered then
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '', title or 'Codex:' })
      item_state.rendered = true
    end

    local line_count = vim.api.nvim_buf_line_count(buf)
    local last = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ''
    local lines = split_lines(delta)
    vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, { last .. lines[1] })
    if #lines > 1 then
      local rest = {}
      for i = 2, #lines do
        table.insert(rest, lines[i])
      end
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, rest)
    end
  end)
  scroll_to_bottom()
end

local function item_summary(item)
  if not item or type(item) ~= 'table' then
    return nil
  end
  if item.type == 'commandExecution' then
    return '$ ' .. (item.command or '')
  end
  if item.type == 'fileChange' then
    return 'File changes proposed'
  end
  if item.type == 'mcpToolCall' then
    return ('MCP %s/%s'):format(item.server or '?', item.tool or '?')
  end
  if item.type == 'dynamicToolCall' then
    return ('Tool %s'):format(item.tool or '?')
  end
  if item.type == 'webSearch' then
    return ('Web search: %s'):format(item.query or '')
  end
  if item.type == 'reasoning' then
    return 'Reasoning'
  end
  if item.type == 'plan' then
    return 'Plan'
  end
  return nil
end

function M.render_notification(msg)
  local method = msg.method
  local params = msg.params or {}

  if method == 'item/agentMessage/delta' then
    M.append_delta(params.itemId, params.delta or '', 'Codex:')
  elseif method == 'item/plan/delta' then
    M.append_delta(params.itemId, params.delta or '', 'Plan:')
  elseif method == 'item/reasoning/summaryTextDelta' then
    M.append_delta(params.itemId, params.delta or '', 'Reasoning:')
  elseif method == 'item/commandExecution/outputDelta' then
    M.append_delta(params.itemId, params.delta or '', 'Command output:')
  elseif method == 'item/started' then
    local summary = item_summary(params.item)
    if summary then
      M.append_block(summary)
    end
  elseif method == 'item/completed' then
    local item = params.item or {}
    if item.type == 'commandExecution' and item.exitCode ~= nil then
      M.append(('Command exited with %s'):format(tostring(item.exitCode)))
    elseif item.type == 'mcpToolCall' and item.status then
      M.append(('MCP tool %s'):format(item.status))
    elseif item.type == 'dynamicToolCall' and item.status then
      M.append(('Tool %s'):format(item.status))
    end
  elseif method == 'turn/completed' then
    local turn = params.turn or {}
    state.app.running = false
    state.app.active_turn_id = nil
    if turn.status == 'failed' and turn.error then
      M.append_block('Turn failed:', util.text_content(turn.error))
    else
      M.append('')
    end
  elseif method == 'thread/status/changed' then
    M.append(('Thread status: %s'):format(tostring(params.status)))
  elseif method == 'mcpServer/startupStatus/updated' then
    M.append(('MCP server %s: %s'):format(tostring(params.name), tostring(params.status)))
  elseif method == 'warning' or method == 'configWarning' or method == 'error' then
    M.append_block(method .. ':', util.text_content(params))
  end
end

function M.render_user_input(prompt, context_items)
  local title = 'You:'
  local body = prompt or ''
  if context_items and #context_items > 0 then
    local labels = {}
    for _, item in ipairs(context_items) do
      table.insert(labels, item.label or item.name or item.path)
    end
    body = body .. '\n\nContext: ' .. table.concat(labels, ', ')
  end
  M.append_block(title, body)
end

return M
