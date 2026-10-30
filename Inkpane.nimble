# Package

version       = "0.0.1"
author        = "Vyrnexis"
description   = "Draw on your screen through a transparent Wayland overlay"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["inkpane", "inkpane_mcp"]


# Dependencies

requires "nim >= 2.2.0"
# Pinned to the commit packaging/aur/PKGBUILD builds with.
requires "https://github.com/nim-lang/sdl3#533d22196dab2ea637ea0131171ed3f8db61fe90"

task Release, "Build small, stripped binaries into ./bin":
  mkDir("bin")
  # -Os + link-time optimisation + strip: about half the size of plain -d:release.
  # Drawing runs on the GPU, so optimising for size costs nothing noticeable.
  const flags = "nim c -d:release --opt:size --passC:-flto --passL:-flto --passL:-s "
  exec flags & "--out:bin/inkpane src/inkpane.nim"
  exec flags & "--out:bin/inkpane-mcp src/inkpane_mcp.nim"

task Debug, "Build debug binaries into ./bin":
  mkDir("bin")
  exec "nim c --out:bin/inkpane src/inkpane.nim"
  exec "nim c --out:bin/inkpane-mcp src/inkpane_mcp.nim"

task Protocols, "Regenerate the Wayland protocol code with wayland-scanner":
  const dir = "src/inkpane/wayland/"
  # xdg-shell is only needed for its interface table (layer-shell refers to xdg_popup).
  for name in ["wlr-layer-shell-unstable-v1", "xdg-shell"]:
    exec "wayland-scanner private-code " & dir & "protocols/" & name & ".xml " &
      dir & "generated/" & name & "-protocol.c"
  exec "wayland-scanner client-header " & dir & "protocols/wlr-layer-shell-unstable-v1.xml " &
    dir & "generated/wlr-layer-shell-unstable-v1-client-protocol.h"
