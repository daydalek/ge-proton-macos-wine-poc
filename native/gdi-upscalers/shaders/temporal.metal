/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include <metal_stdlib>
using namespace metal;

struct TemporalParameters {
    uint width, height, block_columns, block_rows;
    uint tile_columns, tile_rows, previous_valid, excluded;
    float time, fade_seconds, halo, feather;
    uint use_spatial;
};

/* Mirrors struct wgdi_temporal_library_parameters (104 bytes). */
struct TemporalLibraryParameters {
    uint slot_count, table_mask, width, height;
    uint slot_order[16];
    float time, fade_seconds;
    uint halo, exact_translation;
    uint excluded, ring_only;
};

struct TemporalLibraryEntry { atomic_uint key; uint value; };

static uint temporal_fmix32(uint h)
{
    h ^= h >> 16; h *= 0x85ebca6bu; h ^= h >> 13; h *= 0xc2b2ae35u; h ^= h >> 16;
    return h;
}
/* FNV-1a over 16x16 sRGB pixels packed as r|g<<8|b<<16, murmur3 finalised. */
static uint temporal_window_hash(texture2d<float, access::read> image, uint2 origin)
{
    uint h = 2166136261u;
    for (uint y = 0; y < 16; ++y)
        for (uint x = 0; x < 16; ++x) {
            float3 c = image.read(origin + uint2(x, y)).rgb;
            uint px = uint(round(c.r * 255.0f)) | (uint(round(c.g * 255.0f)) << 8) |
                      (uint(round(c.b * 255.0f)) << 16);
            h = (h ^ px) * 16777619u;
        }
    return temporal_fmix32(h);
}
static uint temporal_context_hash(texture2d<float, access::read> image, uint2 origin)
{
    int2 lo = int2(origin) - 8;
    int2 limit = int2(image.get_width(), image.get_height()) - 1;
    uint h = 2166136261u;
    for (uint y = 0; y < 32; ++y)
        for (uint x = 0; x < 32; ++x) {
            float3 c = image.read(uint2(clamp(lo + int2(x, y), int2(0), limit))).rgb;
            uint px = uint(round(c.r * 255.0f)) | (uint(round(c.g * 255.0f)) << 8) |
                      (uint(round(c.b * 255.0f)) << 16);
            h = (h ^ px) * 16777619u;
        }
    return temporal_fmix32(h);
}
static uint temporal_current_hash(texture2d<float, access::read> image,
    texture2d<uint, access::read> exclusion, uint excluded, uint2 origin)
{
    if (!excluded) return temporal_context_hash(image, origin);
    int2 lo = int2(origin) - 8;
    int2 limit = int2(image.get_width(), image.get_height()) - 1;
    uint h = 2166136261u;
    for (uint y = 0; y < 32; ++y)
        for (uint x = 0; x < 32; ++x) {
            uint2 pt = uint2(clamp(lo + int2(x, y), int2(0), limit));
            uint px = 0u;
            if (!exclusion.read(pt).r) {
                float3 c = image.read(pt).rgb;
                px = uint(round(c.r * 255.0f)) | (uint(round(c.g * 255.0f)) << 8) |
                     (uint(round(c.b * 255.0f)) << 16);
            }
            h = (h ^ px) * 16777619u;
        }
    return temporal_fmix32(h);
}
static uint3 temporal_pixel(texture2d<float, access::read> image, uint2 point)
{
    return uint3(round(image.read(point).rgb * 255.0f));
}
static uint3 temporal_current_pixel(texture2d<float, access::read> image,
    texture2d<uint, access::read> exclusion, uint excluded, uint2 point)
{
    if (excluded && exclusion.read(point).r) return uint3(0);
    return temporal_pixel(image, point);
}
static void temporal_mirror_write(device uchar4 *mirror, uint width, uint2 pos, float3 c)
{
    mirror[pos.y * width + pos.x] = uchar4(uchar(round(c.b * 255.0f)),
        uchar(round(c.g * 255.0f)), uchar(round(c.r * 255.0f)), 255);
}

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
    device uchar4 *mirror [[buffer(2)]], uint2 pos [[thread_position_in_grid]])
{
    if (pos.x < p.width && pos.y < p.height) {
        reference.write(float4(0), pos);
        temporal_mirror_write(mirror, p.width, pos, float3(0));
    }
    if (pos.x < p.width * 2 && pos.y < p.height * 2) residual.write(float4(0), pos);
    if (pos.x < p.block_columns && pos.y < p.block_rows) times[pos.y * p.block_columns + pos.x] = -1.0f;
}

