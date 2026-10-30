import std/[dynlib, math, tables]

import sdl3

# Text is optional. SDL3_ttf is a separate package that SDL3 does not pull in, so it is
# opened at runtime instead of linked: without it Inkpane runs as before, only without
# the text tool, step markers, tooltips and the F1 help. FreeType and HarfBuzz, which it
# needs, are on every desktop already.
#
# Text is rendered once into a texture at the monitor's real pixel size and kept while
# it is on screen; textures not drawn in a frame are freed at the end of it.

const LibraryNames = ["libSDL3_ttf.so.0", "libSDL3_ttf.so"]

type
  TtfFont = pointer

  CachedText = object
    texture: Texture
    size: FPoint      # logical px, halo included
    used: bool

  TextCache* = object
    entries: Table[string, CachedText]

var
  tried = false
  loaded = false
  fontFile = ""
  fontLookup: proc (): string   # called once, the first time text is needed
  fonts: Table[int, TtfFont]   # one per pixel size
  ttfInit: proc (): bool {.cdecl.}
  ttfOpenFont: proc (file: cstring, size: cfloat): TtfFont {.cdecl.}
  ttfSetFontOutline: proc (font: TtfFont, outline: cint): bool {.cdecl.}
  ttfGetFontHeight: proc (font: TtfFont): cint {.cdecl.}
  ttfGetStringSizeWrapped: proc (font: TtfFont, text: cstring, length: csize_t,
    wrapWidth: cint, w, h: ptr cint): bool {.cdecl.}
  ttfRenderTextBlendedWrapped: proc (font: TtfFont, text: cstring, length: csize_t,
    color: Color, wrapWidth: cint): ptr Surface {.cdecl.}

proc setFontLookup*(lookup: proc (): string) =
  ## Finding the font may start a process, so it waits until text is first needed.
  fontLookup = lookup

proc loadLibrary(): bool =
  var library: LibHandle
  for name in LibraryNames:
    library = loadLib(name)
    if library != nil:
      break
  if library == nil:
    return false
  template load(target, symbol: untyped) =
    target = cast[typeof(target)](library.symAddr(symbol))
    if target == nil:
      unloadLib(library)
      return false
  load(ttfInit, "TTF_Init")
  load(ttfOpenFont, "TTF_OpenFont")
  load(ttfSetFontOutline, "TTF_SetFontOutline")
  load(ttfGetFontHeight, "TTF_GetFontHeight")
  load(ttfGetStringSizeWrapped, "TTF_GetStringSizeWrapped")
  load(ttfRenderTextBlendedWrapped, "TTF_RenderText_Blended_Wrapped")
  ttfInit()

proc textAvailable*(): bool =
  ## True when SDL3_ttf is installed and a font was found.
  if not tried:
    tried = true
    if loadLibrary() and fontLookup != nil:
      fontFile = fontLookup()
    loaded = fontFile.len > 0
  loaded

proc fontAt(pixels: int): TtfFont =
  ## Font sizes are in points at 72 dpi, so points equal pixels.
  result = fonts.getOrDefault(pixels)
  if result == nil and textAvailable():
    result = ttfOpenFont(fontFile.cstring, cfloat(pixels))
    if result != nil:
      fonts[pixels] = result

proc pixelsFor(size: float32): int =
  max(int(round(size)), 4)

proc measureText*(text: string, size: float32): FPoint =
  ## Size of `text` (several lines when it contains newlines) in logical px.
  let font = fontAt(pixelsFor(size))
  if font == nil:
    return
  if text.len == 0:
    return FPoint(x: 0, y: float32(ttfGetFontHeight(font)))
  var w, h: cint
  if ttfGetStringSizeWrapped(font, text.cstring, csize_t(text.len), 0, w.addr, h.addr):
    result = FPoint(x: float32(w), y: float32(h))

proc lineHeight*(size: float32): float32 =
  let font = fontAt(pixelsFor(size))
  if font != nil: float32(ttfGetFontHeight(font)) else: size

proc toColor(color: FColor): Color =
  Color(r: uint8(color.r * 255), g: uint8(color.g * 255), b: uint8(color.b * 255),
        a: uint8(color.a * 255))

proc haloFor(color: FColor): FColor =
  ## A dark halo behind light text and a light one behind dark text.
  let light = color.r * 0.3 + color.g * 0.59 + color.b * 0.11 > 0.5
  if light: FColor(r: 0, g: 0, b: 0, a: 0.75) else: FColor(r: 1, g: 1, b: 1, a: 0.85)

proc outlineFor(pixels: int): int =
  max(1, pixels div 12)

proc renderSurface(text: string, pixels: int, color: FColor, halo: bool): ptr Surface =
  ## The text, and with `halo` an outlineFor(pixels) wide border around it in haloFor(color).
  let font = fontAt(pixels)
  if font == nil or text.len == 0:
    return nil
  let fill = ttfRenderTextBlendedWrapped(font, text.cstring, csize_t(text.len), color.toColor, 0)
  if fill == nil or not halo:
    return fill
  let outline = outlineFor(pixels)
  discard ttfSetFontOutline(font, cint(outline))
  let back = ttfRenderTextBlendedWrapped(font, text.cstring, csize_t(text.len),
    haloFor(color).toColor, 0)
  discard ttfSetFontOutline(font, 0)
  if back == nil:
    return fill
  var at = Rect(x: cint(outline), y: cint(outline), w: fill.w, h: fill.h)
  discard setSurfaceBlendMode(fill, BLENDMODE_BLEND)
  discard blitSurface(fill, nil, back, at.addr)
  destroySurface(fill)
  back

proc drawText*(renderer: Renderer, cache: var TextCache, text: string, topLeft: FPoint,
    size: float32, color: FColor, halo: bool, scale: float32): FPoint =
  ## Draws `text` with its first line's top-left at `topLeft` (logical px); returns its size.
  let pixels = pixelsFor(size * scale)
  let key = text & "\0" & $pixels & $color & $halo
  var entry = cache.entries.getOrDefault(key)
  if entry.texture == nil:
    let surface = renderSurface(text, pixels, color, halo)
    if surface == nil:
      return
    let texture = renderer.createTextureFromSurface(surface)
    let size = FPoint(x: float32(surface.w) / scale, y: float32(surface.h) / scale)
    destroySurface(surface)
    if texture == nil:
      return
    entry = CachedText(texture: texture, size: size)
  entry.used = true
  cache.entries[key] = entry
  let inset = if halo: float32(outlineFor(pixels)) / scale else: 0
  var target = FRect(x: topLeft.x - inset, y: topLeft.y - inset, w: entry.size.x, h: entry.size.y)
  discard renderer.renderTexture(entry.texture, nil, target.addr)
  FPoint(x: entry.size.x - 2 * inset, y: entry.size.y - 2 * inset)

proc endFrame*(cache: var TextCache) =
  ## Frees the textures of text that was not drawn this frame.
  var unused: seq[string]
  for key, entry in cache.entries.mpairs:
    if entry.used:
      entry.used = false
    else:
      unused.add(key)
  for key in unused:
    destroyTexture(cache.entries[key].texture)
    cache.entries.del(key)
