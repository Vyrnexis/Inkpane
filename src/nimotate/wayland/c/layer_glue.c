/*
 * Thin C glue between SDL3 custom-role surfaces and wlr-layer-shell.
 *
 * libwayland's request helpers are static inline functions in the generated
 * headers, so the protocol calls live here and Nim only sees a tiny API.
 * All objects use the default event queue, which SDL already dispatches.
 */

#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "../generated/wlr-layer-shell-unstable-v1-client-protocol.h"

typedef struct NiLayer {
    struct zwlr_layer_surface_v1 *layer_surface;
    struct wl_surface *surface;
    int configured;
    int closed;
    unsigned int width;
    unsigned int height;
} NiLayer;

static struct wl_registry *ni_registry;
static struct zwlr_layer_shell_v1 *ni_layer_shell;

/* ---- registry ---------------------------------------------------------- */

static void ni_registry_global(void *data, struct wl_registry *registry, uint32_t name,
                               const char *interface, uint32_t version)
{
    (void)data;
    if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0 && !ni_layer_shell) {
        uint32_t bind_version = version < 4 ? version : 4;
        ni_layer_shell = wl_registry_bind(registry, name, &zwlr_layer_shell_v1_interface, bind_version);
    }
}

static void ni_registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener ni_registry_listener = {
    .global = ni_registry_global,
    .global_remove = ni_registry_global_remove,
};

int nimotate_layer_shell_init(struct wl_display *display)
{
    if (ni_layer_shell) {
        return 1;
    }
    ni_registry = wl_display_get_registry(display);
    wl_registry_add_listener(ni_registry, &ni_registry_listener, NULL);
    wl_display_roundtrip(display);
    return ni_layer_shell != NULL;
}

/* ---- layer surfaces ---------------------------------------------------- */

static void ni_layer_configure(void *data, struct zwlr_layer_surface_v1 *layer_surface,
                               uint32_t serial, uint32_t width, uint32_t height)
{
    NiLayer *layer = data;
    layer->width = width;
    layer->height = height;
    layer->configured = 1;
    zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
}

static void ni_layer_closed(void *data, struct zwlr_layer_surface_v1 *layer_surface)
{
    NiLayer *layer = data;
    (void)layer_surface;
    layer->closed = 1;
}

static const struct zwlr_layer_surface_v1_listener ni_layer_listener = {
    .configure = ni_layer_configure,
    .closed = ni_layer_closed,
};

/*
 * Turn an SDL custom-role surface into a full-screen overlay on `output`
 * (NULL lets the compositor choose). Blocks until the first configure so the
 * caller knows the size before SDL attaches a buffer.
 */
NiLayer *nimotate_layer_create(struct wl_display *display, struct wl_surface *surface,
                             struct wl_output *output, const char *name_space,
                             int exclusive_keyboard)
{
    if (!ni_layer_shell || !surface) {
        return NULL;
    }

    NiLayer *layer = calloc(1, sizeof(NiLayer));
    if (!layer) {
        return NULL;
    }
    layer->surface = surface;
    layer->layer_surface = zwlr_layer_shell_v1_get_layer_surface(
        ni_layer_shell, surface, output, ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, name_space);

    zwlr_layer_surface_v1_set_anchor(layer->layer_surface,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
        ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    /* -1: cover panels too instead of being pushed aside by them. */
    zwlr_layer_surface_v1_set_exclusive_zone(layer->layer_surface, -1);
    zwlr_layer_surface_v1_set_keyboard_interactivity(layer->layer_surface,
        exclusive_keyboard ? ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE
                           : ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
    zwlr_layer_surface_v1_add_listener(layer->layer_surface, &ni_layer_listener, layer);

    /* The initial commit must carry no buffer; the compositor answers with configure. */
    wl_surface_commit(surface);
    while (!layer->configured && !layer->closed) {
        if (wl_display_roundtrip(display) < 0) {
            break;
        }
    }
    return layer;
}

int nimotate_layer_configured(NiLayer *layer) { return layer && layer->configured; }
int nimotate_layer_closed(NiLayer *layer) { return !layer || layer->closed; }
unsigned int nimotate_layer_width(NiLayer *layer) { return layer ? layer->width : 0; }
unsigned int nimotate_layer_height(NiLayer *layer) { return layer ? layer->height : 0; }

void nimotate_layer_destroy(NiLayer *layer)
{
    if (!layer) {
        return;
    }
    if (layer->layer_surface) {
        zwlr_layer_surface_v1_destroy(layer->layer_surface);
    }
    free(layer);
}
