import std/[base64, json, math, os, osproc, sequtils, strutils, unicode]

import inkpane/desktop/[dbus, glib, remote]

# inkpane-mcp: an MCP server (newline-delimited JSON-RPC 2.0 on stdio) that lets an AI
# client draw on the user's screen and take screenshots by calling the running Inkpane
# over D-Bus. Only JSON-RPC goes to stdout; diagnostics go to stderr.

const
  Service = "org.vyrnexis.Inkpane"
  ObjectPath = "/org/vyrnexis/Inkpane"
  MaxSide = 1568.0          # images beyond these limits get resized by the API, which
  MaxPixels = 1_150_000.0   # would break the coordinates we hand to the model
  CaptureTimeoutMs = 130_000   # Inkpane waits up to 120 s for the permission dialog
  # Defaults in screenshot pixels, so marks keep the proportions the model sees whatever
  # the monitor's size: 16 px text is 24 px on screen at 1080p, 35 px on a 3440 px screen.
  DefaultFont = 16.0
  DefaultRadius = 11.0   # step markers
  DefaultWidth = 3.0
  Versions = ["2024-11-05", "2025-03-26", "2025-06-18"]
  Colors = {
    "red": "#ed3333", "orange": "#fa8c21", "yellow": "#fad926", "green": "#33c759",
    "blue": "#3385fa", "purple": "#9e59e6", "white": "#ffffff", "black": "#0d0d0d",
  }
  Instructions = """Inkpane draws on the user's real screen. You can only draw; the user does all the clicking.
Ask the user before your first screenshot in a session, and say when you take one.
Teach one step at a time: take a screenshot, mark one thing (`circle` it, or an arrow, plus a 2-4 word label, or a step marker), explain why in chat, wait for the user, screenshot again to check, then `clear` before the next step.
Keep at most about three marks on screen.
Coordinates are pixels of the latest screenshot of that monitor, origin top-left."""

type
  ToolError = object of CatchableError

  Monitor = object
    name: string
    x, y, w, h: int   # logical px, in desktop coordinates
    scale: float   # model px per logical px

############################
# Inkpane Connection
############################

proc call(methodName: string, parameters: GVariant = nil, timeoutMs = 30_000): GVariant =
  dbus.call(Service, ObjectPath, Service, methodName, parameters, timeoutMs)

proc running(): bool =
  try:
    let reply = dbus.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "NameHasOwner", g_variant_new("(s)", Service.cstring))
    var owned: cint
    g_variant_get(reply, "(b)", addr owned)
    g_variant_unref(reply)
    owned != 0
  except CatchableError:
    false

proc ensureRunning() =
  ## Start `inkpane` (next to us first, then on PATH) when it is not on the bus yet.
  if running():
    return
  var exe = getAppDir() / "inkpane"
  if not fileExists(exe):
    exe = findExe("inkpane")
  if exe.len > 0:
    try:
      # poDaemon detaches it, so it outlives this server.
      discard startProcess(exe, options = {poDaemon})
    except CatchableError:
      stderr.writeLine("inkpane-mcp: could not start " & exe & ": " & getCurrentExceptionMsg())
    for _ in 1 .. 50:
      sleep(100)
      if running():
        return
  raise newException(ToolError,
    "Inkpane is not running and could not be started; install it and run `inkpane &`")

############################
# Monitors and Model Space
############################

proc monitors(): seq[Monitor] =
  ## Queried on every call that needs it: monitors come and go.
  let reply = call("Monitors")
  let list = g_variant_get_child_value(reply, 0)   # reply is (a(siiii))
  for i in 0 ..< int(g_variant_n_children(list)):
    let item = g_variant_get_child_value(list, csize_t(i))
    let name = g_variant_get_child_value(item, 0)
    let x = g_variant_get_child_value(item, 1)
    let y = g_variant_get_child_value(item, 2)
    let w = g_variant_get_child_value(item, 3)
    let h = g_variant_get_child_value(item, 4)
    var m = Monitor(name: $g_variant_get_string(name, nil),
      x: int(g_variant_get_int32(x)), y: int(g_variant_get_int32(y)),
      w: int(g_variant_get_int32(w)), h: int(g_variant_get_int32(h)))
    m.scale = min(1.0, min(MaxSide / float(max(m.w, m.h)),
      sqrt(MaxPixels / float(m.w * m.h))))
    result.add m
    for part in [name, x, y, w, h, item]:
      g_variant_unref(part)
  g_variant_unref(list)
  g_variant_unref(reply)

proc modelSize(m: Monitor): (int, int) =
  (int(round(float(m.w) * m.scale)), int(round(float(m.h) * m.scale)))

proc pick(args: JsonNode): (int, Monitor) =
  let all = monitors()
  if all.len == 0:
    raise newException(ToolError, "Inkpane reports no monitors")
  let index = if args.hasKey("monitor"): args["monitor"] else: %0
  if index.kind != JInt or index.getInt notin 0 ..< all.len:
    raise newException(ToolError, "monitor must be an integer from 0 to " & $(all.len - 1))
  (index.getInt, all[index.getInt])

############################
# Argument Parsing
############################

