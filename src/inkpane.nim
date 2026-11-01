import std/[math, os, parseopt, posix, strutils, tables]

import sdl3

import inkpane/[capture, config]
import inkpane/desktop/[dbus, glib, portal, tray]
import inkpane/draw/[render, scene, text, toolbar]
import inkpane/wayland/overlay

# Inkpane: draw on the screen through a transparent Wayland overlay.
#
# Runs in the background with a tray icon. Meta+Z (GlobalShortcuts portal), a tray
# click, or `inkpane --toggle` opens the overlay on every monitor; toggling again or Esc
# closes it and clears the drawing (Ctrl+Z in the next session brings it back). 1 / V switches to click-through: the drawing stays
# while apps get the mouse and keyboard, until the toolbar or the toggle brings it back.
# Ctrl+S saves a screenshot with the drawing on it. AI clients draw and take screenshots
# through the D-Bus methods below, by way of the inkpane-mcp server.

const
  MinWidth = 1'f32
  MaxWidth = 64'f32
  WidthStep = 2'f32
  ToolbarClearance = 24'f32   # a drag this close to the toolbar hides it
  TooltipDelayMs = 600'u64
  TooltipSize = 14'f32
  HelpSize = 16'f32
  TextColor = FColor(r: 0.93, g: 0.93, b: 0.95, a: 1)
  HelpKeys = [
    ("2–0 or R D O A L P T H E", "Tools, as in the toolbar"),
    ("N", "Step marker: numbered circle"),
    ("1 / V", "Click-through: apps get mouse and keys"),
    ("Meta+Z", "Back to drawing, or close"),
    ("Shift+1–8", "Colour"),
    ("- +  [ ]  or wheel", "Thinner / thicker"),
    ("F", "Fill rectangles, diamonds, ellipses"),
    ("Shift / Ctrl while dragging", "Square, snap 15° / from the centre"),
    ("Right drag", "Erase"),
    ("Ctrl+Z, Ctrl+Shift+Z or Ctrl+Y", "Undo, redo"),
    ("C / Delete", "Clear (Ctrl+Z undoes it)"),
    ("Ctrl+W / Ctrl+B", "Whiteboard / blackboard"),
    ("Ctrl+S", "Screenshot: drag an area, or click"),
    ("Tab", "Hide the toolbar"),
    ("F1", "This help"),
    ("Esc", "Cancel a drag, else close")]
  Boards = [   # background of each board; Transparent shows the desktop
    FColor(r: 0, g: 0, b: 0, a: 0),
    FColor(r: 0.98, g: 0.98, b: 0.97, a: 1),
    FColor(r: 0.13, g: 0.14, b: 0.15, a: 1)
  ]

  ServiceName = "org.vyrnexis.Inkpane"
  ServicePath = "/org/vyrnexis/Inkpane"
  ServiceInterface = "org.vyrnexis.Inkpane"
  ServiceXml = """
<node>
  <interface name="org.vyrnexis.Inkpane">
    <method name="Toggle"/>
    <method name="Show"/>
    <method name="Hide"/>
    <method name="Quit"/>
    <method name="Status">
      <arg name="open" type="b" direction="out"/>
      <arg name="clickThrough" type="b" direction="out"/>
      <arg name="toolbars" type="a(iiii)" direction="out"/>
    </method>
    <method name="Monitors">
      <arg name="monitors" type="a(siiii)" direction="out"/>
    </method>
    <method name="Draw">
      <arg name="monitor" type="i" direction="in"/>
      <arg name="kind" type="s" direction="in"/>
      <arg name="points" type="a(dd)" direction="in"/>
      <arg name="color" type="s" direction="in"/>
      <arg name="width" type="d" direction="in"/>
      <arg name="filled" type="b" direction="in"/>
      <arg name="text" type="s" direction="in"/>
    </method>
    <method name="DrawMany">
      <arg name="shapes" type="a(isa(dd)sdbs)" direction="in"/>
    </method>
    <method name="Clear">
      <arg name="aiOnly" type="b" direction="in"/>
    </method>
    <method name="UndoAi">
      <arg name="removed" type="b" direction="out"/>
    </method>
    <method name="SetBoard">
      <arg name="board" type="s" direction="in"/>
    </method>
    <method name="Capture">
      <arg name="monitor" type="i" direction="in"/>
      <arg name="x" type="i" direction="in"/>
      <arg name="y" type="i" direction="in"/>
      <arg name="areaWidth" type="i" direction="in"/>
      <arg name="areaHeight" type="i" direction="in"/>
      <arg name="width" type="i" direction="in"/>
      <arg name="height" type="i" direction="in"/>
      <arg name="path" type="s" direction="out"/>
    </method>
  </interface>
</node>"""

  ToggleShortcutId = "toggle-drawing"
  DefaultShortcutHint = "Meta+Z"
  DrawingWaitMs = 50'i32   # while drawing, how often D-Bus (tray, shortcut) is serviced

type
  Command = enum            # values are the D-Bus method names of our service
    CmdNone = ""
    CmdToggle = "Toggle"
    CmdShow = "Show"
    CmdHide = "Hide"
    CmdQuit = "Quit"
    CmdStatus = "Status"
    CmdMonitors = "Monitors"
    CmdDraw = "Draw"
    CmdDrawMany = "DrawMany"
    CmdClear = "Clear"
    CmdUndoAi = "UndoAi"
    CmdSetBoard = "SetBoard"
    CmdCapture = "Capture"

  Call = object   # a D-Bus method call, answered once the main loop has run it
    command: Command
    parameters: GVariant
    invocation: pointer

  Board = enum
    Transparent, Whiteboard, Blackboard

  App = object
    settings: Settings
    overlays: seq[Overlay]
    tool: Tool
    color: FColor
    width: float32
    fill: bool           # new rectangles, diamonds and ellipses are filled
    hideToolbar: bool
    toolbarPlace: FPoint     # offset from the toolbar's default spot, shared by all monitors
    movingToolbar: Overlay   # overlay whose toolbar is being dragged
    grab: FPoint             # pointer minus toolbarPlace when that drag started
    passthrough: bool    # click-through: only the toolbar still takes the pointer
    board: Board
    closed: seq[ClosedDrawing]   # each monitor's last drawing, until the next session
    boardHint: bool      # the AI put the board up: say how to get back to the desktop
    drawingOn: Overlay   # overlay that owns the drag in progress (drawing or erasing)
    dragTool: Tool       # tool of that drag: the eraser for a right drag
    dragButton: uint8
    erasedTo: FPoint     # where the eraser drag was last, to sweep from there
    typingOn: Overlay    # overlay with text being typed
    help: bool           # F1 cheat sheet shown
    hoverOn: Overlay     # toolbar button under the pointer, for its tooltip
    hoverButton: int
    hoverSince: uint64
    tooltip: bool        # hovered long enough: show it
    moveCursorShown: bool   # over the toolbar's grip, or dragging the toolbar
    selecting: bool      # Ctrl+S: the next drag or click picks what to capture
    selectOn: Overlay    # overlay of that drag
    selectFrom, selectTo: FPoint
    capturing: bool      # a clean frame for a screenshot: none of Inkpane's own UI
    aiGroups: int        # Draw and DrawMany calls so far: each one's items share a group
    warnedNoText: bool
    running: bool
    shortcuts: ShortcutSession

  ClosedDrawing = object
    width, height: float32   # the monitor it was on
    scene: Scene             # empty; Ctrl+Z brings the drawing back

  ActionError = object of CatchableError

