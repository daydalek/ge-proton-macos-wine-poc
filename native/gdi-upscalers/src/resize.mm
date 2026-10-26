/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "backend.h"
#import <Accelerate/Accelerate.h>
#include <cstring>
#include <stdexcept>

void resize_bgra(const std::vector<uint8_t> &pixels, unsigned width, unsigned height, wgdi_image &output)
{
    if (width == output.width && height == output.height)
    {
        for (unsigned y = 0; y < height; ++y)
            std::memcpy(output.pixels + y * output.stride, pixels.data() + size_t(y) * width * 4, width * 4);
        return;
    }
    vImage_Buffer source = {const_cast<uint8_t *>(pixels.data()), height, width, size_t(width) * 4};
    vImage_Buffer destination = {output.pixels, output.height, output.width, output.stride};
    if (vImageScale_ARGB8888(&source, &destination, nullptr, kvImageHighQualityResampling) != kvImageNoError)
        throw std::runtime_error("output resampling failed");
}
