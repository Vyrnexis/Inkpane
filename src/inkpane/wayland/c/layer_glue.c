/*
 * Thin C glue between SDL3 custom-role surfaces and wlr-layer-shell.
 *
 * libwayland's request helpers are static inline functions in the generated
 * headers, so the protocol calls live here and Nim only sees a tiny API.
 * All objects use the default event queue, which SDL already dispatches.
 */

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "../generated/wlr-layer-shell-unstable-v1-client-protocol.h"

/* Mirrored by `Layer` in layershell.nim, which reads the fields directly. */
typedef struct InkLayer {
    struct zwlr_layer_surface_v1 *layer_surface;
    bool configured;
    bool closed;
    uint32_t width;
    uint32_t height;
    struct wl_surface *surface;
} InkLayer;

static struct wl_registry *ink_registry;
static struct zwlr_layer_shell_v1 *ink_layer_shell;
static struct wl_compositor *ink_compositor;   /* for input regions */

/* ---- registry ---------------------------------------------------------- */

static void ink_registry_global(void *data, struct wl_registry *registry, uint32_t name,
                               const char *interface, uint32_t version)
{
    (void)data;
    if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0 && !ink_layer_shell) {
        uint32_t bind_version = version < 4 ? version : 4;
        ink_layer_shell = wl_registry_bind(registry, name, &zwlr_layer_shell_v1_interface, bind_version);
    } else if (strcmp(interface, wl_compositor_interface.name) == 0 && !ink_compositor) {
        ink_compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 1);
    }
}

static void ink_registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener ink_registry_listener = {
    .global = ink_registry_global,
    .global_remove = ink_registry_global_remove,
};

int inkpane_layer_shell_init(struct wl_display *display)
{
    if (ink_layer_shell) {
        return 1;
    }
    ink_registry = wl_display_get_registry(display);
    wl_registry_add_listener(ink_registry, &ink_registry_listener, NULL);
    wl_display_roundtrip(display);
    return ink_layer_shell != NULL;
}

/* ---- layer surfaces ---------------------------------------------------- */

static void ink_layer_configure(void *data, struct zwlr_layer_surface_v1 *layer_surface,
                               uint32_t serial, uint32_t width, uint32_t height)
{
    InkLayer *layer = data;
    layer->width = width;
    layer->height = height;
    layer->configured = true;
    zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
}

static void ink_layer_closed(void *data, struct zwlr_layer_surface_v1 *layer_surface)
{
    InkLayer *layer = data;
    (void)layer_surface;
    layer->closed = true;
}

static const struct zwlr_layer_surface_v1_listener ink_layer_listener = {
    .configure = ink_layer_configure,
    .closed = ink_layer_closed,
};

/*
 * Turn an SDL custom-role surface into a full-screen overlay on `output`
 * (NULL lets the compositor choose). Blocks until the first configure so the
 * caller knows the size before SDL attaches a buffer.
 */
InkLayer *inkpane_layer_create(struct wl_display *display, struct wl_surface *surface,
                             struct wl_output *output, const char *name_space,
                             int exclusive_keyboard)
{
    if (!ink_layer_shell || !surface) {
        return NULL;
    }

    InkLayer *layer = calloc(1, sizeof(InkLayer));
    if (!layer) {
        return NULL;
    }
    layer->surface = surface;
    layer->layer_surface = zwlr_layer_shell_v1_get_layer_surface(
        ink_layer_shell, surface, output, ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, name_space);

    zwlr_layer_surface_v1_set_anchor(layer->layer_surface,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
        ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    /* -1: cover panels too instead of being pushed aside by them. */
    zwlr_layer_surface_v1_set_exclusive_zone(layer->layer_surface, -1);
    zwlr_layer_surface_v1_set_keyboard_interactivity(layer->layer_surface,
        exclusive_keyboard ? ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE
                           : ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
    zwlr_layer_surface_v1_add_listener(layer->layer_surface, &ink_layer_listener, layer);

    /* The initial commit must carry no buffer; the compositor answers with configure. */
    wl_surface_commit(surface);
    while (!layer->configured && !layer->closed) {
        if (wl_display_roundtrip(display) < 0) {
            break;
        }
    }
    return layer;
}

/*
 * Click-through: input outside the given rectangle (surface coordinates; zero size for
 * none) and all keyboard input go to the windows below, while the overlay stays visible.
 * Off restores the whole surface as input region and exclusive keyboard focus.
 */
void inkpane_layer_set_passthrough(InkLayer *layer, int passthrough,
                                    int32_t x, int32_t y, int32_t width, int32_t height)
{
    if (!layer || !layer->layer_surface) {
        return;
    }
    if (passthrough && ink_compositor) {
        struct wl_region *region = wl_compositor_create_region(ink_compositor);
        if (width > 0 && height > 0) {
            wl_region_add(region, x, y, width, height);
        }
        wl_surface_set_input_region(layer->surface, region);
        wl_region_destroy(region);
    } else {
        wl_surface_set_input_region(layer->surface, NULL);   /* NULL: the whole surface */
    }
    zwlr_layer_surface_v1_set_keyboard_interactivity(layer->layer_surface,
        passthrough ? ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE
                    : ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE);
    wl_surface_commit(layer->surface);
}

void inkpane_layer_destroy(InkLayer *layer)
{
    if (!layer) {
        return;
    }
    if (layer->layer_surface) {
        zwlr_layer_surface_v1_destroy(layer->layer_surface);
    }
    free(layer);
}
