import std/math

import sdl3

import scene

# Thick, round-jointed lines built from triangles. SDL's renderer only draws 1px lines,
# so every item becomes a mesh: a quad per segment plus a disc at every point (which
# also rounds the corners of shapes). Filled shapes add a triangle fan; the highlighter is a
# single flat-ended quad, so its translucent colour never overlaps itself.
#
# Items are only appended while drawing, so the mesh is kept between frames and extended;
# it is rebuilt only when undo, redo, the eraser or clear change the scene's revision.
# A shape being dragged changes on every move, so it is drawn separately until finished.

type
  Mesh* = object
    vertices: seq[Vertex]
    indices: seq[cint]
    revision: int   # scene revision the mesh was built from
    item: int       # item being extended (the last one tessellated)
    point: int      # points of that pen item already tessellated

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

proc addPath(mesh: var Mesh, path: openArray[FPoint], first: int, item: Item) =
  ## Tessellates path[first ..], joining it to the point before `first`.
  let radius = item.width / 2
  for i in first ..< path.len:
    mesh.addDisc(path[i], radius, item.color)
    if i > 0:
      mesh.addSegment(path[i - 1], path[i], radius, item.color)

proc addFill(mesh: var Mesh, path: openArray[FPoint], color: FColor) =
  ## Fan from the centre: every fillable shape is convex. The outline is closed, so the
  ## last point repeats the first and closes the fan.
  var center: FPoint
  for p in path:
    center.x += p.x / float32(path.len)
    center.y += p.y / float32(path.len)
  let base = cint(mesh.vertices.len)
  mesh.vertices.add(Vertex(position: center, color: color))
  for p in path:
    mesh.vertices.add(Vertex(position: p, color: color))
  for i in 1 ..< path.len:
    mesh.indices.add([base, base + cint(i), base + cint(i) + 1])

proc addShape(mesh: var Mesh, item: Item) =
  if item.kind == Highlighter:
    mesh.addSegment(item.points[0], item.points[1], item.width / 2, item.color)
    return
  for path in item.outline():
    if item.filled:
      mesh.addFill(path, item.color)
    mesh.addPath(path, 0, item)

proc activeShape(scene: Scene): bool =
  scene.drawing and scene.items[^1].kind != Pen

proc update*(mesh: var Mesh, scene: Scene) =
  ## Brings the mesh up to date with the scene, tessellating only what it has not seen.
  if mesh.revision != scene.revision:
    mesh.vertices.setLen(0)
    mesh.indices.setLen(0)
    mesh.revision = scene.revision
    mesh.item = 0
    mesh.point = 0
  let count = scene.items.len - ord(scene.activeShape)
  while mesh.item < count:
    template item: untyped = scene.items[mesh.item]
    if item.kind == Pen:
      mesh.addPath(item.points, mesh.point, item)
      mesh.point = item.points.len
      if scene.drawing and mesh.item == scene.items.high:
        break   # this pen stroke is still growing
    else:
      mesh.addShape(item)
    inc mesh.item
    mesh.point = 0

proc draw*(renderer: Renderer, mesh: Mesh) =
  ## Overlapping triangles of a translucent colour would double up, so only the highlighter
  ## (one quad per item) is translucent.
  if mesh.indices.len > 0:
    discard renderer.renderGeometry(nil, mesh.vertices, mesh.indices)

proc drawActiveShape*(renderer: Renderer, scene: Scene) =
  ## The shape being dragged, which the cached mesh leaves out until it is finished.
  if scene.activeShape:
    var mesh: Mesh
    mesh.addShape(scene.items[^1])
    renderer.draw(mesh)

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
