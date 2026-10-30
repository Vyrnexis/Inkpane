import std/math

import sdl3

import render, scene

# Floating strip at the top centre of each monitor (or wherever it was dragged):
# click-through, tools, fill, colours, widths.
# Icons and key digits are drawn as lines with the same mesh code as the drawing, so the
# toolbar needs no font and no image files. The mesh is rebuilt only when what the
# toolbar shows (tool, colour, width, fill, hovered button) changes.

const
  ToolOrder* = [(Rectangle, 2), (Diamond, 3), (Ellipse, 4), (Arrow, 5), (Line, 6),
                (Pen, 7), (Highlighter, 9), (Eraser, 0)]

  ButtonSize = 36'f32
  ColorButtonWidth = 28'f32
  Padding = 6'f32
  GroupGap = 13'f32      # between groups, with a separator line in the middle
  TopMargin = 56'f32     # default spot clears a top panel; the overlay covers panels
  BarRadius = 10'f32
  ButtonRadius = 7'f32
  IconScale = 8.5'f32    # icons are drawn in -1 .. 1 and scaled to this
  IconStroke = 1.8'f32

  BarColor = FColor(r: 0.22, g: 0.22, b: 0.26, a: 0.70)
  SeparatorColor = FColor(r: 1, g: 1, b: 1, a: 0.14)
  SelectedColor = FColor(r: 0.42, g: 0.46, b: 0.98, a: 0.55)
  HoverColor = FColor(r: 1, g: 1, b: 1, a: 0.10)
  IconColor = FColor(r: 0.93, g: 0.93, b: 0.95, a: 1)
  DimIconColor = FColor(r: 0.45, g: 0.45, b: 0.50, a: 1)   # fill, when the tool has no inside
  DigitColor = FColor(r: 0.58, g: 0.58, b: 0.64, a: 1)
  SwatchEdgeColor = FColor(r: 0.45, g: 0.45, b: 0.50, a: 1)

type
  ButtonKind* = enum
    PassButton, ToolButton, FillButton, ColorButton, WidthButton

  Button* = object
    kind*: ButtonKind
    index*: int     # into ToolOrder, the palette or the width presets
    rect: FRect

  ToolbarState* = object
    tool*: Tool
    color*: int     # palette index, -1 when the colour is not in the palette
    width*: float32
    fill*: bool
    passthrough*: bool
    hover*: int     # button under the pointer, -1 for none

  Toolbar* = object
    buttons*: seq[Button]
    bounds*: FRect
    separators: seq[float32]   # x of each separator line
    screen: FPoint             # monitor size it was laid out for
    place: FPoint              # offset from the default spot
    pixelSize: float32
    presets: array[3, float32]
    mesh: Mesh
    shown: ToolbarState
    built: bool

proc contains*(rect: FRect, p: FPoint): bool =
  p.x >= rect.x and p.x < rect.x + rect.w and p.y >= rect.y and p.y < rect.y + rect.h

proc center(rect: FRect): FPoint =
  FPoint(x: rect.x + rect.w / 2, y: rect.y + rect.h / 2)

############################
# Layout
############################

proc layout(toolbar: var Toolbar, screen, place: FPoint, colors: int) =
  toolbar.buttons.setLen(0)
  toolbar.separators.setLen(0)
  toolbar.screen = screen
  toolbar.place = place
  var x = Padding
  template add(buttonKind: ButtonKind, i: int, buttonWidth: float32) =
    toolbar.buttons.add(Button(kind: buttonKind, index: i,
      rect: FRect(x: x, y: Padding, w: buttonWidth, h: ButtonSize)))
    x += buttonWidth
  template separate() =
    toolbar.separators.add(x + GroupGap / 2)
    x += GroupGap
  add(PassButton, 0, ButtonSize)
  for i in 0 .. ToolOrder.high:
    add(ToolButton, i, ButtonSize)
  separate()
  add(FillButton, 0, ButtonSize)
  separate()
  for i in 0 ..< colors:
    add(ColorButton, i, ColorButtonWidth)
  separate()
  for i in 0 .. toolbar.presets.high:
    add(WidthButton, i, ButtonSize)
  let width = x + Padding
  let height = ButtonSize + 2 * Padding
  # Whole pixels keep the key digits crisp; clamped so a drag never loses it off screen.
  let left = clamp(round((screen.x - width) / 2 + place.x), 0, max(screen.x - width, 0))
  let top = clamp(round(TopMargin + place.y), 0, max(screen.y - height, 0))
  for button in toolbar.buttons.mitems:
    button.rect.x += left
    button.rect.y += top
  for separator in toolbar.separators.mitems:
    separator += left
  toolbar.bounds = FRect(x: left, y: top, w: width, h: height)

