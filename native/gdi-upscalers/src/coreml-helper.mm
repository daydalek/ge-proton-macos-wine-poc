/* SPDX-License-Identifier: LGPL-2.1-or-later */
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <Accelerate/Accelerate.h>
#include "wine_gdi_coreml_protocol.h"
#include "content-cache.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstdio>
#include <optional>
#include <stdexcept>
#include <string>
#include <cstring>
#include <unordered_map>
#include <vector>

static_assert(sizeof(wgdi_coreml_frame) == 288, "shared protocol layout changed");

/* Tiling: a frame whose size has no model of its own is covered by windows of
 * one fixed-size model instead of falling back to the 14-second CPU network.
 * Neighbouring windows share kTileOverlap pixels so the seam can be blended. */
static constexpr unsigned kTileOverlap = 32;
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


struct TileModel {
    MLModel *model = nil;
    NSString *path = nil;
    unsigned width = 0, height = 0, halo = 18;
    wgdi::Digest fingerprint{};
    bool hasFingerprint = false;
};

static std::optional<wgdi::Digest> model_scope(const char *tag, const std::string &family,
                                             const wgdi::Digest &modelFp, const wgdi::Digest &helperFp,
                                             unsigned w, unsigned h)
{
    wgdi::Hasher hasher;
    hasher.update(tag, std::strlen(tag));
    hasher.update(uint64_t(0));
    hasher.update(family.c_str(), family.size() + 1);
    hasher.update(modelFp.data(), modelFp.size());
    hasher.update(helperFp.data(), helperFp.size());
    hasher.update(uint64_t(w));
    hasher.update(uint64_t(h));
    return hasher.digest();
}

/* Windows needed to cover `length` with windows `tile` wide. */
static unsigned tiles_needed(unsigned length, unsigned tile)
{
    if (length <= tile) return 1;
    const unsigned span = length - tile;
    const unsigned step = tile - kTileOverlap;
    return (span + step - 1) / step + 1;
}

/* Windows covering `length`, spread evenly: the stride stays under the tile
 * width, so every seam gets the same overlap instead of one wide band where a
 * flush last window happens to land. */
static std::vector<unsigned> tile_origins(unsigned length, unsigned tile)
{
    const unsigned count = tiles_needed(length, tile);
    std::vector<unsigned> origins;
    origins.reserve(count);
    if (count == 1) { origins.push_back(0); return origins; }
    const unsigned span = (length - tile + 1) / 2;
    // Keep pooling/stride-2 phases aligned across windows. An odd frame may
    // extend the final window by one reflected pixel, cropped during stitching.
    for (unsigned index = 0; index < count; ++index)
        origins.push_back(2 * unsigned(std::llround(double(index) * span / double(count - 1))));
    return origins;
}

/* Pixels a tiling with a `tw`x`th` window produces for a `w`x`h` frame. The
 * cheapest candidate wins, which keeps a 700-wide frame on one 800x600 window
 * instead of slicing it into four 640x480 pieces that mostly overlap. */
static double tile_cost(unsigned w, unsigned h, unsigned tw, unsigned th)
{
    return double(tiles_needed(w, tw)) * double(tiles_needed(h, th)) * double(tw) * double(th);
}

/* Blend weight of a position inside a window: full in the middle, a linear ramp
 * over the overlap band, and only when a neighbour actually covers that side. */
static inline unsigned blend_weight(unsigned position, unsigned tile, unsigned frame,
                                    unsigned origin)
{
    unsigned weight = 255;
    if (origin > 0 && position < kTileOverlap)
        weight = std::min(weight, (position + 1) * 255 / kTileOverlap);
    if (origin + tile < frame && position + kTileOverlap > tile)
        weight = std::min(weight, (tile - position) * 255 / kTileOverlap);
    return weight;
}

struct CachedTile {
    std::vector<uint8_t> input, output;
};
struct TileCache {
    unsigned width = 0, height = 0, tw = 0, th = 0;
    std::vector<CachedTile> tiles;
};

