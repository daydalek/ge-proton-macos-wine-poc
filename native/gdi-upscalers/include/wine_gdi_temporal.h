/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef WINE_GDI_TEMPORAL_H
#define WINE_GDI_TEMPORAL_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define WGDI_TEMPORAL_BLOCK 16u
#define WGDI_TEMPORAL_TILE 256u
#define WGDI_TEMPORAL_HALO 18u
#define WGDI_TEMPORAL_FEATHER 8u
#define WGDI_TEMPORAL_QUIET_SECONDS 0.200
#define WGDI_TEMPORAL_FADE_SECONDS 0.100
#define WGDI_TEMPORAL_REFERENCE_DIRTY 1u
#define WGDI_TEMPORAL_FRAME_CHANGED 2u
#define WGDI_TEMPORAL_INPUT_DELTA 4u

/* Shared with temporal.metal. Source coordinates have their origin at top left. */
struct wgdi_temporal_parameters {
    uint32_t width, height, block_columns, block_rows;
    uint32_t tile_columns, tile_rows, previous_valid, reserved;
    float time, fade_seconds, halo, feather;
};
struct wgdi_temporal_tile {
    double changed_at;
    uint64_t version;
    uint32_t dirty;
};
struct wgdi_temporal_scheduler {
    unsigned width, height, columns, rows;
    uint64_t epoch, observed_sequence;
    struct wgdi_temporal_tile *tiles;
};

static inline void wgdi_temporal_clear(struct wgdi_temporal_scheduler *state)
{
    uint64_t epoch = state->epoch + 1;
    free(state->tiles);
    memset(state, 0, sizeof(*state));
    state->epoch = epoch;
}

static inline int wgdi_temporal_configure(struct wgdi_temporal_scheduler *state,
                                          unsigned width, unsigned height, double now)
{
    unsigned i;
    if (!width || !height || width > 4096 || height > 4096 ||
        (uint64_t)width * height > 2u * 1024u * 1024u) return 0;
    if (state->tiles && state->width == width && state->height == height) return 1;
    wgdi_temporal_clear(state);
    state->width = width; state->height = height;
    state->columns = (width + WGDI_TEMPORAL_TILE - 1) / WGDI_TEMPORAL_TILE;
    state->rows = (height + WGDI_TEMPORAL_TILE - 1) / WGDI_TEMPORAL_TILE;
    state->tiles = (struct wgdi_temporal_tile *)calloc(
        (size_t)state->columns * state->rows, sizeof(*state->tiles));
    if (!state->tiles) { wgdi_temporal_clear(state); return 0; }
    for (i = 0; i < state->columns * state->rows; ++i) {
        state->tiles[i].changed_at = now;
        state->tiles[i].version = 1;
        state->tiles[i].dirty = 1;
    }
    return 1;
}

/* Metadata represents a particular immutable GPU source snapshot. Motion in a
 * tile's context restarts only that tile's quiet interval. Reference differences
 * alone keep work dirty without resetting the quiet clock on idle redraws. */
