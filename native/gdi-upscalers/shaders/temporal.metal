/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include <metal_stdlib>
using namespace metal;

struct TemporalParameters {
    uint width, height, block_columns, block_rows;
    uint tile_columns, tile_rows, previous_valid, reserved;
    float time, fade_seconds, halo, feather;
};

static float3 decode_srgb(float3 value)
{
    return select(pow((value + 0.055f) / 1.055f, float3(2.4f)), value / 12.92f,
                  value <= 0.04045f);
}
static float3 encode_srgb(float3 value)
{
    value = clamp(value, 0.0f, 1.0f);
    return select(1.055f * pow(value, float3(1.0f / 2.4f)) - 0.055f, value * 12.92f,
                  value <= 0.0031308f);
}
static float3 read_linear(texture2d<float, access::read> image, int2 point)
{
    int2 limit = int2(image.get_width(), image.get_height()) - 1;
    return decode_srgb(image.read(uint2(clamp(point, int2(0), limit))).rgb);
}
static float3 bilinear_linear(texture2d<float, access::read> image, float2 uv)
{
    float2 position = uv * float2(image.get_width(), image.get_height()) - 0.5f;
    int2 origin = int2(floor(position));
    float2 f = fract(position);
    return mix(mix(read_linear(image, origin), read_linear(image, origin + int2(1, 0)), f.x),
               mix(read_linear(image, origin + int2(0, 1)), read_linear(image, origin + int2(1, 1)), f.x), f.y);
}

kernel void temporal_reset(texture2d<float, access::write> reference [[texture(0)]],
    texture2d<float, access::write> residual [[texture(1)]],
    device float *times [[buffer(0)]], constant TemporalParameters &p [[buffer(1)]],
    uint2 pos [[thread_position_in_grid]])
{
    if (pos.x < p.width && pos.y < p.height) reference.write(float4(0), pos);
    if (pos.x < p.width * 2 && pos.y < p.height * 2) residual.write(float4(0), pos);
    if (pos.x < p.block_columns && pos.y < p.block_rows) times[pos.y * p.block_columns + pos.x] = -1.0f;
}

/* Seed input identity even for blocks whose neural residual is still missing.
 * This distinguishes missing detail from an actual neighbouring pixel change. */
kernel void temporal_seed(texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> reference [[texture(1)]],
    constant TemporalParameters &p [[buffer(0)]], uint2 pos [[thread_position_in_grid]])
{
    if (pos.x < p.width && pos.y < p.height) reference.write(source.read(pos), pos);
}

/* Dispatch exactly 16x16 threads per group. Only this compact block metadata
 * is exposed to the CPU scheduler; pixels remain in GPU presentation textures. */
