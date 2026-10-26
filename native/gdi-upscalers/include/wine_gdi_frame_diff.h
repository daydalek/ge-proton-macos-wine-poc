/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef WINE_GDI_FRAME_DIFF_H
#define WINE_GDI_FRAME_DIFF_H
#include "wine_gdi_upscaler.h"
#include <string.h>

/* Exact active-pixel frame comparison. Row padding has no visual meaning.
 * Geometry is part of identity; one changed byte invalidates the frame cache,
 * including isolated text/cursor changes that sampled hashes can overlook. */
static inline int wgdi_frame_bounds_valid(const struct wgdi_image *image)
{
    size_t row;
    if (!image || !image->pixels || !image->width || !image->height ||
        image->width > 8192 || image->height > 8192 ||
        image->width * image->height > 32u * 1024 * 1024) return 0;
    row = (size_t)image->width * 4;
    if (image->stride < row || image->buffer_bytes < row) return 0;
    return image->height - 1 <= (image->buffer_bytes - row) / image->stride;
}

static inline int wgdi_frames_equal(const struct wgdi_image *previous, const struct wgdi_image *current)
{
    size_t row, y;
    if (!wgdi_frame_bounds_valid(previous) || !wgdi_frame_bounds_valid(current) ||
        previous->width != current->width || previous->height != current->height) return 0;
    row = (size_t)previous->width * 4;
    if (previous->stride == row && current->stride == row)
        return !memcmp(previous->pixels, current->pixels, row * previous->height);
    for (y = 0; y < previous->height; ++y)
        if (memcmp(previous->pixels + y * previous->stride, current->pixels + y * current->stride, row)) return 0;
    return 1;
}
#endif
