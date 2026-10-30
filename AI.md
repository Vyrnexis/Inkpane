# Inkpane with AI (optional)

Inkpane is a drawing tool for people first. This page is about an optional extra:
**`inkpane-mcp`**, a small [MCP](https://modelcontextprotocol.io) server that lets an AI
assistant use Inkpane too. It can point at things on your real screen, write on a
whiteboard and take screenshots to see the result. Nothing here is needed to use
Inkpane, and `inkpane-mcp` only runs when an AI client starts it.

<p align="center"><img src="assets/demo-ai.gif" alt="Staged demo: in Claude Code, the user asks how to install only PhotoCraft's update. Claude takes a screenshot, circles Updates in AppGlider's sidebar, the user clicks it and says done, then Claude numbers the old and new versions 1 and 2 and circles PhotoCraft's Update button" width="800"></p>

- [Set up with Claude Code](#set-up-with-claude-code)
- [What you can ask](#what-you-can-ask)
- [What to expect](#what-to-expect)
- [Tutorials](#tutorials)
- [Letting the AI click (opt-in)](#letting-the-ai-click-opt-in)
- [Privacy](#privacy)
- [Other MCP clients](#other-mcp-clients)
- [Troubleshooting](#troubleshooting)

## Set up with Claude Code

Install Inkpane first (see the [README](README.md#install)), so that both `inkpane` and
`inkpane-mcp` are on your PATH. Then, in [Claude Code](https://claude.com/claude-code):

```
/plugin marketplace add Vyrnexis/Inkpane
/plugin install inkpane@inkpane
```

The plugin brings the MCP server and a skill that teaches Claude how to guide people
well: one step at a time, few marks, explanations in the chat.

## What you can ask

Ask the way you'd ask someone looking over your shoulder:

- *"How do I change the screen brightness schedule in KDE? Show me."*
- *"Where are this app's keyboard shortcuts? Point at it."*
- *"Explain how a web page gets from the server to my browser, on the whiteboard."*
- *"Review this dialog: mark anything that looks wrong."*
- *"Read AppGlider's user guide and make a tutorial for adding a GitHub repo."*

## What to expect

- **On your screen**, Claude circles the right control, adds a short label or numbered
  steps, and explains *why* in the chat. After each step, tell it "done" (or what
  happened); it takes a screenshot to check and shows the next step.
- **On the whiteboard**, it draws a small lesson that stands on its own (title, diagram,
  numbered notes), because the board covers the chat. **Ctrl+W** takes you back to your
  desktop and **Esc** closes it.
- **Its colours mean something**: green for "do this", blue for "look here", red for
  "not this one".
- **Its marks are kept apart from your drawing.** It removes only its own when it moves
  on, and you can undo or erase them like anything else. Closing Inkpane clears
  everything.
- **Inkpane opens in click-through for the AI**, so your mouse and keyboard stay yours.
- **By default the AI can only draw**: you do every click.

## Tutorials

Ask Claude to *make a tutorial* and it writes one from your real app:

1. It reads the docs you point it at and plans the steps, then checks the plan with you.
2. For each step, it puts a numbered callout card next to the control and saves an image
   of the app's window (only the window, never the rest of your desktop). Then you
   click, and it checks the result.
3. At the end you get a folder with `tutorial.md` and the step images, written for
   other people to follow.

Want a video too? Start Spectacle or OBS before you begin: Claude's marks are really on
screen, so they're in the recording.

## Letting the AI click (opt-in)

If you'd rather Claude stepped through a task by itself, for example to make a
tutorial while you watch, add these lines to Inkpane's settings file,
`~/.config/inkpane/inkpane.conf` (they aren't there by default, and without them the AI
never clicks):

```ini
[ai]
clicking = yes
```

- **Every new Claude session** that wants to click asks first: your desktop shows its
  "allow input control" dialog, and nothing is remembered between sessions. KDE also
  shows when something is controlling the mouse.
- **Before each action**, Claude says what it is about to do, and it checks a screenshot
  afterwards.
- **It asks you first** before anything that deletes, pays, sends or installs, and it
  never types passwords.
- **Inkpane must be in click-through** for clicks to reach your apps. Clicks that would
  draw, or land on Inkpane's toolbar, are refused.
- **Typing goes through the clipboard** (install `wl-clipboard`): the text is pasted,
  so any language and keyboard layout works, and your clipboard is put back afterwards.
- **Turning it off:** delete the lines (or set `clicking = no`). That takes effect
  immediately.
- **Asking Claude to set it up** is fine: it shows you the lines and adds them only when
  you say so. It never turns clicking on by itself. Either way, it can't click until you
  answer the desktop's dialog, which it has no way to click itself.

## Privacy

- A screenshot shows your screen to the AI. Claude asks before its first one and says
  whenever it takes one, and only takes them while helping you.
- Images it saves (tutorials) are cropped to the app's window.
- Screenshots go through your desktop's screenshot permission. The first one asks you.

## Other MCP clients

`inkpane-mcp` is a standard MCP server on stdio. To add only the server to Claude Code,
without the skill, run `claude mcp add inkpane -- inkpane-mcp`. Coordinates are pixels of
the latest screenshot of a monitor, origin top-left.

| Tool | Does |
|---|---|
| `screen_info` | Monitors and the size of each one's screenshot |
| `screenshot` | One monitor, with the AI's marks, without Inkpane's toolbar |
| `draw` | Rectangle, ellipse, diamond, arrow, line, highlighter or pen; cards with `fill_color`, labels on boxes and arrows; shapes by `center` and `radius` |
| `batch` | Many marks in one call, with shared `defaults`, optionally on a board; one undo step |
| `circle` | Frames a control from its own box, with an optional label outside |
| `callout` | A step card with an arrow to a control and a step number |
| `add_text`, `add_step_marker` | Text (optionally wrapped or centred) and numbered markers |
| `save_screenshot` | Saves a full-resolution image of an area to a file |
| `undo_last`, `clear`, `set_board`, `close` | Remove the last call's marks, clear, show a board, close |
| `click`, `scroll`, `type_text`, `press_keys` | Only with `[ai] clicking = yes` |

Size: `inkpane-mcp` is about 236 KB, with no SDL. It talks to the running Inkpane over
D-Bus.

## Troubleshooting

- **"Inkpane is not running":** `inkpane-mcp` starts Inkpane when needed. It looks next
  to itself and then on your PATH. Check that both are installed:
  `which inkpane inkpane-mcp`.
- **Screenshots fail or time out:** your desktop's permission dialog may be waiting
  behind another window. Allow it and try again.
- **Clicks are refused:** Inkpane is in drawing mode (press **1** or **V** for
  click-through), or the spot is under Inkpane's toolbar (drag it away or hide it with
  **Tab**).
