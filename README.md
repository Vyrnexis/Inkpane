# Nimotate

Draw on your screen through a transparent Wayland overlay — for tutorials, presentations
and screen recordings. Written in Nim with SDL3 and the wlr-layer-shell protocol.

> Status: **phase 1 in progress.** Runs in the background with a tray icon; toggle the
> overlay with Meta+Z, a tray click, or `nimotate --toggle`. Pen, shapes and eraser work;
> highlighter, toolbar and text are planned.

## Requirements

- A Wayland desktop with layer-shell: KDE Plasma, Hyprland, Sway, niri, COSMIC
  (not GNOME or X11 sessions yet)
- SDL3 (3.2+), libwayland-client, GLib/GIO (no GTK)
- Nim 2.2+, and `wayland-scanner` only if you regenerate the protocol code

## Build and install

```bash
nimble install https://github.com/nim-lang/sdl3
nimble Release
scripts/install-user.sh        # or: scripts/install-user.sh --autostart
nimotate &
```

Installing matters: the desktop portal only grants the global shortcut to apps with an
installed `.desktop` file. `scripts/uninstall-user.sh` removes everything again.

## Using it

- **Meta+Z**, a left click on the tray icon, or `nimotate --toggle` turns drawing on/off.
  The first time, KDE may ask you to confirm the shortcut; you can change it later in
  System Settings → Shortcuts.
- Turning drawing off (or Esc) closes the overlay and clears the drawing.
- Right-click the tray icon for Start/Stop Drawing and Quit.
- `nimotate --on`, `--off`, `--quit` control a running instance; launching Nimotate again
  from the app menu toggles drawing.

### Keys while drawing

| Key | Action |
|---|---|
| Left drag | Draw with the current tool |
| 2 / R, 3 / D, 4 / O | Rectangle, diamond, ellipse (Shift = square/circle, Ctrl = from centre) |
| 5 / A, 6 / L | Arrow, line (Shift snaps to 15°) |
| 7 / P | Pen (the default) |
| 0 / E | Eraser: removes every item it touches |
| Shift+1–8 | Colour (red, orange, yellow, green, blue, purple, white, black) |
| `[` `]` / wheel | Thinner / thicker |
| Ctrl+Z, Ctrl+Shift+Z / Ctrl+Y | Undo, redo |
| C / Delete | Clear, keep drawing |
| Esc | Stop drawing |

## License

MIT. The Wayland protocol XML files in `src/nimotate/wayland/protocols/` keep their own licences.