proc offset*(toolbar: Toolbar): FPoint =
  ## Where the toolbar really is, as an offset from its default spot (a drag past the
  ## screen edge is clamped, so this can differ from the place it was given).
  FPoint(x: toolbar.bounds.x - round((toolbar.screen.x - toolbar.bounds.w) / 2),
         y: toolbar.bounds.y - TopMargin)

proc hit*(toolbar: Toolbar, p: FPoint): int =
  ## Index of the button at `p`, or -1.
  for i, button in toolbar.buttons:
    if p in button.rect:
      return i
  -1

############################
# Drawing
############################

proc roundedRect(rect: FRect, radius: float32): seq[FPoint] =
  ## Closed outline (the last point repeats the first), as addFill expects.
  const CornerSegments = 5
  let corners = [
    (FPoint(x: rect.x + rect.w - radius, y: rect.y + radius), -PI / 2),
    (FPoint(x: rect.x + rect.w - radius, y: rect.y + rect.h - radius), 0.0),
    (FPoint(x: rect.x + radius, y: rect.y + rect.h - radius), PI / 2),
    (FPoint(x: rect.x + radius, y: rect.y + radius), PI)
  ]
  for (c, start) in corners:
    for i in 0 .. CornerSegments:
      let angle = float32(start + float(i) / CornerSegments * PI / 2)
      result.add(FPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius))
  result.add(result[0])

proc scaled(c: FPoint, points: openArray[(float32, float32)]): seq[FPoint] =
  for (x, y) in points:
    result.add(FPoint(x: c.x + x * IconScale, y: c.y + y * IconScale))

proc lines(mesh: var Mesh, c: FPoint, points: openArray[(float32, float32)]) =
  mesh.addPath(scaled(c, points), IconStroke, IconColor)

proc addIcon(mesh: var Mesh, tool: Tool, c: FPoint) =
  case tool
  of Rectangle:
    mesh.lines(c, [(-0.85'f32, -0.65'f32), (0.85, -0.65), (0.85, 0.65), (-0.85, 0.65), (-0.85, -0.65)])
  of Diamond:
    mesh.lines(c, [(0'f32, -0.9'f32), (0.9, 0), (0, 0.9), (-0.9, 0), (0, -0.9)])
  of Ellipse:
    var ring: seq[(float32, float32)]
    for i in 0 .. 24:
      let angle = float32(i) / 24 * 2 * float32(PI)
      ring.add((cos(angle) * 0.85'f32, sin(angle) * 0.85'f32))
    mesh.lines(c, ring)
  of Arrow:
    mesh.lines(c, [(-0.8'f32, 0.8'f32), (0.8, -0.8)])
    mesh.lines(c, [(0.0'f32, -0.8'f32), (0.8, -0.8), (0.8, 0.0)])
  of Line:
    mesh.lines(c, [(-0.8'f32, 0.8'f32), (0.8, -0.8)])
  of Pen:
    mesh.lines(c, [(-0.85'f32, 0.85'f32), (-0.65, 0.25), (0.4, -0.8), (0.8, -0.4),
                   (-0.25, 0.65), (-0.85, 0.85)])
    mesh.lines(c, [(0.15'f32, -0.55'f32), (0.55, -0.15)])
  of Highlighter:
    let bar = scaled(c, [(-0.9'f32, 0.62'f32), (0.9, 0.62)])
    mesh.addSegment(bar[0], bar[1], 3.2, FColor(r: IconColor.r, g: IconColor.g, b: IconColor.b, a: 0.4))
    mesh.lines(c, [(-0.3'f32, 0.2'f32), (0.35, -0.75), (0.85, -0.4), (0.2, 0.55), (-0.3, 0.2)])
  of Eraser:
    mesh.lines(c, [(-0.85'f32, 0.2'f32), (0.0, -0.65), (0.65, 0.0), (-0.2, 0.85), (-0.85, 0.2)])
    mesh.lines(c, [(-0.45'f32, -0.25'f32), (0.25, 0.45)])
    mesh.lines(c, [(0.1'f32, 0.85'f32), (0.9, 0.85)])

proc addDigit(mesh: var Mesh, digit: int, topLeft: FPoint) =
  ## Seven-segment digit, 4 × 8 logical px: still readable on a 100 % scale monitor.
  const
    W = 4'f32
    H = 4'f32     # half height
    Segments = [   # a b c d e f g
      [(0'f32, 0'f32), (1'f32, 0'f32)], [(1'f32, 0'f32), (1'f32, 1'f32)],
      [(1'f32, 1'f32), (1'f32, 2'f32)], [(0'f32, 2'f32), (1'f32, 2'f32)],
      [(0'f32, 1'f32), (0'f32, 2'f32)], [(0'f32, 0'f32), (0'f32, 1'f32)],
      [(0'f32, 1'f32), (1'f32, 1'f32)]]
    Digits = ["abcdef", "bc", "abged", "abgcd", "fgbc", "afgcd", "afgedc", "abc",
              "abcdefg", "abcdfg"]
  for letter in Digits[digit]:
    let segment = Segments[ord(letter) - ord('a')]
    mesh.addPath([FPoint(x: topLeft.x + segment[0][0] * W, y: topLeft.y + segment[0][1] * H),
                  FPoint(x: topLeft.x + segment[1][0] * W, y: topLeft.y + segment[1][1] * H)],
                 1.2, DigitColor)