static inline void wgdi_temporal_observe(struct wgdi_temporal_scheduler *state,
    const uint32_t *blocks, uint64_t epoch, uint64_t sequence, double now)
{
    unsigned tx, ty;
    unsigned bc = (state->width + WGDI_TEMPORAL_BLOCK - 1) / WGDI_TEMPORAL_BLOCK;
    unsigned br = (state->height + WGDI_TEMPORAL_BLOCK - 1) / WGDI_TEMPORAL_BLOCK;
    if (!state->tiles || !blocks || epoch != state->epoch || sequence <= state->observed_sequence) return;
    state->observed_sequence = sequence;
    for (ty = 0; ty < state->rows; ++ty) for (tx = 0; tx < state->columns; ++tx) {
        unsigned x = tx * WGDI_TEMPORAL_TILE, y = ty * WGDI_TEMPORAL_TILE;
        unsigned left = x > WGDI_TEMPORAL_HALO ? x - WGDI_TEMPORAL_HALO : 0;
        unsigned top = y > WGDI_TEMPORAL_HALO ? y - WGDI_TEMPORAL_HALO : 0;
        unsigned right = x + WGDI_TEMPORAL_TILE + WGDI_TEMPORAL_HALO;
        unsigned bottom = y + WGDI_TEMPORAL_TILE + WGDI_TEMPORAL_HALO;
        unsigned bx, by, flags = 0;
        unsigned core_right = x + WGDI_TEMPORAL_TILE < state->width ? x + WGDI_TEMPORAL_TILE : state->width;
        unsigned core_bottom = y + WGDI_TEMPORAL_TILE < state->height ? y + WGDI_TEMPORAL_TILE : state->height;
        right = right < state->width ? right : state->width;
        bottom = bottom < state->height ? bottom : state->height;
        for (by = top / WGDI_TEMPORAL_BLOCK;
             by < (bottom + WGDI_TEMPORAL_BLOCK - 1) / WGDI_TEMPORAL_BLOCK && by < br; ++by)
            for (bx = left / WGDI_TEMPORAL_BLOCK;
                 bx < (right + WGDI_TEMPORAL_BLOCK - 1) / WGDI_TEMPORAL_BLOCK && bx < bc; ++bx)
            {
                unsigned bits = blocks[by * bc + bx];
                flags |= bits & (WGDI_TEMPORAL_FRAME_CHANGED | WGDI_TEMPORAL_INPUT_DELTA);
                if (bx >= x / WGDI_TEMPORAL_BLOCK && by >= y / WGDI_TEMPORAL_BLOCK &&
                    bx < (core_right + WGDI_TEMPORAL_BLOCK - 1) / WGDI_TEMPORAL_BLOCK &&
                    by < (core_bottom + WGDI_TEMPORAL_BLOCK - 1) / WGDI_TEMPORAL_BLOCK)
                    flags |= bits & WGDI_TEMPORAL_REFERENCE_DIRTY;
            }
        struct wgdi_temporal_tile *tile = &state->tiles[ty * state->columns + tx];
        tile->dirty = !!(flags & (WGDI_TEMPORAL_REFERENCE_DIRTY | WGDI_TEMPORAL_INPUT_DELTA));
        if ((flags & WGDI_TEMPORAL_FRAME_CHANGED) || now < tile->changed_at) {
            tile->changed_at = now;
            ++tile->version;
        }
    }
}

/* A version snapshot accompanies every selected tile. The caller keeps one
 * inference job active; fresh GPU admission also checks actual context pixels. */
static inline unsigned wgdi_temporal_select(const struct wgdi_temporal_scheduler *state,
    double now, uint32_t *selected, uint64_t *versions, double *next_delay)
{
    unsigned i, count = 0;
    double next = WGDI_TEMPORAL_QUIET_SECONDS;
    for (i = 0; i < state->columns * state->rows; ++i) {
        const struct wgdi_temporal_tile *tile = &state->tiles[i];
        double remaining = WGDI_TEMPORAL_QUIET_SECONDS - (now - tile->changed_at);
        selected[i] = tile->dirty && remaining <= 0;
        versions[i] = tile->version;
        count += selected[i];
        if (tile->dirty && remaining > 0 && remaining < next) next = remaining;
    }
    if (next_delay) *next_delay = next;
    return count;
}

static inline unsigned wgdi_temporal_revalidate(const struct wgdi_temporal_scheduler *state,
    uint64_t epoch, uint32_t *selected, const uint64_t *versions)
{
    unsigned i, count = 0;
    for (i = 0; i < state->columns * state->rows; ++i) {
        selected[i] = epoch == state->epoch && selected[i] && versions[i] == state->tiles[i].version;
        count += selected[i];
    }
    return count;
}
#endif
