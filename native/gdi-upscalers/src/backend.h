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
};

std::unique_ptr<UpscaleBackend> create_anime4k(const std::string &resources);
std::unique_ptr<UpscaleBackend> create_realcugan(const std::string &resources, unsigned threads);
std::unique_ptr<UpscaleBackend> create_realcugan_cpu(const std::string &resources, unsigned threads);
void resize_bgra(const std::vector<uint8_t> &pixels, unsigned width, unsigned height, wgdi_image &output);
