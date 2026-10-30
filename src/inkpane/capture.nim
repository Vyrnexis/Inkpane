import std/[dynlib, os, posix, strutils]

import spawn

import sdl3

# Screenshots. The desktop portal hands over one PNG of the whole desktop; this module
# crops it to a monitor or an area, scales it, saves it and puts it on the clipboard.
# PNG support is new in SDL 3.4, so it is looked up at runtime (SDL3_image as a fallback):
# with neither, Inkpane runs as before, only without screenshots.

type
  Monitor* = object
    name*: string
    bounds*: Rect   # logical px, in desktop coordinates

var
  tried = false
  loaded = false
  loadPng: proc (file: cstring): ptr Surface {.cdecl.}
  savePng: proc (surface: ptr Surface, file: cstring): bool {.cdecl.}
  clipboardPng: string   # served to apps that paste, until the next screenshot

proc pngAvailable*(): bool =
  ## True when SDL 3.4 (or SDL3_image) can read and write PNG files.
  if not tried:
    tried = true
    for (library, loadName, saveName) in [("libSDL3.so.0", "SDL_LoadPNG", "SDL_SavePNG"),
        ("libSDL3_image.so.0", "IMG_Load", "IMG_SavePNG")]:
      let handle = loadLib(library)
      if handle == nil:
        continue
      loadPng = cast[typeof(loadPng)](handle.symAddr(loadName.cstring))
      savePng = cast[typeof(savePng)](handle.symAddr(saveName.cstring))
      if loadPng != nil and savePng != nil:
        loaded = true
        break
  loaded

proc monitors*(): seq[Monitor] =
  ## Every monitor, in the order the overlays are opened in.
  var count: cint
  let displays = getDisplays(count)
  if displays.isNil:
    return
  for i in 0 ..< count:
    var bounds: Rect
    if getDisplayBounds(displays[i], bounds):
      let name = getDisplayName(displays[i])
      result.add(Monitor(name: if name.isNil: "Monitor " & $(i + 1) else: $name, bounds: bounds))
  sdlFree(displays)

############################
# Crop and scale
############################

