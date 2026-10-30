# Inkpane user guide

Everything Inkpane does, and how to get the most out of it. For installation see the
[README](README.md).

- [The basics](#the-basics)
- [Drawing tools](#drawing-tools)
- [Text and step markers](#text-and-step-markers)
- [Colour, width and fill](#colour-width-and-fill)
- [Fixing mistakes](#fixing-mistakes)
- [Click-through](#click-through)
- [Whiteboard and blackboard](#whiteboard-and-blackboard)
- [The toolbar](#the-toolbar)
- [Several monitors](#several-monitors)
- [Settings](#settings)
- [Controlling Inkpane from scripts](#controlling-inkpane-from-scripts)
- [Tips for screen recordings](#tips-for-screen-recordings)
- [Troubleshooting](#troubleshooting)

## The basics

Inkpane waits in the background with an icon in the system tray. It has three states:

```
          Meta+Z                      1 / V
 Closed ─────────▶ Drawing ─────────────────────▶ Click-through
   ▲                │  ▲                              │
   │   Meta+Z or    │  │  Meta+Z, or click a tool     │
   └──── Esc ───────┘  └──── in the toolbar ──────────┘
   (clears everything)
```

- **Closed**: nothing on screen, nothing intercepted.
- **Drawing**: a transparent layer covers every monitor, panels included. It takes the
  mouse and keyboard, so everything you do draws.
- **Click-through**: the drawing stays visible, but the mouse and keyboard go to the apps
  underneath. See [Click-through](#click-through).

Closing always clears: nothing stays on your screen afterwards, and there is nothing
to save or tidy up.

**Meta+Z** (the Windows/Super key and Z) is the main key. What it does depends on the state:

| Now | Meta+Z |
|---|---|
| Closed | Start drawing |
| Drawing | Close and clear |
| Click-through | Back to drawing, drawing kept |

A **left click on the tray icon** and `inkpane --toggle` do exactly the same. The tray
icon's **right-click menu** has *Start Drawing* / *Stop Drawing*, which always do what
they say, and *Quit Inkpane*.

The first time, KDE asks you to confirm the shortcut. To use another key, change it in
System Settings → Shortcuts → Inkpane.

**Esc** closes and clears from drawing mode (in click-through, Esc goes to the app you
are using, like any other key).

## Drawing tools

Pick a tool with its number key, its letter, or the toolbar. The number keys work by
position, so on AZERTY and other layouts it is the key where 2, 3, … would be. The keys
follow [Excalidraw](https://excalidraw.com), so if you know it you know Inkpane.

| Key | Tool | Use it for |
|---|---|---|
| 2 / R | **Rectangle** | Boxing a button, a window or a region |
| 3 / D | **Diamond** | Decisions in a quick diagram, or just variety |
| 4 / O | **Ellipse** | Circling something |
| 5 / A | **Arrow** | Pointing at things |
| 6 / L | **Line** | Underlining, connecting |
| 7 / P | **Pen** | Freehand: ticks, crosses, handwriting (the default) |
| 8 / T | **Text** | Labels, see [Text and step markers](#text-and-step-markers) |
| 9 / H | **Highlighter** | Marking a line of text or code |
| N | **Step marker** | Numbered circles 1, 2, 3 for walkthroughs |
| 0 / E | **Eraser** | Removing whole items |

The pointer previews what you will get at its real size: a ring as wide as the pen, the
eraser or the step marker, or a text cursor as tall as a line of text.

**Shapes, arrows, lines and the highlighter** are dragged from one corner or end to the
other. Hold modifiers while dragging (you can press and release them mid-drag):

| Hold | Rectangle, diamond, ellipse | Arrow, line, highlighter |
|---|---|---|
| Shift | Square, equal-sided diamond, circle | Snap to 15° steps (perfectly level, upright, 45°…) |
| Ctrl | Draw from the centre outwards | — |

A click without dragging draws nothing, so a stray click with a shape tool is harmless.

**The pen** smooths out the jitter of your hand and mouse without lagging behind. It
ends exactly where you let go.

**The highlighter** is a straight, wide, see-through bar in the current colour. Drag it
along a line of text; hold Shift to keep it perfectly level. Yellow (Shift+3) is the
classic choice. Where two bars cross they get darker, like a real highlighter.

**The eraser** removes every item it touches as you drag over them: a whole stroke,
shape or text at a time. You do not need to switch to it: **a right drag erases** with
any tool.

## Text and step markers

Both need SDL3_ttf, see [Troubleshooting](#text-tools-do-nothing).

**Text** (8 / T):

1. Click where the text should start. The first line is centred on the pointer.
2. Type. A hint under the text reminds you of the keys:
   - **Enter** finishes the text,
   - **Shift+Enter** starts a new line,
   - **Backspace** deletes,
   - **Ctrl+V** pastes,
   - **Esc** cancels and removes it.
3. A click anywhere else also finishes it (and with the text tool, starts the next one).

While typing, keys type rather than switching tools, so you can write "Press R" without
picking the rectangle.

The text size follows the width (`[` `]` or the mouse wheel): the default width gives
27 px text. Text has a thin halo, dark behind light colours and light behind dark ones,
so it stays readable over any background.

**Step markers** (N) are filled circles with a number. Each click places the next one:
1, 2, 3. Undo a marker and its number is free again, so the next click reuses it. Their
size also follows the width.

## Colour, width and fill

- **Colour**: Shift+1 to Shift+8, or the colour dots in the toolbar. The default
  palette is red, orange, yellow, green, blue, purple, white and black; you can change
  it in the [settings](#settings).
- **Width**: `[` and `]`, the mouse wheel, or the three width buttons in the toolbar.
  It applies to the next thing you draw, not to what is already there.
- **Fill** (F, or the shape button in the toolbar): rectangles, diamonds and ellipses
  are drawn solid instead of outlined. Useful to cover something you do not want on a
  recording. The button shows the current shape solid or outlined, and is greyed out
  while a tool without an inside is selected.

## Fixing mistakes

| Key | Action |
|---|---|
| Ctrl+Z | Undo |
| Ctrl+Shift+Z or Ctrl+Y | Redo |
| Right drag, or the eraser | Remove items |
| C or Delete | Clear everything, keep drawing |
| Esc | Clear everything and close |

Erasing can be undone too: each item the eraser removes is one undo step.

## Click-through

Click-through keeps your drawing on screen while you use the apps underneath it. It is
made for walkthroughs: draw an arrow to a button, then actually click that button,
then draw the next step.

1. Draw your annotation.
2. Press **1** or **V**, or click the cursor button at the left of the toolbar.
3. Use your apps normally: click, scroll and type, even where you drew. Your drawing
   stays on top.
4. To draw again, either:
   - **click a tool in the toolbar**: you are drawing again with that tool, or
   - press **Meta+Z**: you are drawing again with the same tool as before.

The toolbar is the only part of the overlay that still takes clicks in click-through.
If you hid it (Tab) before switching, use Meta+Z to come back.

Why not press 1 again? In click-through the keyboard belongs to the app you are using,
so Inkpane cannot hear ordinary keys. Only the global shortcut and the tray reach it.

## Whiteboard and blackboard

- **Ctrl+W** fills the screen with a whiteboard, **Ctrl+B** with a blackboard.
- The same key again goes back to drawing over your desktop.

Your drawing stays when you switch. White ink on the whiteboard is shown black, and black
ink on the blackboard is shown white, so nothing disappears; switch back and it has its
own colour again.

## The toolbar

The toolbar floats at the top centre of each monitor, low enough to clear a top panel:

```
 cursor │ tools … │ fill │ colours … │ widths
```

- Click a button to pick it; the current choices are highlighted.
- Rest the pointer on a button for its name and keys.
- **Drag the toolbar by its background** (between the buttons) to move it anywhere.
  It stays there, also after a restart.
- It steps out of the way while you draw near it, and comes back when you let go.
- **Tab** hides and shows it; you can also start with it hidden (see [Settings](#settings)).
- **F1** shows a cheat sheet of every key; F1 or Esc hides it.

## Several monitors

Inkpane covers every monitor at once, each at its own scale.

- What you draw belongs to the monitor you drew it on.
- **Undo and redo** work on one monitor: the one with the keyboard focus, normally the
  one you last clicked on.
- **Clear**, colours, tools, the board and click-through apply to all monitors.
- The toolbar is on every monitor, at the same place.

## Settings

The settings file is `~/.config/inkpane/inkpane.conf`. Inkpane writes it the first
time it starts, with every setting and a comment explaining it. Edit it with any text
editor and restart Inkpane (`inkpane --quit`, then start it again).

```ini
[colors]
# Up to 8 colours, picked with Shift+1 .. Shift+8 and shown in the toolbar.
palette = "#ed3333 #fa8c21 #fad926 #33c759 #3385fa #9e59e6 #ffffff #0d0d0d"
# Colour selected at start: 1 is the first in the palette.
start = 1

[pen]
# Width in logical pixels at start, and the toolbar's three width presets.
width = 6
presets = "2 6 14"
# Tool at start: pen, line, arrow, highlighter, rectangle, diamond, ellipse, text,
# marker or eraser.
tool = pen
# Fill rectangles, diamonds and ellipses at start (F toggles it).
fill = no

[toolbar]
# Show the toolbar at start (Tab toggles it). Drag its background to move it.
visible = yes

[text]
# Font file for text, step markers, tooltips and the F1 help. Empty: the desktop's
# default sans-serif font. Text needs SDL3_ttf (package sdl3_ttf or libsdl3-ttf).
font = ""
```

- Delete a line to get its default back; delete the file to get a fresh, fully
  commented one.
- A value Inkpane does not understand is reported (in the terminal, if you started it
  from one) and the default is used instead.
- Where you dragged the toolbar is kept separately in `~/.local/state/inkpane/state`,
  so Inkpane never rewrites your settings file.

## Controlling Inkpane from scripts

The first `inkpane` you start stays running; running it again talks to that one:

| Command | Does |
|---|---|
| `inkpane` | Starts Inkpane, or toggles drawing if it is already running |
| `inkpane --toggle` | Same as Meta+Z |
| `inkpane --on` | Start drawing (or back to drawing from click-through) |
| `inkpane --off` | Close and clear |
| `inkpane --quit` | Quit Inkpane |

Starting Inkpane from the app menu while it is running also toggles drawing.

On compositors without the global-shortcut portal (Sway, niri and others), bind
`inkpane --toggle` to a key in the compositor's own config, for example in Sway:

```
bindsym $mod+z exec inkpane --toggle
```

## Tips for screen recordings

- Any recorder captures Inkpane (OBS, Spectacle, Kooha, …): the drawing really is on
  the screen, so there is nothing to configure.
- The cursor ring and the toolbar are recorded too. Hide the toolbar with **Tab** for a
  cleaner video; the keys still work.
- Use **click-through** to show a step and then do it, without cutting the recording.
- **Step markers** plus short **text** labels make walkthroughs easy to follow.
- The **whiteboard** (Ctrl+W) gives you a clean page to sketch on mid-recording, and
  Ctrl+W again brings your desktop back with the drawing intact.
- **Esc** wipes everything instantly between scenes.

## Troubleshooting

### Meta+Z does nothing

- Inkpane has to be **installed** (`scripts/install-user.sh` or the package): the desktop
  only gives global shortcuts to apps with an installed `.desktop` file.
- The first time, KDE shows a dialog to confirm the shortcut; check it was not dismissed.
  You can also set it in System Settings → Shortcuts → Inkpane.
- On desktops without the global-shortcut portal, bind `inkpane --toggle` yourself (see
  [Controlling Inkpane from scripts](#controlling-inkpane-from-scripts)). The tray icon
  always works.

### Text tools do nothing

Text, step markers, tooltips and the F1 help need **SDL3_ttf**, which is a separate
package. Inkpane tells you once with a notification. Install it and restart Inkpane:

- Arch: `sudo pacman -S sdl3_ttf`
- Debian / Ubuntu: `sudo apt install libsdl3-ttf0` (name may vary by release)
- Fedora: `sudo dnf install SDL3_ttf`

Inkpane finds your desktop's default font through fontconfig. To use another, set
`font =` in the settings to the path of a `.ttf` or `.otf` file.

### "Needs a Wayland session" or the overlay does not appear

Inkpane needs a Wayland desktop with the layer-shell protocol: KDE Plasma, Hyprland,
Sway, niri, COSMIC and others. GNOME and X11 sessions do not have it yet.

### No tray icon

The tray uses the StatusNotifierItem standard. KDE shows it out of the box; on Sway or
Hyprland you need a bar with a tray, such as Waybar. Inkpane works without a tray
anyway: use Meta+Z or `inkpane --toggle`.

### Where are the error messages?

Errors that need your attention appear as desktop notifications. Start Inkpane from a
terminal (`inkpane --quit; inkpane`) to see everything it reports, including settings
it could not read.