/* Runs the fixed-size network over every window and blends the results into the
 * frame's output area. Returns the number of windows it ran. Weights are 16-bit
 * because a corner can be covered by three windows, where a byte would saturate
 * and skew the average. */
static unsigned infer_tiled(const TileModel &tile, wgdi_coreml_frame *header,
                            std::vector<uint16_t> &weights, InferenceBuffers &buffers,
                            TileCache &cache, wgdi::ContentCache *store,
                            const std::string &family,
                            const std::optional<wgdi::Digest> &helperDigest,
                            const uint32_t *selection = nullptr)
{
    const unsigned w = header->width, h = header->height;
    const unsigned tw = tile.width, th = tile.height;
    const unsigned pw = tw + tile.halo * 2, ph = th + tile.halo * 2;
    auto *input = reinterpret_cast<uint8_t *>(header + 1);
    auto *output = input + size_t(w) * h * 4;
    const unsigned outWidth = w * 2, outHeight = h * 2;
    const unsigned tileColumns = (w + 255) / 256;
    weights.resize(size_t(outWidth) * outHeight);
    if (selection) {
        for (unsigned ty = 0; ty * 256 < h; ++ty)
            for (unsigned tx = 0; tx * 256 < w; ++tx) {
                if (!selection[ty * tileColumns + tx]) continue;
                const unsigned x0 = tx * 512, x1 = std::min(tx * 512 + 512, outWidth);
                const unsigned y1 = std::min(ty * 512 + 512, outHeight);
                for (unsigned y = ty * 512; y < y1; ++y) {
                    memset(output + (size_t(y) * outWidth + x0) * 4, 0, (x1 - x0) * 4);
                    memset(&weights[size_t(y) * outWidth + x0], 0, (x1 - x0) * sizeof(uint16_t));
                }
            }
    } else {
        // Untouched pixels must not blend with stale shared memory.
        std::fill(weights.begin(), weights.end(), 0);
        memset(output, 0, size_t(outWidth) * outHeight * 4);
    }
    NSError *error = nil;
    if (!buffers.array || buffers.width != tw || buffers.height != th) {
        buffers.array = [[MLMultiArray alloc] initWithShape:@[@1, @3, @(ph), @(pw)]
            dataType:MLMultiArrayDataTypeFloat32 error:&error];
        check_error(buffers.array, error, "tile input allocation");
        MLMultiArray *resultArray = [[MLMultiArray alloc]
            initWithShape:@[@1, @3, @(th * 2), @(tw * 2)]
            dataType:MLMultiArrayDataTypeFloat32 error:&error];
        check_error(resultArray, error, "tile output allocation");
        buffers.provider = [[MLDictionaryFeatureProvider alloc]
            initWithDictionary:@{@"input_rgb": [MLFeatureValue featureValueWithMultiArray:buffers.array]}
            error:&error];
        check_error(buffers.provider, error, "tile provider");
        buffers.options = [MLPredictionOptions new];
        buffers.options.outputBackings = @{@"output_rgb": resultArray};

        buffers.width = tw;
        buffers.height = th;
    }
    MLMultiArray *tensor = buffers.array;
    MLDictionaryFeatureProvider *provider = buffers.provider;
    MLPredictionOptions *options = buffers.options;

    float *planes = static_cast<float *>(tensor.dataPointer);
    const size_t cs = tensor.strides[1].unsignedLongLongValue;
    const size_t ys = tensor.strides[2].unsignedLongLongValue;
    const float scale = 1.f / 255.f;
    const auto columnOrigins = tile_origins(w, tw);
    const auto rowOrigins = tile_origins(h, th);
    if (cache.width != w || cache.height != h || cache.tw != tw || cache.th != th) {
        cache = TileCache{};
        cache.width = w; cache.height = h; cache.tw = tw; cache.th = th;
        cache.tiles.resize(columnOrigins.size() * rowOrigins.size());
    }
    const bool enabled = !getenv("WINE_GDI_COREML_DISABLE_TILE_CACHE");
    const auto scope = enabled && store && store->active() && tile.hasFingerprint && helperDigest
        ? model_scope("wgdi-scope-tile-v1", family, tile.fingerprint, *helperDigest, tw, th)
        : std::optional<wgdi::Digest>{};
    std::vector<uint8_t> window(size_t(pw) * ph * 4);
    unsigned runs = 0, tileIndex = 0, stored = 0, served = 0;

    for (unsigned oy : rowOrigins) {
        for (unsigned ox : columnOrigins) {
            @autoreleasepool {
                CachedTile &cached = cache.tiles[tileIndex++];
                if (selection) {
                    bool covered = false;
                    const unsigned ex = std::min(ox + tw, w), ey = std::min(oy + th, h);
                    for (unsigned ty = oy / 256; !covered && ty <= (ey - 1) / 256; ++ty)
                        for (unsigned tx = ox / 256; !covered && tx <= (ex - 1) / 256; ++tx)
                            covered = selection[ty * tileColumns + tx] != 0;
                    if (!covered) continue;
                }
                ++served;
                // Compare every reflected context pixel. This also invalidates a
                // neighbour when a change falls inside its halo.
                for (unsigned y = 0; y < ph; ++y) {
                    const unsigned sy = reflected(int(oy + y) - int(tile.halo), h);
                    for (unsigned x = 0; x < pw; ++x) {
                        const unsigned sx = reflected(int(ox + x) - int(tile.halo), w);
                        memcpy(window.data() + (size_t(y) * pw + x) * 4,
                               input + (size_t(sy) * w + sx) * 4, 4);
                    }
                }
                if (!enabled || cached.output.empty() || cached.input != window) {
                    bool infer = true;
                    if (scope) {
                        cached.output.resize(size_t(tw) * th * 12);
                        if (store->get(*scope, window.data(), window.size(),
                                       cached.output.data(), cached.output.size())) {
                            cached.input = window;
                            ++stored;
                            infer = false;
                        } else {
                            cached.output.clear();
                        }
                    }
                    if (infer) {
                        // Publish a cache entry only after validation and conversion succeed.
                        cached.input.clear();
                        cached.output.clear();
                        for (unsigned c = 0; c < 3; ++c) {
                            float *plane = planes + c * cs;
                            for (unsigned y = 0; y < ph; ++y) {
                                float *row = plane + y * ys;
                                for (unsigned x = 0; x < pw; ++x)
                                    row[x] = float(window[(size_t(y) * pw + x) * 4 + 2 - c]) * scale;
                            }
                        }
                        id<MLFeatureProvider> prediction =
                            [tile.model predictionFromFeatures:provider options:options error:&error];
                        check_error(prediction, error, "tile prediction");
                        MLMultiArray *result = [prediction featureValueForName:@"output_rgb"].multiArrayValue;
                        if (!result || result.dataType != MLMultiArrayDataTypeFloat32 || result.shape.count != 4 ||
                            result.shape[0].unsignedIntValue != 1 || result.shape[1].unsignedIntValue != 3 ||
                            result.shape[2].unsignedIntValue != th * 2 || result.shape[3].unsignedIntValue != tw * 2)
                            throw std::runtime_error("invalid tile output shape");
                        const float *values = static_cast<const float *>(result.dataPointer);
                        const size_t rcs = result.strides[1].unsignedLongLongValue;
                        const size_t rys = result.strides[2].unsignedLongLongValue;
                        if (result.strides[3].unsignedLongLongValue != 1)
                            throw std::runtime_error("unsupported tile output stride");
                        for (unsigned c = 0; c < 3; ++c)
                            for (unsigned y = 0; y < th * 2; ++y) {
                                float sum;
                                vDSP_sve(values + c * rcs + y * rys, 1, &sum, tw * 2);
                                if (!std::isfinite(sum)) throw std::runtime_error("nonfinite tile output");
                            }
                        cached.output.resize(size_t(tw) * th * 12);
                        for (unsigned y = 0; y < th * 2; ++y)
                            for (unsigned x = 0; x < tw * 2; ++x)
                                for (unsigned c = 0; c < 3; ++c) {
                                    const float sample = values[c * rcs + y * rys + x];
                                    cached.output[(size_t(y) * tw * 2 + x) * 3 + c] =
                                        uint8_t(std::min(1.f, std::max(0.f, sample)) * 255.f + 0.5f);
                                }
                        cached.input = window;
                        ++runs;
                        if (scope)
                            store->put(*scope, window.data(), window.size(),
                                       cached.output.data(), cached.output.size());
                    }
                }
                const unsigned visibleX = std::min(tw, w - ox), visibleY = std::min(th, h - oy);
                for (unsigned y = 0; y < visibleY; ++y) {
                    const unsigned wy = blend_weight(y, th, h, oy);
                    for (unsigned x = 0; x < visibleX; ++x) {
                        if (selection &&
                            !selection[((oy + y) / 256) * tileColumns + ((ox + x) / 256)])
                            continue;
                        const unsigned wx = blend_weight(x, tw, w, ox);
                        const unsigned weight = (wx * wy + 127) / 255;
                        if (!weight) continue;
                        for (unsigned dy = 0; dy < 2; ++dy) {
                            for (unsigned dx = 0; dx < 2; ++dx) {
                                const size_t index = size_t(oy + y) * 2 + dy;
                                const size_t column = size_t(ox + x) * 2 + dx;
                                uint8_t *pixel = output + (index * outWidth + column) * 4;
                                unsigned sum = weights[index * outWidth + column];
                                for (unsigned c = 0; c < 3; ++c) {
                                    const unsigned value = cached.output[(size_t(y * 2 + dy) * tw * 2 + x * 2 + dx) * 3 + c];
                                    pixel[2 - c] = uint8_t(sum ? (unsigned(pixel[2 - c]) * sum + value * weight) / (sum + weight) : value);
                                }
                                pixel[3] = 255;
                                weights[index * outWidth + column] = uint16_t(std::min(65535u, sum + weight));
                            }
                        }
                    }
                }
            }
        }
    }
    if (getenv("WINE_GDI_COREML_TRACE"))
        fprintf(stderr, "winegdi: tiles %ux%u frame %ux%u inferred=%u reused=%u stored=%u served=%u\n",
                tw, th, w, h, runs, served - runs, stored, served);
    return runs;
}

