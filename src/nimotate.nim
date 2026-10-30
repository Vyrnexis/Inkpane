import std/[math, parseopt, posix, strutils, tables, times]

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
  Command = enum
    CmdNone
    CmdToggle
    CmdShow
    CmdHide
    CmdQuit

  App = object
    overlays: seq[Overlay]
    color: FColor
    width: float32
    drawingOn: Overlay   # overlay that owns the stroke in progress
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
  if overlay.pointerInside and not overlay.scene.active:
    # Preview of the pen tip: an outline in the pen colour with a dark halo so it shows
    # on both light and dark content.
    let radius = max(app.width / 2, 2)
    renderer.drawRing(overlay.pointer, radius + 1, 3, FColor(r: 0, g: 0, b: 0, a: 0.45))
    renderer.drawRing(overlay.pointer, radius, 1.5, app.color)
  discard renderer.renderPresent()
  overlay.dirty = false

proc handleKey(app: var App, event: KeyboardEvent) =
  let ctrl = (event.`mod` and KMOD_CTRL) != 0
  let shift = (event.`mod` and KMOD_SHIFT) != 0
  let target = if app.drawingOn != nil: app.drawingOn else: app.overlayFor(event.windowID)
  case event.key
  of SDLK_ESCAPE:
    pendingCommands.add(CmdHide)
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
  of SDLK_1 .. SDLK_8:
    app.color = Palette[int(event.key - SDLK_1)]
    app.markAllDirty()
  else:
    discard

proc handleEvent(app: var App, event: Event) =
  case event.`type`
  of EVENT_QUIT:
    app.running = false
  of EVENT_KEY_DOWN:
    app.handleKey(event.key)
  of EVENT_MOUSE_MOTION:
    let overlay = app.overlayFor(event.motion.windowID)
    if overlay == nil:
      return
    let point = FPoint(x: event.motion.x, y: event.motion.y)
    overlay.pointer = point
    overlay.pointerInside = true
    if app.drawingOn == overlay:
      discard overlay.scene.extendStroke(point)
    overlay.dirty = true
  of EVENT_MOUSE_BUTTON_DOWN:
    let overlay = app.overlayFor(event.button.windowID)
    if overlay != nil and event.button.button == BUTTON_LEFT:
      let point = FPoint(x: event.button.x, y: event.button.y)
      overlay.scene.beginStroke(point, app.color, app.width)
      app.drawingOn = overlay
      overlay.dirty = true
  of EVENT_MOUSE_BUTTON_UP:
    if app.drawingOn != nil and event.button.button == BUTTON_LEFT:
      app.drawingOn.scene.endStroke(FPoint(x: event.button.x, y: event.button.y))
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
    let hints = g_variant_builder_new(variantType("a{sv}"))
    let actions = g_variant_builder_new(variantType("as"))
    g_variant_unref(call("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
      "org.freedesktop.Notifications", "Notify",
      g_variant_new("(susss@as@a{sv}i)", "Nimotate".cstring, 0'u32, "org.vyrnexis.Nimotate".cstring,
        "Nimotate".cstring, message.cstring, g_variant_builder_end(actions),
        g_variant_builder_end(hints), -1'i32)))
    g_variant_builder_unref(hints)
    g_variant_builder_unref(actions)
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
  case methodName
  of "Toggle": pendingCommands.add(CmdToggle)
  of "Show": pendingCommands.add(CmdShow)
  of "Hide": pendingCommands.add(CmdHide)
  of "Quit": pendingCommands.add(CmdQuit)
  else: discard
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
  # Another Nimotate owns the bus name: pass the request on and exit.
  let methodName =
    case command
    of CmdShow: "Show"
    of CmdHide: "Hide"
    of CmdQuit: "Quit"
    else: "Toggle"
  try:
    g_variant_unref(call(ServiceName, ServicePath, ServiceInterface, methodName))
    0
  except DBusError:
    stderr.writeLine("nimotate: could not reach the running instance: " & getCurrentExceptionMsg())
    1

proc addDemoStroke(overlay: Overlay) =
  # --demo: a spiral in the middle of the first monitor, to check rendering without input.
  let center = FPoint(x: overlay.width / 2, y: overlay.height / 2)
  overlay.scene.beginStroke(center, Palette[0], 8)
  for i in 1 .. 400:
    let angle = float32(i) * 0.06
    let radius = float32(i) * 0.6
    discard overlay.scene.extendStroke(FPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
  overlay.scene.endStroke(overlay.scene.strokes[^1].points[^1])

proc usage() =
  echo """Usage: nimotate [--toggle | --on | --off | --quit]

Starts Nimotate in the background (tray icon). With an instance already running,
the options control it; plain `nimotate` then toggles drawing.

  --toggle   start or stop drawing
  --on       start drawing
  --off      stop drawing and clear
  --quit     quit the running instance
  --demo     (testing) open the overlay with a sample stroke
  --exit-after=SECONDS  (testing) quit automatically"""

proc run(): int =
  var command = CmdNone
  var demo = false
  var exitAfter = 0.0
  for kind, key, value in getopt():
    if kind in {cmdLongOption, cmdShortOption}:
      case key
      of "toggle": command = CmdToggle
      of "on": command = CmdShow
      of "off": command = CmdHide
      of "quit": command = CmdQuit
      of "demo": demo = true
      of "exit-after": exitAfter = parseFloat(value)
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

  if demo:
    app.showOverlays()
    if app.overlays.len > 0:
      app.overlays[0].addDemoStroke()
  elif command in {CmdShow, CmdToggle}:
    app.showOverlays()
  app.bindToggleShortcut()

  # With no overlay there is no SDL window, and SDL can then only busy-poll for events.
  # So while idle, sleep in GLib instead: D-Bus, the Wayland socket and quit signals wake it.
  discard g_unix_fd_add(waylandFd(), GIoIn or GIoErr or GIoHup, onWaylandReadable, nil)
  for signal in [SIGINT, SIGTERM]:
    discard g_unix_signal_add(signal, onQuitSignal, nil)

  let startedAt = epochTime()
  var event: Event
  while app.running:
    if exitAfter > 0 and epochTime() - startedAt >= exitAfter:
      break
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
