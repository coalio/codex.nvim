# codex.nvim

`codex.nvim` is a Neovim client for the Codex CLI App Server. It talks to `codex app-server` over stdio JSON-RPC, streams Codex turn events into a Neovim buffer, sends prompts and selected ranges with editor context, and exposes Neovim-aware dynamic tools to Codex.

The plugin keeps the original terminal wrapper available as a fallback, but the default backend is the App Server because it supports structured threads, streamed deltas, approvals, apps, skills, MCP server status, and IDE-style editor tools.

## Features

- App Server transport with `initialize`, `thread/start`, `turn/start`, `turn/steer`, and streamed `item/*` / `turn/*` notifications.
- Accurate assistant text deltas in a Codex buffer or side panel.
- Visual/range sending with file path, line range, and selected text context.
- Pending file, app, and skill context for the next prompt.
- Dynamic Neovim tools for `openFile`, selections, open editors, diagnostics, workspace folders, dirty checks, saves, and diff review.
- App Server approval prompts for command execution, file changes, `request_user_input`, and MCP elicitations.
- MCP inventory commands backed by `mcpServerStatus/list` and config reload support.
- Model, app, and skill pickers backed by App Server RPCs.
- Optional legacy terminal backend for users who still want a raw `codex` terminal.

## Requirements

- Neovim with LuaJIT.
- The Codex CLI on `PATH`.

Install Codex with npm:

```bash
npm install -g @openai/codex
```

Codex authentication, models, MCP servers, apps, skills, sandboxing, and approvals are configured through the normal Codex configuration files and login flows. See the official Codex App Server documentation for protocol details:

- <https://developers.openai.com/codex/app-server>
- <https://developers.openai.com/codex/config-reference>

## Installation

Example with `lazy.nvim`:

```lua
return {
  'coalio/codex.nvim',
  cmd = {
    'Codex',
    'CodexToggle',
    'CodexSend',
    'CodexAdd',
    'CodexMcp',
    'CodexApps',
    'CodexSkills',
  },
  keys = {
    {
      '<leader>cc',
      function()
        require('codex').toggle()
      end,
      desc = 'Toggle Codex',
      mode = { 'n', 't' },
    },
    {
      '<leader>cs',
      function()
        vim.cmd('CodexSend')
      end,
      desc = 'Send selection to Codex',
      mode = { 'n', 'v' },
    },
  },
  opts = {
    backend = 'app_server',
    model = nil,
    panel = false,
    width = 0.8,
    height = 0.8,
    border = 'rounded',
    track_selection = true,
    app_server = {
      auto_start = true,
      experimental = true,
      dynamic_tools = true,
      enable_features = { 'apps' },
    },
  },
}
```

## Commands

- `:Codex` toggles the Codex buffer. With arguments or a visual range, it sends a prompt.
- `:CodexToggle` toggles the Codex buffer.
- `:CodexSend [prompt]` sends a prompt. From visual mode or with a range, it includes the selected lines.
- `:CodexAdd [path] [start_line] [end_line]` adds a file, directory, or current selection as context for the next prompt.
- `:CodexNew` starts a fresh App Server thread.
- `:CodexInterrupt` interrupts the active turn.
- `:CodexSelectModel` chooses a model from `model/list`.
- `:CodexApps` adds an app connector mention to the next prompt.
- `:CodexSkills` adds a skill to the next prompt.
- `:CodexMcp` shows configured MCP servers and tools.
- `:CodexReloadMcp` reloads Codex MCP server configuration.
- `:CodexStop` stops the local App Server process.

## Selection Workflow

Use visual mode and run:

```vim
:'<,'>CodexSend Explain this code and suggest a refactor
```

The request includes the selected file path, zero-based protocol positions internally, human-readable line numbers in the prompt, the selected text, and a file mention item for Codex.

To stage context without sending immediately:

```vim
:CodexAdd %
:CodexApps
:CodexSkills
:CodexSend Use the added context to update the implementation
```

## Configuration

```lua
require('codex').setup({
  backend = 'app_server',
  cmd = 'codex',
  model = nil,
  autoinstall = true,
  panel = false,
  width = 0.8,
  height = 0.8,
  border = 'single',
  track_selection = true,
  visual_demotion_delay_ms = 50,
  keymaps = {
    toggle = nil,
    quit = '<C-q>',
    send = '<C-s>',
    interrupt = '<C-c>',
  },
  app_server = {
    listen = 'stdio://',
    experimental = true,
    auto_start = true,
    dynamic_tools = true,
    service_name = 'codex_nvim',
    approval_policy = nil,
    sandbox = nil,
    enable_features = { 'apps' },
    mcp_status_detail = 'toolsAndAuthOnly',
  },
})
```

Set `backend = 'terminal'` to use the legacy raw terminal wrapper. The terminal backend still supports `panel`, `width`, `height`, `border`, `model`, and `use_buffer`.

## Statusline

`require('codex').status()` returns a lualine-compatible component. `require('codex').statusline()` returns a compact string for custom statuslines.
