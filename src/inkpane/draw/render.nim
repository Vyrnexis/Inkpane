import std/math

import sdl3

import scene

# Thick, round-jointed lines built from triangles. SDL's renderer only draws 1px lines,
# so every item becomes a mesh: a quad per segment, a disc at each end, and a disc at
# every bend sharp enough to leave a visible gap between its two quads (which also
# rounds the corners of shapes; along a smooth pen line most points need none). Filled shapes add a triangle fan; the highlighter is a
# single flat-ended quad, so its translucent colour never overlaps itself.
#
# Items are only appended while drawing, so the mesh is kept between frames and extended;
# it is rebuilt only when undo, redo, the eraser or clear change the scene's revision.
# A shape being dragged changes on every move, so it is drawn separately until finished.
#
# SDL draws triangles without anti-aliasing, so every edge gets a fringe one screen pixel
# wide that fades to transparent. That smooths edges at the cost of a few vertices, where
# multisampling would need a framebuffer several times the size of the screen.

type
  Mesh* = object
    vertices: seq[Vertex]
    indices: seq[cint]
    revision: int   # scene revision the mesh was built from
    item: int       # item being extended (the last one tessellated)
    point: int      # points of that pen item already tessellated
    pixel: float32  # one screen pixel in logical units: the width of the edge fringe
    capVertex: int  # where the growing pen line's end cap starts, to replace it
    capIndex: int
    background: FColor   # opaque on a whiteboard/blackboard, else transparent

proc clear*(mesh: var Mesh) =
  mesh.vertices.setLen(0)
  mesh.indices.setLen(0)

proc onBackground*(color, background: FColor): FColor =
  ## Auto-contrast: a colour that would vanish on a board (white on white, black on
  ## black) is shown in the opposite one. Only the display changes, not the item.
  result = color
  if background.a < 1:
    return
  let difference = abs(color.r - background.r) + abs(color.g - background.g) + abs(color.b - background.b)
  if difference < 0.45:
    let light = background.r + background.g + background.b > 1.5
    let value = if light: 0.05'f32 else: 1'f32
    result = FColor(r: value, g: value, b: value, a: color.a)

proc shown*(item: Item, background: FColor): FColor =
  ## The colour an item is drawn in. An AI picks its colours for the board on purpose
  ## (light tints on a whiteboard), so only hand-drawn items get auto-contrast.
  if item.byAi: item.color else: item.color.onBackground(background)

proc setBackground*(mesh: var Mesh, background: FColor) =
  ## Called when the board changes; the next update rebuilds the mesh in its colours.
  if background != mesh.background:
    mesh.background = background
    mesh.revision = -1

proc setPixelSize*(mesh: var Mesh, size: float32) =
  ## Called when the monitor's scale changes; the next update rebuilds the mesh.
  if size != mesh.pixel:
    mesh.pixel = size
    mesh.revision = -1

proc pixelSize*(mesh: Mesh): float32 =
  mesh.pixel

proc transparent(color: FColor): FColor =
  FColor(r: color.r, g: color.g, b: color.b, a: 0)

proc fringe(mesh: Mesh): float32 =
  if mesh.pixel > 0: mesh.pixel else: 1

proc circleSegments(radius: float32): int =
  # Enough segments that the edge looks round at this size, without wasting vertices.
  clamp(int(radius * 1.6), 8, 48)

proc addDisc*(mesh: var Mesh, center: FPoint, radius: float32, color: FColor) =
  ## Solid up to half a pixel inside `radius`, fading out to half a pixel outside.
  let segments = circleSegments(radius)
  let half = mesh.fringe / 2
  let inner = max(radius - half, 0)
  let outer = radius + half
  let edge = transparent(color)
  let base = cint(mesh.vertices.len)
  mesh.vertices.add(Vertex(position: center, color: color))
  for i in 0 ..< segments:
    let angle = float32(i) / float32(segments) * 2 * PI
    let (dx, dy) = (cos(angle), sin(angle))
    mesh.vertices.add(Vertex(position: FPoint(x: center.x + dx * inner, y: center.y + dy * inner), color: color))
    mesh.vertices.add(Vertex(position: FPoint(x: center.x + dx * outer, y: center.y + dy * outer), color: edge))
  for i in 0 ..< segments:
    let a = base + 1 + cint(i * 2)
    let b = base + 1 + cint(((i + 1) mod segments) * 2)
    mesh.indices.add([base, a, b, a, a + 1, b, a + 1, b + 1, b])

