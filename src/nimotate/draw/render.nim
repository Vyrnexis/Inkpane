import std/math

import sdl3

import scene

# Thick, round-jointed lines built from triangles. SDL's renderer only draws 1px lines,
# so every stroke becomes a mesh: a quad per segment plus a disc at every point.

proc circleSegments(radius: float32): int =
  # Enough segments that the edge looks round at this size, without wasting vertices.
  clamp(int(radius * 1.6), 8, 48)

proc addDisc(vertices: var seq[Vertex], indices: var seq[cint], center: FPoint,
    radius: float32, color: FColor) =
  let segments = circleSegments(radius)
  let centerIndex = cint(vertices.len)
  vertices.add(Vertex(position: center, color: color))
  for i in 0 ..< segments:
    let angle = float32(i) / float32(segments) * 2 * PI
    vertices.add(Vertex(
      position: FPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius),
      color: color
    ))
  for i in 0 ..< segments:
    indices.add(centerIndex)
    indices.add(centerIndex + 1 + cint(i))
    indices.add(centerIndex + 1 + cint((i + 1) mod segments))

proc addSegment(vertices: var seq[Vertex], indices: var seq[cint], a, b: FPoint,
    radius: float32, color: FColor) =
  let dx = b.x - a.x
  let dy = b.y - a.y
  let length = sqrt(dx * dx + dy * dy)
  if length < 0.001:
    return
  # Perpendicular offset of half the line width.
  let nx = -dy / length * radius
  let ny = dx / length * radius
  let base = cint(vertices.len)
  vertices.add(Vertex(position: FPoint(x: a.x + nx, y: a.y + ny), color: color))
  vertices.add(Vertex(position: FPoint(x: a.x - nx, y: a.y - ny), color: color))
  vertices.add(Vertex(position: FPoint(x: b.x + nx, y: b.y + ny), color: color))
  vertices.add(Vertex(position: FPoint(x: b.x - nx, y: b.y - ny), color: color))
  indices.add([base, base + 1, base + 2, base + 1, base + 3, base + 2])

proc addStroke*(vertices: var seq[Vertex], indices: var seq[cint], stroke: Stroke) =
  let radius = stroke.width / 2
  for i, point in stroke.points:
    vertices.addDisc(indices, point, radius, stroke.color)
    if i > 0:
      vertices.addSegment(indices, stroke.points[i - 1], point, radius, stroke.color)

proc drawStrokes*(renderer: Renderer, strokes: openArray[Stroke]) =
  ## Opaque strokes only: overlapping triangles of a translucent colour would double up.
  var vertices: seq[Vertex]
  var indices: seq[cint]
  for stroke in strokes:
    vertices.addStroke(indices, stroke)
  if indices.len > 0:
    discard renderer.renderGeometry(nil, vertices, indices)

proc drawRing*(renderer: Renderer, center: FPoint, radius: float32, thickness: float32, color: FColor) =
  ## Hollow circle used for the cursor preview.
  var vertices: seq[Vertex]
  var indices: seq[cint]
  let segments = circleSegments(radius + thickness)
  let inner = max(0'f32, radius - thickness / 2)
  let outer = radius + thickness / 2
  for i in 0 ..< segments:
    let angle = float32(i) / float32(segments) * 2 * PI
    vertices.add(Vertex(position: FPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner), color: color))
    vertices.add(Vertex(position: FPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer), color: color))
  for i in 0 ..< segments:
    let a = cint(i * 2)
    let b = cint(((i + 1) mod segments) * 2)
    indices.add([a, a + 1, b, a + 1, b + 1, b])
  discard renderer.renderGeometry(nil, vertices, indices)
