local M = {
  name = 'openFile',
  description = 'Open a file in Neovim and optionally select a range of text',
  input_schema = {
    type = 'object',
    properties = {
      filePath = { type = 'string', description = 'Path to the file to open' },
      preview = { type = 'boolean', description = 'Open the file as a preview where supported', default = false },
      startLine = { type = 'integer', description = 'Optional 1-based start line' },
      endLine = { type = 'integer', description = 'Optional 1-based end line' },
      startText = { type = 'string', description = 'Plain text to locate the start of the selection' },
      endText = { type = 'string', description = 'Plain text to locate the end of the selection' },
      selectToEndOfLine = { type = 'boolean', description = 'Extend text selection to the end of the line', default = false },
      makeFrontmost = { type = 'boolean', description = 'Focus the opened file', default = true },
    },
    required = { 'filePath' },
    additionalProperties = false,
  },
}

local function find_main_window()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    local buf = vim.api.nvim_win_get_buf(win)
    local buftype = vim.api.nvim_buf_get_option(buf, 'buftype')
    local ft = vim.api.nvim_buf_get_option(buf, 'filetype')
    if (not cfg.relative or cfg.relative == '') and buftype ~= 'terminal' and buftype ~= 'nofile' and ft ~= 'codex' then
      return win
    end
  end
  return nil
end

local function select_lines(start_line, end_line)
  vim.api.nvim_win_set_cursor(0, { start_line, 0 })
  if end_line and end_line > start_line then
    vim.cmd('normal! V' .. tostring(end_line - start_line) .. 'j')
  else
    vim.cmd 'normal! V'
  end
end

local function select_text(params)
  if not params.startText then
    return nil
  end

  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start_line, start_col, end_line, end_col

  for i, line in ipairs(lines) do
    local col = line:find(params.startText, 1, true)
    if col then
      start_line = i
      start_col = col
      break
    end
  end

  if not start_line then
    return nil
  end

  if params.endText then
    for i = start_line, #lines do
      local col = lines[i]:find(params.endText, 1, true)
      if col then
        end_line = i
        end_col = params.selectToEndOfLine and #lines[i] or (col + #params.endText - 1)
        break
      end
    end
  end

  end_line = end_line or start_line
  end_col = end_col or (start_col + #params.startText - 1)
  vim.api.nvim_win_set_cursor(0, { start_line, start_col - 1 })
  vim.cmd 'normal! v'
  vim.api.nvim_win_set_cursor(0, { end_line, end_col })
  return { start_line = start_line, end_line = end_line }
end

function M.handler(params)
  if not params.filePath then
    error 'Missing filePath'
  end

  local file_path = vim.fn.expand(params.filePath)
  if vim.fn.filereadable(file_path) == 0 then
    error('File not found: ' .. file_path)
  end

  local previous_win = vim.api.nvim_get_current_win()
  local target_win = find_main_window()
  if target_win then
    vim.api.nvim_set_current_win(target_win)
  end

  if params.preview then
    vim.cmd('pedit ' .. vim.fn.fnameescape(file_path))
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(file_path))
  end

  local message = 'Opened file: ' .. file_path
  if params.startLine or params.endLine then
    local start_line = tonumber(params.startLine) or 1
    local end_line = tonumber(params.endLine) or start_line
    select_lines(start_line, end_line)
    message = ('Opened file and selected lines %d-%d'):format(start_line, end_line)
  elseif params.startText then
    local range = select_text(params)
    if range then
      message = ('Opened file and selected text at lines %d-%d'):format(range.start_line, range.end_line)
    end
  end

  if params.makeFrontmost == false and previous_win and vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end

  return {
    success = true,
    message = message,
    filePath = file_path,
    lineCount = vim.api.nvim_buf_line_count(vim.fn.bufnr(file_path)),
  }
end

return M
