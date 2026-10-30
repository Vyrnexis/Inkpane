import std/[math, sequtils, strutils, unicode]

import sdl3

# Drawn items for one monitor. Items are kept as data (not pixels) so undo, the eraser
# and every tool work on the same list. A pen item is its path; a shape is the two
# corners of the drag, and its outline is computed from them when drawn. Text and step
# markers are placed with a click; their points are the box they cover on screen.

const
  MinPointDistance = 1.5   # logical px; denser input only adds noise and vertices
  SmoothingFactor = 0.35   # 0 = raw input, closer to 1 = smoother but laggier lines
  SnapAngle = PI / 12      # Shift snaps lines and arrows to 15° steps
  EraserRadius* = 8'f32
  HighlighterAlpha = 0.35'f32
  HighlighterMinWidth = 16'f32

type
  Tool* = enum
    Pen, Line, Arrow, Highlighter, Rectangle, Diamond, Ellipse, Text, Marker, Eraser

  Item* = object
    kind*: Tool           # never Eraser
    color*: FColor
    width*: float32
    points*: seq[FPoint]  # pen: the path; shapes: [start, end] of the drag
    filled*: bool         # rectangle, diamond, ellipse: solid inside
    text*: string         # text: what was typed; marker: its number
    byAi*: bool           # drawn through the MCP server, not by hand

  Change = object
    ## One undo step: `count` items from `index` on (one drawn or erased item, or all of
    ## them for a clear). `present` says whether they are in the scene right now; undoing
    ## or redoing flips it, moving the items between the scene and the change.
    index: int
    count: int
    items: seq[Item]
    present: bool

  Scene* = object
    items*: seq[Item]
    drawing*: bool        # the last item is still being drawn
    revision*: int        # bumped when items are removed or restored, not when they grow
    undoStack: seq[Change]
    redoStack: seq[Change]
    anchor: FPoint        # where the drag started
    smoothed: FPoint

const
  Straight* = {Line, Arrow, Highlighter}
  Fillable* = {Rectangle, Diamond, Ellipse}
  Placed* = {Text, Marker}   # put down with a click instead of dragged

proc toolNamed*(name: string): Tool =
  ## "rectangle", "Marker" …, any case; ValueError for anything else.
  for tool in Tool:
    if cmpIgnoreCase($tool, name) == 0:
      return tool
  raise newException(ValueError, "unknown tool: " & name)

# glibc gave hypot (2.35) and the float32 maths functions atan2f, hypotf and sqrtf (2.43)
# new versions, so a binary calling them won't start on older systems. sqrt and atan2 in
# float64 are as old as glibc; screen distances never need hypot's overflow care.
proc length*(dx, dy: float32): float32 =
  float32(sqrt(float(dx) * float(dx) + float(dy) * float(dy)))

proc angle*(dy, dx: float32): float32 =
  float32(arctan2(float(dy), float(dx)))

proc distance(a, b: FPoint): float32 =
  length(a.x - b.x, a.y - b.y)

proc toolWidth*(kind: Tool, width: float32): float32 =
  ## The highlighter is a wide marker; every other tool draws at the chosen width.
  if kind == Highlighter: max(width * 3, HighlighterMinWidth) else: width

proc toolColor*(kind: Tool, color: FColor): FColor =
  result = color
  if kind == Highlighter:
    result.a = HighlighterAlpha

############################
# Shapes
############################

proc dragCorners(kind: Tool, anchor, to: FPoint, shift, ctrl: bool): array[2, FPoint] =
  var dx = to.x - anchor.x
  var dy = to.y - anchor.y
  if kind in Straight:
    if shift:   # snap the angle, keep the length
      let snapped = round(angle(dy, dx) / SnapAngle) * SnapAngle
      let reach = length(dx, dy)
      dx = cos(snapped) * reach
      dy = sin(snapped) * reach
    return [anchor, FPoint(x: anchor.x + dx, y: anchor.y + dy)]
  if shift:     # square, circle, equal-sided diamond
    let side = max(abs(dx), abs(dy))
    dx = copySign(side, dx)
    dy = copySign(side, dy)
  let start = if ctrl: FPoint(x: anchor.x - dx, y: anchor.y - dy) else: anchor
  [start, FPoint(x: anchor.x + dx, y: anchor.y + dy)]

