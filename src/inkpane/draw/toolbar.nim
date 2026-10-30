import std/[math, strutils]

import sdl3

import render, scene

# Floating strip at the top centre of each monitor (or wherever it was dragged):
# a grip to drag it by, click-through, tools, fill, colours, widths, screenshot.
# Icons and key letters are drawn as lines with the same mesh code as the drawing, so the
# toolbar needs no font and no image files. The mesh is rebuilt only when what the
# toolbar shows (tool, colour, width, fill, hovered button) changes.

type
  ToolKey* = object
    tool*: Tool
    digit*: int     # number key, by position; -1 for none
    letter*: char

const
  # Excalidraw's layout, in toolbar order. The key handling reads it too.
  ToolOrder* = [
    ToolKey(tool: Rectangle, digit: 2, letter: 'R'), ToolKey(tool: Diamond, digit: 3, letter: 'D'),
    ToolKey(tool: Ellipse, digit: 4, letter: 'O'), ToolKey(tool: Arrow, digit: 5, letter: 'A'),
    ToolKey(tool: Line, digit: 6, letter: 'L'), ToolKey(tool: Pen, digit: 7, letter: 'P'),
    ToolKey(tool: Text, digit: 8, letter: 'T'), ToolKey(tool: Highlighter, digit: 9, letter: 'H'),
    ToolKey(tool: Marker, digit: -1, letter: 'N'), ToolKey(tool: Eraser, digit: 0, letter: 'E')]
  ToolNames: array[Tool, string] = ["Pen", "Line", "Arrow", "Highlighter", "Rectangle",
    "Diamond", "Ellipse", "Text", "Step marker", "Eraser"]

  ButtonSize = 36'f32
  GripWidth = 16'f32
  ColorButtonWidth = 28'f32
  Padding = 6'f32
  GroupGap = 13'f32      # between groups, with a separator line in the middle
  TopMargin = 56'f32     # default spot clears a top panel; the overlay covers panels
  BarRadius = 10'f32
  ButtonRadius = 7'f32
  IconScale = 8.5'f32    # icons are drawn in -1 .. 1 and scaled to this
  IconStroke = 1.8'f32

  BarColor = FColor(r: 0.22, g: 0.22, b: 0.26, a: 0.70)
  BackdropColor = FColor(r: 0.12, g: 0.12, b: 0.15, a: 0.92)   # tooltips and help: text on it
  SeparatorColor = FColor(r: 1, g: 1, b: 1, a: 0.14)
  SelectedColor = FColor(r: 0.42, g: 0.46, b: 0.98, a: 0.55)
  HoverColor = FColor(r: 1, g: 1, b: 1, a: 0.10)
  IconColor = FColor(r: 0.93, g: 0.93, b: 0.95, a: 1)
  DimIconColor = FColor(r: 0.45, g: 0.45, b: 0.50, a: 1)   # fill, when the tool has no inside
  KeyColor = FColor(r: 0.58, g: 0.58, b: 0.64, a: 1)
  SwatchEdgeColor = FColor(r: 0.45, g: 0.45, b: 0.50, a: 1)

type
  ButtonKind* = enum
    GripButton, PassButton, ToolButton, FillButton, ColorButton, WidthButton, CaptureButton

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
    selecting*: bool   # picking an area to capture
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
  add(GripButton, 0, GripWidth)
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
  separate()
  add(CaptureButton, 0, ButtonSize)
  let width = x + Padding
  let height = ButtonSize + 2 * Padding
  # Whole pixels keep the key letters crisp; clamped so a drag never loses it off screen.
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

