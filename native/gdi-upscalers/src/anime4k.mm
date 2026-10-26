/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "backend.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstring>
#include <stdexcept>

class Anime4KBackend final : public UpscaleBackend
{
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    id<MTLLibrary> library = nil;
    id<MTLComputePipelineState> pipelines[5] = {};
    id<MTLTexture> input = nil, features[2] = {}, output = nil;
    id<MTLBuffer> upload = nil, readback = nil;
    unsigned width = 0, height = 0;
    size_t input_stride = 0, output_stride = 0;

    void clear_frames()
    {
        [input release]; input = nil;
        for (auto &texture : features) { [texture release]; texture = nil; }
        [output release]; output = nil;
        [upload release]; upload = nil;
        [readback release]; readback = nil;
        width = height = 0;
    }

    void clear()
    {
        clear_frames();
        for (auto &pipeline : pipelines) { [pipeline release]; pipeline = nil; }
        [library release]; library = nil;
        [queue release]; queue = nil;
        [device release]; device = nil;
    }

    void configure(unsigned w, unsigned h)
    {
        clear_frames();
        auto texture = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                         width:w height:h mipmapped:NO];
        texture.storageMode = MTLStorageModePrivate;
        texture.usage = MTLTextureUsageShaderRead;
        input = [device newTextureWithDescriptor:texture];
        texture.pixelFormat = MTLPixelFormatRGBA32Float;
        texture.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        for (auto &feature : features) feature = [device newTextureWithDescriptor:texture];
        texture.pixelFormat = MTLPixelFormatBGRA8Unorm;
        texture.width = w * 2;
        texture.height = h * 2;
        texture.usage = MTLTextureUsageShaderWrite;
        output = [device newTextureWithDescriptor:texture];
        input_stride = (size_t(w) * 4 + 255) & ~size_t(255);
        output_stride = (size_t(w) * 8 + 255) & ~size_t(255);
        upload = [device newBufferWithLength:input_stride * h options:MTLResourceStorageModeShared];
        readback = [device newBufferWithLength:output_stride * h * 2 options:MTLResourceStorageModeShared];
        if (!input || !features[0] || !features[1] || !output || !upload || !readback)
            throw std::runtime_error("Anime4K texture or staging allocation failed");
        width = w;
        height = h;
    }

public:
    explicit Anime4KBackend(const std::string &resources)
    {
        @autoreleasepool
        {
            try
            {
                device = MTLCreateSystemDefaultDevice();
                if (!device) throw std::runtime_error("Anime4K Metal device unavailable");
                queue = [device newCommandQueue];
                NSError *error = nil;
                auto path = [NSString stringWithUTF8String:(resources + "/anime4k.metallib").c_str()];
                library = [device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
                if (!queue || !library) throw std::runtime_error("Anime4K shader library load failed");
                const char *names[] = {"convolution0", "convolution1", "convolution2", "convolution3", "depth_to_space"};
                for (unsigned i = 0; i < 5; ++i)
                {
                    id<MTLFunction> function = [library newFunctionWithName:[NSString stringWithUTF8String:names[i]]];
                    if (function) pipelines[i] = [device newComputePipelineStateWithFunction:function error:&error];
                    [function release];
                    if (!pipelines[i]) throw std::runtime_error("Anime4K compute pipeline creation failed");
                }
            }
            catch (...) { clear(); throw; }
        }
    }

    ~Anime4KBackend() override { @autoreleasepool { clear(); } }

    std::vector<uint8_t> upscale2x(const wgdi_image &image) override
    {
        @autoreleasepool
        {
            if (width != image.width || height != image.height) configure(image.width, image.height);
            for (unsigned y = 0; y < height; ++y)
                std::memcpy(static_cast<uint8_t *>(upload.contents) + y * input_stride,
                            image.pixels + y * image.stride, size_t(width) * 4);
            auto commands = [queue commandBuffer];
            auto blit = [commands blitCommandEncoder];
            if (!commands || !blit) throw std::runtime_error("Anime4K command allocation failed");
            [blit copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:input_stride
                  sourceBytesPerImage:input_stride * height sourceSize:MTLSizeMake(width, height, 1)
                  toTexture:input destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
            id<MTLTexture> source = input;
            for (unsigned i = 0; i < 5; ++i)
            {
                auto destination = i < 4 ? features[i % 2] : output;
                auto encoder = [commands computeCommandEncoder];
                if (!encoder) throw std::runtime_error("Anime4K encoder allocation failed");
                [encoder setComputePipelineState:pipelines[i]];
                [encoder setTexture:source atIndex:0];
                if (i < 4) [encoder setTexture:destination atIndex:1];
                else
                {
                    [encoder setTexture:input atIndex:1];
                    [encoder setTexture:destination atIndex:2];
                }
                [encoder dispatchThreads:MTLSizeMake(destination.width, destination.height, 1)
                    threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                [encoder endEncoding];
                source = destination;
            }
            blit = [commands blitCommandEncoder];
            if (!blit) throw std::runtime_error("Anime4K readback encoder allocation failed");
            [blit copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:MTLSizeMake(width * 2, height * 2, 1) toBuffer:readback destinationOffset:0
                  destinationBytesPerRow:output_stride destinationBytesPerImage:output_stride * height * 2];
            [blit endEncoding];
            [commands commit];
            [commands waitUntilCompleted];
            if (commands.status != MTLCommandBufferStatusCompleted)
                throw std::runtime_error("Anime4K GPU command failed");
            std::vector<uint8_t> result(size_t(width) * height * 16);
            for (unsigned y = 0; y < height * 2; ++y)
                std::memcpy(result.data() + size_t(y) * width * 8,
                            static_cast<const uint8_t *>(readback.contents) + y * output_stride, width * 8);
            return result;
        }
    }
};

std::unique_ptr<UpscaleBackend> create_anime4k(const std::string &resources)
{
    return std::make_unique<Anime4KBackend>(resources);
}