proc number(args: JsonNode, key: string, default: float): float =
  if not args.hasKey(key) or args[key].kind == JNull:
    return default
  if args[key].kind notin {JInt, JFloat}:
    raise newException(ToolError, key & " must be a number")
  args[key].getFloat

proc text(args: JsonNode, key: string, default = ""): string =
  if not args.hasKey(key) or args[key].kind == JNull:
    return default
  if args[key].kind != JString:
    raise newException(ToolError, key & " must be a string")
  args[key].getStr

proc flag(args: JsonNode, key: string): bool =
  if not args.hasKey(key) or args[key].kind == JNull:
    return false
  if args[key].kind != JBool:
    raise newException(ToolError, key & " must be true or false")
  args[key].getBool

proc color(args: JsonNode, key = "color"): string =
  ## "" lets Inkpane pick its default (red).
  let value = text(args, key).toLowerAscii
  if value.len == 0:
    return ""
  for (name, hex) in Colors:
    if value == name:
      return hex
  if value.len == 7 and value[0] == '#' and value[1 .. ^1].allCharsInSet(HexDigits):
    return value
  raise newException(ToolError, "unknown color '" & value &
    "'; use red, orange, yellow, green, blue, purple, white, black or #rrggbb")

proc points(args: JsonNode, m: Monitor, minCount, maxCount: int): GVariant =
  ## Model-space [[x, y], ...] to an a(dd) of logical px.
  let list = if args.hasKey("points"): args["points"] else: newJNull()
  if list.kind != JArray or list.len < minCount or list.len > maxCount:
    raise newException(ToolError, "points must be an array of " &
      (if minCount == maxCount: $minCount else: "at least " & $minCount) & " [x, y] pairs")
  let builder = newBuilder("a(dd)")
  for p in list:
    if p.kind != JArray or p.len != 2 or p[0].kind notin {JInt, JFloat} or
        p[1].kind notin {JInt, JFloat}:
      raise newException(ToolError, "each point must be [x, y] with numbers")
    g_variant_builder_add(builder, "(dd)", cdouble(p[0].getFloat / m.scale),
      cdouble(p[1].getFloat / m.scale))
  builder.finish

proc plain(s: string): string =
  ## Inkpane draws text in one font, and common ones (Noto Sans) have no arrows or ticks.
  ## Markdown emphasis means nothing on screen either.
  s.multiReplace(("→", "->"), ("⇒", "=>"), ("←", "<-"), ("⇐", "<="), ("↔", "<->"),
    ("✓", "OK"), ("✔", "OK"), ("✗", "X"), ("✘", "X"), ("**", ""), ("`", ""))

proc draw(monitor: int, kind: string, pts: GVariant, color: string, width: float,
    filled: bool, label = "") =
  g_variant_unref(call("Draw", g_variant_new("(is@a(dd)sdbs)", cint(monitor), kind.cstring,
    pts, color.cstring, cdouble(width), cint(filled), plain(label).cstring)))

############################
# Tools
############################

proc reply(text: string): JsonNode =
  %*{"content": [{"type": "text", "text": text}]}

proc screenInfo(args: JsonNode): JsonNode =
  var lines: seq[string]
  for i, m in monitors():
    let (w, h) = m.modelSize
    lines.add "Monitor " & $i & " (" & m.name & "): " & $w & "x" & $h & " px"
  if lines.len == 0:
    raise newException(ToolError, "Inkpane reports no monitors")
  lines.add "Coordinates are pixels of that monitor's screenshot, origin at the top-left, x to the right, y down."
  reply(lines.join("\n"))

proc screenshot(args: JsonNode): JsonNode =
  let (index, m) = pick(args)
  let (w, h) = m.modelSize
  let r = call("Capture", g_variant_new("(iiiiiii)", cint(index), cint(0), cint(0), cint(0), cint(0),
    cint(w), cint(h)), CaptureTimeoutMs)
  var path: cstring
  g_variant_get(r, "(&s)", addr path)
  let file = $path
  g_variant_unref(r)
  var png: string
  try:
    png = readFile(file)
  except IOError:
    raise newException(ToolError, "could not read the screenshot " & file)
  %*{"content": [
    {"type": "image", "data": encode(png), "mimeType": "image/png"},
    {"type": "text", "text": "Monitor " & $index & " (" & m.name & "), " & $w & "x" & $h &
      " px. Draw with these coordinates. Your own marks are visible in it; Inkpane's toolbar is hidden."}]}

proc box(args: JsonNode, key: string): (float, float, float, float) =
  ## [left, top, right, bottom], in either order.
  let b = if args.hasKey(key): args[key] else: newJNull()
  if b.kind != JArray or b.len != 4 or b.anyIt(it.kind notin {JInt, JFloat}):
    raise newException(ToolError, key & " must be [left, top, right, bottom]")
  (min(b[0].getFloat, b[2].getFloat), min(b[1].getFloat, b[3].getFloat),
   max(b[0].getFloat, b[2].getFloat), max(b[1].getFloat, b[3].getFloat))