proc outline*(item: Item): seq[seq[FPoint]] =
  ## The polylines a shape is drawn with (pen items are their own path).
  let a = item.points[0]
  let b = item.points[^1]
  case item.kind
  of Pen, Eraser, Line, Highlighter:
    result = @[@[a, b]]
  of Text, Marker:   # the box, for the eraser
    result = @[@[a, FPoint(x: b.x, y: a.y), b, FPoint(x: a.x, y: b.y), a]]
  of Arrow:
    let length = distance(a, b)
    result = @[@[a, b]]
    if length > 0:
      let head = min(max(item.width * 3, 14), length / 2)
      let direction = angle(b.y - a.y, b.x - a.x)
      proc wing(side: float32): FPoint =
        FPoint(x: b.x - cos(direction + side) * head, y: b.y - sin(direction + side) * head)
      result.add(@[wing(PI / 7), b, wing(-PI / 7)])
  of Rectangle:
    result = @[@[a, FPoint(x: b.x, y: a.y), b, FPoint(x: a.x, y: b.y), a]]
  of Diamond:
    let center = FPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    let top = FPoint(x: center.x, y: a.y)
    result = @[@[top, FPoint(x: b.x, y: center.y), FPoint(x: center.x, y: b.y),
      FPoint(x: a.x, y: center.y), top]]
  of Ellipse:
    let center = FPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    let rx = abs(b.x - a.x) / 2
    let ry = abs(b.y - a.y) / 2
    let segments = clamp(int(length(rx, ry) * 0.6), 24, 160)
    var ring: seq[FPoint]
    for i in 0 .. segments:
      let angle = float32(i) / float32(segments) * 2 * PI
      ring.add(FPoint(x: center.x + cos(angle) * rx, y: center.y + sin(angle) * ry))
    result = @[ring]

############################
# Drawing
############################

proc begin*(scene: var Scene, kind: Tool, at: FPoint, color: FColor, width: float32,
    filled = false) =
  scene.items.add(Item(kind: kind, color: toolColor(kind, color), width: toolWidth(kind, width),
    points: @[at, at], filled: filled and kind in Fillable))
  if kind == Pen:
    scene.items[^1].points.setLen(1)
  scene.anchor = at
  scene.smoothed = at
  scene.drawing = true

proc moveTo*(scene: var Scene, to: FPoint, shift = false, ctrl = false): bool =
  ## Follows the pointer; returns true when the item changed and needs a redraw.
  if not scene.drawing:
    return false
  template item: untyped = scene.items[^1]
  if item.kind in Placed:
    return false
  if item.kind != Pen:
    item.points = @(dragCorners(item.kind, scene.anchor, to, shift, ctrl))
    return true
  # Exponential smoothing hides mouse jitter without a visible lag at normal speeds.
  scene.smoothed = FPoint(
    x: scene.smoothed.x + (to.x - scene.smoothed.x) * (1 - SmoothingFactor),
    y: scene.smoothed.y + (to.y - scene.smoothed.y) * (1 - SmoothingFactor)
  )
  if distance(item.points[^1], scene.smoothed) < MinPointDistance:
    return false
  item.points.add(scene.smoothed)
  true

proc finish*(scene: var Scene, at: FPoint, shift = false, ctrl = false) =
  if not scene.drawing:
    return
  template item: untyped = scene.items[^1]
  if item.kind == Pen:
    # Finish exactly where the pointer was released, not at the smoothed position.
    if distance(item.points[^1], at) >= 0.5:
      item.points.add(at)
  elif item.kind notin Placed:
    discard scene.moveTo(at, shift, ctrl)
  scene.drawing = false
  let empty = if item.kind == Text: item.text.len == 0
              elif item.kind == Pen: false
              else: distance(item.points[0], item.points[1]) < 2   # a click, not a shape
  if empty:   # never in the mesh: it was still being drawn
    scene.items.setLen(scene.items.len - 1)
    return
  scene.undoStack.add(Change(index: scene.items.high, count: 1, present: true))
  scene.redoStack.setLen(0)

proc cancel*(scene: var Scene) =
  ## Drops the item being drawn (Esc while typing or dragging).
  if scene.drawing:
    scene.items.setLen(scene.items.len - 1)
    scene.drawing = false
    inc scene.revision

############################
# Text and markers
############################

proc editingText*(scene: Scene): bool =
  scene.drawing and scene.items[^1].kind == Text

proc typeText*(scene: var Scene, text: string) =
  if scene.editingText:
    scene.items[^1].text.add(text)

proc deleteLast*(scene: var Scene) =
  ## Backspace: removes the last character, not just its last byte.
  if scene.editingText:
    template text: untyped = scene.items[^1].text
    if text.len > 0:
      text.setLen(text.len - text.lastRune(text.high)[1])

proc setBox*(item: var Item, size: FPoint) =
  ## Text knows its size only once rendered; the eraser needs it.
  item.points = @[item.points[0],
    FPoint(x: item.points[0].x + size.x, y: item.points[0].y + size.y)]

proc nextMarker(scene: Scene): int =
  ## One past the highest number on screen: undoing the last marker frees its number
  ## again, and erasing one in the middle never makes the next a duplicate.
  for item in scene.items:
    if item.kind == Marker:
      result = max(result, parseInt(item.text))
  inc result

proc addItem*(scene: var Scene, item: Item) =
  ## A finished item from outside (the MCP server). It goes in before an item the user
  ## is still drawing, so their drag carries on; that moves the user's item, so the mesh
  ## is rebuilt.
  let at = scene.items.len - ord(scene.drawing)
  scene.items.insert(item, at)
  if scene.drawing:
    inc scene.revision
  scene.undoStack.add(Change(index: at, count: 1, present: true))
  scene.redoStack.setLen(0)

