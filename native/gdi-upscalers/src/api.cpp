/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "backend.h"
#include "wine_gdi_frame_diff.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <stdexcept>

NeuralModel selected_neural_model()
{
    const char *value = std::getenv("WINE_GDI_NEURAL_MODEL");
    if (!value || !std::strcmp(value, "realcugan")) return NeuralModel::RealCUGAN;
    if (!std::strcmp(value, "animevideov3")) return NeuralModel::AnimeVideoV3;
    std::fprintf(stderr, "winegdi: unknown WINE_GDI_NEURAL_MODEL=%.32s, using realcugan\n", value);
    return NeuralModel::RealCUGAN;
}

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
                                    std::clamp(options->cpu_threads, 1u, 4u),
                                    selected_neural_model()).release();
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
int wgdi_upscaler_process_regions(void *context, const wgdi_image *input, wgdi_image *output,
                                  const uint32_t *selection, size_t selection_count,
                                  char *error, size_t error_size)
{
    try
    {
        const size_t columns = (size_t(input ? input->width : 0) + 255) / 256;
        const size_t rows = (size_t(input ? input->height : 0) + 255) / 256;
        if (!context || !wgdi_frame_bounds_valid(input) || !wgdi_frame_bounds_valid(output) ||
            input->width > 4096 || input->height > 4096 ||
            input->width * input->height > 2u * 1024 * 1024 ||
            output->width != input->width * 2 || output->height != input->height * 2 ||
            !selection || selection_count != columns * rows)
            throw std::invalid_argument("invalid BGRA frame, buffer bounds, upscale dimensions, or selection size");
        unsigned chosen = 0;
        for (size_t i = 0; i < selection_count; ++i)
        {
            if (selection[i] > 1) throw std::invalid_argument("invalid tile selection value");
            chosen += selection[i];
        }
        if (!chosen) throw std::invalid_argument("empty tile selection");
        UpscaleBackend *backend = static_cast<UpscaleBackend *>(context);
        if (backend->upscale_regions(*input, *output, selection, selection_count)) return 0;
        auto pixels = backend->upscale2x(*input);
        if (pixels.size() != size_t(input->width) * input->height * 16)
            throw std::runtime_error("upscaler returned an invalid output buffer");
        for (size_t ty = 0; ty < rows; ++ty)
            for (size_t tx = 0; tx < columns; ++tx)
            {
                if (!selection[ty * columns + tx]) continue;
                const size_t x0 = tx * 512, x1 = std::min(tx * 512 + 512, size_t(output->width));
                const size_t y1 = std::min(ty * 512 + 512, size_t(output->height));
                for (size_t y = ty * 512; y < y1; ++y)
                    memcpy(output->pixels + y * output->stride + x0 * 4,
                           pixels.data() + (y * output->width + x0) * 4, (x1 - x0) * 4);
            }
        return 0;
    }
    catch (const std::exception &exception) { error_text(error, error_size, exception.what()); }
    catch (...) { error_text(error, error_size, "upscaler inference failed"); }
    return -1;
}

extern "C" __attribute__((visibility("default")))
const wgdi_upscaler_api *wgdi_upscaler_get_api(uint32_t version)
{
    static const wgdi_upscaler_api api = {WGDI_UPSCALER_ABI, sizeof(wgdi_upscaler_api), create, process, destroy};
    return version == WGDI_UPSCALER_ABI ? &api : nullptr;
}