proc saveScreenshot(args: JsonNode): JsonNode =
  ## A tutorial image: the area at the screen's real resolution, with the marks on it.
  let file = text(args, "file")
  if file.len == 0 or not file.toLowerAscii.endsWith(".png"):
    raise newException(ToolError, "file must be a path ending in .png")
  let (index, m) = pick(args)
  var area = (0, 0, 0, 0)
  if args.hasKey("region"):
    let (l, t, r, b) = box(args, "region")
    area = (int(l / m.scale), int(t / m.scale), int((r - l) / m.scale), int((b - t) / m.scale))
    if area[2] < 8 or area[3] < 8:
      raise newException(ToolError, "region is too small")
  let captured = call("Capture", g_variant_new("(iiiiiii)", cint(index), cint(area[0]),
    cint(area[1]), cint(area[2]), cint(area[3]), cint(0), cint(0)), CaptureTimeoutMs)
  var path: cstring
  g_variant_get(captured, "(&s)", addr path)
  let source = $path
  g_variant_unref(captured)
  let target = absolutePath(file.expandTilde)
  try:
    createDir(target.parentDir)
    copyFile(source, target)
  except OSError, IOError:
    raise newException(ToolError, "could not save " & target & ": " & getCurrentExceptionMsg())
  reply("Saved " & target & ".")

proc wrapText(s: string, size, maxWidth: float): seq[string] =
  ## Lines no wider than maxWidth, guessing ~0.52 em per character.
  let columns = max(int(maxWidth / (size * 0.52)), 8)
  for paragraph in s.split('\n'):
    var line = ""
    for word in strutils.splitWhitespace(paragraph):
      if line.len > 0 and line.runeLen + 1 + word.runeLen > columns:
        result.add(line)
        line = word
      else:
        line = if line.len == 0: word else: line & " " & word
    result.add(line)

proc callout(args: JsonNode): JsonNode =
  ## A step's card: a short paragraph on a white card beside the target, with an arrow
  ## from the card to it and the step number on the card's corner.
  let body = text(args, "text")
  if body.len == 0:
    raise newException(ToolError, "text must not be empty")
  let (index, m) = pick(args)
  let (l, t, r, b) = box(args, "target")
  let size = number(args, "size", DefaultFont)
  let accent = color(args)
  let step = int(number(args, "step", 0))
  let lines = wrapText(plain(body), size, number(args, "max_width", 320))
  let pad = 14.0
  let w = float(lines.mapIt(it.runeLen).max) * size * 0.52 + 2 * pad
  let h = float(lines.len) * size * 1.4 + 2 * pad
  let gap = 48.0
  let (mw, mh) = m.modelSize
  let (cx, cy) = ((l + r) / 2, (t + b) / 2)
  var (x, y) = case text(args, "side", "right")
    of "right": (r + gap, cy - h / 2)
    of "left": (l - gap - w, cy - h / 2)
    of "above": (cx - w / 2, t - gap - h)
    of "below": (cx - w / 2, b + gap)
    else: raise newException(ToolError, "side must be right, left, above or below")
  x = clamp(x, 8, max(float(mw) - w - 8, 8))
  y = clamp(y, 8, max(float(mh) - h - 8, 8))
  # The arrow runs from the card's edge nearest the target to just short of the target.
  let tail = (clamp(cx, x, x + w), clamp(cy, y, y + h))
  let head = (clamp(tail[0], l - 6, r + 6), clamp(tail[1], t - 6, b + 6))
  draw(index, "rectangle", points(%*{"points": [[x, y], [x + w, y + h]]}, m, 2, 2), "#ffffff",
    1 / m.scale, true)
  draw(index, "rectangle", points(%*{"points": [[x, y], [x + w, y + h]]}, m, 2, 2),
    (if accent.len > 0: accent else: "#2563eb"), 2 / m.scale, false)
  draw(index, "text", points(%*{"points": [[x + pad, y + pad]]}, m, 1, 1), "#1e293b",
    size / m.scale, false, lines.join("\n"))
  if hypot(head[0] - tail[0], head[1] - tail[1]) > 12:
    draw(index, "arrow", points(%*{"points": [[tail[0], tail[1]], [head[0], head[1]]]}, m, 2, 2),
      (if accent.len > 0: accent else: "#2563eb"), DefaultWidth / m.scale, false)
  if step > 0:
    draw(index, "marker", points(%*{"points": [[x, y]]}, m, 1, 1),
      (if accent.len > 0: accent else: "#2563eb"), 13 / m.scale, false, $step)
  reply("Callout drawn: card [" & $int(x) & ", " & $int(y) & ", " & $int(x + w) & ", " &
    $int(y + h) & "].")

############################
# Clicking and typing (only when the user allowed it)
############################

var session: RemoteSession   # started on the first click or key, kept for the session

proc clickingAllowed(): bool =
  ## The user's choice in inkpane.conf, [ai] clicking; read on every use, so turning it
  ## off takes effect at once.
  var section = ""
  try:
    for raw in lines(getConfigDir() / "inkpane" / "inkpane.conf"):
      let line = raw.strip
      if line.startsWith("["):
        section = line.strip(chars = {'[', ']', ' '})
      elif section == "ai" and line.startsWith("clicking") and '=' in line:
        let value = line.split('=', 1)[1].strip(chars = {' ', '"'}).toLowerAscii
        return value in ["yes", "true", "on", "1"]
  except IOError, OSError:
    discard
  false

