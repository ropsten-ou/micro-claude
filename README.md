# micro-claude

A [micro](https://micro-editor.github.io) plugin for talking to Claude Code.
It runs [`claude-agent-acp`](https://www.npmjs.com/package/@agentclientprotocol/claude-agent-acp)
in the background over ACP (Agent Client Protocol) and shows the conversation
in a split next to your file.

## Needs

* [micro](https://micro-editor.github.io), tried with 2.0.15.
* [Claude Code](https://claude.com/claude-code), signed in: the plugin uses
  its sign-in.
* Node.js, for `claude-agent-acp`, the agent the plugin talks to.

## Install

```bash
npm install -g @agentclientprotocol/claude-agent-acp
git clone https://github.com/ropsten-ou/micro-claude.git
cd micro-claude
mkdir -p ~/.config/micro/plug
ln -s "$PWD" ~/.config/micro/plug/claude
```

The `mkdir` is for a micro that has no `plug` folder yet. Then open a
file in micro and press `Alt-c`.

The agent uses Claude Code's own sign-in. If it reports "Authentication
required", run `claude` in a terminal and use `/login`.

## Use

Press `Alt-c` (or run `> claude`) and write a message in the draft that
opens under the chat: Enter starts a new line, `Alt-c` sends, `Ctrl-q`
drops it. Selected text is sent along with its file and line numbers. When Claude wants to run a tool,
the chat says so and `Alt-c` asks `Allow? (y/n)` in the info bar; the
question never opens by itself, so keys typed in a file can't answer it. See `> help claude` inside micro for all commands.

Inside [hill-ops](https://github.com/ropsten-ou/hill-ops/blob/main/README.md), which runs an app over tmux above a strip, micro's settings, command line and help
are in hill-ops's strip, and Claude's failures (the agent exiting, a session or
a turn failing) go to hill-ops's event log, in the plugin's words rather than
the agent's message, which can name a file. `Alt-,` opens the settings in
hill-ops's panel, with hill-ops's own Claude under them, for tips and questions
about micro; `Alt-c` stays this plugin's Claude, about your files. hill-ops's
Claude knows this repo's open work items, and can file a new one in `work/`
for what micro or the plugin doesn't do yet (written, not committed):
`hill.toml` names the folder. When
hill-ops runs micro over an app's side panes, as [palace](https://github.com/ropsten-ou/hill/blob/main/README.md) does to edit a note,
the chat opens at the start where the app's Claude pane was, as wide.
The agent runs without `$HILL_SOCKET`, so that nothing it starts, such as
palace or its tests, joins hill-ops: its hello would take hill-ops's panes over.

`Ctrl-q` in the last file closes the chat (and the draft) too, so micro quits as it would
without it.

## Layout

* `claude.lua`: the whole plugin, including a small JSON encoder/decoder.
* `help/claude.md`: micro help page.
* `work/`: [work items](work/README.md), one file each.
* `hill.toml`: micro's settings and the plugin's, for the settings strip of
  hill-ops, which micro joins when it runs inside hill-ops.
* `test/fake-agent.py`: a stand-in agent for testing without a Claude login:
  `micro -config-dir <dir>` with `"claude.command": "<path>/test/fake-agent.py"`
  in that dir's `settings.json`.

