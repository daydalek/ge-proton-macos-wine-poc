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
    assert(argc >= 2);
    const auto *api = wgdi_upscaler_get_api(WGDI_UPSCALER_ABI);
    assert(api && api->size == sizeof(*api) && api->abi_version == WGDI_UPSCALER_ABI);
    assert(!wgdi_upscaler_get_api(WGDI_UPSCALER_ABI + 1));
    char error[512] = {};
    assert(!api->create(nullptr, error, sizeof(error)) && error[0]);
    wgdi_options options = {sizeof(options), WGDI_REALCUGAN, "/missing-real-cugan-model", 1};
    {
        void *lazy = api->create(&options, error, sizeof(error));
        assert(lazy);
        uint8_t px[16] = {}, po[64] = {};
        wgdi_image fin{px, 16, 8, 2, 2}, fout{po, 64, 16, 4, 4};
        assert(api->process(lazy, &fin, &fout, error, sizeof(error)) == -1 && error[0]);
        api->destroy(lazy);
        setenv("WINE_GDI_REALCUGAN_BACKEND", "cpu", 1);
        assert(!api->create(&options, error, sizeof(error)));
        unsetenv("WINE_GDI_REALCUGAN_BACKEND");
    }
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

    /* Real-ESRGAN AnimeVideo-v3 shares the WGDI_REALCUGAN algorithm, selected
     * through WINE_GDI_NEURAL_MODEL. CPU mode keeps the test window-free. */
    setenv("WINE_GDI_REALCUGAN_BACKEND", "cpu", 1);
    setenv("WINE_GDI_NEURAL_MODEL", "animevideov3", 1);
    options.resource_directory = "/missing-animevideov3-model";
    assert(!api->create(&options, error, sizeof(error)));
    options.resource_directory = argv[1];
    context = api->create(&options, error, sizeof(error));
    if (!context) { std::fprintf(stderr, "%s\n", error); return 1; }
    {
        const unsigned w = 65, h = 49;
        const size_t stride = w * 4, out_stride = w * 8;
        std::vector<uint8_t> input(stride * h), output(out_stride * h * 2);
        for (unsigned y = 0; y < h; ++y)
            for (unsigned x = 0; x < w; ++x)
            {
                auto *pixel = input.data() + y * stride + x * 4;
                pixel[0] = 40; pixel[1] = 120; pixel[2] = 200; pixel[3] = 255;
            }
        wgdi_image source = {input.data(), input.size(), stride, w, h};
        wgdi_image result = {output.data(), output.size(), out_stride, w * 2, h * 2};
        if (api->process(context, &source, &result, error, sizeof(error)))
        { std::fprintf(stderr, "%s\n", error); return 1; }
        for (unsigned y = 0; y < h * 2; ++y)
            for (unsigned x = 0; x < w * 2; ++x)
            {
                const auto *pixel = output.data() + y * out_stride + x * 4;
                assert(std::abs(int(pixel[0]) - 40) < 40);
                assert(std::abs(int(pixel[1]) - 120) < 40);
                assert(std::abs(int(pixel[2]) - 200) < 40);
                assert(pixel[3] == 255);
            }
    }
    api->destroy(context);
    context = api->create(&options, error, sizeof(error));
    if (!context) { std::fprintf(stderr, "%s\n", error); return 1; }
    {
        const unsigned w = 520, h = 264;
        const size_t stride = w * 4 + 8, out_stride = w * 8 + 16;
        const size_t columns = (w + 255) / 256, rows = (h + 255) / 256;
        std::vector<uint8_t> input(stride * h, 0xa5), output(out_stride * h * 2, 0xa5);
        std::vector<uint8_t> reference(out_stride * h * 2, 0xa5);
        for (unsigned y = 0; y < h; ++y)
            for (unsigned x = 0; x < w; ++x)
            {
                auto *pixel = input.data() + y * stride + x * 4;
                pixel[0] = 60; pixel[1] = 130; pixel[2] = 200; pixel[3] = 255;
            }
        wgdi_image source = {input.data(), input.size(), stride, w, h};
        wgdi_image result = {output.data(), output.size(), out_stride, w * 2, h * 2};
        wgdi_image full = {reference.data(), reference.size(), out_stride, w * 2, h * 2};
        if (api->process(context, &source, &full, error, sizeof(error)))
        { std::fprintf(stderr, "%s\n", error); return 1; }
        std::vector<uint32_t> selection(columns * rows, 0);
        selection[0] = 1; selection[columns * rows - 1] = 1;
        assert(wgdi_upscaler_process_regions(nullptr, &source, &result, selection.data(),
                selection.size(), error, sizeof(error)) == -1);
        assert(wgdi_upscaler_process_regions(context, nullptr, &result, selection.data(),
                selection.size(), error, sizeof(error)) == -1);
        assert(wgdi_upscaler_process_regions(context, &source, nullptr, selection.data(),
                selection.size(), error, sizeof(error)) == -1);
        assert(wgdi_upscaler_process_regions(context, &source, &result, nullptr,
                selection.size(), error, sizeof(error)) == -1);
        assert(wgdi_upscaler_process_regions(context, &source, &result, selection.data(),
                selection.size() - 1, error, sizeof(error)) == -1);
        assert(wgdi_upscaler_process_regions(context, &source, &result, selection.data(),
                selection.size() + 1, error, sizeof(error)) == -1);
        {
            auto bad = selection; bad[0] = 2;
            assert(wgdi_upscaler_process_regions(context, &source, &result, bad.data(),
                    bad.size(), error, sizeof(error)) == -1);
            auto zero = std::vector<uint32_t>(columns * rows, 0);
            assert(wgdi_upscaler_process_regions(context, &source, &result, zero.data(),
                    zero.size(), error, sizeof(error)) == -1);
        }
        wgdi_image wrong = result; wrong.width -= 2;
        assert(wgdi_upscaler_process_regions(context, &source, &wrong, selection.data(),
                selection.size(), error, sizeof(error)) == -1);
        wgdi_image tiny = result; tiny.buffer_bytes = 4;
        assert(wgdi_upscaler_process_regions(context, &source, &tiny, selection.data(),
                selection.size(), error, sizeof(error)) == -1);
        wgdi_image thin = result; thin.stride = 4;
        assert(wgdi_upscaler_process_regions(context, &source, &thin, selection.data(),
                selection.size(), error, sizeof(error)) == -1);
        for (size_t i = 0; i < output.size(); ++i) assert(output[i] == 0xa5);
        if (wgdi_upscaler_process_regions(context, &source, &result, selection.data(),
                selection.size(), error, sizeof(error)))
        { std::fprintf(stderr, "%s\n", error); return 1; }
        for (size_t ty = 0; ty < rows; ++ty)
            for (size_t tx = 0; tx < columns; ++tx)
                for (size_t y = ty * 512; y < std::min(ty * 512 + 512, size_t(h) * 2); ++y)
                    for (size_t x = tx * 512; x < std::min(tx * 512 + 512, size_t(w) * 2); ++x)
                    {
                        const bool sel = selection[ty * columns + tx];
                        const size_t off = y * out_stride + x * 4;
                        if (sel)
                            assert(!memcmp(output.data() + off, reference.data() + off, 4));
                        else
                            assert(!memcmp(output.data() + off, "\xa5\xa5\xa5\xa5", 4));
                    }
        for (size_t y = 0; y < size_t(h) * 2; ++y)
            for (size_t x = w * 8; x < out_stride; ++x)
                assert(output[y * out_stride + x] == 0xa5);
        api->destroy(context);
        context = nullptr;
    }
    context = api->create(&options, error, sizeof(error));
    if (!context) { std::fprintf(stderr, "%s\n", error); return 1; }
    api->destroy(context);
    // An unknown selection keeps the Real-CUGAN default rather than failing.
    setenv("WINE_GDI_NEURAL_MODEL", "unknown-model", 1);
    context = api->create(&options, error, sizeof(error));
    if (!context) { std::fprintf(stderr, "%s\n", error); return 1; }
    api->destroy(context);
    unsetenv("WINE_GDI_NEURAL_MODEL");
    unsetenv("WINE_GDI_REALCUGAN_BACKEND");
    if (argc >= 3)
    {
        for (const char *family : {"realcugan", "animevideov3"})
        {
            setenv("WINE_GDI_NEURAL_MODEL", family, 1);
            options.resource_directory = argv[2];
            context = api->create(&options, error, sizeof(error));
            if (!context) { std::fprintf(stderr, "%s: %s\n", family, error); return 1; }
            const unsigned w = 520, h = 264;
            const size_t stride = w * 4 + 8, out_stride = w * 8 + 16;
            const size_t columns = (w + 255) / 256, rows = (h + 255) / 256;
            std::vector<uint8_t> input(stride * h, 0xa5), output(out_stride * h * 2, 0xa5);
            std::vector<uint8_t> reference(out_stride * h * 2, 0xa5);
            for (unsigned y = 0; y < h; ++y)
                for (unsigned x = 0; x < w; ++x)
                {
                    auto *pixel = input.data() + y * stride + x * 4;
                    pixel[0] = uint8_t(x * 3 + y * 7);
                    pixel[1] = uint8_t(x * 5 + y * 11);
                    pixel[2] = uint8_t(x * 7 + y * 13);
                    pixel[3] = 255;
                }
            wgdi_image source = {input.data(), input.size(), stride, w, h};
            wgdi_image result = {output.data(), output.size(), out_stride, w * 2, h * 2};
            wgdi_image full = {reference.data(), reference.size(), out_stride, w * 2, h * 2};
            if (api->process(context, &source, &full, error, sizeof(error)))
            { std::fprintf(stderr, "%s: %s\n", family, error); return 1; }
            std::vector<uint32_t> selection(columns * rows, 0);
            selection[0] = 1; selection[columns * rows - 1] = 1;
            if (wgdi_upscaler_process_regions(context, &source, &result, selection.data(),
                    selection.size(), error, sizeof(error)))
            { std::fprintf(stderr, "%s regions: %s\n", family, error); return 1; }
            for (size_t ty = 0; ty < rows; ++ty)
                for (size_t tx = 0; tx < columns; ++tx)
                    for (size_t y = ty * 512; y < std::min(ty * 512 + 512, size_t(h) * 2); ++y)
                        for (size_t x = tx * 512; x < std::min(tx * 512 + 512, size_t(w) * 2); ++x)
                        {
                            const size_t off = y * out_stride + x * 4;
                            if (selection[ty * columns + tx])
                                assert(!memcmp(output.data() + off, reference.data() + off, 4));
                            else
                                assert(!memcmp(output.data() + off, "\xa5\xa5\xa5\xa5", 4));
                        }
            for (size_t y = 0; y < size_t(h) * 2; ++y)
                for (size_t x = w * 8; x < out_stride; ++x)
                    assert(output[y * out_stride + x] == 0xa5);
            for (size_t y = 0; y < h; ++y)
                for (size_t x = w * 4; x < stride; ++x)
                    assert(input[y * stride + x] == 0xa5);
            std::vector<uint8_t> input2(size_t(300) * 4 * 150, 0x77), output2(size_t(300) * 16 * 150, 0);
            wgdi_image source2 = {input2.data(), input2.size(), 300 * 4, 300, 150};
            wgdi_image result2 = {output2.data(), output2.size(), 300 * 8, 600, 300};
            std::vector<uint32_t> sel2(2, 0); sel2[0] = 1;
            if (wgdi_upscaler_process_regions(context, &source2, &result2, sel2.data(),
                    sel2.size(), error, sizeof(error)))
            { std::fprintf(stderr, "%s regions2: %s\n", family, error); return 1; }
            api->destroy(context);
            context = nullptr;
        }
        unsetenv("WINE_GDI_NEURAL_MODEL");
    }
    std::puts("PASS: ABI, errors, buffer bounds, real Real-CUGAN model inference, "
              "AnimeVideo-v3 model inference, RGB/BGRA, odd shapes and resampling");
}