proc ensureSession() =
  if not clickingAllowed():
    raise newException(ToolError, "The user has not allowed AI clicking ([ai] clicking in " &
      "~/.config/inkpane/inkpane.conf). Ask them to do this step.")
  if session.isNil:
    try:
      session = remote.start()
    except CatchableError:
      raise newException(ToolError, "The desktop did not allow input control: " &
        getCurrentExceptionMsg())

proc checkReachable(index: int, x, y: float) =
  ## A click must reach the app: not draw on Inkpane's overlay, not press its toolbar.
  let status = call("Status")
  var open, through: cint
  var bars: GVariant
  g_variant_get(status, "(bb@a(iiii))", addr open, addr through, addr bars)
  g_variant_unref(status)
  defer: g_variant_unref(bars)
  if open != 0 and through == 0:
    raise newException(ToolError, "Inkpane is in drawing mode, so a click would draw. Ask " &
      "the user to switch to click-through (1 or V), or call clear and close if your marks " &
      "are no longer needed.")
  if open != 0 and index < int(g_variant_n_children(bars)):
    let bar = g_variant_get_child_value(bars, csize_t(index))
    var bx, by, bw, bh: int32
    g_variant_get(bar, "(iiii)", addr bx, addr by, addr bw, addr bh)
    g_variant_unref(bar)
    if x >= float(bx) and x < float(bx + bw) and y >= float(by) and y < float(by + bh):
      raise newException(ToolError, "That spot is under Inkpane's toolbar (hidden in your " &
        "screenshots). Ask the user to move the toolbar or hide it with Tab.")

proc pointAt(args: JsonNode): (int, Stream, float, float) =
  ## The monitor's stream and the point on it in logical px, after the checks.
  let (index, m) = pick(args)
  let (x, y) = (number(args, "x", -1) / m.scale, number(args, "y", -1) / m.scale)
  if x < 0 or y < 0 or x >= float(m.w) or y >= float(m.h):
    raise newException(ToolError, "x and y must be inside the screenshot")
  checkReachable(index, x, y)
  ensureSession()
  let found = session.streams.filterIt(it.x == m.x and it.y == m.y)
  let stream = if found.len > 0: found[0]
               elif index < session.streams.len: session.streams[index]
               else: raise newException(ToolError, "The desktop did not share monitor " & $index)
  # Stream sizes can differ from the monitor's logical size; scale into them.
  let sx = if stream.w > 0: float(stream.w) / float(m.w) else: 1.0
  let sy = if stream.h > 0: float(stream.h) / float(m.h) else: 1.0
  (index, stream, x * sx, y * sy)

proc clickTool(args: JsonNode): JsonNode =
  let (index, stream, x, y) = pointAt(args)
  let which = text(args, "button", "left")
  var code = 0'i32
  for (name, c) in ButtonCodes:
    if name == which: code = c
  if code == 0:
    raise newException(ToolError, "button must be left, right or middle")
  session.moveTo(stream, x, y)
  for _ in 1 .. (if flag(args, "double"): 2 else: 1):
    session.button(code, true)
    session.button(code, false)
  reply("Clicked " & which & " at " & $int(number(args, "x", 0)) & ", " &
    $int(number(args, "y", 0)) & " on monitor " & $index & ". Take a screenshot to see what it did.")

proc scrollTool(args: JsonNode): JsonNode =
  let (_, stream, x, y) = pointAt(args)
  let steps = int(number(args, "amount", 0))
  if steps == 0 or abs(steps) > 30:
    raise newException(ToolError, "amount must be -30 .. 30 notches, not 0")
  session.moveTo(stream, x, y)
  session.scroll(steps)
  reply("Scrolled " & $steps & " notches.")

proc typeText(args: JsonNode): JsonNode =
  let s = text(args, "text")
  if s.len == 0 or s.runeLen > 2000:
    raise newException(ToolError, "text must be 1 to 2000 characters")
  ensureSession()
  for rune in s.runes:
    let sym = keysymFor(rune)
    session.key(sym, true)
    session.key(sym, false)
  reply("Typed " & $s.runeLen & " characters into the focused field.")

proc pressKeys(args: JsonNode): JsonNode =
  ## "ctrl+s", "enter", "alt+f4" …: modifiers held while the last key is pressed.
  let combo = text(args, "keys")
  let parts = combo.split('+').mapIt(it.strip)
  if parts.len == 0 or parts.anyIt(it.len == 0):
    raise newException(ToolError, "keys must look like ctrl+s or enter")
  var syms: seq[int]
  for part in parts:
    let sym = namedKeysym(part)
    if sym < 0:
      raise newException(ToolError, "unknown key " & part)
    syms.add(sym)
  ensureSession()
  for sym in syms:
    session.key(sym, true)
  for i in countdown(syms.high, 0):
    session.key(syms[i], false)
  reply("Pressed " & combo & ".")

