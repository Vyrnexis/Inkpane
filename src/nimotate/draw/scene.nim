import std/math

import sdl3

# Drawn items for one monitor. Items are kept as data (not pixels) so undo, the eraser
# and every tool work on the same list. A pen item is its path; a shape is the two
# corners of the drag, and its outline is computed from them when drawn.

const
  MinPointDistance = 1.5   # logical px; denser input only adds noise and vertices
  SmoothingFactor = 0.35   # 0 = raw input, closer to 1 = smoother but laggier lines
  SnapAngle = PI / 12      # Shift snaps lines and arrows to 15° steps
  EraserRadius* = 8'f32

type
  Tool* = enum
    Pen, Line, Arrow, Rectangle, Diamond, Ellipse, Eraser

  Item* = object
    kind*: Tool           # never Eraser
    color*: FColor
    width*: float32
    points*: seq[FPoint]  # pen: the path; shapes: [start, end] of the drag

  Change = object
    ## One undo step. `present` says whether the item is in the scene right now;
    ## undoing or redoing flips it, moving the item between the scene and the change.
    index: int
    item: Item
    present: bool

  Scene* = object
    items*: seq[Item]
    drawing*: bool        # the last item is still being drawn
    revision*: int        # bumped when items are removed or restored, not when they grow
    undoStack: seq[Change]
    redoStack: seq[Change]
    anchor: FPoint        # where the drag started
    smoothed: FPoint

proc distance(a, b: FPoint): float32 =
  hypot(a.x - b.x, a.y - b.y)

############################
# Shapes
############################

proc dragCorners(kind: Tool, anchor, to: FPoint, shift, ctrl: bool): array[2, FPoint] =
  var dx = to.x - anchor.x
  var dy = to.y - anchor.y
  if kind in {Line, Arrow}:
    if shift:   # snap the angle, keep the length
      let angle = round(arctan2(dy, dx) / SnapAngle) * SnapAngle
      let length = hypot(dx, dy)
      dx = cos(angle) * length
      dy = sin(angle) * length
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
  of Pen, Eraser, Line:
    result = @[@[a, b]]
  of Arrow:
    let length = distance(a, b)
    result = @[@[a, b]]
    if length > 0:
      let head = min(max(item.width * 3, 14), length / 2)
      let angle = arctan2(b.y - a.y, b.x - a.x)
      proc wing(side: float32): FPoint =
        FPoint(x: b.x - cos(angle + side) * head, y: b.y - sin(angle + side) * head)
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
    let segments = clamp(int(hypot(rx, ry) * 0.6), 24, 160)
    var ring: seq[FPoint]
    for i in 0 .. segments:
      let angle = float32(i) / float32(segments) * 2 * PI
      ring.add(FPoint(x: center.x + cos(angle) * rx, y: center.y + sin(angle) * ry))
    result = @[ring]

############################
# Drawing
############################

proc begin*(scene: var Scene, kind: Tool, at: FPoint, color: FColor, width: float32) =
  scene.items.add(Item(kind: kind, color: color, width: width, points: @[at, at]))
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
  else:
    discard scene.moveTo(at, shift, ctrl)
  scene.drawing = false
  if item.kind != Pen and distance(item.points[0], item.points[1]) < 2:
    scene.items.setLen(scene.items.len - 1)   # a click, not a shape
    return
  scene.undoStack.add(Change(index: scene.items.high, present: true))
  scene.redoStack.setLen(0)

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

proc touches(item: Item, p: FPoint): bool =
  let reach = EraserRadius + item.width / 2
  if item.kind == Pen:
    return item.points.touches(p, reach)
  for path in item.outline():
    if path.touches(p, reach):
      return true

proc flip(scene: var Scene, change: var Change) =
  ## Undoes `change` (or redoes it) and turns it into its own inverse.
  if change.present:
    change.item = move(scene.items[change.index])
    scene.items.delete(change.index)
  else:
    scene.items.insert(move(change.item), change.index)
  change.present = not change.present
  inc scene.revision

proc eraseAt*(scene: var Scene, p: FPoint): bool =
  ## Removes every item under the eraser; each removal is its own undo step.
  for i in countdown(scene.items.high, 0):
    if scene.items[i].touches(p):
      var change = Change(index: i, present: true)
      scene.flip(change)
      scene.undoStack.add(change)
      scene.redoStack.setLen(0)
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
  scene.items.setLen(0)
  scene.undoStack.setLen(0)
  scene.redoStack.setLen(0)
  scene.drawing = false
  inc scene.revision
