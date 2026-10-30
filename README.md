# Nimotate

Draw on your screen through a transparent Wayland overlay, for tutorials, presentations
and screen recordings. Press a key, draw arrows, boxes, highlights and text over anything,
press it again and it is gone. Any screen recorder captures it, because the drawing
really is on screen.

Nimotate is small and fast on purpose: a 240 KB binary that idles at about 10 MB of
memory and no CPU, with the tools people actually use and nothing else. Its keys follow
[Excalidraw](https://excalidraw.com), with clean shapes instead of hand-drawn ones.

Written in Nim with SDL3 and the wlr-layer-shell protocol.

## Requirements

- A Wayland desktop with layer-shell: KDE Plasma, Hyprland, Sway, niri, COSMIC.
  GNOME and X11 sessions are not supported yet.
- SDL3 (3.2+), libwayland-client and GLib/GIO (no GTK).
- Optional: SDL3_ttf (`sdl3_ttf` on Arch, `libsdl3-ttf` on Debian/Ubuntu) for text, step
  markers, toolbar tooltips and the F1 help. Without it everything else works, and
  Nimotate tells you what to install the first time you reach for text.
- To build: Nim 2.2+ (and `wayland-scanner` only to regenerate the protocol code).

## Build and install

```bash
nimble install https://github.com/nim-lang/sdl3
nimble Release
scripts/install-user.sh        # or: scripts/install-user.sh --autostart
nimotate &
```

Installing matters: the desktop portal only grants the global shortcut to apps with an
installed `.desktop` file. `scripts/uninstall-user.sh` removes everything again. On Arch,
`packaging/aur/PKGBUILD` builds a system-wide package instead.

## How it works

Nimotate runs in the background with a tray icon. The overlay has three states:

```
          Meta+Z                      1 / V
 Closed ─────────▶ Drawing ─────────────────────▶ Click-through
   ▲                │  ▲                              │
   │   Meta+Z or    │  │  Meta+Z, or click a tool     │
   └──── Esc ───────┘  └──── in the toolbar ──────────┘
   (clears everything)
```

- **Closed**: nothing on screen.
- **Drawing**: the overlay covers every monitor and takes the mouse and keyboard.
- **Click-through**: your drawing stays on screen, but clicks and typing go to the apps
  underneath. Use it to annotate a step, then click through to actually do it. Only the
  toolbar still takes clicks.

**Meta+Z does two jobs**, depending on where you are:

| You are in | Meta+Z (or a tray click, or `nimotate --toggle`) |
|---|---|
| Closed | Opens the overlay: drawing |
| Drawing | **Closes the overlay and clears the drawing** |
| Click-through | **Goes back to drawing**, with your drawing kept |

So from click-through, press Meta+Z once to keep drawing, twice to close. Esc always
closes and clears (when you are drawing; in click-through Esc goes to the app below).

In click-through the overlay cannot hear any keys (they go to the app you are using),
which is why getting back is Meta+Z or a click on the toolbar, not a key like 1 again.

The first time, KDE may ask you to confirm the Meta+Z shortcut; you can change it later
in System Settings → Shortcuts. Right-click the tray icon for Start/Stop Drawing and
Quit. `nimotate --on`, `--off` and `--quit` control a running instance.

## Tools and keys

The toolbar shows every tool with its number key; rest the pointer on a button for its
name and keys, or press **F1** for all keys. Number keys work by position, so they also
work on AZERTY and other layouts.

| Key | Tool |
|---|---|
| 1 / V | Click-through (see above) |
| 2 / R | Rectangle |
| 3 / D | Diamond |
| 4 / O | Ellipse |
| 5 / A | Arrow |
| 6 / L | Line |
| 7 / P | Pen (the default) |
| 8 / T | Text: click and type. Enter finishes, Shift+Enter starts a new line, Esc cancels, Ctrl+V pastes |
| 9 / H | Highlighter: a straight, see-through bar |
| N | Step marker: each click places the next numbered circle |
| 0 / E | Eraser: removes every item it touches |

| Key | While drawing |
|---|---|
| Shift while dragging | Square, circle, equal-sided diamond; lines, arrows and highlights snap to 15° |
| Ctrl while dragging | Rectangle, diamond or ellipse from its centre |
| Right drag | Erase, whatever the tool |
| Shift+1 … Shift+8 | Colour (red, orange, yellow, green, blue, purple, white, black) |
| `[` `]` or wheel | Thinner / thicker (text and markers follow it) |
| F | Fill rectangles, diamonds and ellipses on/off |
| Ctrl+Z, Ctrl+Shift+Z or Ctrl+Y | Undo, redo |
| C or Delete | Clear, keep drawing |
| Ctrl+W / Ctrl+B | Whiteboard / blackboard; the same key again shows the desktop. White or black ink flips so it stays visible |
| Tab | Hide/show the toolbar |
| F1 | Cheat sheet |
| Esc | Close and clear |

Drag the toolbar by its background to move it.

## Settings

On first run Nimotate writes `~/.config/nimotate/nimotate.conf`, with every setting and
a comment explaining it: the palette, the width and its three toolbar presets, the
tool, fill and toolbar visibility at start, and the font for text. Edit it by hand and
restart Nimotate; a line you delete goes back to its default, and a bad value is
reported and ignored.

Where you dragged the toolbar is remembered in `~/.local/state/nimotate/state`, kept
apart so Nimotate never rewrites your settings file.

## Size and speed

Measured on a release build (x86-64, KDE Plasma):

| | |
|---|---|
| Binary | 240 KB, linking only SDL3, libwayland-client and libc (GLib is opened at start, SDL3_ttf only when text is first used) |
| Idle in the background | ~10 MB resident, of which ~1.5 MB is Nimotate's own; 0 % CPU (it sleeps until D-Bus, the shortcut or the tray wakes it) |
| Drawing | ~8 µs to add a pen point; the drawing is cached as one triangle mesh per monitor, drawn in a single call |
| Undo or erase on a busy screen | under 4 ms to rebuild 30 000 points |

Everything is drawn with triangles, anti-aliased by a one-pixel fading edge instead of
multisampling, so no extra screen-sized buffers are needed. Toolbar icons are drawn the
same way: no icon files, no icon font.

## License

MIT. The Wayland protocol XML files in `src/nimotate/wayland/protocols/` keep their own licences.
