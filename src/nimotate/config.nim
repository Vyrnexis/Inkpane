import std/[os, parsecfg, streams, strutils]

import sdl3

import draw/scene

# Settings the user edits by hand, in ~/.config/nimotate/nimotate.conf, and what Nimotate
# remembers by itself (where the toolbar was dragged), in ~/.local/state/nimotate/state.
# They are kept apart so Nimotate never rewrites the user's file or its comments.
#
# The defaults are the commented file below: it is written out on first run and also
# parsed first, so a missing or partial file falls back to exactly what it documents.

const DefaultConfig = """
# Nimotate settings. Delete a line to get its default back.
# Changes apply the next time Nimotate starts.

[colors]
# Up to 8 colours, picked with Shift+1 .. Shift+8 and shown in the toolbar.
palette = "#ed3333 #fa8c21 #fad926 #33c759 #3385fa #9e59e6 #ffffff #0d0d0d"
# Colour selected at start: 1 is the first in the palette.
start = 1

[pen]
# Width in logical pixels at start, and the toolbar's three width presets.
width = 6
presets = "2 6 14"
# Tool at start: pen, line, arrow, highlighter, rectangle, diamond, ellipse or eraser.
tool = pen
# Fill rectangles, diamonds and ellipses at start (F toggles it).
fill = no

[toolbar]
# Show the toolbar at start (Tab toggles it). Drag its background to move it.
visible = yes
"""

type
  Settings* = object
    palette*: seq[FColor]
    color*: int            # index into palette
    width*: float32
    presets*: array[3, float32]
    tool*: Tool
    fill*: bool
    toolbar*: bool

proc configPath*(): string =
  getConfigDir() / "nimotate" / "nimotate.conf"

proc statePath(): string =
  getEnv("XDG_STATE_HOME", getHomeDir() / ".local" / "state") / "nimotate" / "state"

proc warn(message: string) =
  stderr.writeLine("nimotate: " & configPath() & ": " & message)

proc parseColor(text: string): FColor =
  let hex = text.strip(chars = {'#', ' '})
  if hex.len != 6:
    raise newException(ValueError, "not a #rrggbb colour: " & text)
  let value = parseHexInt(hex)
  FColor(r: float32((value shr 16) and 255) / 255, g: float32((value shr 8) and 255) / 255,
         b: float32(value and 255) / 255, a: 1)

proc parseBool(text: string): bool =
  case text.toLowerAscii
  of "yes", "true", "on", "1": true
  of "no", "false", "off", "0": false
  else: raise newException(ValueError, "expected yes or no: " & text)

proc apply(settings: var Settings, file: Config) =
  ## Copies every valid value from `file`; a bad one is reported and the current value kept.
  template read(section, key: string, body: untyped) =
    block:
      let raw {.inject.} = file.getSectionValue(section, key)
      if raw.len > 0:
        try:
          body
        except ValueError:
          warn("[" & section & "] " & key & ": " & getCurrentExceptionMsg())
  read("colors", "palette"):
    var palette: seq[FColor]
    for word in raw.splitWhitespace:
      palette.add(parseColor(word))
    if palette.len notin 1 .. 8:
      raise newException(ValueError, "needs 1 to 8 colours")
    settings.palette = palette
  read("colors", "start"):
    settings.color = clamp(parseInt(raw) - 1, 0, settings.palette.high)
  read("pen", "width"):
    settings.width = clamp(parseFloat(raw), 1, 64)
  read("pen", "presets"):
    let words = raw.splitWhitespace
    if words.len != 3:
      raise newException(ValueError, "needs 3 widths")
    for i, word in words:
      settings.presets[i] = clamp(parseFloat(word), 1, 64)
  read("pen", "tool"):
    var found = false
    for tool in Tool:
      if cmpIgnoreCase($tool, raw) == 0:
        settings.tool = tool
        found = true
    if not found:
      raise newException(ValueError, "unknown tool: " & raw)
  read("pen", "fill"):
    settings.fill = parseBool(raw)
  read("toolbar", "visible"):
    settings.toolbar = parseBool(raw)

proc loadSettings*(): Settings =
  ## Defaults, then the user's file; writes the documented defaults if there is none.
  result.apply(loadConfig(newStringStream(DefaultConfig)))
  let path = configPath()
  if not fileExists(path):
    try:
      createDir(path.parentDir)
      writeFile(path, DefaultConfig)
    except OSError, IOError:
      warn("could not write the default settings: " & getCurrentExceptionMsg())
    return
  try:
    result.apply(loadConfig(path))
  except IOError, OSError, ValueError:
    warn(getCurrentExceptionMsg())

############################
# State
############################

proc loadToolbarPlace*(): FPoint =
  ## How far the toolbar was dragged from its default spot (top centre); (0, 0) if never.
  try:
    let words = loadConfig(statePath()).getSectionValue("", "toolbar").splitWhitespace
    if words.len == 2:
      result = FPoint(x: parseFloat(words[0]), y: parseFloat(words[1]))
  except IOError, OSError, ValueError:
    discard   # no state yet, or unreadable: the default spot

proc saveToolbarPlace*(place: FPoint) =
  let path = statePath()
  try:
    createDir(path.parentDir)
    writeFile(path, "# Written by Nimotate.\ntoolbar = \"" & $place.x & " " & $place.y & "\"\n")
  except OSError, IOError:
    stderr.writeLine("nimotate: could not save " & path & ": " & getCurrentExceptionMsg())