proc addSegment*(mesh: var Mesh, a, b: FPoint, radius: float32, color: FColor) =
  let dx = b.x - a.x
  let dy = b.y - a.y
  let span = length(dx, dy)
  if span < 0.001:
    return
  # Unit perpendicular; the quad is solid to half a pixel inside each side and fades out
  # to half a pixel outside. The ends are left hard: paths cover them with discs.
  let nx = -dy / span
  let ny = dx / span
  let half = mesh.fringe / 2
  let edge = transparent(color)
  let base = cint(mesh.vertices.len)
  for (offset, c) in [(radius + half, edge), (max(radius - half, 0), color),
                      (-max(radius - half, 0), color), (-radius - half, edge)]:
    mesh.vertices.add(Vertex(position: FPoint(x: a.x + nx * offset, y: a.y + ny * offset), color: c))
    mesh.vertices.add(Vertex(position: FPoint(x: b.x + nx * offset, y: b.y + ny * offset), color: c))
  for strip in 0 .. 2:
    let s = base + cint(strip * 2)
    mesh.indices.add([s, s + 1, s + 2, s + 1, s + 3, s + 2])

proc needsJoint(mesh: Mesh, a, b, c: FPoint, radius: float32): bool =
  ## Whether the bend at `b` opens a gap of half a pixel or more on its outer side.
  var turn = abs(angle(c.y - b.y, c.x - b.x) - angle(b.y - a.y, b.x - a.x))
  if turn > PI:
    turn = 2 * PI - turn
  radius * turn > mesh.fringe / 2

proc addPath*(mesh: var Mesh, path: openArray[FPoint], width: float32, color: FColor,
    first = 0) =
  ## Tessellates path[first ..]. Continuing a path (first > 0) must follow the call that
  ## added its earlier points: the end cap left then is replaced, since that end is now
  ## a bend.
  let radius = width / 2
  if first > 0:
    mesh.vertices.setLen(mesh.capVertex)
    mesh.indices.setLen(mesh.capIndex)
  elif path.len > 0:
    mesh.addDisc(path[0], radius, color)   # start cap
  for i in max(first, 1) .. path.high:
    if i >= 2 and mesh.needsJoint(path[i - 2], path[i - 1], path[i], radius):
      mesh.addDisc(path[i - 1], radius, color)
    mesh.addSegment(path[i - 1], path[i], radius, color)
  mesh.capVertex = mesh.vertices.len
  mesh.capIndex = mesh.indices.len
  if path.len > 1:
    mesh.addDisc(path[^1], radius, color)  # end cap

proc addFill*(mesh: var Mesh, path: openArray[FPoint], color: FColor) =
  ## Fan from the centre: every fillable shape is convex. The outline is closed, so the
  ## last point repeats the first and closes the fan.
  var center: FPoint
  for p in path:
    center.x += p.x / float32(path.len)
    center.y += p.y / float32(path.len)
  let base = cint(mesh.vertices.len)
  let edge = transparent(color)
  mesh.vertices.add(Vertex(position: center, color: color))
  for p in path:
    # Each point pushed one pixel away from the centre gives the fading edge.
    let dx = p.x - center.x
    let dy = p.y - center.y
    let reach = max(length(dx, dy), 0.001)
    let push = mesh.fringe / reach
    mesh.vertices.add(Vertex(position: p, color: color))
    mesh.vertices.add(Vertex(position: FPoint(x: p.x + dx * push, y: p.y + dy * push), color: edge))
  for i in 0 ..< path.high:
    let a = base + 1 + cint(i * 2)
    let b = a + 2
    mesh.indices.add([base, a, b, a, a + 1, b, a + 1, b + 1, b])

proc addShape(mesh: var Mesh, item: Item) =
  let color = item.shown(mesh.background)
  case item.kind
  of Text:
    return   # textures, drawn by the caller
  of Marker:   # the disc; its number is text
    let a = item.points[0]
    let b = item.points[1]
    mesh.addDisc(FPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), (b.x - a.x) / 2, color)
    return
  else:
    discard
  if item.kind == Highlighter:
    mesh.addSegment(item.points[0], item.points[1], item.width / 2, color)
    return
  for path in item.outline():
    if item.filled:
      mesh.addFill(path, color)
    mesh.addPath(path, item.width, color)

proc activeShape(scene: Scene): bool =
  scene.drawing and scene.items[^1].kind != Pen

proc update*(mesh: var Mesh, scene: Scene) =
  ## Brings the mesh up to date with the scene, tessellating only what it has not seen.
  if mesh.revision != scene.revision:
    mesh.clear()
    mesh.revision = scene.revision
    mesh.item = 0
    mesh.point = 0
  let count = scene.items.len - ord(scene.activeShape)
  while mesh.item < count:
    template item: untyped = scene.items[mesh.item]
    if item.kind == Pen:
      mesh.addPath(item.points, item.width, item.shown(mesh.background), mesh.point)
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

proc drawActiveShape*(renderer: Renderer, cached: Mesh, scene: Scene) =
  ## The shape being dragged, which the cached mesh leaves out until it is finished.
  if scene.activeShape:
    var mesh = Mesh(pixel: cached.pixel, background: cached.background)
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