proc drawTool(args: JsonNode): JsonNode =
  let kind = text(args, "kind")
  if kind notin ["rectangle", "ellipse", "diamond", "arrow", "line", "highlighter", "pen"]:
    raise newException(ToolError, "kind must be rectangle, ellipse, diamond, arrow, line, highlighter or pen")
  let (index, m) = pick(args)
  let pts = points(args, m, 2, (if kind == "pen": 10_000 else: 2))
  let label = text(args, "label")
  let closed = kind in ["rectangle", "ellipse", "diamond"]
  if label.len > 0 and kind notin ["rectangle", "ellipse", "diamond", "arrow", "line"]:
    raise newException(ToolError, "label is for shapes, arrows and lines; use add_text")
  # Everything is checked before anything is drawn, so an error never leaves half a mark.
  let (labelColor, labelSize) = (color(args, "label_color"), number(args, "size", DefaultFont))
  let fill = color(args, "fill_color")
  if fill.len > 0 and not closed:
    raise newException(ToolError, "fill_color is for rectangle, ellipse and diamond")
  if fill.len > 0:   # a card: the tinted inside first, the outline over its edge
    draw(index, kind, points(args, m, 2, 2), fill, 1, true)
  draw(index, kind, pts, color(args), number(args, "width", DefaultWidth) / m.scale,
    flag(args, "filled"))
  if label.len > 0 and closed:   # Inkpane centres it in the shape's box
    draw(index, "text", points(args, m, 2, 2), labelColor, labelSize / m.scale, false, label)
  elif label.len > 0:
    # Beside the middle of the arrow, clear of the line: above a level one (centred by
    # Inkpane, which knows the text's width), to the right of a steep one.
    let (a, b) = (args["points"][0], args["points"][1])
    let (ax, ay, bx, by) = (a[0].getFloat, a[1].getFloat, b[0].getFloat, b[1].getFloat)
    let (mx, my) = ((ax + bx) / 2, (ay + by) / 2)
    let length = max(hypot(bx - ax, by - ay), 1)
    let (dx, dy) = ((bx - ax) / length, (by - ay) / length)
    let at =
      if abs(dx) >= 0.5:
        var (nx, ny) = (dy, -dx)   # the normal pointing up the screen
        if ny > 0: (nx, ny) = (-nx, -ny)
        let reach = labelSize * 0.75 + 6
        let (cx, cy) = (mx + nx * reach, my + ny * reach)
        %*{"points": [[cx, cy], [cx, cy]]}
      else:
        %*{"points": [[mx + 10, my - labelSize * 0.7]]}
    draw(index, "text", points(at, m, 1, 2), labelColor, labelSize / m.scale, false, label)
  reply("Drew " & kind & (if label.len > 0: " with its label" else: "") & " on monitor " &
    $index & ".")

proc circle(args: JsonNode): JsonNode =
  ## An ellipse inside a box only touches the box's sides, so one drawn on a control's
  ## own box cuts its corners: grow it by √2 (through the corners) plus a margin.
  let box = if args.hasKey("box"): args["box"] else: newJNull()
  if box.kind != JArray or box.len != 4 or box.anyIt(it.kind notin {JInt, JFloat}):
    raise newException(ToolError, "box must be [left, top, right, bottom]")
  let (left, top) = (min(box[0].getFloat, box[2].getFloat), min(box[1].getFloat, box[3].getFloat))
  let (right, bottom) = (max(box[0].getFloat, box[2].getFloat), max(box[1].getFloat, box[3].getFloat))
  let (cx, cy) = ((left + right) / 2, (top + bottom) / 2)
  let rx = (right - left) / 2 * sqrt(2.0) + 4
  let ry = (bottom - top) / 2 * sqrt(2.0) + 4
  let (index, m) = pick(args)
  let pts = points(%*{"points": [[cx - rx, cy - ry], [cx + rx, cy + ry]]}, m, 2, 2)
  draw(index, "ellipse", pts, color(args), number(args, "width", DefaultWidth) / m.scale, false)
  result = reply("Circled [" & $int(left) & ", " & $int(top) & ", " & $int(right) & ", " &
    $int(bottom) & "] on monitor " & $index & "; the ellipse spans [" & $int(cx - rx) & ", " &
    $int(cy - ry) & ", " & $int(cx + rx) & ", " & $int(cy + ry) & "].")
  let label = text(args, "label")
  if label.len == 0:
    return
  # The label goes just outside the ellipse on the side asked for. Its width is estimated
  # (about 0.55 em per character); Inkpane's default text is 24 px on screen.
  let font = number(args, "size", DefaultFont)
  let (w, h) = (float(label.runeLen) * font * 0.55, font * 1.25)
  let gap = 8.0
  let (mw, mh) = m.modelSize
  let side = text(args, "label_side", "right")
  var (x, y) = case side
    of "right": (cx + rx + gap, cy - h / 2)
    of "left": (cx - rx - gap - w, cy - h / 2)
    of "above": (cx - w / 2, cy - ry - gap - h)
    of "below": (cx - w / 2, cy + ry + gap)
    else: raise newException(ToolError, "label_side must be right, left, above or below")
  x = clamp(x, 0, max(float(mw) - w, 0))
  y = clamp(y, 0, max(float(mh) - h, 0))
  # Above and below are centred by Inkpane, which knows the text's real width.
  let at = if side in ["above", "below"]: %*{"points": [[cx, y], [cx, y + h]]}
           else: %*{"points": [[x, y]]}
  draw(index, "text", points(at, m, 1, 2), color(args), font / m.scale, false, label)
  result = reply(result["content"][0]["text"].getStr & " Label at about [" & $int(x) & ", " &
    $int(y) & ", " & $int(x + w) & ", " & $int(y + h) & "].")

