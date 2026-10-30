import std/[math, parseopt, posix, strutils, tables]

import sdl3

import nimotate/config
import nimotate/desktop/[dbus, glib, portal, tray]
import nimotate/draw/[render, scene, text, toolbar]
import nimotate/wayland/overlay

# Nimotate: draw on the screen through a transparent Wayland overlay.
#
# Runs in the background with a tray icon. Meta+Z (GlobalShortcuts portal), a tray
# click, or `nimotate --toggle` opens the overlay on every monitor; toggling again or Esc
# closes it and clears the drawing. 1 / V switches to click-through: the drawing stays
# while apps get the mouse and keyboard, until the toolbar or the toggle brings it back.

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
    ("[ ]  or wheel", "Thinner / thicker"),
    ("F", "Fill rectangles, diamonds, ellipses"),
    ("Shift / Ctrl while dragging", "Square, snap 15° / from the centre"),
    ("Right drag", "Erase"),
    ("Ctrl+Z, Ctrl+Shift+Z", "Undo, redo"),
    ("C / Delete", "Clear"),
    ("Ctrl+W / Ctrl+B", "Whiteboard / blackboard"),
    ("Tab", "Hide the toolbar"),
    ("F1", "This help"),
    ("Esc", "Close and clear")]
  Boards = [   # background of each board; Transparent shows the desktop
    FColor(r: 0, g: 0, b: 0, a: 0),
    FColor(r: 0.98, g: 0.98, b: 0.97, a: 1),
    FColor(r: 0.13, g: 0.14, b: 0.15, a: 1)
  ]

  ServiceName = "org.vyrnexis.Nimotate"
  ServicePath = "/org/vyrnexis/Nimotate"
  ServiceInterface = "org.vyrnexis.Nimotate"
  ServiceXml = """
<node>
  <interface name="org.vyrnexis.Nimotate">
    <method name="Toggle"/>
    <method name="Show"/>
    <method name="Hide"/>
    <method name="Quit"/>
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
    drawingOn: Overlay   # overlay that owns the drag in progress (drawing or erasing)
    dragTool: Tool       # tool of that drag: the eraser for a right drag
    dragButton: uint8
    typingOn: Overlay    # overlay with text being typed
    help: bool           # F1 cheat sheet shown
    hoverOn: Overlay     # toolbar button under the pointer, for its tooltip
    hoverButton: int
    hoverSince: uint64
    tooltip: bool        # hovered long enough: show it
    warnedNoText: bool
    running: bool
    shortcuts: ShortcutSession

var pendingCommands: seq[Command]   # filled by D-Bus callbacks, drained by the main loop

proc notifyError(message: string) =
  # Desktop notification so errors are visible even though Nimotate has no window.
  stderr.writeLine("nimotate: " & message)
  try:
    g_variant_unref(call("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
      "org.freedesktop.Notifications", "Notify",
      g_variant_new("(susssasa{sv}i)", "Nimotate".cstring, 0'u32, AppId.cstring,
        "Nimotate".cstring, message.cstring, pointer(nil), pointer(nil), -1'i32)))
  except DBusError:
    discard

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
      "(Arch) or libsdl3-ttf (Debian, Ubuntu), then restart Nimotate.")
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
    fill: app.fill, passthrough: app.passthrough, hover: app.toolbarHit(overlay))

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
      let size = renderer.drawText(overlay.texts, item.text, item.points[0], item.width,
        item.color.onBackground(background), true, overlay.scale)
      item.setBox(size)   # for the eraser
    of Marker:
      let a = item.points[0]
      let b = item.points[1]
      let size = item.width * 0.6
      let extent = measureText(item.text, size)
      let disc = item.color.onBackground(background)
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
      item.color.onBackground(background))
    renderer.draw(caret)

proc drawTooltip(app: App, overlay: Overlay) =
  let button = overlay.toolbar.buttons[app.hoverButton]
  let label = overlay.toolbar.label(button)
  let size = measureText(label, TooltipSize)
  let anchor = button.tooltipAnchor
  let x = clamp(anchor.x - size.x / 2 - 8, 4, max(overlay.width - size.x - 20, 4))
  overlay.renderer.drawBackdrop(FRect(x: x, y: anchor.y + 8, w: size.x + 16, h: size.y + 8),
    overlay.mesh.pixelSize)
  discard overlay.renderer.drawText(overlay.texts, label, FPoint(x: x + 8, y: anchor.y + 12),
    TooltipSize, TextColor, false, overlay.scale)

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

proc redraw(app: App, overlay: Overlay) =
  let renderer = overlay.renderer
  let background = Boards[ord(app.board)]
  discard renderer.setRenderDrawColorFloat(background.r, background.g, background.b, background.a)
  discard renderer.renderClear()
  overlay.mesh.setBackground(background)
  overlay.mesh.update(overlay.scene)
  renderer.draw(overlay.mesh)
  renderer.drawActiveShape(overlay.mesh, overlay.scene)
  overlay.drawTexts(background)
  let toolbarShown = not app.hideToolbar and not app.toolbarInTheWay(overlay)
  if toolbarShown:
    overlay.toolbar.update(FPoint(x: overlay.width, y: overlay.height), app.toolbarPlace,
      overlay.mesh.pixelSize, app.toolbarState(overlay), app.settings.palette, app.settings.presets)
    renderer.draw(overlay.toolbar)
  let overToolbar = toolbarShown and overlay.pointer in overlay.toolbar.bounds
  if overlay.pointerInside and not overlay.scene.drawing and not overToolbar and
      not app.passthrough and app.tool notin Placed:
    # Preview of the pen tip (or the eraser): an outline with a dark halo so it shows on
    # both light and dark content.
    let erasing = app.tool == Eraser
    let radius = if erasing: EraserRadius else: max(toolWidth(app.tool, app.width) / 2, 2)
    let color = if erasing: FColor(r: 1, g: 1, b: 1, a: 0.9)
                else: toolColor(app.tool, app.color).onBackground(background)
    renderer.drawRing(overlay.pointer, radius + 1, 3, FColor(r: 0, g: 0, b: 0, a: 0.45))
    renderer.drawRing(overlay.pointer, radius, 1.5, color)
  if toolbarShown and app.tooltip and app.hoverOn == overlay:
    app.drawTooltip(overlay)
  if app.help:
    overlay.drawHelp()
  overlay.texts.endFrame()
  discard renderer.renderPresent()
  overlay.dirty = false

proc follow(app: var App, overlay: Overlay, point: FPoint) =
  ## Moves the drag in progress to `point`; Shift and Ctrl shape rectangles, lines etc.
  let mods = getModState()
  if app.dragTool == Eraser:
    discard overlay.scene.eraseAt(point)
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

proc press(app: var App, button: Button) =
  if button.kind == PassButton:
    app.setPassthrough(not app.passthrough)
    return
  if app.passthrough:   # picking anything else goes back to drawing, as in Excalidraw
    app.setPassthrough(false)
  case button.kind
  of PassButton: discard
  of ToolButton: app.tool = ToolOrder[button.index].tool
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
      app.setPassthrough(true)
      return
    for key in ToolOrder:
      if key.keyFor(event):
        app.tool = key.tool
        app.markAllDirty()
        return
  case event.key
  of SDLK_ESCAPE:
    if app.help:
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
  of SDLK_TAB:
    app.hideToolbar = not app.hideToolbar
  of SDLK_DELETE, SDLK_C:
    for overlay in app.overlays:
      overlay.scene.clear()
    app.markAllDirty()
  of SDLK_Z:
    if ctrl and target != nil:
      let changed = if shift: target.scene.redo() else: target.scene.undo()
      target.dirty = target.dirty or changed
  of SDLK_W, SDLK_B:
    if ctrl:   # Ctrl+W whiteboard, Ctrl+B blackboard; the same key again goes back
      let board = if event.key == SDLK_W: Whiteboard else: Blackboard
      app.board = if app.board == board: Transparent else: board
      app.markAllDirty()
  of SDLK_Y:
    if ctrl and target != nil:
      target.dirty = target.scene.redo() or target.dirty
  of SDLK_LEFTBRACKET:
    app.width = max(MinWidth, app.width - WidthStep)
    app.markAllDirty()
  of SDLK_RIGHTBRACKET:
    app.width = min(MaxWidth, app.width + WidthStep)
    app.markAllDirty()
  else:
    discard

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
      if pressed >= 0:
        if int(button) == BUTTON_LEFT:
          app.press(overlay.toolbar.buttons[pressed])
        return
      if not app.hideToolbar and point in overlay.toolbar.bounds:
        if int(button) == BUTTON_LEFT:   # the background between buttons is the handle
          app.movingToolbar = overlay
          app.grab = FPoint(x: point.x - app.toolbarPlace.x, y: point.y - app.toolbarPlace.y)
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
    if app.drawingOn != nil and event.button.button == app.dragButton:
      let mods = getModState()
      app.drawingOn.scene.finish(FPoint(x: event.button.x, y: event.button.y),
        (mods and KMOD_SHIFT) != 0, (mods and KMOD_CTRL) != 0)
      app.drawingOn.dirty = true
      app.drawingOn = nil
  of EVENT_MOUSE_WHEEL:
    if event.wheel.y == 0:
      return   # horizontal scroll
    let step = if event.wheel.y > 0: WidthStep else: -WidthStep
    app.width = clamp(app.width + step, MinWidth, MaxWidth)
    app.markAllDirty()
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
  setTrayDrawing(true)

proc hideOverlays(app: var App) =
  # Closing the overlay also discards the drawing: nothing lingers on screen.
  for overlay in app.overlays:
    overlay.close()
  app.overlays.setLen(0)
  app.drawingOn = nil
  app.typingOn = nil
  app.hoverOn = nil
  app.tooltip = false
  app.help = false
  app.passthrough = false
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
  of CmdNone: discard

############################
# Background Services
############################

proc serviceMethod(methodName: string, parameters: GVariant, invocation: pointer) =
  for command in CmdToggle .. CmdQuit:
    if methodName == $command:
      pendingCommands.add(command)
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
    notifyError("Global shortcut unavailable (" & getCurrentExceptionMsg() &
      "). Use the tray icon or `nimotate --toggle`.")

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
    pendingCommands.add(if action == TrayQuit: CmdQuit else: CmdToggle)
  for shortcutId in app.shortcuts.takeActivated():
    if shortcutId == ToggleShortcutId:
      pendingCommands.add(CmdToggle)
  let commands = pendingCommands
  pendingCommands.setLen(0)
  for command in commands:
    app.runCommand(command)

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
  # Another Nimotate owns the bus name: pass the request on (plain `nimotate` toggles).
  let methodName = $(if command == CmdNone: CmdToggle else: command)
  try:
    g_variant_unref(call(ServiceName, ServicePath, ServiceInterface, methodName))
    0
  except DBusError:
    stderr.writeLine("nimotate: could not reach the running instance: " & getCurrentExceptionMsg())
    1

proc usage() =
  echo """Usage: nimotate [--toggle | --on | --off | --quit]