proc addMarker*(scene: var Scene, center: FPoint, radius: float32, color: FColor,
    byAi = false, number = 0) =
  ## Numbered from 1 on, or `number` when given (a tutorial's step 3 stays 3).
  let shown = if number > 0: number else: scene.nextMarker
  scene.addItem(Item(kind: Marker, color: color, width: radius * 2, text: $shown,
    points: @[FPoint(x: center.x - radius, y: center.y - radius),
              FPoint(x: center.x + radius, y: center.y + radius)], byAi: byAi))

############################
# Eraser
############################

proc distanceToSegment(p, a, b: FPoint): float32 =
  let dx = b.x - a.x
  let dy = b.y - a.y
  let lengthSquared = dx * dx + dy * dy
  let t = if lengthSquared == 0: 0'f32
          else: clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0, 1)
  distance(p, FPoint(x: a.x + t * dx, y: a.y + t * dy))

proc touches(path: openArray[FPoint], p: FPoint, reach: float32): bool =
  if path.len == 1:
    return distance(p, path[0]) <= reach
  for i in 1 ..< path.len:
    if distanceToSegment(p, path[i - 1], path[i]) <= reach:
      return true

proc inside(path: openArray[FPoint], p: FPoint): bool =
  ## Even-odd test against a closed outline.
  var j = path.high
  for i in 0 .. path.high:
    let a = path[i]
    let b = path[j]
    if (a.y > p.y) != (b.y > p.y) and p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x:
      result = not result
    j = i

proc touches(item: Item, p: FPoint): bool =
  let reach = if item.kind in Placed: EraserRadius else: EraserRadius + item.width / 2
  if item.kind == Pen:
    return item.points.touches(p, reach)
  for path in item.outline():
    if path.touches(p, reach) or ((item.filled or item.kind in Placed) and path.inside(p)):
      return true

proc flip(scene: var Scene, change: var Change) =
  ## Undoes `change` (or redoes it) and turns it into its own inverse.
  if change.present:
    change.items = scene.items[change.index ..< change.index + change.count]
    scene.items.delete(change.index ..< change.index + change.count)
  else:
    scene.items.insert(move(change.items), change.index)
  change.present = not change.present
  inc scene.revision

proc removeAt*(scene: var Scene, index: int) =
  ## Removes one item as an undo step, like the eraser does.
  var change = Change(index: index, count: 1, present: true)
  scene.flip(change)
  scene.undoStack.add(change)
  scene.redoStack.setLen(0)

proc eraseAt*(scene: var Scene, p: FPoint): bool =
  ## Removes every item under the eraser; each removal is its own undo step.
  for i in countdown(scene.items.high, 0):
    if scene.items[i].touches(p):
      scene.removeAt(i)
      result = true

proc eraseAlong*(scene: var Scene, a, b: FPoint): bool =
  ## Erases from `a` to `b`, so a fast swipe catches thin lines between two mouse events.
  let steps = max(int(ceil(distance(a, b) / EraserRadius)), 1)
  for i in 1 .. steps:
    let t = float32(i) / float32(steps)
    if scene.eraseAt(FPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)):
      result = true

############################
# Drawn by the AI
############################

proc aiItem*(kind: Tool, points: seq[FPoint], color: FColor, width: float32, filled = false,
    text = ""): Item =
  ## An item as the MCP server describes it: shapes by two corners, arrows and lines by
  ## tail and head, the pen by its path, text by its top-left corner.
  Item(kind: kind, color: toolColor(kind, color), width: toolWidth(kind, width), byAi: true,
    points: (if kind == Text: @[points[0], points[0]] else: points),
    filled: filled and kind in Fillable, text: text)

proc lastAi*(scene: Scene): int =
  ## Index of the newest AI item, or -1.
  for i in countdown(scene.items.high - ord(scene.drawing), 0):
    if scene.items[i].byAi:
      return i
  -1

proc clearAi*(scene: var Scene): bool =
  ## Removes every AI item, the user's drawing stays; each is an undo step.
  for i in countdown(scene.items.high - ord(scene.drawing), 0):
    if scene.items[i].byAi:
      scene.removeAt(i)
      result = true

############################
# History
############################

proc undo*(scene: var Scene): bool =
  if scene.drawing or scene.undoStack.len == 0:
    return false
  var change = scene.undoStack.pop()
  scene.flip(change)
  scene.redoStack.add(change)
  true

proc redo*(scene: var Scene): bool =
  if scene.drawing or scene.redoStack.len == 0:
    return false
  var change = scene.redoStack.pop()
  scene.flip(change)
  scene.undoStack.add(change)
  true

proc clear*(scene: var Scene) =
  ## Removes everything as one undo step, so a stray C or Delete costs nothing.
  scene.cancel()
  if scene.items.len == 0:
    return
  var change = Change(index: 0, count: scene.items.len, present: true)
  scene.flip(change)
  scene.undoStack.add(change)
  scene.redoStack.setLen(0)