proc addText(args: JsonNode): JsonNode =
  let label = text(args, "text")
  if label.len == 0:
    raise newException(ToolError, "text must not be empty")
  let (index, m) = pick(args)
  let (x, y) = (number(args, "x", 0), number(args, "y", 0))
  let size = number(args, "size", DefaultFont)
  let maxWidth = number(args, "max_width", 0)
  var shown = label
  if maxWidth > 0:   # wrap at word boundaries, guessing ~0.52 em per character
    let columns = max(int(maxWidth / (size * 0.52)), 8)
    var lines: seq[string]
    for paragraph in shown.split('\n'):
      var line = ""
      for word in strutils.splitWhitespace(paragraph):
        if line.len > 0 and line.runeLen + 1 + word.runeLen > columns:
          lines.add(line)
          line = word
        else:
          line = if line.len == 0: word else: line & " " & word
      lines.add(line)
    shown = lines.join("\n")
  # Two equal points: Inkpane centres the text on them.
  let at = if flag(args, "centered"): %*{"points": [[x, y], [x, y]]} else: %*{"points": [[x, y]]}
  draw(index, "text", points(at, m, 1, 2), color(args), size / m.scale, false, shown)
  let lineCount = shown.count('\n') + 1
  reply("Added text on monitor " & $index & ": " & $lineCount &
    (if lineCount == 1: " line" else: " lines") & ", about " & $int(float(lineCount) * size * 1.4) &
    " px tall.")

proc addStepMarker(args: JsonNode): JsonNode =
  let (index, m) = pick(args)
  let at = %*{"points": [[number(args, "x", 0), number(args, "y", 0)]]}
  let step = int(number(args, "number", 0))
  draw(index, "marker", points(at, m, 1, 1), color(args),
    number(args, "size", DefaultRadius) / m.scale, false, (if step > 0: $step else: ""))
  reply("Added a numbered step marker on monitor " & $index & ".")

proc undoLast(args: JsonNode): JsonNode =
  let r = call("UndoAi")
  var removed: cint
  g_variant_get(r, "(b)", addr removed)
  g_variant_unref(r)
  reply(if removed != 0: "Removed your most recent mark." else: "You have no marks to remove.")

proc clear(args: JsonNode): JsonNode =
  let scope = text(args, "scope", "ai")
  if scope notin ["ai", "all"]:
    raise newException(ToolError, "scope must be ai or all")
  g_variant_unref(call("Clear", g_variant_new("(b)", cint(scope == "ai"))))
  reply(if scope == "ai": "Removed your marks." else: "Removed all drawing, including the user's.")

proc setBoard(args: JsonNode): JsonNode =
  let board = text(args, "board")
  if board notin ["none", "whiteboard", "blackboard"]:
    raise newException(ToolError, "board must be none, whiteboard or blackboard")
  g_variant_unref(call("SetBoard", g_variant_new("(s)", board.cstring)))
  reply("Board: " & board & ".")

proc close(args: JsonNode): JsonNode =
  g_variant_unref(call("Hide"))
  reply("Closed Inkpane's overlay and cleared all drawing.")

############################
# Tool Schemas
############################

proc schema(description: string, properties: JsonNode, required: seq[string] = @[]): JsonNode =
  %*{"type": "object", "description": description, "properties": properties,
     "required": required}

let monitorProp = %*{"type": "integer", "minimum": 0,
  "description": "Monitor index from screen_info. Default 0."}
let colorProp = %*{"type": "string",
  "description": "red (default), orange, yellow, green, blue, purple, white, black, or #rrggbb."}

proc tool(name, description: string, inputSchema: JsonNode): JsonNode =
  %*{"name": name, "description": description, "inputSchema": inputSchema}

proc inputTools(): JsonNode =
  ## Offered only when the user turned AI clicking on.
  let xy = %*{"type": "number"}
  let caution = " Only when the user asked you to do the steps. Never confirm anything " &
    "that deletes, pays, sends or installs without asking them first, and never type " &
    "passwords. Take a screenshot after each action to see what happened."
  %*[
    tool("click", "Click at x, y (pixels of the latest screenshot of that monitor)." & caution,
      schema("", %*{"x": xy, "y": xy,
        "button": {"type": "string", "enum": ["left", "right", "middle"]},
        "double": {"type": "boolean"}, "monitor": monitorProp}, @["x", "y"])),
    tool("scroll", "Scroll the mouse wheel at x, y: amount in notches, positive down." & caution,
      schema("", %*{"x": xy, "y": xy, "amount": {"type": "integer"}, "monitor": monitorProp},
        @["x", "y", "amount"])),
    tool("type_text", "Type text into the focused field (click it first)." & caution,
      schema("", %*{"text": {"type": "string"}}, @["text"])),
    tool("press_keys", "Press a key or combination, such as enter, tab, esc, ctrl+s or " &
      "alt+left." & caution, schema("", %*{"keys": {"type": "string"}}, @["keys"]))]

