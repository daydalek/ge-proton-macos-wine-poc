/* SPDX-License-Identifier: LGPL-2.1-or-later */
#pragma once
#include "wine_gdi_upscaler.h"
#include <memory>
#include <string>
#include <vector>

class UpscaleBackend
{
public:
    virtual ~UpscaleBackend() = default;
    virtual std::vector<uint8_t> upscale2x(const wgdi_image &input) = 0;
    virtual bool upscale_regions(const wgdi_image &, wgdi_image &,
                                 const uint32_t *, size_t) { return false; }
};

enum class NeuralModel { RealCUGAN, AnimeVideoV3 };

/* WINE_GDI_NEURAL_MODEL selects the neural network behind the WGDI_REALCUGAN
 * algorithm: "animevideov3" for Real-ESRGAN AnimeVideo-v3, unset/"realcugan"
 * for Real-CUGAN. Unknown values keep Real-CUGAN and report once to stderr. */
NeuralModel selected_neural_model();

std::unique_ptr<UpscaleBackend> create_anime4k(const std::string &resources);
std::unique_ptr<UpscaleBackend> create_realcugan(const std::string &resources, unsigned threads, NeuralModel model);
std::unique_ptr<UpscaleBackend> create_realcugan_cpu(const std::string &resources, unsigned threads);
std::unique_ptr<UpscaleBackend> create_realesrgan_cpu(const std::string &resources, unsigned threads);
void resize_bgra(const std::vector<uint8_t> &pixels, unsigned width, unsigned height, wgdi_image &output);
