/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "backend.h"
#include "wine_gdi_frame_diff.h"
#include <algorithm>
#include <cstdio>
#include <exception>
#include <stdexcept>

static void error_text(char *out, size_t size, const char *message)
{
    if (out && size) std::snprintf(out, size, "%s", message);
}

static void *create(const wgdi_options *options, char *error, size_t size)
{
    try
    {
        if (!options || options->size != sizeof(*options) || !options->resource_directory ||
            options->resource_directory[0] != '/')
            throw std::invalid_argument("invalid upscaler options or resource directory");
        if (options->algorithm == WGDI_ANIME4K)
            return create_anime4k(options->resource_directory).release();
        if (options->algorithm == WGDI_REALCUGAN)
            return create_realcugan(options->resource_directory,
                                    std::clamp(options->cpu_threads, 1u, 4u)).release();
        throw std::invalid_argument("unknown upscaler algorithm");
    }
    catch (const std::exception &exception) { error_text(error, size, exception.what()); }
    catch (...) { error_text(error, size, "upscaler initialization failed"); }
    return nullptr;
}

static int process(void *context, const wgdi_image *input, wgdi_image *output, char *error, size_t size)
{
    try
    {
        if (!context || !wgdi_frame_bounds_valid(input) || !wgdi_frame_bounds_valid(output) ||
            input->width > 4096 || input->height > 4096 ||
            input->width * input->height > 2u * 1024 * 1024 ||
            output->width <= input->width || output->height <= input->height ||
            output->width > input->width * 2 || output->height > input->height * 2)
            throw std::invalid_argument("invalid BGRA frame, buffer bounds, or upscale dimensions");
        auto pixels = static_cast<UpscaleBackend *>(context)->upscale2x(*input);
        if (pixels.size() != size_t(input->width) * input->height * 16)
            throw std::runtime_error("upscaler returned an invalid output buffer");
        resize_bgra(pixels, input->width * 2, input->height * 2, *output);
        return 0;
    }
    catch (const std::exception &exception) { error_text(error, size, exception.what()); }
    catch (...) { error_text(error, size, "upscaler inference failed"); }
    return -1;
}

static void destroy(void *context)
{
    try { delete static_cast<UpscaleBackend *>(context); }
    catch (...) {}
}

extern "C" __attribute__((visibility("default")))
const wgdi_upscaler_api *wgdi_upscaler_get_api(uint32_t version)
{
    static const wgdi_upscaler_api api = {WGDI_UPSCALER_ABI, sizeof(wgdi_upscaler_api), create, process, destroy};
    return version == WGDI_UPSCALER_ABI ? &api : nullptr;
}
