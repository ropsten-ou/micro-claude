---
status: done
since: 2026-10-02
created: 2026-10-02
---
# The Claude prompt takes more than one line

## Goal
Alt-c (and `claude` with no words) opens a single-line prompt in micro's
info bar. It should take more than one line, so a longer question or a
pasted snippet can be written before it's sent.

## Notes
- Then: `micro.InfoBar():Prompt("claude> ", ...)` handed the line to
  `ask_text`, which built the prompt and sent it.
- The info bar is one line by nature. Ways to look at: a newline key
  (Alt-Enter, say) in the info bar, if micro allows it; or a scratch
  buffer in a split, sent on a key or on close.
- micro 2.0.15's info bar can't: it is one line on screen, and the prompt
  hands back only its first line (`LineBytes(0)` in `infopane.go`).
- The plan: a draft in a split under the chat. Enter is a new line,
  `Alt-c` sends, `Ctrl-q` drops it.
- Built. `Alt-c` (and `claude` with no words) opens a scratch split,
  `claude-prompt`, under the chat, and focus goes there. `Alt-c` or
  `> claude` in it sends, closes it and goes back to the file. The file
  and selection are taken from the pane `Alt-c` was pressed in, when it's
  sent. While Claude is busy the draft stays, to send later. `Ctrl-q` in
  the last file closes the chat and the draft, so micro quits.
- Found along the way: typing in the draft while Claude asked a
  permission answered it (a `y` in a word allowed the tool). The question
  now waits while the draft has focus, with a note in the info bar; the
  same in files became an item of its own.
- Tried in micro 2.0.15 under tmux with `test/fake-agent.py` (its "slow"
  prompt asks after 2 s): two lines reach the agent with the break, with
  file and selection; busy keeps the draft; the deferred question shows
  after Ctrl-w; Ctrl-q in the file quits micro.

## Done when
- [x] a prompt of several lines reaches Claude with its line breaks
- [x] README and `help/claude.md` say how
