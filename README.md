# Inkpane

**Draw on your screen** — for tutorials, presentations and screen recordings on Linux
Wayland desktops. Press a key, circle the button, add an arrow and a label, click
through to show it working, press the key again and it is gone.

<p align="center"><img src="assets/demo.gif" alt="Inkpane on KDE Plasma annotating AppGlider: a highlight, a label and arrow, clicking through to the Updates page, step markers, an ellipse around Update all, and a pen underline" width="800"></p>

## Why Inkpane

- **Small and fast.** A 245 KB program that waits in the tray at about 10 MB of memory
  and no CPU. Drawing is one cached mesh per monitor, anti-aliased, at full refresh rate.
- **The tools people actually use.** Pen, rectangle, diamond, ellipse, arrow, line,
  highlighter, text, numbered step markers and an eraser, with a whiteboard and
  blackboard. No selection, no layers, nothing to save: annotate, then it is gone.
- **Excalidraw's keys.** Tools on the number keys and letters (2 / R rectangle, 5 / A
  arrow, 7 / P pen …), Shift for squares and 15° angles, Ctrl from the centre.
- **Click-through.** Keep your drawing on screen while you click and type in the app
  below it, then carry on drawing: show a step, do it, show the next.
- **Screenshots with your notes on them.** Ctrl+S, drag an area (or click for the whole
  screen): saved to Pictures/Inkpane and copied to the clipboard, ready to paste.
- **Recorder-friendly.** The drawing really is on screen, so OBS, Spectacle or any
  recorder captures it with no setup.

## Quick start

| Key | |
|---|---|
| **Meta+Z** | Start drawing · from click-through: back to drawing · while drawing: close and clear |
| 2–0 or R D O A L P T H E, N | Pick a tool (the toolbar shows them all) |
| Shift+1–8 | Colour |
| `-` `+`, `[` `]` or wheel | Thinner / thicker |
| F | Fill rectangles, diamonds and ellipses |
| Shift / Ctrl while dragging | Square, snap to 15° / draw from the centre |
| Right drag | Erase |
| Ctrl+Z | Undo |
| Ctrl+Shift+Z or Ctrl+Y | Redo |
| C or Delete | Clear (Ctrl+Z brings it back) |
| 1 / V | Click-through: apps get the mouse and keys, your drawing stays |
| Ctrl+W / Ctrl+B | Whiteboard / blackboard |
| Ctrl+S | Screenshot: drag an area, or click for the whole screen |
| Tab | Hide or show the toolbar |
| F1 | Every key, on screen |
| Esc | Cancel the shape being drawn, or close and clear (Ctrl+Z next time brings it back) |

The [user guide](GUIDE.md) explains every tool, click-through, the boards, settings,
scripting and troubleshooting.

## Requirements

- A Wayland desktop with layer-shell: **KDE Plasma, Hyprland, Sway, niri, COSMIC**.
  GNOME and X11 sessions are not supported yet.
- SDL3 (3.2+), libwayland-client and GLib/GIO. No GTK, no Qt.
- Optional: **SDL3_ttf** for text, step markers, tooltips and the F1 help
  (`sdl3_ttf` on Arch). Everything else works without it.
- Screenshots need SDL 3.4 (or SDL3_image) and the desktop's screenshot portal;
  `wl-clipboard` makes copying them to the clipboard more reliable.

## Install

**Arch Linux (AUR):** the [`inkpane-git`](https://aur.archlinux.org/packages/inkpane-git)
package builds the latest version:

```bash
yay -S inkpane-git             # or paru, or any AUR helper
```

**NixOS (flake):** try it with `nix run github:Vyrnexis/Inkpane`, or install it so the
desktop finds its launcher (needed for the Meta+Z shortcut):

```nix
# flake.nix inputs
inkpane.url = "github:Vyrnexis/Inkpane";
inkpane.inputs.nixpkgs.follows = "nixpkgs";

# configuration.nix, or home.packages in Home Manager
environment.systemPackages = [ inputs.inkpane.packages.${pkgs.stdenv.hostPlatform.system}.default ];
```

The flake builds its own Wayland-only SDL3, without audio, X11 and zenity, so it adds
about 100 MB with its dependencies instead of 1 GB. That takes a minute or two the first
time, as no binary cache has it.

**Any other distribution:** download `inkpane-<version>-x86_64-linux.tar.gz` from the
[releases page](https://github.com/Vyrnexis/Inkpane/releases), then:

```bash
tar xf inkpane-*-x86_64-linux.tar.gz
cd inkpane-*/
scripts/install-user.sh        # or: scripts/install-user.sh --autostart
inkpane &
```

The binaries run on any 64-bit x86 Linux with glibc 2.34 or newer. They use your
distribution's SDL3, which recent releases package (for example Debian 13, Ubuntu 25.04
and Fedora 42); install it and the other [requirements](#requirements) first.

**From source** (needs Nim 2.2+):

```bash
nimble install https://github.com/nim-lang/sdl3
nimble Release
scripts/install-user.sh        # or: scripts/install-user.sh --autostart
inkpane &
```

With choosenim's Nim on Arch, you can also build the package in
[`packaging/aur`](packaging/aur/PKGBUILD) with `makepkg -si --nodeps`.

This installs `inkpane` (and the optional `inkpane-mcp`, see below). Installing matters: the
desktop only grants the Meta+Z shortcut to apps with an installed `.desktop` file.
`scripts/uninstall-user.sh` removes everything again.

The first time you press Meta+Z, KDE asks you to confirm the shortcut. On compositors
without the shortcut portal, bind `inkpane --toggle` to a key yourself (see the
[guide](GUIDE.md#controlling-inkpane-from-scripts)).

## Size and speed

Measured on a release build (x86-64, KDE Plasma):

| | |
|---|---|
| Binary | 245 KB; links only SDL3, libwayland-client and libc |
| Runs on | Any 64-bit x86 CPU (no AVX needed) with glibc 2.34 or newer |
| Idle in the background | ~10 MB resident (~1.5 MB of it Inkpane's own), 0 % CPU |
| Drawing | ~8 µs per pen point; one draw call per monitor per frame |
| Undo or erase on a busy screen | under 4 ms to rebuild 30 000 points |

Lines and shapes are triangles with a one-pixel fading edge for anti-aliasing, so no
screen-sized multisample buffers are needed. Toolbar icons are drawn the same way: no
icon files, no icon font. GLib is opened at start and SDL3_ttf only when text is first
used.

## Optional: use it with AI

`inkpane-mcp` lets an AI assistant such as Claude Code use Inkpane too: point at things
on your screen, explain on a whiteboard, or make a tutorial from your real app. It is
separate and optional; see [AI.md](AI.md).

## License

Copyright (C) 2026 Vyrnexis. Inkpane is free software under the
[GNU General Public License v3.0 or later](LICENSE): you may use, study, share and change
it, and anything built from it must stay free under the same terms. The Wayland protocol
XML files in `src/inkpane/wayland/protocols/` (and the code generated from them) keep
their own licences.
