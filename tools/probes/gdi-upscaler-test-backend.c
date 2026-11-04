/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "wine_gdi_frame_diff.h"
#include <stdlib.h>

static unsigned processCalls;

static void *create_context(const struct wgdi_options *options, char *error, size_t size)
{
    (void)options;
    (void)error;
    (void)size;
    return malloc(1);
}

static int process_frame(void *context, const struct wgdi_image *input,
    struct wgdi_image *output, char *error, size_t size)
{
    (void)context;
    (void)error;
    (void)size;
    ++processCalls;
    if (!wgdi_frame_bounds_valid(input) || !wgdi_frame_bounds_valid(output) ||
        output->width > input->width * 2 || output->height > input->height * 2) return -1;
    for (unsigned y = 0; y < output->height; ++y)
        for (unsigned x = 0; x < output->width; ++x)
        {
            const uint8_t *source = input->pixels + (size_t)(y * input->height / output->height) *
                input->stride + (x * input->width / output->width) * 4;
            uint8_t *pixel = output->pixels + (size_t)y * output->stride + x * 4;
            for (unsigned c = 0; c < 3; ++c)
                pixel[c] = source[c] > 223 ? 255 : source[c] + 32;
            pixel[3] = 255;
        }
    return 0;
}

const struct wgdi_upscaler_api *wgdi_upscaler_get_api(uint32_t version)
{
    static const struct wgdi_upscaler_api api = {
        WGDI_UPSCALER_ABI, sizeof(api), create_context, process_frame, free};
    return version == WGDI_UPSCALER_ABI ? &api : NULL;
}

unsigned wgdi_mock_process_count(void) { return processCalls; }