proc selected(toolbar: Toolbar, button: Button, state: ToolbarState): bool =
  case button.kind
  of PassButton: state.passthrough
  of ToolButton: not state.passthrough and ToolOrder[button.index][0] == state.tool
  of FillButton: state.fill and state.tool in Fillable
  of ColorButton: button.index == state.color
  of WidthButton: abs(toolbar.presets[button.index] - state.width) < 0.01

proc build(toolbar: var Toolbar, state: ToolbarState, palette: openArray[FColor]) =
  template mesh: untyped = toolbar.mesh
  mesh.clear()
  mesh.addFill(roundedRect(toolbar.bounds, BarRadius), BarColor)
  for x in toolbar.separators:
    mesh.addSegment(FPoint(x: x, y: toolbar.bounds.y + 12),
                    FPoint(x: x, y: toolbar.bounds.y + toolbar.bounds.h - 12), 0.5, SeparatorColor)
  for i, button in toolbar.buttons:
    let back = roundedRect(FRect(x: button.rect.x + 2, y: button.rect.y + 2,
                                 w: button.rect.w - 4, h: button.rect.h - 4), ButtonRadius)
    if toolbar.selected(button, state):
      mesh.addFill(back, SelectedColor)
    elif i == state.hover:
      mesh.addFill(back, HoverColor)
    let c = button.rect.center
    case button.kind
    of PassButton:
      # Mouse cursor, as Excalidraw's select tool in the same place.
      mesh.lines(FPoint(x: c.x - 1.5, y: c.y - 1.5),
        [(-0.45'f32, -0.9'f32), (-0.45, 0.6), (-0.08, 0.22), (0.2, 0.85), (0.42, 0.75),
         (0.14, 0.12), (0.62, 0.1), (-0.45, -0.9)])
      mesh.addDigit(1, FPoint(x: c.x + 9.5, y: c.y + 3.5))
    of ToolButton:
      let (tool, digit) = ToolOrder[button.index]
      mesh.addIcon(tool, FPoint(x: c.x - 1.5, y: c.y - 1.5))
      mesh.addDigit(digit, FPoint(x: c.x + 9.5, y: c.y + 3.5))  # on pixel centres: crisp at 100 %
    of FillButton:
      # The current shape, solid or outlined; dimmed while the tool cannot be filled.
      let fillable = state.tool in Fillable
      let shape = if fillable: state.tool else: Rectangle
      let half = case shape
        of Rectangle: (x: 0.8'f32, y: 0.6'f32)
        of Ellipse: (x: 0.85'f32, y: 0.7'f32)
        else: (x: 0.85'f32, y: 0.85'f32)
      let corners = scaled(c, [(-half.x, -half.y), (half.x, half.y)])
      let color = if fillable: IconColor else: DimIconColor
      for path in Item(kind: shape, points: corners).outline():
        if state.fill:
          mesh.addFill(path, color)
        mesh.addPath(path, IconStroke, color)
    of ColorButton:
      mesh.addDisc(c, 9, SwatchEdgeColor)
      mesh.addDisc(c, 8, palette[button.index])
    of WidthButton:
      let thickness = [2'f32, 4.5, 8][button.index]   # by rank: the presets can be anything
      mesh.addPath([FPoint(x: c.x - 8, y: c.y), FPoint(x: c.x + 8, y: c.y)], thickness, IconColor)
  toolbar.shown = state
  toolbar.built = true

proc update*(toolbar: var Toolbar, screen, place: FPoint, pixelSize: float32,
    state: ToolbarState, palette: openArray[FColor], presets: array[3, float32]) =
  ## Lays out and rebuilds only what changed since the last frame.
  toolbar.presets = presets
  if screen != toolbar.screen or place != toolbar.place or toolbar.buttons.len == 0:
    toolbar.layout(screen, place, palette.len)
    toolbar.built = false
  if pixelSize != toolbar.pixelSize:
    toolbar.pixelSize = pixelSize
    toolbar.mesh.setPixelSize(pixelSize)
    toolbar.built = false
  if not toolbar.built or state != toolbar.shown:
    toolbar.build(state, palette)

proc draw*(renderer: Renderer, toolbar: Toolbar) =
  renderer.draw(toolbar.mesh)
