local M = {}

M.state = {
  latest_selection = nil,
  tracking_enabled = false,
  debounce_timer = nil,
  debounce_ms = 100,
  last_active_visual_selection = nil,
  demotion_timer = nil,
  visual_demotion_delay_ms = 50,
}

local function is_visual_mode(mode)
  return mode == 'v' or mode == 'V' or mode == '\022'
end

local function current_buffer_is_codex()
  local buf = vim.api.nvim_get_current_buf()
  local ft = vim.api.nvim_buf_get_option(buf, 'filetype')
  local name = vim.api.nvim_buf_get_name(buf)
  return ft == 'codex' or (name and name:match '^codex://')
end

function M.enable(visual_demotion_delay_ms)
  if M.state.tracking_enabled then
    return
  end

  M.state.tracking_enabled = true
  M.state.visual_demotion_delay_ms = visual_demotion_delay_ms or 50
  M._create_autocommands()
  M.update_selection()
end

function M.disable()
  if not M.state.tracking_enabled then
    return
  end

  M.state.tracking_enabled = false
  vim.api.nvim_clear_autocmds { group = 'CodexSelection' }
  M.state.latest_selection = nil
  M.state.last_active_visual_selection = nil

  if M.state.debounce_timer then
    vim.loop.timer_stop(M.state.debounce_timer)
    M.state.debounce_timer = nil
  end
  if M.state.demotion_timer then
    M.state.demotion_timer:stop()
    M.state.demotion_timer:close()
    M.state.demotion_timer = nil
  end
end

function M._create_autocommands()
  local group = vim.api.nvim_create_augroup('CodexSelection', { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter', 'TextChanged' }, {
    group = group,
    callback = function()
      M.debounce_update()
    end,
  })
  vim.api.nvim_create_autocmd('ModeChanged', {
    group = group,
    callback = function()
      M.debounce_update()
    end,
  })
end

function M.debounce_update()
  if M.state.debounce_timer then
    vim.loop.timer_stop(M.state.debounce_timer)
  end

  M.state.debounce_timer = vim.defer_fn(function()
    M.update_selection()
    M.state.debounce_timer = nil
  end, M.state.debounce_ms)
end

local function selection_coordinates()
  local anchor = vim.fn.getpos 'v'
  local cursor = vim.api.nvim_win_get_cursor(0)
  local p1 = { lnum = anchor[2], col = anchor[3] }
  local p2 = { lnum = cursor[1], col = cursor[2] + 1 }

  if p1.lnum < p2.lnum or (p1.lnum == p2.lnum and p1.col <= p2.col) then
    return p1, p2
  end
  return p2, p1
end

local function visual_mode()
  local mode = vim.fn.visualmode()
  if mode and mode ~= '' then
    return mode
  end
  local current = vim.api.nvim_get_mode().mode
  if is_visual_mode(current) then
    return current
  end
  return nil
end

