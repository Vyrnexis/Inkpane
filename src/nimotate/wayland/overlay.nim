import sdl3

import layershell
import ../draw/scene

# One transparent, full-screen overlay window per monitor. Each SDL window is created
# without a shell role and then turned into a wlr-layer-shell surface on its output.

const LayerNamespace = "nimotate"

type
  Overlay* = ref object
    window*: Window
    renderer*: Renderer
    layer: LayerHandle
    windowId*: WindowID
    width*: float32       # logical size; mouse coordinates use the same units
    height*: float32
    scene*: Scene
    pointer*: FPoint
    pointerInside*: bool
    dirty*: bool

  OverlayError* = object of CatchableError

proc fail(message: string) =
  raise newException(OverlayError, message & ": " & $getError())

proc newOverlay(display: DisplayID): Overlay =
  var bounds: Rect
  if not getDisplayBounds(display, bounds):
    fail("Could not read the monitor size")

  let props = createProperties()
  discard props.setBooleanProperty(PROP_WINDOW_CREATE_WAYLAND_SURFACE_ROLE_CUSTOM_BOOLEAN, true)
  discard props.setBooleanProperty(PROP_WINDOW_CREATE_TRANSPARENT_BOOLEAN, true)
  discard props.setBooleanProperty(PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN, true)
  discard props.setNumberProperty(PROP_WINDOW_CREATE_WIDTH_NUMBER, bounds.w.int64)
  discard props.setNumberProperty(PROP_WINDOW_CREATE_HEIGHT_NUMBER, bounds.h.int64)
  let window = createWindowWithProperties(props)
  destroyProperties(props)
  if window.isNil:
    fail("Could not create the overlay window")

  let windowProps = getWindowProperties(window)
  let wlDisplay = windowProps.getPointerProperty(PROP_WINDOW_WAYLAND_DISPLAY_POINTER, nil)
  let wlSurface = windowProps.getPointerProperty(PROP_WINDOW_WAYLAND_SURFACE_POINTER, nil)
  let wlOutput = getDisplayProperties(display).getPointerProperty(PROP_DISPLAY_WAYLAND_WL_OUTPUT_POINTER, nil)
  if wlDisplay.isNil or wlSurface.isNil:
    destroyWindow(window)
    fail("SDL did not expose the Wayland surface")

  if not initLayerShell(wlDisplay):
    destroyWindow(window)
    raise newException(OverlayError,
      "This desktop does not support the layer-shell protocol (GNOME is not supported).")

  let layer = createOverlayLayer(wlDisplay, wlSurface, wlOutput, LayerNamespace)
  if layer.isNil or layer.closed or not layer.configured:
    if not layer.isNil:
      layer.destroy()
    destroyWindow(window)
    fail("The compositor refused the overlay surface")

  # Custom surfaces get no resize notifications, so tell SDL the configured size.
  let width = if layer.width > 0: layer.width else: bounds.w.int
  let height = if layer.height > 0: layer.height else: bounds.h.int
  discard window.setWindowSize(cint(width), cint(height))

  let renderer = createRenderer(window, nil)
  if renderer.isNil:
    layer.destroy()
    destroyWindow(window)
    fail("Could not create a renderer")
  discard renderer.setRenderVSync(1)
  discard renderer.setRenderDrawBlendMode(BLENDMODE_BLEND)

  Overlay(
    window: window,
    renderer: renderer,
    layer: layer,
    windowId: getWindowID(window),
    width: width.float32,
    height: height.float32,
    dirty: true
  )

proc updateRenderScale*(overlay: Overlay) =
  # Draw in logical coordinates (same as mouse events) at the monitor's real pixel density.
  var pixelWidth, pixelHeight: cint
  if overlay.window.getWindowSizeInPixels(pixelWidth, pixelHeight) and overlay.width > 0:
    let scale = pixelWidth.float32 / overlay.width
    discard overlay.renderer.setRenderScale(scale, scale)

proc closedByCompositor*(overlay: Overlay): bool =
  overlay.layer.closed

proc close*(overlay: Overlay) =
  if overlay.renderer != nil:
    destroyRenderer(overlay.renderer)
    overlay.renderer = nil
  if not overlay.layer.isNil:
    overlay.layer.destroy()
    overlay.layer = LayerHandle(nil)
  if overlay.window != nil:
    destroyWindow(overlay.window)
    overlay.window = nil

proc openOverlays*(): seq[Overlay] =
  ## One overlay per connected monitor; all or none, so a failure never leaves one open.
  var count: cint
  let displays = getDisplays(count)
  if displays.isNil or count == 0:
    raise newException(OverlayError, "No monitors found: " & $getError())
  try:
    for i in 0 ..< count:
      result.add(newOverlay(displays[i]))
      result[^1].updateRenderScale()
  except OverlayError:
    for overlay in result:
      overlay.close()
    raise
  finally:
    sdlFree(displays)
