import std/math

import sdl3

import layershell
import ../draw/[render, scene, toolbar]

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
    mesh*: Mesh           # triangles of `scene`, kept between frames
    toolbar*: Toolbar
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
  let width = if layer.width > 0: int(layer.width) else: int(bounds.w)
  let height = if layer.height > 0: int(layer.height) else: int(bounds.h)
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
    overlay.mesh.setPixelSize(1 / scale)
    discard overlay.renderer.setRenderScale(scale, scale)

proc setPassthrough*(overlay: Overlay, on: bool, clickable: FRect) =
  ## Click-through: the drawing stays visible, but only `clickable` (logical px, which are
  ## also surface coordinates) still takes the pointer, and the keyboard goes elsewhere.
  overlay.layer.setPassthrough(on, int32(clickable.x), int32(clickable.y),
    int32(ceil(clickable.w)), int32(ceil(clickable.h)))

proc closedByCompositor*(overlay: Overlay): bool =
  overlay.layer.closed

proc waylandFd*(): cint =
  ## SDL's Wayland connection, for waiting on it while no overlay (and so no SDL window) exists.
  displayFd(getGlobalProperties().getPointerProperty(PROP_GLOBAL_VIDEO_WAYLAND_WL_DISPLAY_POINTER, nil))

proc close*(overlay: Overlay) =
  if overlay.renderer != nil:
    destroyRenderer(overlay.renderer)
    overlay.renderer = nil
  if not overlay.layer.isNil:
    overlay.layer.destroy()
    overlay.layer = nil
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
