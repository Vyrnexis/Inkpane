# wlr-layer-shell bindings for SDL3 custom-role surfaces.
# The protocol work is in c/layer_glue.c; this module only exposes it to Nim.

{.passL: "-lwayland-client".}
{.compile: "generated/xdg-shell-protocol.c".}
{.compile: "generated/wlr-layer-shell-unstable-v1-protocol.c".}
{.compile: "c/layer_glue.c".}

type
  Layer* = object         # InkLayer in c/layer_glue.c; updated by the compositor's events
    layerSurface: pointer
    configured*: bool
    closed*: bool
    width*: uint32
    height*: uint32
    surface: pointer

  LayerHandle* = ptr Layer

proc layerShellInit(display: pointer): cint {.importc: "inkpane_layer_shell_init", cdecl.}
proc layerCreate(display, surface, output: pointer, nameSpace: cstring,
  exclusiveKeyboard: cint): LayerHandle {.importc: "inkpane_layer_create", cdecl.}
proc layerDestroy(layer: LayerHandle) {.importc: "inkpane_layer_destroy", cdecl.}
proc layerSetPassthrough(layer: LayerHandle, passthrough: cint, x, y, width, height: int32)
  {.importc: "inkpane_layer_set_passthrough", cdecl.}
proc wl_display_get_fd(display: pointer): cint {.importc, cdecl.}

proc displayFd*(display: pointer): cint =
  ## The Wayland socket; readable whenever the compositor sent something.
  wl_display_get_fd(display)

proc initLayerShell*(display: pointer): bool =
  ## Binds zwlr_layer_shell_v1. False means the compositor has no layer-shell (e.g. GNOME).
  layerShellInit(display) != 0

proc createOverlayLayer*(display, surface, output: pointer, nameSpace: string,
    exclusiveKeyboard = true): LayerHandle =
  ## Full-screen overlay-layer surface; blocks until the compositor configures it.
  layerCreate(display, surface, output, nameSpace.cstring, cint(exclusiveKeyboard))

proc setPassthrough*(layer: LayerHandle, on: bool, x, y, width, height: int32) =
  ## Click-through: only the given rectangle (zero size: nothing) still takes the pointer,
  ## and the keyboard goes to the windows below.
  layerSetPassthrough(layer, cint(on), x, y, width, height)

proc destroy*(layer: LayerHandle) =
  layerDestroy(layer)
