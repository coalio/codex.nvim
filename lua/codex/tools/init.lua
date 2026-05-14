local util = require 'codex.util'

local M = {}

M.DEFERRED = {}
M.tools = {}

local tool_modules = {
  'codex.tools.open_file',
  'codex.tools.get_current_selection',
  'codex.tools.get_latest_selection',
  'codex.tools.get_open_editors',
  'codex.tools.get_diagnostics',
  'codex.tools.get_workspace_folders',
  'codex.tools.check_document_dirty',
  'codex.tools.save_document',
  'codex.tools.open_diff',
}

local function content_response(value, success)
  return {
    contentItems = {
      {
        type = 'inputText',
        text = util.text_content(value),
      },
    },
    success = success ~= false,
  }
end

function M.register(tool)
  if not tool or not tool.name or not tool.handler then
    return
  end
  M.tools[tool.name] = tool
end

function M.register_all()
  M.tools = {}
  for _, module_name in ipairs(tool_modules) do
    local ok, tool = pcall(require, module_name)
    if ok then
      M.register(tool)
    end
  end
end

function M.get_specs()
  if vim.tbl_isempty(M.tools) then
    M.register_all()
  end

  local specs = {}
  for _, tool in pairs(M.tools) do
    table.insert(specs, {
      namespace = 'nvim',
      name = tool.name,
      description = tool.description,
      inputSchema = tool.input_schema or { type = 'object', additionalProperties = false },
    })
  end
  table.sort(specs, function(a, b)
    return a.name < b.name
  end)
  return specs
end

function M.handle(params, respond)
  if vim.tbl_isempty(M.tools) then
    M.register_all()
  end

  local tool = M.tools[params.tool]
  if not tool then
    respond(content_response('Unknown tool: ' .. tostring(params.tool), false))
    return
  end

  local function done(value, success)
    respond(content_response(value, success))
  end

  local ok, result = pcall(tool.handler, params.arguments or {}, done)
  if not ok then
    respond(content_response(result, false))
    return
  end

  if result == M.DEFERRED or (type(result) == 'table' and result.__codex_deferred) then
    return
  end

  done(result, true)
end

return M