proc toolList(): JsonNode =
  let xy = %*{"type": "number"}
  result = %*[
    tool("screen_info", "List the monitors and the size of each one's screenshot. " &
      "Coordinates you give to other tools are pixels of that monitor's screenshot.",
      schema("", %*{})),
    tool("screenshot", "Take a screenshot of one monitor (your own marks included, Inkpane's " &
      "toolbar hidden). Ask the user first, once per session. Draw with the returned " &
      "image's pixel coordinates, origin top-left.",
      schema("", %*{"monitor": monitorProp})),
    tool("draw", "Draw a shape on the user's screen. All points are [x, y] pixels of that " &
      "monitor's latest screenshot, origin top-left. Shapes take 2 points: for rectangle, " &
      "ellipse and diamond the start and the opposite corner; for arrow and line the tail " &
      "and the head (the arrowhead lands on the target); highlighter takes start and end. " &
      "pen takes 2 or more points. To circle something, use an ellipse whose corners lie a " &
      "bit outside it (or use the circle tool, which does that for you).",
      schema("", %*{
        "kind": {"type": "string", "enum": ["rectangle", "ellipse", "diamond", "arrow",
          "line", "highlighter", "pen"]},
        "points": {"type": "array", "minItems": 2,
          "items": {"type": "array", "items": xy, "minItems": 2, "maxItems": 2}},
        "color": colorProp,
        "width": {"type": "number", "description": "Line width in screenshot pixels. Default 3."},
        "filled": {"type": "boolean", "description": "Fill rectangle, ellipse or diamond with its own colour."},
        "fill_color": {"type": "string", "description": "Inside colour of a rectangle, ellipse or diamond, under an outline in `color`: a light tint such as #dbeafe makes a card. #rrggbb or a colour name."},
        "label": {"type": "string", "description": "For a rectangle, ellipse or diamond: text centred inside it. For an arrow or line: a short caption placed beside its middle, clear of the line."},
        "label_color": {"type": "string", "description": "Colour of the label; default red. On a board, black or white reads best."},
        "size": {"type": "number", "description": "Label font size in screenshot pixels. Default 16."},
        "monitor": monitorProp}, @["kind", "points"])),
    tool("circle", "Circle a control or area: give the box of the thing itself (its own " &
      "edges, in screenshot pixels) and Inkpane draws an ellipse that frames it with room " &
      "to spare. The best way to say \"click this\". Leave space around the box for it.",
      schema("", %*{
        "box": {"type": "array", "items": xy, "minItems": 4, "maxItems": 4,
          "description": "[left, top, right, bottom] of the thing to circle."},
        "label": {"type": "string", "description": "Optional label of 2-4 words, placed just outside the circle."},
        "label_side": {"type": "string", "enum": ["right", "left", "above", "below"],
          "description": "Side of the circle for the label: pick the side with empty space (no buttons or text). Default right."},
        "size": {"type": "number", "description": "Label font size in screenshot pixels. Default 16."},
        "color": colorProp,
        "width": {"type": "number", "description": "Line width in screenshot pixels. Omit for the default."},
        "monitor": monitorProp}, @["box"])),
    tool("callout", "A step card for walkthroughs and tutorials: a short paragraph (one or " &
      "two sentences: what to do and why) on a white card beside the target, with an arrow " &
      "to it and an optional step number on the card. Pick the side with empty space.",
      schema("", %*{
        "text": {"type": "string"},
        "target": {"type": "array", "items": xy, "minItems": 4, "maxItems": 4,
          "description": "[left, top, right, bottom] of the control the step is about."},
        "side": {"type": "string", "enum": ["right", "left", "above", "below"],
          "description": "Where the card goes, relative to the target. Default right."},
        "step": {"type": "integer", "minimum": 1, "description": "Step number shown on the card's corner."},
        "max_width": {"type": "number", "description": "Card text width in screenshot pixels. Default 320."},
        "size": {"type": "number", "description": "Font size in screenshot pixels. Default 16."},
        "color": {"type": "string", "description": "Accent for the card's border, arrow and number. Default blue."},
        "monitor": monitorProp}, @["text", "target"])),
    tool("save_screenshot", "Save an image of the screen, with your marks on it, at full " &
      "resolution: for tutorials and documentation. Crop it to the app's window with " &
      "`region` so nothing else on the user's desktop ends up in the file. Ask the user " &
      "before saving screenshots to files.",
      schema("", %*{
        "file": {"type": "string", "description": "Where to save, ending in .png. Relative paths are from the current directory."},
        "region": {"type": "array", "items": xy, "minItems": 4, "maxItems": 4,
          "description": "[left, top, right, bottom] in screenshot pixels: usually the app's window. Omit for the whole monitor."},
        "monitor": monitorProp}, @["file"])),
    tool("add_text", "Write a short label on the screen (2-4 words works best), next to " &
      "what it explains.",
      schema("", %*{"x": xy, "y": xy, "text": {"type": "string"}, "color": colorProp,
        "size": {"type": "number", "description": "Font size in screenshot pixels. Default 16."},
        "centered": {"type": "boolean", "description": "x, y is the centre of the text instead of its top-left corner."},
        "max_width": {"type": "number", "description": "Wrap the text into lines no wider than this (screenshot pixels): for notes of a sentence or two on a board."},
        "monitor": monitorProp}, @["x", "y", "text"])),
    tool("add_step_marker", "Place a numbered circle (1, 2, 3, ... assigned automatically) " &
      "centred at x, y, to mark the order of steps.",
      schema("", %*{"x": xy, "y": xy, "color": colorProp,
        "size": {"type": "number", "description": "Radius in screenshot pixels. Default 11."},
        "number": {"type": "integer", "minimum": 1, "description": "Show this number instead of the next one in order."},
        "monitor": monitorProp}, @["x", "y"])),
    tool("undo_last", "Remove the most recent mark you made.", schema("", %*{})),
    tool("clear", "Remove marks from the screen. \"ai\" (default) removes only the marks you " &
      "made; \"all\" also removes the user's own drawing (the user can undo that with Ctrl+Z).",
      schema("", %*{"scope": {"type": "string", "enum": ["ai", "all"]}})),
    tool("set_board", "Show a blank whiteboard or blackboard over the screen, for diagrams. " &
      "It hides everything, including the user's chat with you, so write the explanation " &
      "on the board itself (see add_text's max_width). The user's keyboard goes to Inkpane " &
      "and a hint tells them how to get back. \"none\" brings the screen back.",
      schema("", %*{"board": {"type": "string", "enum": ["none", "whiteboard", "blackboard"]}},
        @["board"])),
    tool("close", "Close Inkpane's overlay and clear everything, including the user's own " &
      "drawing. Only use this when the user is done.", schema("", %*{})),
  ]
  if clickingAllowed():
    for t in inputTools():
      result.add(t)

