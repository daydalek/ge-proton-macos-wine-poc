/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "wine_gdi_frame_diff.h"
#include "wine_gdi_upscale_policy.h"
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    enum { width = 37, height = 29, stride = width * 4 + 11 };
    uint8_t previous[stride * height], current[stride * height];
    memset(previous, 0x40, sizeof(previous));
    memcpy(current, previous, sizeof(current));
    struct wgdi_image first = {previous, sizeof(previous), stride, width, height};
    struct wgdi_image second = {current, sizeof(current), stride, width, height};
    assert(wgdi_frames_equal(&first, &second));
    /* Every active byte matters, including a one-pixel text/cursor change. */
    for (size_t y = 0; y < height; ++y)
        for (size_t x = 0; x < width * 4; ++x)
        {
            current[y * stride + x] ^= 1;
            assert(!wgdi_frames_equal(&first, &second));
            current[y * stride + x] ^= 1;
        }
    for (size_t y = 0; y < height; ++y)
        memset(current + y * stride + width * 4, 0xa5, stride - width * 4);
    assert(wgdi_frames_equal(&first, &second));
    second.width--;
    assert(!wgdi_frames_equal(&first, &second));
    second = first; second.height--;
    assert(!wgdi_frames_equal(&first, &second));
    second = first; second.buffer_bytes--;
    /* Last-row trailing padding is outside the active image. */
    assert(wgdi_frames_equal(&first, &second));
    second.buffer_bytes = 1;
    assert(!wgdi_frames_equal(&first, &second));
    second = first; second.stride = SIZE_MAX;
    assert(!wgdi_frames_equal(&first, &second));
    assert(!wgdi_frames_equal(NULL, &first));
    struct wgdi_stability state = {0};
    assert(wgdi_stability_observe(&state, 1, 10.0) == WGDI_STABLE_SECONDS);
    assert(wgdi_stability_observe(&state, 0, 10.1) > 0);
    assert(wgdi_stability_observe(&state, 1, 10.2) == WGDI_STABLE_SECONDS);
    assert(wgdi_stability_observe(&state, 0, 10.3) > 0);
    assert(wgdi_stability_observe(&state, 0, 10.451) == 0);
    assert(wgdi_stability_observe(&state, 1, 10.5) == WGDI_STABLE_SECONDS);
    assert(wgdi_stability_observe(&state, 0, 1.0) == WGDI_STABLE_SECONDS);
    return 0;
}
