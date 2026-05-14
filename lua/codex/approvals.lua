local logger = require 'codex.logger'
local util = require 'codex.util'

local M = {}

local function select_decision(prompt, choices, fallback, cb)
  vim.ui.select(choices, {
    prompt = prompt,
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    cb(choice and choice.value or fallback)
  end)
end

local function decision_label(decision)
  if type(decision) == 'string' then
    if decision == 'accept' then
      return 'Accept'
    elseif decision == 'acceptForSession' then
      return 'Accept for session'
    elseif decision == 'decline' then
      return 'Decline'
    elseif decision == 'cancel' then
      return 'Cancel'
    end
    return decision
  end
  if decision.acceptWithExecpolicyAmendment then
    return 'Accept similar commands'
  end
  if decision.applyNetworkPolicyAmendment then
    return 'Apply network policy'
  end
  return util.text_content(decision)
end

function M.command(params, respond)
  local prompt
  if params.networkApprovalContext then
    prompt = ('Allow %s network access to %s?'):format(params.networkApprovalContext.protocol or 'network', params.networkApprovalContext.host or '?')
  else
    prompt = ('Allow command: %s'):format(params.command or params.reason or 'unknown command')
  end

  local available = params.availableDecisions or { 'accept', 'acceptForSession', 'decline', 'cancel' }
  local choices = {}
  for _, decision in ipairs(available) do
    table.insert(choices, { label = decision_label(decision), value = decision })
  end

  select_decision(prompt, choices, 'cancel', function(decision)
    respond({ decision = decision })
  end)
end

function M.file_change(params, respond)
  local detail = params.grantRoot and (' under ' .. params.grantRoot) or ''
  local reason = params.reason and ('\n' .. params.reason) or ''
  select_decision('Allow file changes' .. detail .. '?' .. reason, {
    { label = 'Accept', value = 'accept' },
    { label = 'Accept for session', value = 'acceptForSession' },
    { label = 'Decline', value = 'decline' },
    { label = 'Cancel', value = 'cancel' },
  }, 'cancel', function(decision)
    respond({ decision = decision })
  end)
end

local function ask_question(question, cb)
  if question.options and #question.options > 0 then
    local choices = {}
    for _, option in ipairs(question.options) do
      table.insert(choices, {
        label = option.label,
        value = option.label,
      })
    end
    if question.isOther then
      table.insert(choices, { label = 'Other', value = nil })
    end

    vim.ui.select(choices, {
      prompt = question.question or question.header,
      format_item = function(item)
        return item.label
      end,
    }, function(choice)
      if not choice then
        cb(nil)
      elseif choice.value then
        cb(choice.value)
      else
        vim.ui.input({ prompt = question.question or question.header }, cb)
      end
    end)
  else
    vim.ui.input({ prompt = question.question or question.header }, cb)
  end
end

function M.user_input(params, respond)
  local answers = {}
  local questions = params.questions or {}

  local function step(index)
    local question = questions[index]
    if not question then
      respond({ answers = answers })
      return
    end

    ask_question(question, function(answer)
      if answer == nil then
        respond({ answers = answers })
        return
      end
      answers[question.id] = { answers = { answer } }
      step(index + 1)
    end)
  end

  step(1)
end

local function default_for_schema(schema)
  if schema.default ~= nil then
    return tostring(schema.default)
  end
  if schema.type == 'boolean' then
    return 'false'
  end
  return ''
end

local function coerce_schema_value(schema, value)
  if schema.type == 'boolean' then
    return value == true or value == 'true' or value == '1' or value == 'yes'
  elseif schema.type == 'integer' or schema.type == 'number' then
    return tonumber(value)
  end
  return value
end

function M.mcp_elicitation(params, respond)
  if params.mode == 'url' then
    vim.ui.select({ 'Open URL', 'Accept', 'Decline', 'Cancel' }, { prompt = params.message or params.url }, function(choice)
      if choice == 'Open URL' then
        if vim.ui.open then
          vim.ui.open(params.url)
        else
          vim.fn.jobstart({ 'xdg-open', params.url }, { detach = true })
        end
        respond({ action = 'accept', content = nil, _meta = nil })
      elseif choice == 'Accept' then
        respond({ action = 'accept', content = nil, _meta = nil })
      elseif choice == 'Decline' then
        respond({ action = 'decline', content = nil, _meta = nil })
      else
        respond({ action = 'cancel', content = nil, _meta = nil })
      end
    end)
    return
  end

  local schema = params.requestedSchema or {}
  local properties = schema.properties or {}
  local keys = {}
  for key in pairs(properties) do
    table.insert(keys, key)
  end
  table.sort(keys)

  local content = {}
  local function step(index)
    local key = keys[index]
    if not key then
      respond({ action = 'accept', content = content, _meta = nil })
      return
    end

    local prop = properties[key] or {}
    local prompt = prop.title or prop.description or key
    vim.ui.input({ prompt = prompt, default = default_for_schema(prop) }, function(value)
      if value == nil then
        respond({ action = 'cancel', content = nil, _meta = nil })
        return
      end
      content[key] = coerce_schema_value(prop, value)
      step(index + 1)
    end)
  end

  logger.info(params.message or ('MCP server ' .. tostring(params.serverName) .. ' requests input'))
  step(1)
end

return M
