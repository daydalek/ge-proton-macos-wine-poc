/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "wine_gdi_upscaler.h"
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

int main(int argc, const char **argv)
{
    assert(argc == 2);
    const auto *api = wgdi_upscaler_get_api(WGDI_UPSCALER_ABI);
    assert(api && api->size == sizeof(*api) && api->abi_version == WGDI_UPSCALER_ABI);
    assert(!wgdi_upscaler_get_api(WGDI_UPSCALER_ABI + 1));
    char error[512] = {};
    assert(!api->create(nullptr, error, sizeof(error)) && error[0]);
    wgdi_options options = {sizeof(options), WGDI_REALCUGAN, "/missing-real-cugan-model", 1};
    assert(!api->create(&options, error, sizeof(error)));
    options.algorithm = 0;
    assert(!api->create(&options, error, sizeof(error)));
    options.algorithm = WGDI_REALCUGAN;
    options.resource_directory = argv[1];
    void *context = api->create(&options, error, sizeof(error));
    if (!context) { std::fprintf(stderr, "%s\n", error); return 1; }
    for (unsigned pass = 0; pass < 2; ++pass)
    {
        /* Odd shapes and padded input/output rows exercise cropping and strides.
         * Distinct channel values catch channel swaps. Flat fields have a
         * stable expected result without relying on a particular SIMD kernel. */
        const unsigned w = pass ? 23 : 24, h = pass ? 25 : 24;
        const size_t stride = w * 4 + 12, out_stride = w * 8 + 16;
        std::vector<uint8_t> input(stride * h, 0xa5), output(out_stride * h * 2, 0xa5);
        for (unsigned y = 0; y < h; ++y)
            for (unsigned x = 0; x < w; ++x)
            {
                auto *pixel = input.data() + y * stride + x * 4;
                pixel[0] = 50; pixel[1] = 110; pixel[2] = 180; pixel[3] = 255;
            }
        const auto original = input;
        wgdi_image source = {input.data(), input.size(), stride, w, h};
        wgdi_image result = {output.data(), output.size(), out_stride, w * 2, h * 2};
        assert(api->process(nullptr, &source, &result, error, sizeof(error)) == -1);
        auto invalid = result; invalid.buffer_bytes = 1;
        assert(api->process(context, &source, &invalid, error, sizeof(error)) == -1);
        invalid = result; invalid.stride = SIZE_MAX;
        assert(api->process(context, &source, &invalid, error, sizeof(error)) == -1);
        invalid = result; invalid.width = UINT32_MAX;
        assert(api->process(context, &source, &invalid, error, sizeof(error)) == -1);
        if (api->process(context, &source, &result, error, sizeof(error)))
        { std::fprintf(stderr, "%s\n", error); return 1; }
        assert(input == original);
        for (unsigned y = 0; y < h * 2; ++y)
        {
            for (unsigned x = 0; x < w * 2; ++x)
            {
                const auto *pixel = output.data() + y * out_stride + x * 4;
                assert(std::abs(int(pixel[0]) - 50) < 25);
                assert(std::abs(int(pixel[1]) - 110) < 25);
                assert(std::abs(int(pixel[2]) - 180) < 25);
                assert(pixel[3] == 255);
            }
            for (size_t x = w * 8; x < out_stride; ++x) assert(output[y * out_stride + x] == 0xa5);
        }
        result.width -= 1; result.height -= 1;
        assert(api->process(context, &source, &result, error, sizeof(error)) == 0);
    }
    api->destroy(context);
    api->destroy(nullptr);
    std::puts("PASS: ABI, errors, buffer bounds, real Real-CUGAN model inference, RGB/BGRA, odd shapes and resampling");
}
