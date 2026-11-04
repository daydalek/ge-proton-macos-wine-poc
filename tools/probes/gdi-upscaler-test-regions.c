/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "wine_gdi_frame_diff.h"
#include "wine_gdi_upscaler.h"
#include <string.h>

static unsigned regionsCalls;
static uint32_t lastSelection[256];
static size_t lastCount;

int wgdi_upscaler_process_regions(void *context, const struct wgdi_image *input,
    struct wgdi_image *output, const uint32_t *selection, size_t selection_count,
    char *error, size_t size)
{
    (void)context;
    (void)error;
    (void)size;
    if (!wgdi_frame_bounds_valid(input) || !wgdi_frame_bounds_valid(output) ||
        output->width != input->width * 2 || output->height != input->height * 2 ||
        !selection)
        return -1;
    const size_t cols = ((size_t)input->width + 255) / 256;
    const size_t rows = ((size_t)input->height + 255) / 256;
    if (selection_count != cols * rows || selection_count > 256) return -1;
    unsigned chosen = 0;
    for (size_t i = 0; i < selection_count; ++i)
    {
        if (selection[i] > 1) return -1;
        chosen += selection[i];
    }
    if (!chosen) return -1;
    ++regionsCalls;
    lastCount = selection_count;
    memcpy(lastSelection, selection, selection_count * sizeof(uint32_t));
    for (size_t ty = 0; ty < rows; ++ty)
        for (size_t tx = 0; tx < cols; ++tx)
        {
            if (!selection[ty * cols + tx]) continue;
            const size_t x1 = tx * 512 + 512 < output->width ? tx * 512 + 512 : output->width;
            const size_t y1 = ty * 512 + 512 < output->height ? ty * 512 + 512 : output->height;
            for (size_t y = ty * 512; y < y1; ++y)
                for (size_t x = tx * 512; x < x1; ++x)
                {
                    const uint8_t *source = input->pixels + (size_t)(y * input->height / output->height) *
                        input->stride + (x * input->width / output->width) * 4;
                    uint8_t *pixel = output->pixels + y * output->stride + x * 4;
                    for (unsigned c = 0; c < 3; ++c)
                        pixel[c] = source[c] > 223 ? 255 : source[c] + 32;
                    pixel[3] = 255;
                }
        }
    return 0;
}

unsigned wgdi_mock_regions_count(void) { return regionsCalls; }
unsigned wgdi_mock_regions_tile_count(void) { return (unsigned)lastCount; }
unsigned wgdi_mock_regions_selected_total(void)
{
    unsigned total = 0;
    for (size_t i = 0; i < lastCount; ++i) total += lastSelection[i];
    return total;
}
unsigned wgdi_mock_regions_selected_first(void)
{
    return lastCount && lastSelection[0] ? 1 : 0;
}