var
  pendingCommands: seq[Command]   # from the tray, the shortcut, keys and signals
  pendingCalls: seq[Call]         # from our D-Bus service
  moveCursor: Cursor              # made the first time the pointer is on the grip

proc notify(message: string) =
  # Desktop notification: Inkpane has no window to say things in.
  try:
    g_variant_unref(call("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
      "org.freedesktop.Notifications", "Notify",
      g_variant_new("(susssasa{sv}i)", "Inkpane".cstring, 0'u32, AppId.cstring,
        "Inkpane".cstring, message.cstring, pointer(nil), pointer(nil), -1'i32)))
  except DBusError:
    discard

proc notifyError(message: string) =
  stderr.writeLine("inkpane: " & message)
  notify(message)

proc textSize(width: float32): float32 =
  ## Text follows the width setting: 6 (the default) gives 27 px.
  12 + width * 2.5

proc markerRadius(width: float32): float32 =
  10 + width * 0.9

proc scale(overlay: Overlay): float32 =
  let pixel = overlay.mesh.pixelSize
  if pixel > 0: 1 / pixel else: 1

proc textMissing(app: var App): bool =
  ## True (and says so once) when SDL3_ttf or a font is missing.
  if textAvailable():
    return false
  if not app.warnedNoText:
    app.warnedNoText = true
    notifyError("Text, step markers and the help need SDL3_ttf: install sdl3_ttf " &
      "(Arch) or libsdl3-ttf (Debian, Ubuntu), then restart Inkpane.")
  true

proc overlayFor(app: App, windowId: WindowID): Overlay =
  for overlay in app.overlays:
    if overlay.windowId == windowId:
      return overlay

proc markAllDirty(app: var App) =
  for overlay in app.overlays:
    overlay.dirty = true

proc toolbarHit(app: App, overlay: Overlay): int =
  if app.hideToolbar or not overlay.pointerInside or app.drawingOn != nil or
      app.movingToolbar != nil:
    return -1
  overlay.toolbar.hit(overlay.pointer)

proc toolbarState(app: App, overlay: Overlay): ToolbarState =
  ToolbarState(tool: app.tool, color: app.settings.palette.find(app.color), width: app.width,
    fill: app.fill, passthrough: app.passthrough, selecting: app.selecting,
    hover: app.toolbarHit(overlay))

proc toolbarInTheWay(app: App, overlay: Overlay): bool =
  ## While dragging under or near the toolbar it steps aside, so it never covers a stroke.
  let b = overlay.toolbar.bounds
  let around = FRect(x: b.x - ToolbarClearance, y: b.y - ToolbarClearance,
    w: b.w + 2 * ToolbarClearance, h: b.h + 2 * ToolbarClearance)
  app.drawingOn == overlay and overlay.pointer in around

proc drawTexts(overlay: Overlay, background: FColor) =
  ## Text items and marker numbers: textures on top of the mesh.
  let renderer = overlay.renderer
  for item in overlay.scene.items.mitems:
    case item.kind
    of Text:
      # A halo keeps text readable over the desktop; a board needs none.
      let size = if item.text.len == 0: FPoint(x: 0, y: lineHeight(item.width))   # just typing
                 else: renderer.drawText(overlay.texts, item.text, item.points[0], item.width,
                   item.shown(background), background.a < 1, overlay.scale)
      item.setBox(size)   # for the eraser and the typing hint
    of Marker:
      let a = item.points[0]
      let b = item.points[1]
      let size = item.width * 0.6
      let extent = measureText(item.text, size)
      let disc = item.shown(background)
      let light = disc.r * 0.3 + disc.g * 0.59 + disc.b * 0.11 > 0.6
      let ink = if light: FColor(r: 0.05, g: 0.05, b: 0.05, a: 1) else: FColor(r: 1, g: 1, b: 1, a: 1)
      discard renderer.drawText(overlay.texts, item.text,
        FPoint(x: (a.x + b.x - extent.x) / 2, y: (a.y + b.y - extent.y) / 2), size, ink, false,
        overlay.scale)
    else:
      discard
  if overlay.scene.editingText:   # caret after the last character
    let item = overlay.scene.items[^1]
    let lines = item.text.split('\n')
    let height = lineHeight(item.width)
    let x = item.points[0].x + measureText(lines[^1], item.width).x + 1
    let y = item.points[0].y + float32(lines.high) * height
    var caret: Mesh
    caret.setPixelSize(overlay.mesh.pixelSize)
    caret.addPath([FPoint(x: x, y: y + 2), FPoint(x: x, y: y + height - 2)], 2,
      item.shown(background))
    renderer.draw(caret)

proc drawChip(overlay: Overlay, text: string, at: FPoint) =
  ## A line of text on a dark panel (tooltips and hints); `at` is the text's top-left.
  let size = measureText(text, TooltipSize)
  overlay.renderer.drawBackdrop(FRect(x: at.x - 8, y: at.y - 4, w: size.x + 16, h: size.y + 8),
    overlay.mesh.pixelSize)
  discard overlay.renderer.drawText(overlay.texts, text, at, TooltipSize, TextColor, false,
    overlay.scale)

proc drawBottomChip(overlay: Overlay, text: string, margin: float32) =
  ## A hint centred near the bottom of the screen.
  let size = measureText(text, TooltipSize)
  overlay.drawChip(text, FPoint(x: round((overlay.width - size.x) / 2),
    y: overlay.height - size.y - margin))

proc drawTooltip(app: App, overlay: Overlay) =
  let button = overlay.toolbar.buttons[app.hoverButton]
  let label = overlay.toolbar.label(button)
  let size = measureText(label, TooltipSize)
  let anchor = button.tooltipAnchor
  let x = clamp(anchor.x - size.x / 2, 12, max(overlay.width - size.x - 12, 12))
  var y = anchor.y + 12
  if y + size.y + 4 > overlay.height:   # toolbar dragged to the bottom: above it instead
    y = overlay.toolbar.bounds.y - size.y - 12
  overlay.drawChip(label, FPoint(x: x, y: y))

proc drawTypingHint(overlay: Overlay) =
  ## Under the text being typed: how to finish it.
  const Hint = "Enter  done     Shift+Enter  new line     Esc  cancel"
  let item = overlay.scene.items[^1]
  let size = measureText(Hint, TooltipSize)
  let x = clamp(item.points[0].x + 8, 12, max(overlay.width - size.x - 12, 12))
  var y = item.points[1].y + 12
  if y + size.y + 4 > overlay.height:   # no room below: above the text instead
    y = item.points[0].y - size.y - 12
  overlay.drawChip(Hint, FPoint(x: x, y: y))

proc drawHelp(overlay: Overlay) =
  var keys, actions: seq[string]
  for (key, action) in HelpKeys:
    keys.add(key)
    actions.add(action)
  let keyText = keys.join("\n")
  let actionText = actions.join("\n")
  let keySize = measureText(keyText, HelpSize)
  let actionSize = measureText(actionText, HelpSize)
  let gap = 28'f32
  let w = keySize.x + gap + actionSize.x + 56
  let h = max(keySize.y, actionSize.y) + 48
  let left = round((overlay.width - w) / 2)
  let top = round((overlay.height - h) / 2)
  overlay.renderer.drawBackdrop(FRect(x: left, y: top, w: w, h: h), overlay.mesh.pixelSize)
  discard overlay.renderer.drawText(overlay.texts, keyText, FPoint(x: left + 28, y: top + 24),
    HelpSize, FColor(r: 0.72, g: 0.75, b: 1, a: 1), false, overlay.scale)
  discard overlay.renderer.drawText(overlay.texts, actionText,
    FPoint(x: left + 28 + keySize.x + gap, y: top + 24), HelpSize, TextColor, false, overlay.scale)

proc rectPath(r: FRect): seq[FPoint] =
  @[FPoint(x: r.x, y: r.y), FPoint(x: r.x + r.w, y: r.y), FPoint(x: r.x + r.w, y: r.y + r.h),
    FPoint(x: r.x, y: r.y + r.h), FPoint(x: r.x, y: r.y)]

proc selection(app: App): FRect =
  let a = app.selectFrom
  let b = app.selectTo
  FRect(x: min(a.x, b.x), y: min(a.y, b.y), w: abs(b.x - a.x), h: abs(b.y - a.y))

proc drawSelection(app: App, overlay: Overlay) =
  ## Capture mode: the screen dimmed except the area being dragged, and how it works.
  const Dim = FColor(r: 0, g: 0, b: 0, a: 0.3)
  var mesh: Mesh
  mesh.setPixelSize(overlay.mesh.pixelSize)
  let w = overlay.width
  let h = overlay.height
  if app.selectOn == overlay:
    let r = app.selection
    for band in [FRect(w: w, h: r.y), FRect(y: r.y + r.h, w: w, h: h - r.y - r.h),
                 FRect(y: r.y, w: r.x, h: r.h), FRect(x: r.x + r.w, y: r.y, w: w - r.x - r.w, h: r.h)]:
      if band.w > 0 and band.h > 0:
        mesh.addFill(rectPath(band), Dim)
    mesh.addPath(rectPath(r), 3, FColor(r: 0, g: 0, b: 0, a: 0.45))
    mesh.addPath(rectPath(r), 1.5, FColor(r: 1, g: 1, b: 1, a: 1))
  else:
    mesh.addFill(rectPath(FRect(w: w, h: h)), Dim)
  overlay.renderer.draw(mesh)
  if textAvailable() and app.selectOn != overlay:
    overlay.drawBottomChip("Drag an area     Click  whole screen     Esc  cancel", 72)

proc render(app: App, overlay: Overlay) =
  ## One frame, not yet presented.
  let renderer = overlay.renderer
  let background = Boards[ord(app.board)]
  discard renderer.setRenderDrawColorFloat(background.r, background.g, background.b, background.a)
  discard renderer.renderClear()
  overlay.mesh.setBackground(background)
  overlay.mesh.update(overlay.scene)
  renderer.draw(overlay.mesh)
  renderer.drawActiveShape(overlay.mesh, overlay.scene)
  overlay.drawTexts(background)
  # While capturing, only the drawing: none of Inkpane's own UI ends up in the screenshot.
  let toolbarShown = not (app.hideToolbar or app.capturing) and not app.toolbarInTheWay(overlay)
  if toolbarShown:
    overlay.toolbar.update(FPoint(x: overlay.width, y: overlay.height), app.toolbarPlace,
      overlay.mesh.pixelSize, app.toolbarState(overlay), app.settings.palette, app.settings.presets)
    renderer.draw(overlay.toolbar)
  if app.selecting and not app.capturing:
    app.drawSelection(overlay)
  if app.boardHint and not app.capturing and textAvailable():
    let key = if app.board == Whiteboard: "Ctrl+W" else: "Ctrl+B"
    overlay.drawBottomChip(key & "  back to your desktop     Esc  close", 28)
  let overToolbar = toolbarShown and overlay.pointer in overlay.toolbar.bounds
  if overlay.pointerInside and not overlay.scene.drawing and not overToolbar and
      not (app.passthrough or app.capturing):
    # Preview of what a click or drag makes, at its real size, with a dark halo so it
    # shows on both light and dark content: the pen tip, the eraser, the marker, or a
    # text cursor as tall as a line of text.
    let p = overlay.pointer
    let color = if app.tool == Eraser: FColor(r: 1, g: 1, b: 1, a: 0.9)
                else: toolColor(app.tool, app.color).onBackground(background)
    if app.selecting:   # crosshair
      for (width, ink) in [(4'f32, FColor(r: 0, g: 0, b: 0, a: 0.45)),
                           (1.5'f32, FColor(r: 1, g: 1, b: 1, a: 1))]:
        var cross: Mesh
        cross.setPixelSize(overlay.mesh.pixelSize)
        cross.addPath([FPoint(x: p.x - 12, y: p.y), FPoint(x: p.x + 12, y: p.y)], width, ink)
        cross.addPath([FPoint(x: p.x, y: p.y - 12), FPoint(x: p.x, y: p.y + 12)], width, ink)
        renderer.draw(cross)
    elif app.tool == Text:
      let half = lineHeight(textSize(app.width)) / 2
      let serif = max(half / 4, 3)
      for (width, ink) in [(4'f32, FColor(r: 0, g: 0, b: 0, a: 0.45)), (1.5'f32, color)]:
        var beam: Mesh
        beam.setPixelSize(overlay.mesh.pixelSize)
        beam.addPath([FPoint(x: p.x, y: p.y - half), FPoint(x: p.x, y: p.y + half)], width, ink)
        for y in [p.y - half, p.y + half]:
          beam.addPath([FPoint(x: p.x - serif, y: y), FPoint(x: p.x + serif, y: y)], width, ink)
        renderer.draw(beam)
    else:
      let radius = case app.tool
        of Eraser: EraserRadius
        of Marker: markerRadius(app.width)
        else: max(toolWidth(app.tool, app.width) / 2, 2)
      renderer.drawRing(p, radius + 1, 3, FColor(r: 0, g: 0, b: 0, a: 0.45))
      renderer.drawRing(p, radius, 1.5, color)
  if overlay.scene.editingText and not app.capturing:
    overlay.drawTypingHint()
  if toolbarShown and app.tooltip and app.hoverOn == overlay:
    app.drawTooltip(overlay)
  if app.help and not app.capturing:
    overlay.drawHelp()
  overlay.texts.endFrame()

proc redraw(app: App, overlay: Overlay) =
  app.render(overlay)
  discard overlay.renderer.renderPresent()
  overlay.dirty = false

proc follow(app: var App, overlay: Overlay, point: FPoint) =
  ## Moves the drag in progress to `point`; Shift and Ctrl shape rectangles, lines etc.
  let mods = getModState()
  if app.dragTool == Eraser:
    discard overlay.scene.eraseAlong(app.erasedTo, point)
    app.erasedTo = point
  else:
    discard overlay.scene.moveTo(point, (mods and KMOD_SHIFT) != 0, (mods and KMOD_CTRL) != 0)
  overlay.dirty = true

proc setPassthrough(app: var App, on: bool) =
  app.passthrough = on
  for overlay in app.overlays:
    let clickable = if app.hideToolbar: FRect() else: overlay.toolbar.bounds
    overlay.setPassthrough(on, clickable)
  app.markAllDirty()

proc startTyping(app: var App, overlay: Overlay, at: FPoint) =
  ## Text starts where clicked, the first line centred on the pointer.
  let size = textSize(app.width)
  overlay.scene.begin(Text, FPoint(x: at.x, y: at.y - lineHeight(size) / 2), app.color, size)
  discard startTextInput(overlay.window)
  app.typingOn = overlay
  overlay.dirty = true

proc stopTyping(app: var App, keep: bool) =
  ## Commits the text (empty text is dropped) or, without `keep`, throws it away.
  let overlay = app.typingOn
  if overlay == nil:
    return
  if keep: overlay.scene.finish(FPoint()) else: overlay.scene.cancel()
  discard stopTextInput(overlay.window)
  app.typingOn = nil
  overlay.dirty = true

proc typingKey(app: var App, event: KeyboardEvent) =
  ## While typing, keys edit the text instead of running shortcuts.
  let scene = addr app.typingOn.scene
  let ctrl = (event.`mod` and KMOD_CTRL) != 0
  case event.key
  of SDLK_ESCAPE:
    app.stopTyping(keep = false)
    return
  of SDLK_RETURN, SDLK_KP_ENTER:
    if (event.`mod` and KMOD_SHIFT) != 0:
      scene[].typeText("\n")
    else:
      app.stopTyping(keep = true)
      return
  of SDLK_BACKSPACE:
    scene[].deleteLast()
  of SDLK_V:
    if ctrl:
      let clip = getClipboardText()
      if clip != nil:
        scene[].typeText(($clip).replace("\r", ""))
        sdlFree(clip)
  else:
    discard
  app.typingOn.dirty = true

############################
# Screenshots
############################

proc runtimeDir(): string =
  result = getEnv("XDG_RUNTIME_DIR", getTempDir()) / "inkpane"
  createDir(result)

proc grabDesktop(app: var App): string =
  ## A screenshot of the whole desktop, drawing included but none of Inkpane's own UI;
  ## returns the PNG's path. Input is released meanwhile, so a permission dialog from the
  ## desktop (the first time) is never covered by the overlay.
  if not pngAvailable():
    raise newException(ActionError, "Screenshots need SDL 3.4 or SDL3_image.")
  app.capturing = true
  for round in 1 .. 2:   # the second present waits until the first, clean one is shown
    for overlay in app.overlays:
      app.redraw(overlay)
  for overlay in app.overlays:
    overlay.setPassthrough(true, FRect())
  try:
    let fake = getEnv("INKPANE_TEST_SCREENSHOT")   # tests: this PNG instead of the portal,
    if fake.len > 0:                                # with the drawing laid over it
      result = runtimeDir() / "test-shot.png"
      var layers: seq[ptr Surface]
      for overlay in app.overlays:
        app.render(overlay)
        layers.add(overlay.renderer.renderReadPixels(nil))
        discard overlay.renderer.renderPresent()
      let ok = composite(fake, result, monitors(), layers)
      for layer in layers:
        if not layer.isNil: destroySurface(layer)
      if not ok:
        raise newException(ActionError, "Could not compose the test screenshot.")
    else:
      result = takeScreenshot()
  finally:
    app.capturing = false
    app.setPassthrough(app.passthrough)   # input back, and the UI redrawn

proc saveCapture(app: var App, monitor: int, area: Rect, width, height: int, path: string) =
  ## Saves `area` of `monitor` (zero size: all of it) to `path`, scaled to width × height.
  let shot = app.grabDesktop()
  let image = crop(shot, monitors(), monitor, area, width, height)
  try:
    removeFile(shot)   # the portal's copy: ours is saved below
  except OSError:
    discard
  if image.isNil:
    raise newException(ActionError, "Could not read the screenshot: " & $getError())
  defer: destroySurface(image)
  if not save(image, path):
    raise newException(ActionError, "Could not save " & path & ": " & $getError())

proc screenshot(app: var App, overlay: Overlay, area: Rect) =
  ## Ctrl+S: saves into the screenshot folder and puts it on the clipboard.
  let path = newScreenshotPath(screenshotFolder(app.settings.screenshotFolder))
  try:
    app.saveCapture(app.overlays.find(overlay), area, 0, 0, path)
  except CatchableError:
    notifyError("Screenshot failed: " & getCurrentExceptionMsg())
    return
  let shown = if path.startsWith(getHomeDir()): "~/" & path.relativePath(getHomeDir()) else: path
  notify("Screenshot saved to " & shown &
    (if copyToClipboard(path): " and copied to the clipboard." else: "."))

proc startSelecting(app: var App, on: bool) =
  if on and not pngAvailable():
    notifyError("Screenshots need SDL 3.4 (or SDL3_image): update SDL3 and restart Inkpane.")
    return
  app.selecting = on
  app.selectOn = nil
  app.markAllDirty()

proc finishSelecting(app: var App) =
  ## Mouse up in capture mode: a drag captures that area, a click the whole monitor.
  let overlay = app.selectOn
  let r = app.selection
  app.startSelecting(false)
  let area = if r.w >= 4 and r.h >= 4: Rect(x: cint(r.x), y: cint(r.y), w: cint(r.w), h: cint(r.h))
             else: Rect()
  app.screenshot(overlay, area)

proc press(app: var App, button: Button) =
  ## A toolbar button. Any but click-through itself goes back to drawing, as in Excalidraw.
  case button.kind
  of GripButton:
    return   # dragged, not pressed
  of PassButton:
    app.startSelecting(false)
    app.setPassthrough(not app.passthrough)
    return
  else:
    if app.passthrough:
      app.setPassthrough(false)
  case button.kind
  of GripButton, PassButton: discard
  of CaptureButton: app.startSelecting(not app.selecting)
  of ToolButton:
    app.tool = ToolOrder[button.index].tool
    app.startSelecting(false)
  of FillButton: app.fill = not app.fill
  of ColorButton: app.color = app.settings.palette[button.index]
  of WidthButton: app.width = app.settings.presets[button.index]
  app.markAllDirty()

proc keyFor(key: ToolKey, event: KeyboardEvent): bool =
  ## Number keys by position, so any keyboard layout works; letters by what they type.
  let digit = case key.digit
    of -1: -1
    of 0: ord(SCANCODE_0)
    else: ord(SCANCODE_1) + key.digit - 1
  ord(event.scancode) == digit or event.key == Keycode(ord(key.letter.toLowerAscii))

proc changeWidth(app: var App, step: float32) =
  app.width = clamp(app.width + step, MinWidth, MaxWidth)
  app.markAllDirty()

proc handleKey(app: var App, event: KeyboardEvent) =
  if app.typingOn != nil:
    app.typingKey(event)
    return
  let ctrl = (event.`mod` and KMOD_CTRL) != 0
  let shift = (event.`mod` and KMOD_SHIFT) != 0
  let target = if app.drawingOn != nil: app.drawingOn else: app.overlayFor(event.windowID)
  if shift and event.scancode in SCANCODE_1 .. SCANCODE_8:
    let index = ord(event.scancode) - ord(SCANCODE_1)
    if index < app.settings.palette.len:
      app.color = app.settings.palette[index]
      app.markAllDirty()
    return
  if not (ctrl or shift) and app.drawingOn == nil:
    if event.scancode == SCANCODE_1 or event.key == SDLK_V:
      app.startSelecting(false)
      app.setPassthrough(true)
      return
    for key in ToolOrder:
      if key.keyFor(event):
        app.tool = key.tool
        app.startSelecting(false)
        return
  case event.key
  of SDLK_ESCAPE:
    if app.drawingOn != nil:   # drop the shape being dragged, keep drawing
      app.drawingOn.scene.cancel()
      app.drawingOn.dirty = true
      app.drawingOn = nil
    elif app.selecting:
      app.startSelecting(false)
    elif app.help:
      app.help = false
      app.markAllDirty()
    else:
      pendingCommands.add(CmdHide)
  of SDLK_F1:
    if not app.textMissing:
      app.help = not app.help
      app.markAllDirty()
  of SDLK_F:
    app.fill = not app.fill
    app.markAllDirty()
  of SDLK_TAB:
    app.hideToolbar = not app.hideToolbar
    app.markAllDirty()
  of SDLK_DELETE, SDLK_C:
    if not ctrl:   # Ctrl+C is copy by habit, never a clear
      for overlay in app.overlays:
        overlay.scene.clear()
      app.drawingOn = nil
      app.markAllDirty()
  of SDLK_Z:
    if ctrl and target != nil:
      let changed = if shift: target.scene.redo() else: target.scene.undo()
      target.dirty = target.dirty or changed
  of SDLK_S:
    if ctrl and app.drawingOn == nil:
      app.startSelecting(not app.selecting)
  of SDLK_W, SDLK_B:
    if ctrl:   # Ctrl+W whiteboard, Ctrl+B blackboard; the same key again goes back
      let board = if event.key == SDLK_W: Whiteboard else: Blackboard
      app.board = if app.board == board: Transparent else: board
      app.boardHint = false
      app.markAllDirty()
  of SDLK_Y:
    if ctrl and target != nil:
      target.dirty = target.scene.redo() or target.dirty
  of SDLK_MINUS, SDLK_KP_MINUS:
    app.changeWidth(-WidthStep)
  of SDLK_PLUS, SDLK_EQUALS, SDLK_KP_PLUS:
    app.changeWidth(WidthStep)
  else:
    # [ and ] by position, as on a US keyboard: elsewhere they need AltGr or are missing.
    if event.scancode == SCANCODE_LEFTBRACKET: app.changeWidth(-WidthStep)
    elif event.scancode == SCANCODE_RIGHTBRACKET: app.changeWidth(WidthStep)

proc handleEvent(app: var App, event: Event) =
  case event.`type`
  of EVENT_QUIT:
    app.running = false
  of EVENT_KEY_DOWN, EVENT_KEY_UP:
    if event.key.key in [SDLK_LSHIFT, SDLK_RSHIFT, SDLK_LCTRL, SDLK_RCTRL]:
      if app.drawingOn != nil:   # pressing or releasing a modifier reshapes the drag
        app.follow(app.drawingOn, app.drawingOn.pointer)
    elif event.`type` == EVENT_KEY_DOWN:
      app.handleKey(event.key)
  of EVENT_TEXT_INPUT:
    if app.typingOn != nil:
      app.typingOn.scene.typeText($event.text.text)
      app.typingOn.dirty = true
  of EVENT_MOUSE_MOTION:
    let overlay = app.overlayFor(event.motion.windowID)
    if overlay == nil:
      return
    let point = FPoint(x: event.motion.x, y: event.motion.y)
    overlay.pointer = point
    overlay.pointerInside = true
    if app.drawingOn == overlay:
      app.follow(overlay, point)
    elif app.selectOn == overlay:
      app.selectTo = point
    elif app.movingToolbar == overlay:
      app.toolbarPlace = FPoint(x: point.x - app.grab.x, y: point.y - app.grab.y)
      app.markAllDirty()
    overlay.dirty = true
  of EVENT_MOUSE_BUTTON_DOWN:
    let overlay = app.overlayFor(event.button.windowID)
    let button = event.button.button
    if overlay != nil and app.drawingOn == nil and int(button) in [BUTTON_LEFT, BUTTON_RIGHT]:
      let point = FPoint(x: event.button.x, y: event.button.y)
      app.stopTyping(keep = true)   # a click anywhere finishes the text being typed
      let pressed = app.toolbarHit(overlay)
      if pressed >= 0 and overlay.toolbar.buttons[pressed].kind != GripButton:
        if int(button) == BUTTON_LEFT:
          app.press(overlay.toolbar.buttons[pressed])
        return
      if not app.hideToolbar and point in overlay.toolbar.bounds:
        if int(button) == BUTTON_LEFT:   # the grip, or the background between buttons
          app.movingToolbar = overlay
          app.grab = FPoint(x: point.x - app.toolbarPlace.x, y: point.y - app.toolbarPlace.y)
        return
      if app.selecting:   # left drag picks the area, right click cancels
        if int(button) == BUTTON_LEFT:
          app.selectOn = overlay
          app.selectFrom = point
          app.selectTo = point
        else:
          app.startSelecting(false)
        return
      app.dragTool = if int(button) == BUTTON_RIGHT: Eraser else: app.tool
      if app.dragTool in Placed:
        if not app.textMissing:
          if app.dragTool == Text:
            app.startTyping(overlay, point)
          else:
            overlay.scene.addMarker(point, markerRadius(app.width), app.color)
            overlay.dirty = true
        return
      app.dragButton = button
      if app.dragTool == Eraser:
        discard overlay.scene.eraseAt(point)
        app.erasedTo = point
      else:
        overlay.scene.begin(app.tool, point, app.color, app.width, app.fill)
      app.drawingOn = overlay
      overlay.dirty = true
  of EVENT_MOUSE_BUTTON_UP:
    if app.movingToolbar != nil and int(event.button.button) == BUTTON_LEFT:
      app.toolbarPlace = app.movingToolbar.toolbar.offset   # as clamped to the screen
      app.movingToolbar = nil
      saveToolbarPlace(app.toolbarPlace)
      if app.passthrough:
        app.setPassthrough(true)   # the clickable area moved with the toolbar
      return
    if app.selectOn != nil and int(event.button.button) == BUTTON_LEFT:
      app.selectTo = FPoint(x: event.button.x, y: event.button.y)
      app.finishSelecting()
      return
    if app.drawingOn != nil and event.button.button == app.dragButton:
      let mods = getModState()
      app.drawingOn.scene.finish(FPoint(x: event.button.x, y: event.button.y),
        (mods and KMOD_SHIFT) != 0, (mods and KMOD_CTRL) != 0)
      app.drawingOn.dirty = true
      app.drawingOn = nil
  of EVENT_MOUSE_WHEEL:
    if event.wheel.y == 0:
      return   # horizontal scroll
    app.changeWidth(if event.wheel.y > 0: WidthStep else: -WidthStep)
  of EVENT_WINDOW_MOUSE_LEAVE:
    let overlay = app.overlayFor(event.window.windowID)
    if overlay != nil:
      overlay.pointerInside = false
      overlay.dirty = true
  of EVENT_WINDOW_PIXEL_SIZE_CHANGED, EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
    let overlay = app.overlayFor(event.window.windowID)
    if overlay != nil:
      overlay.updateRenderScale()
      overlay.dirty = true
  else:
    discard

############################
# Draw Mode
############################

proc drawing(app: App): bool =
  app.overlays.len > 0

proc showOverlays(app: var App) =
  if app.drawing:
    return
  try:
    app.overlays = openOverlays()
  except OverlayError:
    notifyError(getCurrentExceptionMsg())
    return
  # Ctrl+Z on a fresh session undoes the close, as long as the monitors are the same.
  if app.closed.len == app.overlays.len:
    for i, overlay in app.overlays:
      if app.closed[i].width == overlay.width and app.closed[i].height == overlay.height:
        overlay.scene = move(app.closed[i].scene)
  app.closed.setLen(0)
  setTrayDrawing(true)

proc hideOverlays(app: var App) =
  # Closing takes the drawing off screen, but keeps it for one Ctrl+Z in the next session.
  app.closed.setLen(0)
  for overlay in app.overlays:
    app.closed.add(ClosedDrawing(width: overlay.width, height: overlay.height,
      scene: overlay.scene.stash()))
    overlay.close()
  app.overlays.setLen(0)
  app.drawingOn = nil
  app.typingOn = nil
  app.movingToolbar = nil
  app.hoverOn = nil
  app.tooltip = false
  app.help = false
  app.passthrough = false
  app.board = Transparent   # the next session starts over the desktop again
  app.boardHint = false
  app.selecting = false
  app.selectOn = nil
  setTrayDrawing(false)

proc runCommand(app: var App, command: Command) =
  case command
  of CmdToggle:
    if app.passthrough: app.setPassthrough(false)
    elif app.drawing: app.hideOverlays()
    else: app.showOverlays()
  of CmdShow:
    if app.passthrough: app.setPassthrough(false) else: app.showOverlays()
  of CmdHide: app.hideOverlays()
  of CmdQuit: app.running = false
  of CmdNone, CmdStatus .. CmdCapture: discard   # D-Bus calls with arguments: answer()

############################
# Drawn by an AI (inkpane-mcp)
############################

proc openForAi(app: var App) =
  ## The AI draws without taking the mouse and keyboard: a closed overlay opens in
  ## click-through. One the user is drawing on stays as it is.
  if app.drawing:
    return
  app.showOverlays()
  if not app.drawing:
    raise newException(ActionError, "Could not open the overlay.")
  app.setPassthrough(true)

type AiShape = object   # one shape from Draw or DrawMany, checked and ready to add
  monitor: int
  tool: Tool
  path: seq[FPoint]
  ink: FColor
  size: float32
  filled: bool
  text: string
  number: int   # step markers: 0 picks the next number

proc aiShape(app: var App, shape: GVariant, monitorCount: int): AiShape =
  ## Reads and checks one (isa(dd)sdbs) without changing anything, so a list of shapes
  ## is refused as a whole before any of it is drawn.
  var monitor: int32
  var kind, color, text: cstring
  var points: GVariant
  var width: cdouble
  var filled: cint
  g_variant_get(shape, "(i&s@a(dd)&sdb&s)", addr monitor, addr kind, addr points,
    addr color, addr width, addr filled, addr text)
  var path: seq[FPoint]
  for i in 0 ..< int(g_variant_n_children(points)):
    let point = g_variant_get_child_value(points, csize_t(i))
    var x, y: cdouble
    g_variant_get(point, "(dd)", addr x, addr y)
    g_variant_unref(point)
    path.add(FPoint(x: float32(x), y: float32(y)))
  g_variant_unref(points)

  let tool = toolNamed($kind)
  if tool == Eraser:
    raise newException(ValueError, "The AI can't erase; use Clear or UndoAi.")
  let (fits, needs) = case tool
    of Marker: (path.len == 1, "1 point")
    of Text: (path.len in 1 .. 2, "1 point (top-left), or 2 to centre it in their box")
    of Pen: (path.len >= 2, "2 or more points")
    else: (path.len == 2, "2 points")
  if not fits:
    raise newException(ValueError, $kind & " needs " & needs)
  if tool == Text and ($text).len == 0:
    raise newException(ValueError, "Text needs some text.")
  if tool in Placed and app.textMissing:
    raise newException(ValueError, "Text and step markers need SDL3_ttf, which is not installed.")
  if monitor notin 0'i32 ..< int32(monitorCount):
    raise newException(ValueError, "No monitor " & $monitor)
  result = AiShape(monitor: int(monitor), tool: tool, path: path,
    ink: (if ($color).len == 0: app.settings.palette[0] else: parseColor($color)),
    size: float32(width), filled: filled != 0, text: $text)
  if tool == Marker:
    result.number = if ($text).len == 0: 0 else: parseInt($text)   # ValueError: refused
    if result.number notin 0 .. 999:
      raise newException(ValueError, "A step number goes from 1 to 999.")

proc aiDraw(app: var App, shapes: seq[AiShape]) =
  ## Adds checked shapes; together they are one step for UndoAi.
  if shapes.len == 0:
    return
  app.openForAi()
  for s in shapes:
    if s.monitor >= app.overlays.len:
      raise newException(ValueError, "No overlay on monitor " & $s.monitor)
  inc app.aiGroups
  let group = app.aiGroups
  for s in shapes:
    let overlay = app.overlays[s.monitor]
    case s.tool
    of Marker:
      overlay.scene.addMarker(s.path[0], (if s.size > 0: s.size else: 15), s.ink, group,
        s.number)
    of Text:
      let fontSize = if s.size > 0: s.size else: 24
      var at = s.path[0]
      if s.path.len == 2:   # centred in the box of the two points
        let extent = measureText(s.text, fontSize)
        at = FPoint(x: (s.path[0].x + s.path[1].x - extent.x) / 2,
          y: (s.path[0].y + s.path[1].y - extent.y) / 2)
      overlay.scene.addItem(aiItem(Text, @[at], s.ink, fontSize, group, text = s.text))
    else:
      overlay.scene.addItem(aiItem(s.tool, s.path, s.ink, (if s.size > 0: s.size else: 4),
        group, s.filled))
    overlay.dirty = true

proc aiUndo(app: var App): bool =
  ## Removes what is left of the AI's newest call (one Draw or DrawMany) on every monitor;
  ## items the user already erased or undid by hand don't make it reach further back.
  var group = 0
  for overlay in app.overlays:
    group = max(group, overlay.scene.newestAiGroup)
  for overlay in app.overlays:
    if group > 0 and overlay.scene.clearAi(group):
      overlay.dirty = true
      result = true

proc answer(app: var App, command: Command, parameters: GVariant): GVariant =
  ## Runs a call to our D-Bus service; the result is its reply.
  case command
  of CmdNone, CmdToggle .. CmdQuit:
    app.runCommand(command)
  of CmdStatus:
    # For inkpane-mcp before it clicks for the AI: a click must reach the app below,
    # not draw (drawing mode) or press Inkpane's toolbar (x, y, w, h per monitor).
    let bars = newBuilder("a(iiii)")
    for overlay in app.overlays:
      let b = if app.hideToolbar: FRect() else: overlay.toolbar.bounds
      g_variant_builder_add(bars, "(iiii)", cint(b.x), cint(b.y), cint(ceil(b.w)), cint(ceil(b.h)))
    result = g_variant_new("(bb@a(iiii))", cint(app.drawing), cint(app.passthrough), bars.finish())
  of CmdMonitors:
    let list = newBuilder("a(siiii)")
    for m in monitors():
      g_variant_builder_add(list, "(siiii)", m.name.cstring, m.bounds.x, m.bounds.y,
        m.bounds.w, m.bounds.h)
    result = g_variant_new("(@a(siiii))", list.finish())
  of CmdDraw:
    app.aiDraw(@[app.aiShape(parameters, monitors().len)])
  of CmdDrawMany:
    let list = g_variant_get_child_value(parameters, 0)   # parameters is (a(isa(dd)sdbs))
    defer: g_variant_unref(list)
    let monitorCount = monitors().len
    var shapes: seq[AiShape]
    for i in 0 ..< int(g_variant_n_children(list)):
      let shape = g_variant_get_child_value(list, csize_t(i))
      defer: g_variant_unref(shape)
      try:
        shapes.add(app.aiShape(shape, monitorCount))
      except ValueError as e:
        raise newException(ValueError, "Shape " & $i & ": " & e.msg)
    app.aiDraw(shapes)
  of CmdClear:
    var aiOnly: cint
    g_variant_get(parameters, "(b)", addr aiOnly)
    if aiOnly == 0:   # everything goes, including what the user is typing or dragging
      app.stopTyping(keep = false)
      app.drawingOn = nil
    for overlay in app.overlays:
      if aiOnly != 0: discard overlay.scene.clearAi() else: overlay.scene.clear()
      overlay.dirty = true
  of CmdUndoAi:
    result = g_variant_new("(b)", cint(app.aiUndo()))
  of CmdSetBoard:
    var name: cstring
    g_variant_get(parameters, "(&s)", addr name)
    let board = case $name
      of "none": Transparent
      of "whiteboard": Whiteboard
      of "blackboard": Blackboard
      else: raise newException(ValueError, "Board must be none, whiteboard or blackboard.")
    app.openForAi()
    app.board = board
    # A board hides the screen, so click-through has nothing to offer: the keyboard
    # comes to Inkpane, where Ctrl+W / Ctrl+B and Esc work, and a hint says so.
    app.boardHint = board != Transparent
    if app.boardHint and app.passthrough:
      app.setPassthrough(false)
    app.markAllDirty()
  of CmdCapture:
    var monitor, x, y, w, h, width, height: int32
    g_variant_get(parameters, "(iiiiiii)", addr monitor, addr x, addr y, addr w, addr h,
      addr width, addr height)
    if monitor notin 0'i32 ..< int32(monitors().len):
      raise newException(ValueError, "No monitor " & $monitor)
    if width < 0 or height < 0 or width > 16384 or height > 16384:
      raise newException(ValueError, "Bad size " & $width & " × " & $height)
    if w < 0 or h < 0:
      raise newException(ValueError, "Bad area " & $w & " × " & $h)
    let path = runtimeDir() / "capture.png"
    app.saveCapture(monitor, Rect(x: x, y: y, w: w, h: h), width, height, path)
    result = g_variant_new("(s)", path.cstring)

############################
# Background Services
############################

proc serviceMethod(methodName: string, parameters: GVariant, invocation: pointer) =
  # Queued and answered from the main loop (collectCommands), which for Capture can take
  # a while.
  for command in CmdToggle .. CmdCapture:
    if methodName == $command:
      pendingCalls.add(Call(command: command, parameters: g_variant_ref(parameters),
        invocation: invocation))
      return
  reply(invocation)

proc bindToggleShortcut(app: var App) =
  # May show the desktop's shortcut confirmation dialog the first time.
  if not globalShortcutsAvailable():
    setTrayShortcutHint("")
    return
  try:
    app.shortcuts = bindShortcuts([ShortcutBinding(
      id: ToggleShortcutId, description: "Toggle drawing on screen", trigger: "LOGO+z")])
    # The desktop keeps any key the user already confirmed or chose; show that one.
    if app.shortcuts.triggers.hasKey(ToggleShortcutId):
      setTrayShortcutHint(app.shortcuts.triggers[ToggleShortcutId])
  except CatchableError:
    setTrayShortcutHint("")
    # Once only: on compositors like Niri it fails at every start, and the user binds
    # `inkpane --toggle` in the compositor instead.
    if not shortcutNoticeShown():
      markShortcutNoticeShown()
      notifyError("Global shortcut unavailable (" & getCurrentExceptionMsg() &
        "). Bind `inkpane --toggle` to a key in your compositor, or use the tray icon.")

proc updateCursor(app: var App) =
  ## A move cursor over the toolbar's grip and while the toolbar is dragged.
  let grip = app.movingToolbar != nil or (app.hoverOn != nil and app.hoverButton >= 0 and
    app.hoverOn.toolbar.buttons[app.hoverButton].kind == GripButton)
  if grip != app.moveCursorShown:
    app.moveCursorShown = grip
    if grip and moveCursor == nil:
      moveCursor = createSystemCursor(SYSTEM_CURSOR_MOVE)
    discard setCursor(if grip: moveCursor else: getDefaultCursor())

proc updateTooltip(app: var App) =
  ## A tooltip appears once the pointer rests on a toolbar button for a moment.
  var on: Overlay = nil
  var button = -1
  for overlay in app.overlays:
    let hit = app.toolbarHit(overlay)
    if hit >= 0:
      on = overlay
      button = hit
  if on != app.hoverOn or button != app.hoverButton:
    if app.tooltip and app.hoverOn != nil:
      app.hoverOn.dirty = true   # take the old tooltip away
    app.hoverOn = on
    app.hoverButton = button
    app.hoverSince = getTicks()
    app.tooltip = false
  elif on != nil and not app.tooltip and getTicks() - app.hoverSince >= TooltipDelayMs:
    app.tooltip = textAvailable()
    on.dirty = app.tooltip

proc collectCommands(app: var App) =
  dbus.pump()
  for action in takeTrayActions():
    pendingCommands.add(case action
      of TrayToggle: CmdToggle
      of TrayStartStop: (if app.drawing: CmdHide else: CmdShow)
      of TrayQuit: CmdQuit)
  for shortcutId in app.shortcuts.takeActivated():
    if shortcutId == ToggleShortcutId:
      pendingCommands.add(CmdToggle)
  let commands = pendingCommands
  pendingCommands.setLen(0)
  for command in commands:
    app.runCommand(command)
  let calls = pendingCalls
  pendingCalls.setLen(0)
  for call in calls:
    try:
      reply(call.invocation, app.answer(call.command, call.parameters))
    except CatchableError:
      g_dbus_method_invocation_return_dbus_error(call.invocation,
        "org.vyrnexis.Inkpane.Error.Failed", getCurrentExceptionMsg().cstring)
    g_variant_unref(call.parameters)

proc onWaylandReadable(fd: cint, condition: cuint, data: pointer): cint {.cdecl.} =
  # Only wakes the idle loop; SDL reads the events. A hang-up means the compositor is gone.
  if (condition and (GIoErr or GIoHup)) != 0:
    pendingCommands.add(CmdQuit)
    return 0
  1

proc onQuitSignal(data: pointer): cint {.cdecl.} =
  pendingCommands.add(CmdQuit)
  1

proc forwardToRunningInstance(command: Command): int =
  # Another Inkpane owns the bus name: pass the request on (plain `inkpane` toggles).
  let methodName = $(if command == CmdNone: CmdToggle else: command)
  try:
    g_variant_unref(call(ServiceName, ServicePath, ServiceInterface, methodName))
    0
  except DBusError:
    stderr.writeLine("inkpane: could not reach the running instance: " & getCurrentExceptionMsg())
    1

proc usage() =
  echo """Usage: inkpane [--toggle | --on | --off | --quit]

Starts Inkpane in the background (tray icon). With an instance already running,
the options control it; plain `inkpane` then toggles drawing.

  --toggle   start or stop drawing
  --on       start drawing
  --off      stop drawing and clear
  --quit     quit the running instance"""

proc run(): int =
  var command = CmdNone
  for kind, key, value in getopt():
    if kind in {cmdLongOption, cmdShortOption}:
      case key
      of "toggle": command = CmdToggle
      of "on": command = CmdShow
      of "off": command = CmdHide
      of "quit": command = CmdQuit
      of "h", "help":
        usage()
        return 0
      else:
        usage()
        return 2

  try:
    if not requestName(ServiceName):
      return forwardToRunningInstance(command)
  except DBusError:
    stderr.writeLine("inkpane: D-Bus unavailable: " & getCurrentExceptionMsg())
    return 1
  if command in {CmdQuit, CmdHide}:
    echo "inkpane: not running"
    return 0

  discard setHint(HINT_NO_SIGNAL_HANDLERS, "1")   # GLib handles SIGINT/SIGTERM below
  # Only Wayland works. Without this, SDL picks X11 on compositors lacking fifo-v1 (Niri).
  discard setHintWithPriority(HINT_VIDEO_DRIVER, "wayland", HINT_OVERRIDE)
  if not init(INIT_VIDEO):
    notifyError("Inkpane needs a Wayland session: " & $getError())
    return 1
  defer: sdl3.quit()

  let settings = loadSettings()
  setFontLookup(proc (): string = settings.findFont())
  var app = App(settings: settings, color: settings.palette[settings.color], width: settings.width,
    tool: settings.tool, fill: settings.fill, hideToolbar: not settings.toolbar,
    toolbarPlace: loadToolbarPlace(), running: true)
  exportObject(ServicePath, ServiceXml, ServiceInterface, serviceMethod)
  startTray(ServiceName, DefaultShortcutHint)
  defer: app.hideOverlays()

  # Before any overlay: the first time, the desktop asks the user to confirm the shortcut,
  # and a full-screen overlay would cover that dialog while this waits for the answer.
  app.bindToggleShortcut()
  if command in {CmdShow, CmdToggle}:
    app.showOverlays()

  # With no overlay there is no SDL window, and SDL can then only busy-poll for events.
  # So while idle, sleep in GLib instead: D-Bus, the Wayland socket and quit signals wake it.
  discard g_unix_fd_add(waylandFd(), GIoIn or GIoErr or GIoHup, onWaylandReadable, nil)
  for signal in [SIGINT, SIGTERM]:
    discard g_unix_signal_add(signal, onQuitSignal, nil)

  var event: Event
  while app.running:
    if app.drawing:
      if waitEventTimeout(event, DrawingWaitMs):
        app.handleEvent(event)
    else:
      dbus.wait()
    while pollEvent(event):
      app.handleEvent(event)
    app.collectCommands()
    app.updateTooltip()
    app.updateCursor()
    for overlay in app.overlays:
      if overlay.closedByCompositor():
        pendingCommands.add(CmdHide)
      elif overlay.dirty:
        app.redraw(overlay)
  0

when isMainModule:
  quit(run())