local function lsp_positions(start_pos, end_pos, mode, lines)
  local start_line = start_pos.lnum - 1
  local end_line = end_pos.lnum - 1
  if mode == 'V' then
    return {
      start = { line = start_line, character = 0 },
      ['end'] = { line = end_line, character = #(lines[#lines] or '') },
    }
  end
  return {
    start = { line = start_line, character = start_pos.col - 1 },
    ['end'] = { line = end_line, character = end_pos.col },
  }
end

function M.get_visual_selection()
  if not is_visual_mode(vim.api.nvim_get_mode().mode) then
    return nil
  end

  local mode = visual_mode()
  if not mode then
    return nil
  end

  local start_pos, end_pos = selection_coordinates()
  if start_pos.lnum == 0 or end_pos.lnum == 0 then
    return nil
  end

  local buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(buf)
  if file_path == '' then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(buf, start_pos.lnum - 1, end_pos.lnum, false)
  if #lines == 0 then
    return nil
  end

  local text
  if mode == 'V' then
    text = table.concat(lines, '\n')
    start_pos.col = 1
  else
    if start_pos.lnum == end_pos.lnum then
      text = string.sub(lines[1], start_pos.col, end_pos.col)
    else
      local parts = { string.sub(lines[1], start_pos.col) }
      for i = 2, #lines - 1 do
        table.insert(parts, lines[i])
      end
      table.insert(parts, string.sub(lines[#lines], 1, end_pos.col))
      text = table.concat(parts, '\n')
    end
  end

  local positions = lsp_positions(start_pos, end_pos, mode, lines)
  return {
    text = text or '',
    filePath = file_path,
    fileUrl = 'file://' .. file_path,
    selection = {
      start = positions.start,
      ['end'] = positions['end'],
      isEmpty = not text or text == '',
    },
  }
end

function M.get_cursor_position()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(buf)

  return {
    text = '',
    filePath = file_path,
    fileUrl = 'file://' .. file_path,
    selection = {
      start = { line = cursor[1] - 1, character = cursor[2] },
      ['end'] = { line = cursor[1] - 1, character = cursor[2] },
      isEmpty = true,
    },
  }
end

function M.get_range_selection(line1, line2)
  if not line1 or not line2 or line1 < 1 or line2 < 1 or line1 > line2 then
    return nil
  end

  local buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(buf)
  if file_path == '' then
    return nil
  end

  line2 = math.min(line2, vim.api.nvim_buf_line_count(buf))
  local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
  if #lines == 0 then
    return nil
  end

  local text = table.concat(lines, '\n')
  return {
    text = text,
    filePath = file_path,
    fileUrl = 'file://' .. file_path,
    selection = {
      start = { line = line1 - 1, character = 0 },
      ['end'] = { line = line2 - 1, character = #(lines[#lines] or '') },
      isEmpty = text == '',
    },
  }
end

function M.has_selection_changed(new_selection)
  local old = M.state.latest_selection
  if not old then
    return new_selection ~= nil
  end
  if not new_selection then
    return true
  end
  if old.filePath ~= new_selection.filePath or old.text ~= new_selection.text then
    return true
  end
  return old.selection.start.line ~= new_selection.selection.start.line
    or old.selection.start.character ~= new_selection.selection.start.character
    or old.selection['end'].line ~= new_selection.selection['end'].line
    or old.selection['end'].character ~= new_selection.selection['end'].character
end

function M.update_selection()
  if not M.state.tracking_enabled or current_buffer_is_codex() then
    return
  end

  local mode = vim.api.nvim_get_mode().mode
  local current_buf = vim.api.nvim_get_current_buf()
  local selection

  if is_visual_mode(mode) then
    if M.state.demotion_timer then
      M.state.demotion_timer:stop()
      M.state.demotion_timer:close()
      M.state.demotion_timer = nil
    end
    selection = M.get_visual_selection()
    if selection then
      M.state.last_active_visual_selection = {
        bufnr = current_buf,
        selection_data = vim.deepcopy(selection),
      }
    end
  else
    local last_visual = M.state.last_active_visual_selection
    if last_visual and last_visual.bufnr == current_buf and last_visual.selection_data and not last_visual.selection_data.selection.isEmpty then
      selection = M.state.latest_selection
      if not M.state.demotion_timer then
        M.state.demotion_timer = vim.loop.new_timer()
        M.state.demotion_timer:start(M.state.visual_demotion_delay_ms, 0, vim.schedule_wrap(function()
          if M.state.demotion_timer then
            M.state.demotion_timer:stop()
            M.state.demotion_timer:close()
            M.state.demotion_timer = nil
          end
          M.state.last_active_visual_selection = nil
          local cursor_selection = M.get_cursor_position()
          if M.has_selection_changed(cursor_selection) then
            M.state.latest_selection = cursor_selection
          end
        end))
      end
    else
      selection = M.get_cursor_position()
    end
  end

  if selection and M.has_selection_changed(selection) then
    M.state.latest_selection = selection
  end
end

function M.get_latest_selection()
  return M.state.latest_selection
end

return M
