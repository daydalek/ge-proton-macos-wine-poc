/*
 * SPDX-License-Identifier: LGPL-2.1-or-later
 * Real-ESRGAN AnimeVideo-v3 x2 inference using the official ncnn graph.
 * Preprocessing mirrors the Real-CUGAN path — RGB / 255 with reflect101
 * padding of 19 — without its even-dimension padding or SE pooling, since
 * SRVGGNetCompact is fully convolutional. The 4x sub-pixel output plus the
 * bicubic x0.5 tail yields a 2x image cropped back to the content region.
 */
#include "backend.h"
#include "net.h"
#include <algorithm>
#include <cmath>
#include <stdexcept>

static int reflected(int coordinate, int length)
{
    if (length == 1) return 0;
    int period = 2 * length - 2;
    coordinate %= period;
    if (coordinate < 0) coordinate += period;
    return coordinate < length ? coordinate : period - coordinate;
}

class RealESRGANBackend final : public UpscaleBackend
{
    ncnn::Net network;

public:
    RealESRGANBackend(const std::string &resources, unsigned threads)
    {
        network.opt.num_threads = threads;
        network.opt.use_vulkan_compute = false;
        network.opt.use_fp16_packed = false;
        network.opt.use_fp16_storage = false;
        network.opt.use_fp16_arithmetic = false;
        network.opt.lightmode = true;
        const std::string base = resources + "/models-animevideov3/realesr-animevideov3-x2";
        if (network.load_param((base + ".param").c_str()) || network.load_model((base + ".bin").c_str()))
            throw std::runtime_error("Real-ESRGAN models-animevideov3/realesr-animevideov3-x2 model load failed");
    }

    std::vector<uint8_t> upscale2x(const wgdi_image &image) override
    {
        const int width = image.width, height = image.height;
        const int pw = width + 38, ph = height + 38;
        ncnn::Mat input(pw, ph, 3);
        if (input.empty()) throw std::runtime_error("Real-ESRGAN input allocation failed");
        for (int channel = 0; channel < 3; ++channel)
        {
            float *plane = input.channel(channel);
            for (int y = 0; y < ph; ++y)
            {
                const uint8_t *row = image.pixels + size_t(reflected(y - 19, height)) * image.stride;
                for (int x = 0; x < pw; ++x)
                    plane[y * pw + x] = row[reflected(x - 19, width) * 4 + (2 - channel)] / 255.f;
            }
        }
        auto extractor = network.create_extractor();
        ncnn::Mat result;
        if (extractor.input("data", input) || extractor.extract("output", result) || result.empty() ||
            result.c != 3 || result.elempack != 1 || result.elemsize != sizeof(float) ||
            result.w != pw * 2 || result.h != ph * 2)
            throw std::runtime_error("Real-ESRGAN inference or output shape failed");
        std::vector<uint8_t> output(size_t(width) * height * 16);
        for (int y = 0; y < height * 2; ++y)
            for (int x = 0; x < width * 2; ++x)
            {
                uint8_t *pixel = output.data() + (size_t(y) * width * 2 + x) * 4;
                for (int channel = 0; channel < 3; ++channel)
                {
                    const float *plane = result.channel(channel);
                    float value = plane[(y + 38) * result.w + x + 38];
                    if (!std::isfinite(value)) throw std::runtime_error("Real-ESRGAN returned nonfinite pixels");
                    pixel[2 - channel] = uint8_t(std::lround(std::clamp(value, 0.f, 1.f) * 255.f));
                }
                pixel[3] = 255;
            }
        return output;
    }
};

std::unique_ptr<UpscaleBackend> create_realesrgan_cpu(const std::string &resources, unsigned threads)
{
    return std::make_unique<RealESRGANBackend>(resources, threads);
}