proc callTool(name: string, args: JsonNode): JsonNode =
  try:
    if args.kind != JObject:
      raise newException(ToolError, "arguments must be an object")
    let handler = case name
      of "screen_info": screenInfo
      of "screenshot": screenshot
      of "draw": drawTool
      of "circle": circle
      of "callout": callout
      of "save_screenshot": saveScreenshot
      of "click": clickTool
      of "scroll": scrollTool
      of "type_text": typeText
      of "press_keys": pressKeys
      of "add_text": addText
      of "add_step_marker": addStepMarker
      of "undo_last": undoLast
      of "clear": clear
      of "set_board": setBoard
      of "close": close
      else: raise newException(ToolError, "unknown tool " & name)
    ensureRunning()
    result = handler(args)
  except CatchableError as e:
    # Inkpane's own message, without GDBus's "GDBus.Error:org.….Failed: " in front.
    let message = if e.msg.startsWith("GDBus.Error:"): e.msg.split(": ", 1)[^1] else: e.msg
    result = reply(message)
    result["isError"] = %true

############################
# JSON-RPC
############################

proc send(message: JsonNode) =
  stdout.writeLine($message)
  stdout.flushFile()

proc fail(id: JsonNode, code: int, message: string) =
  send(%*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})

proc handle(request: JsonNode) =
  if request.kind != JObject or not request.hasKey("method") or request["method"].kind != JString:
    fail(if request.kind == JObject and request.hasKey("id"): request["id"] else: newJNull(),
      -32600, "Invalid request")
    return
  if not request.hasKey("id"):
    return   # notifications get no reply
  let id = request["id"]
  let params = if request.hasKey("params"): request["params"] else: newJObject()
  var result: JsonNode
  case request["method"].getStr
  of "initialize":
    var version = "2025-06-18"
    if params.kind == JObject and params.hasKey("protocolVersion") and
        params["protocolVersion"].kind == JString and params["protocolVersion"].getStr in Versions:
      version = params["protocolVersion"].getStr
    result = %*{"protocolVersion": version, "capabilities": {"tools": {}},
      "serverInfo": {"name": "inkpane", "version": "0.1.0"}, "instructions": Instructions}
  of "ping":
    result = newJObject()
  of "tools/list":
    result = %*{"tools": toolList()}
  of "tools/call":
    if params.kind != JObject or not params.hasKey("name") or params["name"].kind != JString:
      fail(id, -32602, "tools/call needs a tool name")
      return
    result = callTool(params["name"].getStr,
      if params.hasKey("arguments"): params["arguments"] else: newJObject())
  else:
    fail(id, -32601, "Method not found: " & request["method"].getStr)
    return
  send(%*{"jsonrpc": "2.0", "id": id, "result": result})

proc main() =
  for line in stdin.lines:
    if line.strip.len == 0:
      continue
    var request: JsonNode
    try:
      request = parseJson(line)
    except CatchableError:
      fail(newJNull(), -32700, "Parse error")
      continue
    try:
      handle(request)
    except CatchableError:
      stderr.writeLine("inkpane-mcp: " & getCurrentExceptionMsg())
      if request.kind == JObject and request.hasKey("id"):
        fail(request["id"], -32603, "Internal error")

main()
