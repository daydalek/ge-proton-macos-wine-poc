/* SPDX-License-Identifier: LGPL-2.1-or-later */
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <Accelerate/Accelerate.h>
#include "wine_gdi_coreml_protocol.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <unistd.h>
#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <cstring>

static_assert(sizeof(wgdi_coreml_frame) == 288, "shared protocol layout changed");

static int reflected(int x, int length)
{
    if (length == 1) return 0;
    const int period = length * 2 - 2;
    x %= period;
    if (x < 0) x += period;
    return x < length ? x : period - x;
}

static void check_error(id value, NSError *error, const char *stage)
{
    if (!value) throw std::runtime_error(std::string(stage) + ": " +
        (error ? error.localizedDescription.UTF8String : "unknown Core ML error"));
}

struct InferenceBuffers {
    MLMultiArray *array = nil;
    MLDictionaryFeatureProvider *provider = nil;
    MLPredictionOptions *options = nil;
    unsigned width = 0, height = 0;
};

static void infer(MLModel *model, wgdi_coreml_frame *header, InferenceBuffers &buffers)
{
    const unsigned w = header->width, h = header->height;
    const unsigned pw = w + 36 + (w & 1), ph = h + 36 + (h & 1);
    auto *input = reinterpret_cast<uint8_t *>(header + 1);
    auto *output = input + size_t(w) * h * 4;
    NSError *error = nil;
    if (!buffers.array || buffers.width != w || buffers.height != h) {
        buffers.array = [[MLMultiArray alloc] initWithShape:@[@1, @3, @(ph), @(pw)]
            dataType:MLMultiArrayDataTypeFloat32 error:&error];
        check_error(buffers.array, error, "input allocation");
        buffers.provider = [[MLDictionaryFeatureProvider alloc]
            initWithDictionary:@{@"input_rgb": [MLFeatureValue featureValueWithMultiArray:buffers.array]} error:&error];
        check_error(buffers.provider, error, "input provider");
        MLMultiArray *outputArray = [[MLMultiArray alloc] initWithShape:@[@1, @3, @((ph-36)*2), @((pw-36)*2)]
            dataType:MLMultiArrayDataTypeFloat32 error:&error];
        check_error(outputArray, error, "output allocation");
        buffers.options = [MLPredictionOptions new];
        buffers.options.outputBackings = @{@"output_rgb": outputArray};
        buffers.width = w;
        buffers.height = h;
    }
    MLMultiArray *array = buffers.array;
    check_error(array, error, "input allocation");
    float *planes = static_cast<float *>(array.dataPointer);
    const size_t cs = array.strides[1].unsignedLongLongValue;
    const size_t ys = array.strides[2].unsignedLongLongValue;
    const size_t xs = array.strides[3].unsignedLongLongValue;
    if (xs != 1) throw std::runtime_error("unsupported input tensor stride");
    const float scale = 1.f / 255.f;
    for (unsigned c = 0; c < 3; ++c) {
        float *plane = planes + c * cs;
        for (unsigned y = 0; y < h; ++y) {
            float *row = plane + (y + 18) * ys;
            vDSP_vfltu8(input + size_t(y) * w * 4 + 2 - c, 4, row + 18, 1, w);
            vDSP_vsmul(row + 18, 1, &scale, row + 18, 1, w);
            for (unsigned x = 0; x < 18; ++x) row[x] = row[18 + reflected(int(x) - 18, w)];
            for (unsigned x = w + 18; x < pw; ++x) row[x] = row[18 + reflected(int(x) - 18, w)];
        }
        for (unsigned y = 0; y < 18; ++y)
            memcpy(plane + y * ys, plane + (18 + reflected(int(y)-18, h)) * ys, pw * sizeof(float));
        for (unsigned y = h + 18; y < ph; ++y)
            memcpy(plane + y * ys, plane + (18 + reflected(int(y)-18, h)) * ys, pw * sizeof(float));
    }
    auto begin = std::chrono::steady_clock::now();
    id<MLFeatureProvider> prediction = [model predictionFromFeatures:buffers.provider options:buffers.options error:&error];
    header->inference_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - begin).count();
    check_error(prediction, error, "prediction");
    MLMultiArray *result = [prediction featureValueForName:@"output_rgb"].multiArrayValue;
    if (result.dataType != MLMultiArrayDataTypeFloat32 || result.shape.count != 4 ||
        result.shape[0].intValue != 1 || result.shape[1].intValue != 3 ||
        result.shape[2].unsignedIntValue != (ph - 36) * 2 || result.shape[3].unsignedIntValue != (pw - 36) * 2)
        throw std::runtime_error("invalid Core ML output shape/type");
    const float *values = static_cast<const float *>(result.dataPointer);
    const size_t rcs = result.strides[1].unsignedLongLongValue;
    const size_t rys = result.strides[2].unsignedLongLongValue;
    const size_t rxs = result.strides[3].unsignedLongLongValue;
    if (rxs != 1) throw std::runtime_error("unsupported output tensor stride");
    for (unsigned c = 0; c < 3; ++c)
        for (unsigned y = 0; y < h * 2; ++y) {
            float sum;
            vDSP_sve(values + c * rcs + y * rys, 1, &sum, w * 2);
            if (!std::isfinite(sum)) throw std::runtime_error("nonfinite Core ML output");
        }
    vImage_Buffer red = {const_cast<float *>(values), h * 2, w * 2, rys * sizeof(float)};
    vImage_Buffer green = {const_cast<float *>(values + rcs), h * 2, w * 2, rys * sizeof(float)};
    vImage_Buffer blue = {const_cast<float *>(values + rcs * 2), h * 2, w * 2, rys * sizeof(float)};
    vImage_Buffer destination = {output, h * 2, w * 2, size_t(w) * 8};
    const Pixel_FFFF maximum = {1,1,1,1}, minimum = {0,0,0,0};
    if (vImageConvert_PlanarFToBGRX8888(&blue, &green, &red, 255, &destination,
            maximum, minimum, kvImageDoNotTile) != kvImageNoError)
        throw std::runtime_error("Core ML BGRA conversion failed");
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 3 || std::string(argv[1]) != "--serve" || argv[2][0] != '/') return 2;
        struct stat info;
        if (fstat(3, &info) || info.st_size != (off_t)WGDI_COREML_BYTES) return 3;
        auto *header = static_cast<wgdi_coreml_frame *>(mmap(nullptr, WGDI_COREML_BYTES,
            PROT_READ | PROT_WRITE, MAP_SHARED, 3, 0));
        if (header == MAP_FAILED) return 4;
        int enabled = 1;
        setsockopt(4, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
        NSString *resources = [NSString stringWithUTF8String:argv[2]];
        MLModel *model = nil;
        unsigned previousW = 0, previousH = 0;
        InferenceBuffers buffers;
        uint32_t sequence = 0;
        char command;
        while (recv(4, &command, 1, 0) == 1 && command == 'R') {
            @autoreleasepool {
                header->status = 1;
                header->inference_ns = 0;
                header->error[0] = 0;
                try {
                    if (header->magic != WGDI_COREML_MAGIC || header->version != WGDI_COREML_VERSION ||
                        header->sequence == sequence || !header->width || !header->height ||
                        header->width > 4096 || header->height > 4096 ||
                        uint64_t(header->width) * header->height > WGDI_COREML_PIXELS)
                        throw std::runtime_error("invalid shared frame header");
                    sequence = header->sequence;
                    if (!model || previousW != header->width || previousH != header->height) {
                        model = nil;
                        NSString *name = [NSString stringWithFormat:@"coreml/realcugan-%ux%u.mlmodelc",
                            header->width, header->height];
                        NSURL *url = [NSURL fileURLWithPath:[resources stringByAppendingPathComponent:name]];
                        MLModelConfiguration *config = [MLModelConfiguration new];
                        // Explicit ANE-eligible policy. Core ML owns graph placement.
                        config.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
                        NSError *error = nil;
                        model = [MLModel modelWithContentsOfURL:url configuration:config error:&error];
                        check_error(model, error, "model load");
                        previousW = header->width;
                        previousH = header->height;
                    }
                    infer(model, header, buffers);
                    header->status = 0;
                } catch (const std::exception &e) {
                    snprintf(header->error, sizeof(header->error), "%s", e.what());
                } catch (...) {
                    snprintf(header->error, sizeof(header->error), "Core ML helper exception");
                }
                char reply = 'D';
                if (send(4, &reply, 1, 0) != 1) break;
            }
        }
        munmap(header, WGDI_COREML_BYTES);
        return 0;
    }
}