proc label*(toolbar: Toolbar, button: Button): string =
  ## Tooltip: what the button does and its keys.
  case button.kind
  of GripButton: "Drag to move"
  of PassButton: "Click-through   V · 1"
  of ToolButton:
    let key = ToolOrder[button.index]
    ToolNames[key.tool] & "   " & $key.letter & (if key.digit >= 0: " · " & $key.digit else: "")
  of FillButton: "Fill shapes   F"
  of ColorButton: "Colour   Shift+" & $(button.index + 1)
  of WidthButton: "Width " & formatFloat(toolbar.presets[button.index], precision = -1) & "   [ ]"
  of CaptureButton: "Screenshot   Ctrl+S"

proc tooltipAnchor*(button: Button): FPoint =
  ## Centre of the button's bottom edge, where its tooltip hangs from.
  FPoint(x: button.rect.x + button.rect.w / 2, y: button.rect.y + button.rect.h)

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

proc ring(radius: float32, dy = 0'f32, segments = 24): seq[(float32, float32)] =
  ## A closed circle in icon units, centred `dy` below the middle.
  for i in 0 .. segments:
    let angle = float32(i) / float32(segments) * 2 * float32(PI)
    result.add((cos(angle) * radius, dy + sin(angle) * radius))

proc addIcon(mesh: var Mesh, tool: Tool, c: FPoint) =
  case tool
  of Rectangle:
    mesh.lines(c, [(-0.85'f32, -0.65'f32), (0.85, -0.65), (0.85, 0.65), (-0.85, 0.65), (-0.85, -0.65)])
  of Diamond:
    mesh.lines(c, [(0'f32, -0.9'f32), (0.9, 0), (0, 0.9), (-0.9, 0), (0, -0.9)])
  of Ellipse:
    mesh.lines(c, ring(0.85))
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
  of Text:
    mesh.lines(c, [(-0.7'f32, 0.85'f32), (0.0, -0.85), (0.7, 0.85)])
    mesh.lines(c, [(-0.42'f32, 0.25'f32), (0.42, 0.25)])
  of Marker:
    mesh.lines(c, ring(0.9))
    mesh.lines(c, [(-0.22'f32, -0.3'f32), (0.05, -0.48), (0.05, 0.48)])
  of Eraser:
    mesh.lines(c, [(-0.85'f32, 0.2'f32), (0.0, -0.65), (0.65, 0.0), (-0.2, 0.85), (-0.85, 0.2)])
    mesh.lines(c, [(-0.45'f32, -0.25'f32), (0.25, 0.45)])
    mesh.lines(c, [(0.1'f32, 0.85'f32), (0.9, 0.85)])

proc addLetter(mesh: var Mesh, letter: char, topLeft: FPoint) =
  ## Key letter as strokes, 4 × 8 logical px: still readable on a 100 % scale monitor.
  ## Mostly straight lines on whole pixels, so they stay crisp.
  const
    W = 4'f32
    H = 4'f32     # half height
  let strokes: seq[seq[(float32, float32)]] = case letter
    of 'A': @[@[(0'f32, 2'f32), (0, 0), (1, 0), (1, 2)], @[(0'f32, 1'f32), (1, 1)]]
    of 'D': @[@[(0'f32, 0'f32), (0.75, 0), (1, 0.5), (1, 1.5), (0.75, 2), (0, 2), (0, 0)]]
    of 'E': @[@[(1'f32, 0'f32), (0, 0), (0, 2), (1, 2)], @[(0'f32, 1'f32), (0.75, 1)]]
    of 'F': @[@[(1'f32, 0'f32), (0, 0), (0, 2)], @[(0'f32, 1'f32), (0.75, 1)]]
    of 'H': @[@[(0'f32, 0'f32), (0, 2)], @[(1'f32, 0'f32), (1, 2)], @[(0'f32, 1'f32), (1, 1)]]
    of 'L': @[@[(0'f32, 0'f32), (0, 2), (1, 2)]]
    of 'N': @[@[(0'f32, 2'f32), (0, 0), (1, 2), (1, 0)]]
    of 'O': @[@[(0'f32, 0'f32), (1, 0), (1, 2), (0, 2), (0, 0)]]
    of 'P': @[@[(0'f32, 2'f32), (0, 0), (1, 0), (1, 1), (0, 1)]]
    of 'R': @[@[(0'f32, 2'f32), (0, 0), (1, 0), (1, 1), (0, 1)], @[(0.5'f32, 1'f32), (1, 2)]]
    of 'T': @[@[(0'f32, 0'f32), (1, 0)], @[(0.5'f32, 0'f32), (0.5, 2)]]
    of 'V': @[@[(0'f32, 0'f32), (0.5, 2), (1, 0)]]
    else: @[]
  for stroke in strokes:
    var path: seq[FPoint]
    for (x, y) in stroke:
      path.add(FPoint(x: topLeft.x + x * W, y: topLeft.y + y * H))
    mesh.addPath(path, 1.2, KeyColor)

proc selected(toolbar: Toolbar, button: Button, state: ToolbarState): bool =
  case button.kind
  of GripButton: false
  of PassButton: state.passthrough
  of ToolButton: not (state.passthrough or state.selecting) and
    ToolOrder[button.index].tool == state.tool
  of FillButton: state.fill and state.tool in Fillable
  of ColorButton: button.index == state.color
  of WidthButton: abs(toolbar.presets[button.index] - state.width) < 0.01
  of CaptureButton: state.selecting

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
    of GripButton:   # two columns of three dots: "drag me"
      for dx in [-2.5'f32, 2.5]:
        for dy in [-5'f32, 0, 5]:
          mesh.addDisc(FPoint(x: c.x + dx, y: c.y + dy), 1.4, KeyColor)
    of PassButton:
      # Mouse cursor, as Excalidraw's select tool in the same place.
      mesh.lines(FPoint(x: c.x - 1.5, y: c.y - 1.5),
        [(-0.45'f32, -0.9'f32), (-0.45, 0.6), (-0.08, 0.22), (0.2, 0.85), (0.42, 0.75),
         (0.14, 0.12), (0.62, 0.1), (-0.45, -0.9)])
      mesh.addLetter('V', FPoint(x: c.x + 9.5, y: c.y + 3.5))
    of ToolButton:
      let key = ToolOrder[button.index]
      mesh.addIcon(key.tool, FPoint(x: c.x - 1.5, y: c.y - 1.5))
      mesh.addLetter(key.letter, FPoint(x: c.x + 9.5, y: c.y + 3.5))  # on pixel centres: crisp at 100 %
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
      mesh.addLetter('F', FPoint(x: c.x + 9.5, y: c.y + 3.5))
    of ColorButton:
      mesh.addDisc(c, 9, SwatchEdgeColor)
      mesh.addDisc(c, 8, palette[button.index])
    of WidthButton:
      let thickness = [2'f32, 4.5, 8][button.index]   # by rank: the presets can be anything
      mesh.addPath([FPoint(x: c.x - 8, y: c.y), FPoint(x: c.x + 8, y: c.y)], thickness, IconColor)
    of CaptureButton:   # camera: body with a bump on top, and the lens
      mesh.lines(c, [(-0.9'f32, -0.45'f32), (-0.35, -0.45), (-0.2, -0.75), (0.2, -0.75),
                     (0.35, -0.45), (0.9, -0.45), (0.9, 0.7), (-0.9, 0.7), (-0.9, -0.45)])
      mesh.lines(c, ring(0.38, 0.12, 20))
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

proc drawBackdrop*(renderer: Renderer, rect: FRect, pixelSize: float32) =
  ## Dark rounded panel behind tooltips and the help.
  var mesh: Mesh
  mesh.setPixelSize(pixelSize)
  mesh.addFill(roundedRect(rect, min(ButtonRadius, rect.h / 2)), BackdropColor)
  renderer.draw(mesh)

proc draw*(renderer: Renderer, toolbar: Toolbar) =
  renderer.draw(toolbar.mesh)
