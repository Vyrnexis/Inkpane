import std/math

import sdl3

# Drawn items for one monitor. Items are kept as data (not pixels) so undo, erase and
# later tools (shapes, text) all work on the same list.

const
  MinPointDistance = 1.5   # logical px; denser input only adds noise and vertices
  SmoothingFactor = 0.35   # 0 = raw input, closer to 1 = smoother but laggier lines

type
  Stroke* = object
    color*: FColor
    width*: float32
    points*: seq[FPoint]

  Scene* = object
    strokes*: seq[Stroke]
    redoStack: seq[Stroke]
    active*: bool         # a stroke is being drawn right now
    smoothed: FPoint

proc distance(a, b: FPoint): float32 =
  sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))

proc beginStroke*(scene: var Scene, at: FPoint, color: FColor, width: float32) =
  scene.strokes.add(Stroke(color: color, width: width, points: @[at]))
  scene.redoStack.setLen(0)
  scene.smoothed = at
  scene.active = true

proc extendStroke*(scene: var Scene, to: FPoint): bool =
  ## Adds a smoothed point; returns true when the stroke changed and needs a redraw.
  if not scene.active or scene.strokes.len == 0:
    return false
  # Exponential smoothing hides mouse jitter without a visible lag at normal speeds.
  scene.smoothed = FPoint(
    x: scene.smoothed.x + (to.x - scene.smoothed.x) * (1 - SmoothingFactor),
    y: scene.smoothed.y + (to.y - scene.smoothed.y) * (1 - SmoothingFactor)
  )
  let points = addr scene.strokes[^1].points
  if distance(points[][^1], scene.smoothed) < MinPointDistance:
    return false
  points[].add(scene.smoothed)
  true

proc endStroke*(scene: var Scene, at: FPoint) =
  if not scene.active:
    return
  # Finish exactly where the pointer was released, not at the smoothed position.
  if scene.strokes.len > 0 and distance(scene.strokes[^1].points[^1], at) >= 0.5:
    scene.strokes[^1].points.add(at)
  scene.active = false

proc undo*(scene: var Scene): bool =
  if scene.active or scene.strokes.len == 0:
    return false
  scene.redoStack.add(scene.strokes.pop())
  true

proc redo*(scene: var Scene): bool =
  if scene.active or scene.redoStack.len == 0:
    return false
  scene.strokes.add(scene.redoStack.pop())
  true

proc clear*(scene: var Scene) =
  scene.strokes.setLen(0)
  scene.redoStack.setLen(0)
  scene.active = false