Starts Nimotate in the background (tray icon). With an instance already running,
the options control it; plain `nimotate` then toggles drawing.

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
    stderr.writeLine("nimotate: D-Bus unavailable: " & getCurrentExceptionMsg())
    return 1
  if command in {CmdQuit, CmdHide}:
    echo "nimotate: not running"
    return 0

  discard setHint(HINT_NO_SIGNAL_HANDLERS, "1")   # GLib handles SIGINT/SIGTERM below
  if not init(INIT_VIDEO):
    echo "nimotate: SDL init failed: ", getError()
    return 1
  defer: sdl3.quit()

  if $getCurrentVideoDriver() != "wayland":
    echo "nimotate: needs a Wayland session (SDL video driver is ", getCurrentVideoDriver(), ")"
    return 1

  let settings = loadSettings()
  setFontLookup(proc (): string = settings.findFont())
  var app = App(settings: settings, color: settings.palette[settings.color], width: settings.width,
    tool: settings.tool, fill: settings.fill, hideToolbar: not settings.toolbar,
    toolbarPlace: loadToolbarPlace(), running: true)
  exportObject(ServicePath, ServiceXml, ServiceInterface, serviceMethod)
  startTray(ServiceName, DefaultShortcutHint)
  defer: app.hideOverlays()

  if command in {CmdShow, CmdToggle}:
    app.showOverlays()
  app.bindToggleShortcut()

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
    for overlay in app.overlays:
      if overlay.closedByCompositor():
        pendingCommands.add(CmdHide)
      elif overlay.dirty:
        app.redraw(overlay)
  0

when isMainModule:
  quit(run())
