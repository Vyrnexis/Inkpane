# wlr-layer-shell bindings for SDL3 custom-role surfaces.
# The protocol work is in c/layer_glue.c; this module only exposes it to Nim.

{.passL: "-lwayland-client".}
{.compile: "generated/xdg-shell-protocol.c".}
{.compile: "generated/wlr-layer-shell-unstable-v1-protocol.c".}
{.compile: "c/layer_glue.c".}

type
  LayerHandle* = distinct pointer

proc layerShellInit(display: pointer): cint {.importc: "nimotate_layer_shell_init", cdecl.}
proc layerCreate(display, surface, output: pointer, nameSpace: cstring,
  exclusiveKeyboard: cint): LayerHandle {.importc: "nimotate_layer_create", cdecl.}
proc layerConfigured(layer: LayerHandle): cint {.importc: "nimotate_layer_configured", cdecl.}
proc layerClosed(layer: LayerHandle): cint {.importc: "nimotate_layer_closed", cdecl.}
proc layerWidth(layer: LayerHandle): cuint {.importc: "nimotate_layer_width", cdecl.}
proc layerHeight(layer: LayerHandle): cuint {.importc: "nimotate_layer_height", cdecl.}
proc layerDestroy(layer: LayerHandle) {.importc: "nimotate_layer_destroy", cdecl.}

proc isNil*(layer: LayerHandle): bool =
  pointer(layer).isNil

proc initLayerShell*(display: pointer): bool =
  ## Binds zwlr_layer_shell_v1. False means the compositor has no layer-shell (e.g. GNOME).
  layerShellInit(display) != 0

proc createOverlayLayer*(display, surface, output: pointer, nameSpace: string,
    exclusiveKeyboard = true): LayerHandle =
  ## Full-screen overlay-layer surface; blocks until the compositor configures it.
  layerCreate(display, surface, output, nameSpace.cstring, cint(exclusiveKeyboard))

proc configured*(layer: LayerHandle): bool = layerConfigured(layer) != 0
proc closed*(layer: LayerHandle): bool = layerClosed(layer) != 0
proc width*(layer: LayerHandle): int = layerWidth(layer).int
proc height*(layer: LayerHandle): int = layerHeight(layer).int

proc destroy*(layer: LayerHandle) =
  layerDestroy(layer)