/* Cheapest tiling model for a `w`x`h` frame: candidates are ranked by produced
 * pixels, then loaded in order so a broken bundle entry still leaves a usable
 * one behind it. */
static TileModel load_tile_model(NSString *resources, const char *prefix, unsigned w, unsigned h)
{
    struct Candidate {
        double cost;
        NSString *path;
        unsigned width, height;
    };
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "%s-%%ux%%u.mlmodelc%%n", prefix);
    std::vector<Candidate> candidates;
    NSString *directory = [resources stringByAppendingPathComponent:@"coreml"];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil]) {
        unsigned tw = 0, th = 0;
        int consumed = 0;
        if (sscanf(name.UTF8String, pattern, &tw, &th, &consumed) != 2 ||
            consumed != int(strlen(name.UTF8String)) || tw <= kTileOverlap || th <= kTileOverlap ||
            tw > 4096 || th > 4096 || (tw & 1) || (th & 1)) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        candidates.push_back({tile_cost(w, h, tw, th), path, tw, th});
    }
    // Small models make sparse changes cheap. The grid remains fixed for
    // the frame geometry and all cached entries share one model.
    const bool small = std::any_of(candidates.begin(), candidates.end(),
        [](const Candidate &c) { return c.width <= 384 && c.height <= 384; });
    if (small) candidates.erase(std::remove_if(candidates.begin(), candidates.end(),
        [](const Candidate &c) { return c.width > 384 || c.height > 384; }), candidates.end());
    std::sort(candidates.begin(), candidates.end(),
        [](const Candidate &a, const Candidate &b) { return a.cost < b.cost; });
    for (const Candidate &candidate : candidates) {
        MLModelConfiguration *config = [MLModelConfiguration new];
        config.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
        NSError *error = nil;
        MLModel *model = [MLModel modelWithContentsOfURL:[NSURL fileURLWithPath:candidate.path]
                                           configuration:config error:&error];
        if (!model) continue;
        MLFeatureDescription *input =
            model.modelDescription.inputDescriptionsByName[@"input_rgb"];
        NSArray<NSNumber *> *shape = input.multiArrayConstraint.shape;
        if (shape.count != 4 || shape[0].unsignedIntValue != 1 ||
            shape[1].unsignedIntValue != 3) continue;
        const long long ih = shape[2].longLongValue - candidate.height;
        const long long iw = shape[3].longLongValue - candidate.width;
        if (ih != iw || ih < 0 || (ih & 1)) continue;
        const long long halo = ih / 2;
        if (halo < 18 || halo > 64) continue;
        TileModel tile;
        tile.model = model;
        tile.path = candidate.path;
        tile.width = candidate.width;
        tile.height = candidate.height;
        tile.halo = unsigned(halo);
        return tile;
    }
    return TileModel{};
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if ((argc != 3 && argc != 4) || std::string(argv[1]) != "--serve" || argv[2][0] != '/') return 2;
        // argc==3 keeps the original client compatible: it means Real-CUGAN.
        const std::string family = argc == 4 ? argv[3] : "realcugan";
        if (family != "realcugan" && family != "animevideov3") return 2;
        struct stat info;
        if (fstat(3, &info) || (info.st_size != (off_t)WGDI_COREML_BYTES &&
            info.st_size != (off_t)WGDI_COREML_EXTENDED_BYTES)) return 3;
        const bool extended = info.st_size == (off_t)WGDI_COREML_EXTENDED_BYTES;
        auto *header = static_cast<wgdi_coreml_frame *>(mmap(nullptr, size_t(info.st_size),
            PROT_READ | PROT_WRITE, MAP_SHARED, 3, 0));
        if (header == MAP_FAILED) return 4;
        int enabled = 1;
        setsockopt(4, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
        NSString *resources = [NSString stringWithUTF8String:argv[2]];
        wgdi::ContentCache store = wgdi::content_cache_from_environment();
        std::optional<wgdi::Digest> helperDigest;
        {
            char executable[4096];
            uint32_t length = sizeof(executable);
            if (!_NSGetExecutablePath(executable, &length)) {
                char resolved[4096];
                if (realpath(executable, resolved))
                    helperDigest = wgdi::hash_file(resolved);
            }
        }
        std::unordered_map<std::string, std::optional<wgdi::Digest>> modelFingerprints;
        const auto fingerprint = [&modelFingerprints](NSString *path) noexcept -> const wgdi::Digest * {
            try {
                const std::string key = path.UTF8String;
                auto it = modelFingerprints.find(key);
                if (it == modelFingerprints.end())
                    it = modelFingerprints.emplace(key, wgdi::hash_directory(key)).first;
                return it->second ? &*it->second : nullptr;
            } catch (...) {
                return nullptr;
            }
        };
        std::optional<wgdi::Digest> exactScope;
        NSString *modelPath = nil;
        MLModel *model = nil;
        TileModel tileModel;
        TileCache tileCache;
        std::vector<uint16_t> tileWeights;
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
                    if (header->magic != WGDI_COREML_MAGIC ||
                        (header->version != WGDI_COREML_VERSION &&
                         header->version != WGDI_COREML_VERSION_REGIONS) ||
                        header->sequence == sequence || !header->width || !header->height ||
                        header->width > 4096 || header->height > 4096 ||
                        uint64_t(header->width) * header->height > WGDI_COREML_PIXELS)
                        throw std::runtime_error("invalid shared frame header");
                    sequence = header->sequence;
                    uint32_t selection[256];
                    const uint32_t *regionSelection = nullptr;
                    if (header->version == WGDI_COREML_VERSION_REGIONS) {
                        if (!extended) throw std::runtime_error("regions request on legacy mapping");
                        const auto *bits = reinterpret_cast<const uint32_t *>(
                            reinterpret_cast<const uint8_t *>(header) + WGDI_COREML_BYTES);
                        const size_t columns = (size_t(header->width) + 255) / 256;
                        const size_t rows = (size_t(header->height) + 255) / 256;
                        bool any = false;
                        for (size_t i = 0; i < 256; ++i) {
                            const bool marked = bits[i / 32] & (1u << (i % 32));
                            if (i < columns * rows) {
                                selection[i] = marked ? 1u : 0u;
                                any |= marked;
                            } else if (marked)
                                throw std::runtime_error("selection marks tiles outside the grid");
                        }
                        if (!any) throw std::runtime_error("empty tile selection");
                        regionSelection = selection;
                    }
                    if (previousW != header->width || previousH != header->height) {
                        model = nil;
                        modelPath = nil;
                        exactScope.reset();
                        tileCache = TileCache{};
                        tileModel = TileModel{};
                        NSString *name = [NSString stringWithFormat:@"coreml/%s-%ux%u.mlmodelc",
                            family.c_str(), header->width, header->height];
                        NSString *path = [resources stringByAppendingPathComponent:name];
                        tileModel = load_tile_model(resources, family.c_str(), header->width, header->height);
                        if (tileModel.model) {
                            if (const wgdi::Digest *fp = fingerprint(tileModel.path)) {
                                tileModel.fingerprint = *fp;
                                tileModel.hasFingerprint = true;
                            }
                        }
                        // AnimeVideo-v3 is fully convolutional, so its fixed-size
                        // tiles are exact and no full-frame variant is built.
                        if (family == "realcugan" && !tileModel.model &&
                            [[NSFileManager defaultManager] fileExistsAtPath:path]) {
                            MLModelConfiguration *config = [MLModelConfiguration new];
                            // Explicit ANE-eligible policy. Core ML owns graph placement.
                            config.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
                            NSError *error = nil;
                            model = [MLModel modelWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                      configuration:config error:&error];
                            modelPath = model ? path : nil;
                        }
                        if (!model && !tileModel.model)
                            throw std::runtime_error("no usable " + family + " model");
                        if (model && store.active() && helperDigest) {
                            if (const wgdi::Digest *fp = fingerprint(modelPath))
                                exactScope = model_scope("wgdi-scope-frame-v1", family, *fp,
                                                         *helperDigest, header->width, header->height);
                        }
                        previousW = header->width;
                        previousH = header->height;
                    }
                    const bool cacheable = !getenv("WINE_GDI_COREML_DISABLE_TILE_CACHE");
                    if (model) {
                        const size_t inBytes = size_t(header->width) * header->height * 4;
                        const size_t outBytes = inBytes * 4;
                        auto *input = reinterpret_cast<uint8_t *>(header + 1);
                        auto *output = input + inBytes;
                        bool ran = true;
                        if (cacheable && exactScope &&
                            store.get(*exactScope, input, inBytes, output, outBytes))
                            ran = false;
                        if (ran) {
                            infer(model, header, buffers);
                            if (cacheable && exactScope)
                                store.put(*exactScope, input, inBytes, output, outBytes);
                        }
                        if (getenv("WINE_GDI_COREML_TRACE"))
                            fprintf(stderr, "winegdi: frame %ux%u inferred=%u reused=%u stored=%u\n",
                                    header->width, header->height, unsigned(ran), unsigned(!ran),
                                    unsigned(!ran));
                    } else {
                        auto begin = std::chrono::steady_clock::now();
                        const unsigned runs = infer_tiled(tileModel, header, tileWeights, buffers,
                                                          tileCache, cacheable ? &store : nullptr,
                                                          family, helperDigest, regionSelection);
                        header->inference_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                            std::chrono::steady_clock::now() - begin).count();
                        (void)runs;
                    }
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
        munmap(header, size_t(info.st_size));
        return 0;
    }
}
