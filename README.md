# codex.nvim

`codex.nvim` connects Neovim to Codex through the Codex App Server while keeping the Codex terminal UI as the primary interface. Neovim starts a local `codex app-server` WebSocket endpoint, opens `codex --remote ...` in a terminal split or float, and keeps a lightweight control client attached for App Server actions.

The result is a terminal-first workflow with IDE context. Visual selections are sent without an extra prompt, Neovim-originated prompts include active-buffer context, and once the terminal has an active App Server thread, sends are routed through that thread. Codex apps, skills, MCP servers, approvals, and model selection continue to come from the normal Codex configuration and App Server APIs.

## Features

- Terminal UI backed by a local App Server WebSocket transport.
- The terminal pane opens immediately; App Server startup and TUI connection happen asynchronously.
- Visual/range `:CodexSend` without a second prompt; selected text, path, and line numbers are sent immediately.
- Active-buffer context on Neovim-originated prompts.
- App Server thread tracking, so sends use the active terminal thread after the TUI connects.
- App Server approvals for commands, file changes, user-input requests, and MCP elicitations.
- Codex app, skill, model, and MCP inventory commands.
- Optional buffer transcript mode for App Server debugging and a legacy raw terminal backend.

## Requirements

- Neovim with LuaJIT.
- Codex CLI on `PATH`.

Install Codex with npm:

```bash
npm install -g @openai/codex
```

Codex authentication, MCP servers, apps, skills, sandboxing, approvals, and model defaults are configured through `~/.codex/config.toml` and the usual Codex login flows.

Useful Codex references:

- <https://developers.openai.com/codex/app-server>
- <https://developers.openai.com/codex/cli/features#connect-the-tui-to-a-remote-app-server>
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
    panel = true,
    width = 0.32,
    track_selection = true,
    app_server = {
      ui = 'terminal',
      auto_start = true,
      open_terminal = true,
      experimental = true,
      dynamic_tools = true,
      enable_features = { 'apps' },
    },
  },
}
```

## Commands

- `:Codex` opens or toggles Codex. With arguments or a visual range, it sends a prompt.
- `:CodexToggle` toggles the Codex terminal.
- `:CodexSend [prompt]` sends a prompt. From visual mode or with a range, it sends the selected lines immediately; when no prompt is supplied, `selection_prompt` is used.
- `:CodexAdd [path] [start_line] [end_line]` stages a file, directory, or selection as context for the next Neovim-originated prompt.
- `:CodexNew` asks the terminal UI to start a fresh thread.
- `:CodexInterrupt` interrupts the active turn.
- `:CodexSelectModel` chooses a model from `model/list`.
- `:CodexApps` adds an app connector mention to the next prompt.
- `:CodexSkills` adds a skill to the next prompt.
- `:CodexMcp` shows configured MCP servers and tools.
- `:CodexReloadMcp` reloads Codex MCP server configuration.
- `:CodexStop` stops the local App Server process.

## Selection Workflow

In visual mode, run:

```vim
:'<,'>CodexSend
```

The selection is sent without asking for another prompt. The request includes the selected line range and selected text. If the Codex terminal is not connected yet, the selection becomes the initial prompt used to launch the TUI; after the TUI has an active App Server thread, the request is sent through that thread. Supplying text after the command uses that text as the prompt while keeping the same selection context:

```vim
:'<,'>CodexSend Explain this code and suggest a refactor
```

Normal-mode prompts include the active file path, cursor position, filetype, dirty state, and line count so Codex has editor orientation without needing a separate question.

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
  include_active_buffer_context = true,
  visual_demotion_delay_ms = 50,
  selection_prompt = 'Use the selected Neovim context.',
  keymaps = {
    toggle = nil,
    quit = '<C-q>',
    send = '<C-s>',
    interrupt = '<C-c>',
  },
  app_server = {
    ui = 'terminal',
    listen = 'stdio://',
    port = nil,
    port_range = { min = 45000, max = 45999 },
    experimental = true,
    auto_start = true,
    dynamic_tools = true,
    open_terminal = true,
    editor_instructions = true,
    service_name = 'codex_nvim',
    approval_policy = nil,
    sandbox = nil,
    enable_features = { 'apps' },
    mcp_status_detail = 'toolsAndAuthOnly',
  },
})
```

Set `app_server.ui = 'buffer'` to use the App Server transcript buffer for debugging. Set `backend = 'terminal'` to use the legacy raw `codex` terminal wrapper without App Server integration.

## Statusline

`require('codex').status()` returns a lualine-compatible component. `require('codex').statusline()` returns a compact string for custom statuslines.