kernel void temporal_detect(texture2d<float, access::read> current [[texture(0)]],
    texture2d<float, access::read> previous [[texture(1)]],
    texture2d<float, access::read> reference [[texture(2)]],
    texture2d<uint, access::write> changes [[texture(3)]],
    device const float *times [[buffer(0)]], device uint *metadata [[buffer(1)]],
    constant TemporalParameters &p [[buffer(2)]],
    uint2 pos [[thread_position_in_grid]], uint2 group [[threadgroup_position_in_grid]],
    uint local [[thread_index_in_threadgroup]])
{
    threadgroup atomic_uint flags;
    if (local == 0) atomic_store_explicit(&flags, 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (pos.x < p.width && pos.y < p.height) {
        float3 value = current.read(pos).rgb;
        uint bits = 0;
        bool delta = any(abs(value - reference.read(pos).rgb) > 0.5f / 255.0f);
        if (times[group.y * p.block_columns + group.x] < 0 || delta) bits |= 1u;
        if (delta) bits |= 4u;
        if (!p.previous_valid || any(abs(value - previous.read(pos).rgb) > 0.5f / 255.0f)) bits |= 2u;
        atomic_fetch_or_explicit(&flags, bits, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (local == 0) {
        uint bits = atomic_load_explicit(&flags, memory_order_relaxed);
        changes.write(uint4(bits, 0, 0, 0), group);
        metadata[group.y * p.block_columns + group.x] = bits;
    }
}

/* The detect pass for admission binds the immutable job source as previous.
 * Bit 2 therefore covers changes since that job, including old/new cursor sites. */
kernel void temporal_accept(texture2d<uint, access::read> changes [[texture(0)]],
    device const uint *selected [[buffer(0)]], device uint *accepted [[buffer(1)]],
    device const float *times [[buffer(2)]], constant TemporalParameters &p [[buffer(3)]],
    uint2 block [[thread_position_in_grid]])
{
    if (block.x >= p.block_columns || block.y >= p.block_rows) return;
    uint index = block.y * p.block_columns + block.x;
    uint2 tile = block * 16u / 256u;
    uint bits = 0;
    int2 first = max(int2(0), int2(floor((float2(block * 16u) - p.halo) / 16.0f)));
    int2 last = min(int2(p.block_columns, p.block_rows) - 1,
                   int2(floor((float2((block + 1u) * 16u) + p.halo - 1.0f) / 16.0f)));
    for (int y = first.y; y <= last.y; ++y)
        for (int x = first.x; x <= last.x; ++x) bits |= changes.read(uint2(x, y)).r;
    bool eligible = selected[tile.y * p.tile_columns + tile.x] != 0;
    accepted[index] = eligible && !(bits & 2u) && ((bits & 4u) || times[index] < 0);
}

kernel void temporal_commit_input(texture2d<float, access::read> job [[texture(0)]],
    texture2d<float, access::write> reference [[texture(1)]],
    device const uint *accepted [[buffer(0)]], constant TemporalParameters &p [[buffer(1)]],
    uint2 pos [[thread_position_in_grid]])
{
    if (pos.x >= p.width || pos.y >= p.height) return;
    uint index = (pos.y / 16) * p.block_columns + pos.x / 16;
    if (accepted[index]) reference.write(job.read(pos), pos);
}

kernel void temporal_commit_residual(texture2d<float, access::read> job [[texture(0)]],
    texture2d<float, access::read> neural [[texture(1)]],
    texture2d<float, access::write> residual [[texture(2)]],
    device const uint *accepted [[buffer(0)]], constant TemporalParameters &p [[buffer(1)]],
    uint2 pos [[thread_position_in_grid]])
{
    uint2 size = uint2(p.width, p.height) * 2u;
    if (any(pos >= size)) return;
    uint index = (pos.y / 32) * p.block_columns + pos.x / 32;
    if (accepted[index]) {
        float2 uv = (float2(pos) + 0.5f) / float2(size);
        float3 detail = decode_srgb(neural.read(pos).rgb) - bilinear_linear(job, uv);
        residual.write(float4(detail, 1.0f), pos);
    }
}

kernel void temporal_commit_times(device const uint *accepted [[buffer(0)]],
    device float *times [[buffer(1)]], constant TemporalParameters &p [[buffer(2)]],
    uint2 block [[thread_position_in_grid]])
{
    if (block.x >= p.block_columns || block.y >= p.block_rows) return;
    uint index = block.y * p.block_columns + block.x;
    if (accepted[index]) times[index] = p.time;
}

struct TemporalVertex { float4 position [[position]]; float2 uv; };
vertex TemporalVertex temporal_vertex(uint index [[vertex_id]])
{
    float2 uv = float2((index << 1) & 2u, index & 2u);
    return {float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv};
}

kernel void temporal_mask(texture2d<uint, access::read> changes [[texture(0)]],
    texture2d<float, access::write> weights [[texture(1)]],
    constant TemporalParameters &p [[buffer(0)]], uint2 pos [[thread_position_in_grid]])
{
    if (pos.x >= p.width || pos.y >= p.height) return;
    float2 source = float2(pos) + 0.5f;
    int2 block = clamp(int2(source / 16.0f), int2(0), int2(p.block_columns, p.block_rows) - 1);
    int radius = int(ceil((p.halo + p.feather) / 16.0f)) + 1;
    float distance = p.halo + p.feather;
    for (int y = max(0, block.y-radius); y <= min(int(p.block_rows)-1, block.y+radius); ++y)
        for (int x = max(0, block.x-radius); x <= min(int(p.block_columns)-1, block.x+radius); ++x)
            if (changes.read(uint2(x, y)).r & 1u) {
                float2 low = float2(x, y) * 16.0f, high = low + 16.0f;
                float2 delta = max(max(low-source, source-high), 0.0f);
                distance = min(distance, max(delta.x, delta.y));
            }
    weights.write(float4(smoothstep(p.halo, p.halo + p.feather, distance)), pos);
}

fragment float4 temporal_fragment(TemporalVertex varying [[stage_in]],
    texture2d<float, access::read> current [[texture(0)]],
    texture2d<float, access::sample> residual [[texture(1)]],
    texture2d<float, access::sample> weights [[texture(2)]],
    device const float *times [[buffer(0)]], constant TemporalParameters &p [[buffer(1)]])
{
    constexpr sampler linear_sampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 source = varying.uv * float2(p.width, p.height);
    int2 block = clamp(int2(source / 16.0f), int2(0), int2(p.block_columns, p.block_rows) - 1);
    float keep = weights.sample(linear_sampler, varying.uv).r;
    float start = times[block.y * p.block_columns + block.x];
    float maturity = start < 0 ? 0 : clamp((p.time-start) / max(p.fade_seconds, 0.001f), 0.0f, 1.0f);
    float3 base = bilinear_linear(current, varying.uv);
    float3 detail = residual.sample(linear_sampler, varying.uv).rgb;
    return float4(encode_srgb(base + keep * maturity * detail), 1.0f);
}
