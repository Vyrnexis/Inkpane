# Package

version       = "0.0.1"
author        = "Vyrnexis"
description   = "Draw on your screen through a transparent Wayland overlay"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["nimotate"]


# Dependencies

requires "nim >= 2.2.0"
requires "https://github.com/nim-lang/sdl3"

task Release, "Build a small, stripped binary into ./bin":
  mkDir("bin")
  # -Os + link-time optimisation + strip: about half the size of plain -d:release.
  # Drawing runs on the GPU, so optimising for size costs nothing noticeable.
  exec "nim c -d:release --opt:size --passC:-flto --passL:-flto --passL:-s " &
    "--out:bin/nimotate src/nimotate.nim"

task Debug, "Build a debug binary into ./bin":
  mkDir("bin")
  exec "nim c --out:bin/nimotate src/nimotate.nim"

task Protocols, "Regenerate the Wayland protocol code with wayland-scanner":
  for name in ["wlr-layer-shell-unstable-v1", "xdg-shell"]:
    let xml = "src/nimotate/wayland/protocols/" & name & ".xml"
    exec "wayland-scanner client-header " & xml & " src/nimotate/wayland/generated/" & name & "-client-protocol.h"
    exec "wayland-scanner private-code " & xml & " src/nimotate/wayland/generated/" & name & "-protocol.c"
