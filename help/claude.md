# Claude

Talk to Claude Code from micro. The plugin runs `claude-agent-acp` in the
background and shows the conversation in a split on the right.

## Usage

* `Alt-c` or `> claude`: open a draft under the chat and write to Claude
  there. Enter starts a new line, so a prompt can take several lines or a
  pasted snippet; `Alt-c` (or `> claude`) in the draft sends it, and
  `Ctrl-q` drops it. While Claude is still working, the draft stays, to
  send once it's done.
* `> claude <text>`: send `<text>` straight away.
* Each message tells Claude which file you are in and the cursor line. If
  text is selected, the selection is sent too, with its line numbers.
* When Claude wants to run a tool, the chat and the info bar say so, and
  the question waits for `Alt-c`: it never opens by itself, so a `y` or
  `n` typed in a file or the draft can't answer it. `Alt-c` asks `Allow?
  (y/n)`; Escape leaves it waiting. `> claude-cancel` answers the waiting
  questions with a cancel.
* `> claude-cancel`: stop the current turn.
* `Ctrl-q` in the last file closes the chat (and the draft) too, so micro
  quits as it would without it.
* `> claude-restart`: start a fresh agent and session.
* `Alt-,`: the settings, open on the part you were in: Claude in the chat,
  Editor elsewhere. Inside hill-ops they open in its strip; elsewhere `Alt-,`
  runs the settings program in `claude.settingscommand`, such as `hill-ops
  settings {section}`, where `{section}` becomes `claude` in the chat and
  `editor` elsewhere. Either way, what changed in settings.json applies
  straight away, per-filetype options included for the files already open.

The agent runs in micro's working directory, so start micro from the project
you want Claude to work in.

## Inside hill-ops

hill-ops runs an app above a strip for its settings, help, command line and
questions. When micro runs inside it (`$HILL_SOCKET` is set), the plugin
talks to the strip through `hill-ops connect`:

* The strip shows micro's keys: `Alt-,` settings, `Alt-c` Claude, `Ctrl-e`
  command, `Ctrl-g` help, "keys & commands", `Ctrl-q` quit. Clicking one
  runs it, except quit.
* `Ctrl-e` opens the command line in the strip: it lists micro's commands
  as you type, Tab completes one, and Enter runs the line in micro, as `>`
  would.
* `Ctrl-g` still opens micro's own help pages; "keys & commands" on the
  strip shows micro's main keys and its commands there.
* `Alt-,` opens the settings in the strip; a setting changed there applies
  in micro at once.
* When hill-ops runs micro over the panes an app runs beside it, as palace
  does to edit a note, over its preview and its Claude pane, the chat
  opens at the start where the Claude pane was, as wide
  (`$HILL_CLAUDE_COLUMNS`), so Claude stays on the right while you edit.
  `Alt-c` asks about the file.
* Claude's failures go to hill-ops's event log, for Claude in the strip later:
  the agent exiting, or a session or a turn failing, in the plugin's words
  (never the agent's message, which can name a file).
* `hill.toml`, next to this plugin, describes micro's settings and the
  plugin's (the Editor and Claude groups) for hill-ops.

## Files

Claude reads and edits files on disk, so the plugin keeps micro and the disk
in step:

* Before each message, open files with unsaved edits are saved, so Claude
  sees them (`saved` in the chat).
* After each tool call, open files that Claude changed are reloaded (`↻` in
  the chat), and `Ctrl-z` in that file undoes Claude's change.
* If a file has unsaved edits *and* Claude changed it on disk, it is neither
  saved nor reloaded; the chat shows a `!` warning instead. `> save` keeps
  your version, overwriting Claude's change. `> reopen`, answering `n` to
  "Save file before reopen?", loads Claude's version and drops your edits.

## Options

* `claude.command`: the agent to run. Default: `claude-agent-acp`.
  Any ACP agent should work.
* `claude.settingscommand`: the program `Alt-,` runs outside hill-ops;
  `{section}` in it is replaced as above. Default: none.
* `claude.autosave`: save open files before each message. Default: `true`.
* `claude.autoreload`: reload open files Claude changed. Default: `true`.
  When `false`, micro's own `reload` option decides, on your next keypress
  in that file.