proc crop*(shot: string, desktop: openArray[Monitor], monitor: int, area: Rect,
    width = 0, height = 0): ptr Surface =
  ## The part of the desktop screenshot `shot` under `area` (logical px on `monitor`; zero
  ## size: the whole monitor), scaled to width × height (zero: real pixels). The portal's
  ## image spans every monitor, so its scale is its width over the desktop's: exact for
  ## one monitor or monitors of equal scale. Nil on failure; the caller destroys it.
  if not pngAvailable() or monitor notin 0 .. desktop.high:
    return nil
  let image = loadPng(shot.cstring)
  if image.isNil:
    return nil
  defer: destroySurface(image)
  var left, top = high(cint)
  var right, bottom = low(cint)
  for m in desktop:
    left = min(left, m.bounds.x)
    top = min(top, m.bounds.y)
    right = max(right, m.bounds.x + m.bounds.w)
    bottom = max(bottom, m.bounds.y + m.bounds.h)
  let factor = image.w.float / float(right - left)
  let m = desktop[monitor].bounds
  let region = if area.w > 0 and area.h > 0: area else: Rect(w: m.w, h: m.h)
  var source = Rect(x: cint(float(m.x - left + region.x) * factor),
                    y: cint(float(m.y - top + region.y) * factor),
                    w: cint(float(region.w) * factor), h: cint(float(region.h) * factor))
  if source.x < 0: (source.w, source.x) = (source.w + source.x, 0'i32)   # area past the edge
  if source.y < 0: (source.h, source.y) = (source.h + source.y, 0'i32)
  source.w = min(source.w, image.w - source.x)
  source.h = min(source.h, image.h - source.y)
  if source.w <= 0 or source.h <= 0:
    return nil
  let w = if width > 0: cint(width) else: source.w
  let h = if height > 0: cint(height) else: source.h
  result = createSurface(w, h, image.format)
  if result.isNil:
    return nil
  discard setSurfaceBlendMode(image, BLENDMODE_NONE)   # copy, don't blend onto the blank
  if not blitSurfaceScaled(image, source.addr, result, nil, SCALEMODE_LINEAR):
    destroySurface(result)
    return nil

proc composite*(shot, path: string, desktop: openArray[Monitor],
    layers: openArray[ptr Surface]): bool =
  ## Tests only: lays each overlay's frame (premultiplied, as the renderer leaves it) over
  ## the stand-in desktop `shot`, as the compositor would, and saves it to `path`.
  let image = loadPng(shot.cstring)
  if image.isNil:
    return false
  defer: destroySurface(image)
  let factor = image.w.float / float(desktop[^1].bounds.x + desktop[^1].bounds.w)
  for i, layer in layers:
    if layer.isNil or i > desktop.high:
      continue
    let m = desktop[i].bounds
    var target = Rect(x: cint(float(m.x) * factor), y: cint(float(m.y) * factor),
                      w: cint(float(m.w) * factor), h: cint(float(m.h) * factor))
    discard setSurfaceBlendMode(layer, BLENDMODE_BLEND_PREMULTIPLIED)
    discard blitSurfaceScaled(layer, nil, image, target.addr, SCALEMODE_LINEAR)
  savePng(image, path.cstring)

############################
# Saving
############################

proc picturesDir(): string =
  ## XDG_PICTURES_DIR from ~/.config/user-dirs.dirs, else ~/Pictures.
  result = getHomeDir() / "Pictures"
  try:
    for line in lines(getConfigDir() / "user-dirs.dirs"):
      if line.startsWith("XDG_PICTURES_DIR="):
        let value = line.split('=', 1)[1].strip(chars = {'"'})
        result = value.replace("$HOME", getHomeDir().strip(leading = false, chars = {'/'}))
  except IOError, OSError:
    discard

proc screenshotFolder*(setting: string): string =
  ## The configured folder, or Pictures/Inkpane.
  if setting.len > 0: setting.expandTilde else: picturesDir() / "Inkpane"

proc save*(surface: ptr Surface, path: string): bool =
  try:
    createDir(path.parentDir)
  except OSError, IOError:
    return false
  savePng(surface, path.cstring)

proc newScreenshotPath*(folder: string): string =
  ## Inkpane_2026-10-30_17-05-09.png, with -2, -3 … when several land in one second.
  var now: posix.Time
  discard posix.time(now)
  var stamp: array[32, char]
  discard strftime(cast[cstring](stamp[0].addr), stamp.len, "%Y-%m-%d_%H-%M-%S",
    localtime(now)[])
  let stem = folder / "Inkpane_" & $cast[cstring](stamp[0].addr)
  result = stem & ".png"
  var n = 2
  while fileExists(result):
    result = stem & "-" & $n & ".png"
    inc n

############################
# Clipboard
############################

proc serveClipboard(userdata: pointer, mimeType: cstring, size: ptr csize_t): pointer {.cdecl.} =
  size[] = csize_t(clipboardPng.len)
  if clipboardPng.len > 0: clipboardPng[0].addr else: nil

proc copyToClipboard*(path: string): bool =
  ## Offers the PNG at `path` to apps that paste an image. wl-copy (wl-clipboard) works
  ## whether or not Inkpane has the keyboard; SDL's clipboard needs it, and Inkpane hands
  ## the keyboard back while the screenshot is taken.
  try:
    clipboardPng = readFile(path)
  except IOError:
    return false
  # wl-copy serves pastes from a forked copy of itself, so this returns at once.
  if findExe("wl-copy").len > 0 and run(["wl-copy", "--type", "image/png"], clipboardPng).code == 0:
    return true
  setClipboardData(serveClipboard, nil, nil, ["image/png".cstring])
