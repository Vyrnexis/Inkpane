import std/[parseopt, posix, tables]

import sdl3

import nimotate/desktop/[dbus, glib, portal, tray]
import nimotate/draw/[render, scene]
import nimotate/wayland/overlay

# Nimotate: draw on the screen through a transparent Wayland overlay.
#
# Runs in the background with a tray icon. Meta+Z (GlobalShortcuts portal), a tray
# click, or `nimotate --toggle` opens the overlay on every monitor; toggling again or Esc
# closes it and clears the drawing.

const
  Palette = [
    FColor(r: 0.93, g: 0.20, b: 0.20, a: 1.0),  # 1 red
    FColor(r: 0.98, g: 0.55, b: 0.13, a: 1.0),  # 2 orange
    FColor(r: 0.98, g: 0.85, b: 0.15, a: 1.0),  # 3 yellow
    FColor(r: 0.20, g: 0.78, b: 0.35, a: 1.0),  # 4 green
    FColor(r: 0.20, g: 0.52, b: 0.98, a: 1.0),  # 5 blue
    FColor(r: 0.62, g: 0.35, b: 0.90, a: 1.0),  # 6 purple
    FColor(r: 1.00, g: 1.00, b: 1.00, a: 1.0),  # 7 white
    FColor(r: 0.05, g: 0.05, b: 0.05, a: 1.0)   # 8 black
  ]
  # Excalidraw's layout: a number key (by position, so any keyboard layout works) or a letter.
  ToolKeys = [
    (SCANCODE_2, SDLK_R, Rectangle),
    (SCANCODE_3, SDLK_D, Diamond),
    (SCANCODE_4, SDLK_O, Ellipse),
    (SCANCODE_5, SDLK_A, Arrow),
    (SCANCODE_6, SDLK_L, Line),
    (SCANCODE_7, SDLK_P, Pen),
    (SCANCODE_9, SDLK_H, Highlighter),
    (SCANCODE_0, SDLK_E, Eraser)
  ]
  MinWidth = 1'f32
  MaxWidth = 64'f32
  WidthStep = 2'f32

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

  App = object
    overlays: seq[Overlay]
    tool: Tool
    color: FColor
    width: float32
    fill: bool           # new rectangles, diamonds and ellipses are filled
    drawingOn: Overlay   # overlay that owns the drag in progress (drawing or erasing)
    dragTool: Tool       # tool of that drag: the eraser for a right drag
    dragButton: uint8
    running: bool
    shortcuts: ShortcutSession

var pendingCommands: seq[Command]   # filled by D-Bus callbacks, drained by the main loop

proc overlayFor(app: App, windowId: WindowID): Overlay =
  for overlay in app.overlays:
    if overlay.windowId == windowId:
      return overlay

proc markAllDirty(app: var App) =
  for overlay in app.overlays:
    overlay.dirty = true

proc redraw(app: App, overlay: Overlay) =
  let renderer = overlay.renderer
  discard renderer.setRenderDrawColor(0, 0, 0, 0)
  discard renderer.renderClear()
  overlay.mesh.update(overlay.scene)
  renderer.draw(overlay.mesh)
  renderer.drawActiveShape(overlay.scene)
  if overlay.pointerInside and not overlay.scene.drawing:
    # Preview of the pen tip (or the eraser): an outline with a dark halo so it shows on
    # both light and dark content.
    let erasing = app.tool == Eraser
    let radius = if erasing: EraserRadius else: max(toolWidth(app.tool, app.width) / 2, 2)
    let color = if erasing: FColor(r: 1, g: 1, b: 1, a: 0.9) else: toolColor(app.tool, app.color)
    renderer.drawRing(overlay.pointer, radius + 1, 3, FColor(r: 0, g: 0, b: 0, a: 0.45))
    renderer.drawRing(overlay.pointer, radius, 1.5, color)
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

proc handleKey(app: var App, event: KeyboardEvent) =
  let ctrl = (event.`mod` and KMOD_CTRL) != 0
  let shift = (event.`mod` and KMOD_SHIFT) != 0
  let target = if app.drawingOn != nil: app.drawingOn else: app.overlayFor(event.windowID)
  if shift and event.scancode in SCANCODE_1 .. SCANCODE_8:
    app.color = Palette[ord(event.scancode) - ord(SCANCODE_1)]
    app.markAllDirty()
    return
  if not (ctrl or shift) and app.drawingOn == nil:
    for (digit, letter, tool) in ToolKeys:
      if event.scancode == digit or event.key == letter:
        app.tool = tool
        app.markAllDirty()
        return
  case event.key
  of SDLK_ESCAPE:
    pendingCommands.add(CmdHide)
  of SDLK_F:
    app.fill = not app.fill
  of SDLK_DELETE, SDLK_C:
    for overlay in app.overlays:
      overlay.scene.clear()
    app.markAllDirty()
  of SDLK_Z:
    if ctrl and target != nil:
      let changed = if shift: target.scene.redo() else: target.scene.undo()
      target.dirty = target.dirty or changed
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
  of EVENT_MOUSE_MOTION:
    let overlay = app.overlayFor(event.motion.windowID)
    if overlay == nil:
      return
    let point = FPoint(x: event.motion.x, y: event.motion.y)
    overlay.pointer = point
    overlay.pointerInside = true
    if app.drawingOn == overlay:
      app.follow(overlay, point)
    overlay.dirty = true
  of EVENT_MOUSE_BUTTON_DOWN:
    let overlay = app.overlayFor(event.button.windowID)
    let button = event.button.button
    if overlay != nil and app.drawingOn == nil and int(button) in [BUTTON_LEFT, BUTTON_RIGHT]:
      let point = FPoint(x: event.button.x, y: event.button.y)
      app.dragTool = if int(button) == BUTTON_RIGHT: Eraser else: app.tool
      app.dragButton = button
      if app.dragTool == Eraser:
        discard overlay.scene.eraseAt(point)
      else:
        overlay.scene.begin(app.tool, point, app.color, app.width, app.fill)
      app.drawingOn = overlay
      overlay.dirty = true
  of EVENT_MOUSE_BUTTON_UP:
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
  setTrayDrawing(false)

proc runCommand(app: var App, command: Command) =
  case command
  of CmdToggle:
    if app.drawing: app.hideOverlays() else: app.showOverlays()
  of CmdShow: app.showOverlays()
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

  var app = App(color: Palette[0], width: 6, running: true)
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
    for overlay in app.overlays:
      if overlay.closedByCompositor():
        pendingCommands.add(CmdHide)
      elif overlay.dirty:
        app.redraw(overlay)
  0

when isMainModule:
  quit(run())
