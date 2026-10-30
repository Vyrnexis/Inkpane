import std/math

import sdl3

import scene

# Thick, round-jointed lines built from triangles. SDL's renderer only draws 1px lines,
# so every stroke becomes a mesh: a quad per segment plus a disc at every point.
#
# Strokes only grow while drawing, so the mesh is kept between frames and extended with
# the new points; it is rebuilt only when undo, redo or clear change the scene's revision.

type
  Mesh* = object
    vertices: seq[Vertex]
    indices: seq[cint]
    revision: int   # scene revision the mesh was built from
    stroke: int     # stroke being extended (the last one tessellated)
    point: int      # points of that stroke already tessellated

proc circleSegments(radius: float32): int =
  # Enough segments that the edge looks round at this size, without wasting vertices.
  clamp(int(radius * 1.6), 8, 48)

proc addDisc(mesh: var Mesh, center: FPoint, radius: float32, color: FColor) =
  let segments = circleSegments(radius)
  let centerIndex = cint(mesh.vertices.len)
  mesh.vertices.add(Vertex(position: center, color: color))
  for i in 0 ..< segments:
    let angle = float32(i) / float32(segments) * 2 * PI
    mesh.vertices.add(Vertex(
      position: FPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius),
      color: color
    ))
  for i in 0 ..< segments:
    mesh.indices.add([centerIndex, centerIndex + 1 + cint(i), centerIndex + 1 + cint((i + 1) mod segments)])

proc addSegment(mesh: var Mesh, a, b: FPoint, radius: float32, color: FColor) =
  let dx = b.x - a.x
  let dy = b.y - a.y
  let length = sqrt(dx * dx + dy * dy)
  if length < 0.001:
    return
  # Perpendicular offset of half the line width.
  let nx = -dy / length * radius
  let ny = dx / length * radius
  let base = cint(mesh.vertices.len)
  mesh.vertices.add(Vertex(position: FPoint(x: a.x + nx, y: a.y + ny), color: color))
  mesh.vertices.add(Vertex(position: FPoint(x: a.x - nx, y: a.y - ny), color: color))
  mesh.vertices.add(Vertex(position: FPoint(x: b.x + nx, y: b.y + ny), color: color))
  mesh.vertices.add(Vertex(position: FPoint(x: b.x - nx, y: b.y - ny), color: color))
  mesh.indices.add([base, base + 1, base + 2, base + 1, base + 3, base + 2])

proc update*(mesh: var Mesh, scene: Scene) =
  ## Brings the mesh up to date with the scene, tessellating only points it has not seen.
  if mesh.revision != scene.revision:
    mesh.vertices.setLen(0)
    mesh.indices.setLen(0)
    mesh.revision = scene.revision
    mesh.stroke = 0
    mesh.point = 0
  while mesh.stroke < scene.strokes.len:
    template stroke: untyped = scene.strokes[mesh.stroke]
    let radius = stroke.width / 2
    for i in mesh.point ..< stroke.points.len:
      mesh.addDisc(stroke.points[i], radius, stroke.color)
      if i > 0:
        mesh.addSegment(stroke.points[i - 1], stroke.points[i], radius, stroke.color)
    mesh.point = stroke.points.len
    if mesh.stroke == scene.strokes.high:
      break   # the last stroke may still grow
    inc mesh.stroke
    mesh.point = 0

proc draw*(renderer: Renderer, mesh: Mesh) =
  ## Opaque strokes only: overlapping triangles of a translucent colour would double up.
  if mesh.indices.len > 0:
    discard renderer.renderGeometry(nil, mesh.vertices, mesh.indices)

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