/* Seed input identity even for blocks whose neural residual is still missing.
 * This distinguishes missing detail from an actual neighbouring pixel change. */
kernel void temporal_seed(texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> reference [[texture(1)]],
    texture2d<uint, access::read> exclusion [[texture(2)]],
    device uchar4 *mirror [[buffer(0)]],
    constant TemporalParameters &p [[buffer(1)]], uint2 pos [[thread_position_in_grid]])
{
    if (pos.x < p.width && pos.y < p.height) {
        float4 c = (p.excluded && exclusion.read(pos).r) ? float4(0.0f, 0.0f, 0.0f, 1.0f) : source.read(pos);
        reference.write(c, pos);
        temporal_mirror_write(mirror, p.width, pos, c.rgb);
    }
}

/* Dispatch exactly 16x16 threads per group. Only this compact block metadata
 * is exposed to the CPU scheduler; pixels remain in GPU presentation textures. */
kernel void temporal_detect(texture2d<float, access::read> current [[texture(0)]],
    texture2d<float, access::read> previous [[texture(1)]],
    texture2d<float, access::read> reference [[texture(2)]],
    texture2d<uint, access::write> changes [[texture(3)]],
    texture2d<uint, access::read> exclusion [[texture(4)]],
    device const float *times [[buffer(0)]], device uint *metadata [[buffer(1)]],
    constant TemporalParameters &p [[buffer(2)]], device const uint *provisional [[buffer(3)]],
    uint2 pos [[thread_position_in_grid]], uint2 group [[threadgroup_position_in_grid]],
    uint local [[thread_index_in_threadgroup]])
{
    threadgroup atomic_uint flags;
    if (local == 0) {
        atomic_store_explicit(&flags, 0u, memory_order_relaxed);
        if (provisional[group.y * p.block_columns + group.x])
            atomic_fetch_or_explicit(&flags, 8u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (pos.x < p.width && pos.y < p.height && !(p.excluded && exclusion.read(pos).r)) {
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
    device const uint *provisional [[buffer(4)]],
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
    accepted[index] = eligible && !(bits & 2u) &&
        ((bits & 4u) || times[index] < 0 || provisional[index]);
}

kernel void temporal_commit_input(texture2d<float, access::read> job [[texture(0)]],
    texture2d<float, access::write> reference [[texture(1)]],
    device const uint *accepted [[buffer(0)]], device uchar4 *mirror [[buffer(1)]],
    constant TemporalParameters &p [[buffer(2)]], uint2 pos [[thread_position_in_grid]])
{
    if (pos.x >= p.width || pos.y >= p.height) return;
    uint index = (pos.y / 16) * p.block_columns + pos.x / 16;
    if (accepted[index]) {
        float4 c = job.read(pos);
        reference.write(c, pos);
        temporal_mirror_write(mirror, p.width, pos, c.rgb);
    }
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
    device uint *provisional [[buffer(3)]],
    texture2d<uint, access::read> changed [[texture(0)]], uint2 block [[thread_position_in_grid]])
{
    if (block.x >= p.block_columns || block.y >= p.block_rows) return;
    uint index = block.y * p.block_columns + block.x;
    if (accepted[index]) {
        times[index] = p.time;
        provisional[index] = 0;
        return;
    }
    for (int y = int(block.y) - 2; y <= int(block.y) + 2; ++y)
        for (int x = int(block.x) - 2; x <= int(block.x) + 2; ++x) {
            if (x < 0 || y < 0 || x >= int(p.block_columns) || y >= int(p.block_rows) ||
                (x == int(block.x) && y == int(block.y))) continue;
            uint n = uint(y) * p.block_columns + uint(x);
            if (accepted[n] && (changed.read(uint2(x, y)).r & 4u)) {
                times[index] = -1.0f;
                provisional[index] = 0;
                return;
            }
        }
}

struct TemporalVertex { float4 position [[position]]; float2 uv; };
vertex TemporalVertex temporal_vertex(uint index [[vertex_id]])
{
    float2 uv = float2((index << 1) & 2u, index & 2u);
    return {float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv};
}

kernel void temporal_mask(texture2d<uint, access::read> changes [[texture(0)]],
    texture2d<float, access::write> weights [[texture(1)]],
    texture2d<uint, access::read> exclusion [[texture(2)]],
    texture2d<float, access::read> exclusionWeight [[texture(3)]],
    device const float *times [[buffer(0)]], constant TemporalParameters &p [[buffer(1)]],
    uint2 pos [[thread_position_in_grid]])
{
    if (pos.x >= p.width || pos.y >= p.height) return;
    if (p.excluded && exclusion.read(pos).r) { weights.write(float4(0), pos); return; }
    float2 source = float2(pos) + 0.5f;
    int2 block = clamp(int2(source / 16.0f), int2(0), int2(p.block_columns, p.block_rows) - 1);
    int radius = int(ceil((p.halo + p.feather) / 16.0f)) + 1;
    float distance = p.halo + p.feather, fade = 1.0f;
    for (int y = max(0, block.y-radius); y <= min(int(p.block_rows)-1, block.y+radius); ++y)
        for (int x = max(0, block.x-radius); x <= min(int(p.block_columns)-1, block.x+radius); ++x)
        {
            float2 low = float2(x, y) * 16.0f, high = low + 16.0f;
            float2 delta = max(max(low-source, source-high), 0.0f);
            float separation = max(delta.x, delta.y);
            if (changes.read(uint2(x, y)).r & 1u) distance = min(distance, separation);
            float start = times[y * p.block_columns + x];
            float maturity = start < 0 ? 0 : clamp((p.time-start) / max(p.fade_seconds, 0.001f), 0.0f, 1.0f);
            float edge = smoothstep(0.0f, max(p.feather, 1.0f), separation);
            fade = min(fade, mix(maturity, 1.0f, edge));
        }
    weights.write(float4(smoothstep(p.halo, p.halo + p.feather, distance) * fade *
        exclusionWeight.read(pos).r), pos);
}

fragment float4 temporal_fragment(TemporalVertex varying [[stage_in]],
    texture2d<float, access::read> current [[texture(0)]],
    texture2d<float, access::sample> residual [[texture(1)]],
    texture2d<float, access::sample> weights [[texture(2)]],
    texture2d<float, access::sample> exclusion [[texture(3)]],
    texture2d<float, access::sample> spatial [[texture(4)]],
    constant TemporalParameters &p [[buffer(0)]])
{
    constexpr sampler linear_sampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float keep = weights.sample(linear_sampler, varying.uv).r;
    float gate = exclusion.sample(linear_sampler, varying.uv).r;
    float3 base = bilinear_linear(current, varying.uv);
    float3 detail = residual.sample(linear_sampler, varying.uv).rgb;
    float3 mixed = base + keep * detail;
    if (p.use_spatial)
        mixed += (1.0f - keep) * gate * (decode_srgb(spatial.sample(linear_sampler, varying.uv).rgb) - base);
    return float4(encode_srgb(mixed), 1.0f);
}

/* ---- Block residual library ---- */

static uint temporal_lib_blocks(constant TemporalLibraryParameters &lp)
{
    return ((lp.width + 15u) / 16u) * ((lp.height + 15u) / 16u);
}

/* Per-block snapshot validity for the slot being stored. */
kernel void temporal_library_valid(device uchar *valid [[buffer(0)]],
    device const float *times [[buffer(1)]], device const uint *provisional [[buffer(2)]],
    constant TemporalLibraryParameters &lp [[buffer(3)]],
    uint index [[thread_position_in_grid]])
{
    if (index >= temporal_lib_blocks(lp)) return;
    valid[index] = (times[index] >= 0.0f && !provisional[index]) ? 1 : 0;
}

/* Index every even-offset 16x16 window of the slot input whose covered blocks
 * are all valid. Keys are content hashes; zero is reserved for empty entries. */
kernel void temporal_library_index(texture2d<float, access::read> input [[texture(0)]],
    device TemporalLibraryEntry *table [[buffer(0)]],
    device const uchar *valid [[buffer(1)]],
    constant TemporalLibraryParameters &lp [[buffer(2)]],
    uint2 pos [[thread_position_in_grid]])
{
    uint x = pos.x * 2u, y = pos.y * 2u;
    if (x + 16u > lp.width || y + 16u > lp.height) return;
    uint bc = (lp.width + 15u) / 16u;
    uint x1 = x / 16u, x2 = (x + 15u) / 16u, y1 = y / 16u, y2 = (y + 15u) / 16u;
    for (uint by = y1; by <= y2; ++by)
        for (uint bx = x1; bx <= x2; ++bx)
            if (!valid[by * bc + bx]) return;
    uint key = temporal_context_hash(input, uint2(x, y));
    if (!key) key = 1;
    uint found = 0;
    for (uint i = 0; i < 32u; ++i) {
        uint entry = (key + i) & lp.table_mask;
        uint expected = 0;
        while (!atomic_compare_exchange_weak_explicit(&table[entry].key, &expected, key,
                memory_order_relaxed, memory_order_relaxed) && !expected)
            expected = 0;
        if (!expected) {
            table[entry].value = x | (y << 16);
            return;
        }
        if (expected == key && ++found >= 4u) return;
    }
}

/* Per-block content hash of a stored slot, for CPU redundancy checks. */
kernel void temporal_library_block_hash(texture2d<float, access::read> input [[texture(0)]],
    device uint *hashes [[buffer(0)]], device const uchar *valid [[buffer(1)]],
    constant TemporalLibraryParameters &lp [[buffer(2)]],
    uint2 block [[thread_position_in_grid]])
{
    uint bc = (lp.width + 15u) / 16u, br = (lp.height + 15u) / 16u;
    if (block.x >= bc || block.y >= br) return;
    uint index = block.y * bc + block.x;
    hashes[index] = valid[index] ? temporal_window_hash(input, block * 16u) : 0;
}

/* One 16x16 threadgroup per dirty block. Threads 0..3 hash the four parity
 * windows of the current frame and look up every active slot; all threads then
 * verify candidates in order against 8px context, then 19px context for
 * exactness. */
kernel void temporal_library_probe(texture2d<float, access::read> current [[texture(0)]],
    const array<texture2d<float, access::read>, 16> inputs [[texture(1)]],
    texture2d<uint, access::read> changes [[texture(17)]],
    texture2d<uint, access::read> exclusion [[texture(18)]],
    device const uchar *valid [[buffer(0)]],
    device const uint2 *tables [[buffer(1)]],
    device uint4 *matches [[buffer(2)]],
    device atomic_uint *stats [[buffer(3)]],
    device atomic_uint *hits [[buffer(4)]],
    constant TemporalLibraryParameters &lp [[buffer(5)]],
    device const uint *provisional [[buffer(6)]],
    uint2 group [[threadgroup_position_in_grid]], uint local [[thread_index_in_threadgroup]])
{
    const uint2 parities[4] = {uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 1)};
    uint bc = (lp.width + 15u) / 16u;
    uint blocks = temporal_lib_blocks(lp);
    uint index = group.y * bc + group.x;
    threadgroup atomic_uint mismatches, extended;
    threadgroup uint candidateCount[4];
    threadgroup int2 candidateShift[4][80];
    threadgroup uchar candidateSlot[4][80];
    threadgroup int winner, fallback;
    if (local == 0) {
        atomic_store_explicit(&mismatches, 0u, memory_order_relaxed);
        atomic_store_explicit(&extended, 0u, memory_order_relaxed);
        winner = -1;
        fallback = -1;
        candidateCount[0] = candidateCount[1] = candidateCount[2] = candidateCount[3] = 0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lp.ring_only) {
        if (provisional[index] != 2u) return;
    } else if (!(changes.read(group).r & 1u)) {
        if (local == 0) matches[index] = uint4(0);
        return;
    }
    if (local < 4) {
        if (local == 0) {
            for (uint si = 0; si < lp.slot_count; ++si) {
                uint slot = lp.slot_order[si];
                if (valid[slot * blocks + index]) {
                    uint n = candidateCount[0]++;
                    candidateShift[0][n] = int2(0);
                    candidateSlot[0][n] = uchar(slot);
                }
            }
        }
        uint2 g = group * 16u + parities[local];
        if (g.x + 16u <= lp.width && g.y + 16u <= lp.height) {
            uint key = temporal_current_hash(current, exclusion, lp.excluded, g);
            if (!key) key = 1;
            for (uint si = 0; si < lp.slot_count; ++si) {
                uint slot = lp.slot_order[si];
                device const uint2 *table = tables + slot * (lp.table_mask + 1u);
                uint found = 0;
                for (uint i = 0; i < 32u && found < 4u; ++i) {
                    uint2 entry = table[(key + i) & lp.table_mask];
                    if (!entry.x) break;
                    if (entry.x == key) {
                        uint2 source = uint2(entry.y & 0xffffu, entry.y >> 16);
                        ++found;
                        if (local == 0 && source.x == g.x && source.y == g.y &&
                            valid[slot * blocks + index]) continue;
                        uint n = candidateCount[local]++;
                        candidateShift[local][n] = int2(g) - int2(source);
                        candidateSlot[local][n] = uchar(slot);
                    }
                }
            }
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const uint side = 16u + 2u * lp.halo;
    for (uint e = 0; e < 4u; ++e)
        for (uint i = 0; i < candidateCount[e]; ++i) {
            if (winner >= 0 || (!lp.exact_translation && fallback >= 0)) break;
            int2 d = candidateShift[e][i];
            uint slot = candidateSlot[e][i];
            int2 g = int2(group * 16u);
            int2 source = g - d;
            bool covered = source.x >= 0 && source.y >= 0 &&
                source.x + 16 <= int(lp.width) && source.y + 16 <= int(lp.height);
            if (covered) {
                int bx1 = source.x / 16, bx2 = (source.x + 15) / 16;
                int by1 = source.y / 16, by2 = (source.y + 15) / 16;
                for (int by = by1; covered && by <= by2; ++by)
                    for (int bx = bx1; covered && bx <= bx2; ++bx)
                        covered = valid[slot * blocks + uint(by * int(bc) + bx)] != 0;
            }
            if (local == 0 && !covered)
                atomic_fetch_add_explicit(&mismatches, 65536u, memory_order_relaxed);
            /* 32x32 context [G-8, G+24): four pixels per thread. */
            for (uint k = 0; k < 4u; ++k) {
                uint f = local + k * 256u;
                int2 point = g + int2(int(f % 32u), int(f / 32u)) - 8;
                int2 other = point - d;
                if (point.x < 0 || point.y < 0 || point.x >= int(lp.width) ||
                    point.y >= int(lp.height)) continue;
                if (other.x < 0 || other.y < 0 || other.x >= int(lp.width) ||
                    other.y >= int(lp.height) ||
                    any(temporal_current_pixel(current, exclusion, lp.excluded, uint2(point)) !=
                        temporal_pixel(inputs[slot], uint2(other))))
                    atomic_fetch_add_explicit(&mismatches, 1u, memory_order_relaxed);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (atomic_load_explicit(&mismatches, memory_order_relaxed) == 0) {
                bool axes = lp.exact_translation != 0;
                for (uint a = 0; axes && a < 2u; ++a) {
                    if (!d[a]) continue;
                    const int limit = a ? int(lp.height) : int(lp.width);
                    axes = g[a] - int(lp.halo) >= 0 && g[a] + 16 + int(lp.halo) <= limit &&
                        source[a] - int(lp.halo) >= 0 && source[a] + 16 + int(lp.halo) <= limit;
                }
                if (axes) {
                    if (local == 0)
                        atomic_store_explicit(&extended, 0u, memory_order_relaxed);
                    threadgroup_barrier(mem_flags::mem_threadgroup);
                    /* 54x54 context [G-19, G+35) must also match exactly. */
                    for (uint f = local; f < side * side; f += 256u) {
                        int2 point = g + int2(int(f % side), int(f / side)) - int(lp.halo);
                        int2 other = point - d;
                        if (point.x < 0 || point.y < 0 || point.x >= int(lp.width) ||
                            point.y >= int(lp.height)) continue;
                        if (other.x < 0 || other.y < 0 || other.x >= int(lp.width) ||
                            other.y >= int(lp.height) ||
                            any(temporal_current_pixel(current, exclusion, lp.excluded, uint2(point)) !=
                                temporal_pixel(inputs[slot], uint2(other))))
                            atomic_fetch_add_explicit(&extended, 1u, memory_order_relaxed);
                    }
                    threadgroup_barrier(mem_flags::mem_threadgroup);
                    if (local == 0) {
                        if (atomic_load_explicit(&extended, memory_order_relaxed) == 0)
                            winner = int(e * 80u + i);
                        else if (fallback < 0)
                            fallback = int(e * 80u + i);
                    }
                } else if (local == 0 && fallback < 0) {
                    fallback = int(e * 80u + i);
                }
            } else if (local == 0) {
                atomic_store_explicit(&mismatches, 0u, memory_order_relaxed);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
    const int chosen = winner >= 0 ? winner : (lp.ring_only ? -1 : fallback);
    if (chosen >= 0) {
        uint e = uint(chosen) / 80u;
        int2 d = candidateShift[e][uint(chosen) % 80u];
        uint slot = candidateSlot[e][uint(chosen) % 80u];
        if (local == 0) {
            matches[index] = uint4(slot + 1u, as_type<uint>(d.x), as_type<uint>(d.y),
                winner >= 0 ? 1u : 0u);
            atomic_fetch_add_explicit(&stats[0], 1u, memory_order_relaxed);
            atomic_fetch_add_explicit(&stats[winner >= 0 ? 1u : 2u], 1u, memory_order_relaxed);
            atomic_fetch_add_explicit(&hits[slot], 1u, memory_order_relaxed);
        }
    } else if (local == 0 && !lp.ring_only) {
        matches[index] = uint4(0);
        atomic_fetch_add_explicit(&stats[0], 1u, memory_order_relaxed);
    }
}

/* Translated residual for matched blocks, sampled at 2x coordinates. Pixels in
 * a matched block's verified 8px context ring take the same residual: their
 * content was proven identical to the slot, so earlier admissions cannot leave
 * stale boundary residual there. */
kernel void temporal_library_apply_residual(texture2d<float, access::write> residual [[texture(0)]],
    const array<texture2d<float, access::read>, 16> residuals [[texture(1)]],
    device const uint4 *matches [[buffer(0)]],
    constant TemporalLibraryParameters &lp [[buffer(1)]],
    uint2 pos [[thread_position_in_grid]])
{
    if (pos.x >= lp.width * 2u || pos.y >= lp.height * 2u) return;
    int bc = int((lp.width + 15u) / 16u), br = int((lp.height + 15u) / 16u);
    int2 block = int2(pos / 32u);
    int2 point = int2(pos / 2u);
    uint4 m = matches[uint(block.y * bc + block.x)];
    if (!m.x) {
        /* Look for a matched neighbour whose [G-8, G+24) context covers this
         * pixel; the band stays within the 3x3 block neighbourhood. */
        for (int dy = -1; !m.x && dy <= 1; ++dy)
            for (int dx = -1; !m.x && dx <= 1; ++dx) {
                if (!dx && !dy) continue;
                int2 other = block + int2(dx, dy);
                if (other.x < 0 || other.y < 0 || other.x >= bc || other.y >= br) continue;
                uint4 candidate = matches[uint(other.y * bc + other.x)];
                /* Only exact neighbours may write into clean blocks' rings; a
                 * provisional approximation must never become permanent. */
                if (!candidate.x || !candidate.w) continue;
                int2 g = other * 16;
                if (point.x >= g.x - 8 && point.x < g.x + 24 &&
                    point.y >= g.y - 8 && point.y < g.y + 24) m = candidate;
            }
        if (!m.x) return;
    }
    int2 d = int2(as_type<int>(m.y), as_type<int>(m.z));
    int2 source = int2(pos) - 2 * d;
    if (source.x < 0 || source.y < 0 || source.x >= int(lp.width * 2u) ||
        source.y >= int(lp.height * 2u)) return;
    residual.write(residuals[m.x - 1u].read(uint2(source)), pos);
}

/* Matched blocks publish the current input as their new reference so delta
 * detection and job snapshots stay consistent with the displayed content. */
kernel void temporal_library_apply_input(texture2d<float, access::read> current [[texture(0)]],
    texture2d<float, access::write> reference [[texture(1)]],
    texture2d<uint, access::read> exclusion [[texture(2)]],
    device uchar4 *mirror [[buffer(0)]],
    device const uint4 *matches [[buffer(1)]],
    constant TemporalLibraryParameters &lp [[buffer(2)]],
    uint2 pos [[thread_position_in_grid]])
{
    if (pos.x >= lp.width || pos.y >= lp.height) return;
    uint bc = (lp.width + 15u) / 16u;
    if (!matches[(pos.y / 16u) * bc + pos.x / 16u].x) return;
    float4 c = (lp.excluded && exclusion.read(pos).r) ? float4(0.0f, 0.0f, 0.0f, 1.0f) : current.read(pos);
    reference.write(c, pos);
    temporal_mirror_write(mirror, lp.width, pos, c.rgb);
}

/* A matched neighbor can still shift this block's residual context, so blocks
 * invalidated by an adjacent halo write rejoin the dirty set this frame. */
kernel void temporal_library_invalidate(
    texture2d<uint, access::read> changes [[texture(0)]],
    texture2d<uint, access::read> exclusion [[texture(1)]],
    device float *times [[buffer(0)]], device uint *provisional [[buffer(1)]],
    device const uint4 *matches [[buffer(2)]],
    constant TemporalLibraryParameters &lp [[buffer(3)]],
    uint2 block [[thread_position_in_grid]])
{
    uint bc = (lp.width + 15u) / 16u, br = (lp.height + 15u) / 16u;
    if (block.x >= bc || block.y >= br) return;
    uint index = block.y * bc + block.x;
    if (matches[index].x) return;
    if (lp.excluded) {
        bool any_unmasked = false;
        for (uint py = 0; !any_unmasked && py < 16u; ++py)
            for (uint px = 0; !any_unmasked && px < 16u; ++px) {
                uint2 pt = block * 16u + uint2(px, py);
                if (pt.x < lp.width && pt.y < lp.height && !exclusion.read(pt).r)
                    any_unmasked = true;
            }
        if (!any_unmasked) return;
    }
    for (int y = int(block.y) - 2; y <= int(block.y) + 2; ++y)
        for (int x = int(block.x) - 2; x <= int(block.x) + 2; ++x) {
            if (x < 0 || y < 0 || x >= int(bc) || y >= int(br) ||
                (x == int(block.x) && y == int(block.y))) continue;
            uint n = uint(y) * bc + uint(x);
            if (matches[n].x && (changes.read(uint2(x, y)).r & 4u)) {
                times[index] = -1.0f;
                provisional[index] = lp.exact_translation ? 2u : 0u;
                return;
            }
        }
}

/* Matched blocks leave the dirty set; non-exact matches stay provisional so
 * detail shows immediately while quiet-interval inference refines them. */
kernel void temporal_library_fixup(texture2d<uint, access::read_write> changes [[texture(0)]],
    device uint *metadata [[buffer(0)]], device float *times [[buffer(1)]],
    device uint *provisional [[buffer(2)]], device const uint4 *matches [[buffer(3)]],
    constant TemporalLibraryParameters &lp [[buffer(4)]],
    uint2 block [[thread_position_in_grid]])
{
    uint bc = (lp.width + 15u) / 16u, br = (lp.height + 15u) / 16u;
    if (block.x >= bc || block.y >= br) return;
    uint index = block.y * bc + block.x;
    uint4 m = matches[index];
    if (!m.x) {
        if (times[index] < 0) {
            uint bits = changes.read(block).r | 1u;
            changes.write(uint4(bits, 0, 0, 0), block);
            metadata[index] = bits;
            provisional[index] = 0u;
        }
        return;
    }
    bool exact = m.w != 0;
    uint bits = changes.read(block).r & ~13u;
    if (!exact) bits |= 8u;
    changes.write(uint4(bits, 0, 0, 0), block);
    metadata[index] = bits;
    provisional[index] = exact ? 0u : 1u;
    float start = times[index];
    times[index] = min(start >= 0 ? start : INFINITY, lp.time - lp.fade_seconds);
}
