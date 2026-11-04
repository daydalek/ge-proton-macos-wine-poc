/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "../src/content-cache.h"
#include <sys/file.h>
#include <cassert>
#include <cstdio>
#include <thread>

using wgdi::ContentCache;
using wgdi::Digest;

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { \
    std::fprintf(stderr, "FAIL %d: %s\n", __LINE__, #cond); ++failures; } } while (0)

static Digest scope(const char *text)
{
    wgdi::Hasher hasher;
    hasher.update(text, std::strlen(text));
    return hasher.digest();
}

static std::vector<uint8_t> bytes(uint8_t seed, size_t n)
{
    std::vector<uint8_t> v(n);
    for (size_t i = 0; i < n; ++i) v[i] = uint8_t(seed + i * 7 + (i >> 3));
    return v;
}

static std::string test_root()
{
    char tmpl[] = "/tmp/wgdi-cache-test-XXXXXX";
    assert(mkdtemp(tmpl));
    return tmpl;
}

static Digest key_for(const Digest &sc, const std::vector<uint8_t> &in)
{
    wgdi::Hasher hasher;
    hasher.update(sc.data(), sc.size());
    hasher.update(in.data(), in.size());
    return hasher.digest();
}

static std::string record_path(const std::string &dir, const Digest &sc,
                               const std::vector<uint8_t> &in)
{
    return dir + "/" + wgdi::hex_digest(key_for(sc, in)) + ".bin";
}

static void put_u32(std::vector<uint8_t> &r, size_t off, uint32_t v)
{
    for (unsigned i = 0; i < 4; ++i) r[off + i] = uint8_t(v >> (i * 8));
}

static void put_u64(std::vector<uint8_t> &r, size_t off, uint64_t v)
{
    for (unsigned i = 0; i < 8; ++i) r[off + i] = uint8_t(v >> (i * 8));
}

static void write_v1_record(const std::string &path, const Digest &key,
                            const std::vector<uint8_t> &in,
                            const std::vector<uint8_t> &out)
{
    std::vector<uint8_t> record(120 + in.size() + out.size());
    put_u32(record, 0, 0x57474443u);
    put_u32(record, 4, 1);
    std::memcpy(record.data() + 8, key.data(), key.size());
    put_u64(record, 40, in.size());
    put_u64(record, 48, out.size());
    wgdi::Hasher hasher;
    hasher.update(in.data(), in.size());
    const Digest inputDigest = hasher.digest();
    hasher = wgdi::Hasher();
    hasher.update(out.data(), out.size());
    const Digest outputDigest = hasher.digest();
    std::memcpy(record.data() + 56, inputDigest.data(), inputDigest.size());
    std::memcpy(record.data() + 88, outputDigest.data(), outputDigest.size());
    std::memcpy(record.data() + 120, in.data(), in.size());
    std::memcpy(record.data() + 120 + in.size(), out.data(), out.size());
    FILE *f = fopen(path.c_str(), "wb");
    assert(f);
    assert(fwrite(record.data(), 1, record.size(), f) == record.size());
    assert(!fclose(f));
}

static size_t count_records(const std::string &dir)
{
    size_t n = 0;
    for (const auto &entry : std::filesystem::directory_iterator(dir))
        if (entry.path().filename().string().size() == 68) ++n;
    return n;
}

int main()
{
    const std::string root = test_root();
    const auto scene = scope("realcugan|model-a|256x256");
    const auto inA = bytes(3, 1024), inB = bytes(77, 1024);
    const auto outA = bytes(200, 3072), outB = bytes(90, 3072);
    std::vector<uint8_t> got;

    {
        ContentCache cache(ContentCache::Mode::memory, 1 << 20, 0, "");
        got.assign(outA.size(), 0);
        cache.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        cache.put(scene, inB.data(), inB.size(), outB.data(), outB.size());
        CHECK(cache.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        CHECK(got == outA);
        CHECK(cache.get(scene, inB.data(), inB.size(), got.data(), got.size()));
        CHECK(got == outB);
        CHECK(cache.stats().memoryHits == 2 && cache.stats().misses == 0);
        auto mutated = inA;
        mutated.back() ^= 0xFF;
        CHECK(!cache.get(scene, mutated.data(), mutated.size(), got.data(), got.size()));
        mutated = inA; mutated[0] ^= 0xFF;
        CHECK(!cache.get(scene, mutated.data(), mutated.size(), got.data(), got.size()));
        for (const char *other : {"realcugan|model-b|256x256", "animevideov3|model-a|256x256",
                                  "realcugan|model-a|384x384", "esrgan|model-a|256x256"})
            CHECK(!cache.get(scope(other), inA.data(), inA.size(), got.data(), got.size()));
        CHECK(!cache.get(scene, inA.data(), inA.size(), got.data(), got.size() - 1));
    }

    {
        const uint64_t entryBytes = 1024 + 256;
        ContentCache cache(ContentCache::Mode::memory, entryBytes * 3, 0, "");
        auto io = [&](uint8_t seed) {
            auto in = bytes(seed, 512), out = bytes(seed ^ 0x5A, 1024);
            cache.put(scene, in.data(), in.size(), out.data(), out.size());
            return std::pair{in, out};
        };
        auto [k1, v1] = io(1);
        io(2);
        auto [k3, v3] = io(3);
        CHECK(cache.memory_bytes() <= entryBytes * 3);
        io(4);
        CHECK(cache.memory_bytes() <= entryBytes * 3);
        got.assign(v1.size(), 0);
        CHECK(!cache.get(scene, k1.data(), k1.size(), got.data(), got.size()));
        CHECK(cache.get(scene, k3.data(), k3.size(), got.data(), got.size()));
        CHECK(got == v3);
        auto big = bytes(9, 1 << 20), bigOut = bytes(8, 1024);
        cache.put(scene, big.data(), big.size(), bigOut.data(), bigOut.size());
        got.assign(bigOut.size(), 0);
        CHECK(cache.get(scene, big.data(), big.size(), got.data(), got.size()));
        CHECK(got == bigOut);
        CHECK(cache.memory_bytes() <= entryBytes * 3);
    }

    {
        ContentCache cache(ContentCache::Mode::memory, 1024 + 256, 0, "");
        auto hugeIn = bytes(9, 1 << 20), smallOut = bytes(8, 1024);
        cache.put(scene, hugeIn.data(), hugeIn.size(), smallOut.data(), smallOut.size());
        CHECK(cache.memory_bytes() == 1024 + 256);
        got.assign(smallOut.size(), 0);
        CHECK(cache.get(scene, hugeIn.data(), hugeIn.size(), got.data(), got.size()));
        CHECK(got == smallOut);
    }

    {
        ContentCache none(ContentCache::Mode::memory, 0, 0, "");
        none.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        got.assign(outA.size(), 0);
        CHECK(!none.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        ContentCache off(ContentCache::Mode::off, 1 << 20, 1 << 20, "/tmp/x");
        off.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        CHECK(!off.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        CHECK(off.stats().stores == 0 && off.stats().misses == 1);
        ContentCache bounds(ContentCache::Mode::memory, 1 << 20, 0, "");
        uint8_t any = 1;
        bounds.put(scene, &any, 0, &any, 4);
        bounds.put(scene, &any, 4, &any, 0);
        bounds.put(scene, nullptr, 4, &any, 4);
        bounds.put(scene, &any, 4, nullptr, 4);
        CHECK(!bounds.get(scene, &any, 0, &any, 4));
        CHECK(!bounds.get(scene, nullptr, 4, &any, 4));
        CHECK(!bounds.get(scene, &any, 4, nullptr, 4));
        CHECK(bounds.stats().stores == 0);
    }

    {
        const std::string dir = root + "/memory-only";
        ContentCache cache(ContentCache::Mode::memory, 1 << 20, 4ull << 30, dir);
        cache.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        got.assign(outA.size(), 0);
        CHECK(cache.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        std::error_code ec;
        CHECK(!std::filesystem::exists(dir, ec));
    }

    {
        const std::string dir = root + "/persistent";
        const auto ns = scope("ns");
        {
            ContentCache cache(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
            cache.put(ns, inA.data(), inA.size(), outA.data(), outA.size());
            cache.put(ns, inB.data(), inB.size(), outB.data(), outB.size());
            std::error_code ec;
            CHECK(std::filesystem::exists(dir, ec));
        }
        {
            ContentCache cache(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
            got.assign(outA.size(), 0);
            CHECK(cache.get(ns, inA.data(), inA.size(), got.data(), got.size()));
            CHECK(got == outA);
            CHECK(cache.stats().diskHits == 1);
            CHECK(cache.disk_entries() == 2);
        }
        const std::string path = record_path(dir, ns, inA);
        for (int variant = 0; variant < 3; ++variant) {
            {
                ContentCache valid(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
                valid.put(ns, inA.data(), inA.size(), outA.data(), outA.size());
                ContentCache check(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
                got.assign(outA.size(), 0);
                CHECK(check.get(ns, inA.data(), inA.size(), got.data(), got.size()));
            }
            const off_t size = off_t(88 + outA.size());
            const int fd = open(path.c_str(), O_WRONLY);
            CHECK(fd >= 0);
            switch (variant) {
            case 0: {
                const uint8_t b = 0xFF;
                CHECK(pwrite(fd, &b, 1, size - 1) == 1);
                break;
            }
            case 1:
                CHECK(pwrite(fd, "\xFF", 1, 56) == 1);
                break;
            case 2:
                CHECK(pwrite(fd, "\x01", 1, 48) == 1);
                break;
            }
            close(fd);
            ContentCache cache(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
            got.assign(outA.size(), 0);
            CHECK(!cache.get(ns, inA.data(), inA.size(), got.data(), got.size()));
        }
        assert(!truncate(path.c_str(), 64));
        ContentCache cache(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
        got.assign(outA.size(), 0);
        CHECK(!cache.get(ns, inA.data(), inA.size(), got.data(), got.size()));
        CHECK(cache.get(ns, inB.data(), inB.size(), got.data(), got.size()));
        CHECK(got == outB);
        CHECK(!cache.get(ns, inB.data(), inB.size(), got.data(), got.size() / 2));
    }

    {
        const std::string dir = root + "/legacy-v1";
        ContentCache cache(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
        write_v1_record(record_path(dir, scene, inA), key_for(scene, inA), inA, outA);
        got.assign(outA.size(), 0);
        CHECK(!cache.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        cache.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        CHECK(cache.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        CHECK(got == outA);
        std::error_code ec;
        CHECK(std::filesystem::file_size(record_path(dir, scene, inA), ec) == 88 + outA.size());
        CHECK(count_records(dir) == 1);
    }

    {
        const std::string dir = root + "/input-identity";
        ContentCache cache(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
        cache.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        got.assign(outA.size(), 0);
        CHECK(!cache.get(scene, inB.data(), inB.size(), got.data(), got.size()));
        auto mutated = inA;
        mutated[0] ^= 0xFF;
        CHECK(!cache.get(scene, mutated.data(), mutated.size(), got.data(), got.size()));
        CHECK(cache.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        CHECK(got == outA);
        CHECK(count_records(dir) == 1);
    }

    {
        const std::string dir = root + "/output-integrity";
        ContentCache cache(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
        cache.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        const std::string path = record_path(dir, scene, inA);
        const int fd = open(path.c_str(), O_WRONLY);
        CHECK(fd >= 0);
        CHECK(pwrite(fd, "\xFF", 1, 88) == 1);
        close(fd);
        ContentCache reader(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
        got.assign(outA.size(), 0);
        CHECK(!reader.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        reader.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        CHECK(reader.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        CHECK(got == outA);
    }

    {
        const std::string dir = root + "/readonly";
        std::filesystem::create_directories(dir);
        chmod(dir.c_str(), 0500);
        ContentCache cache(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
        cache.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        got.assign(outA.size(), 0);
        CHECK(!cache.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        chmod(dir.c_str(), 0700);
        const std::string file = root + "/not-a-dir";
        { FILE *f = fopen(file.c_str(), "w"); fputs("x", f); fclose(f); }
        ContentCache blocked(ContentCache::Mode::persistent, 0, 4ull << 30, file + "/sub");
        blocked.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        CHECK(!blocked.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        CHECK(!blocked.disk_ready());
    }

    {
        const std::string real = root + "/real", link = root + "/link";
        std::filesystem::create_directories(real);
        assert(!symlink(real.c_str(), link.c_str()));
        ContentCache viaLink(ContentCache::Mode::persistent, 0, 4ull << 30, link);
        viaLink.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        CHECK(!viaLink.disk_ready());
        CHECK(count_records(real) == 0);
        got.assign(outA.size(), 0);
        CHECK(!viaLink.get(scene, inA.data(), inA.size(), got.data(), got.size()));
    }

    {
        const std::string base = root + "/namespaces";
        const std::string a = base + "/" + wgdi::cache_namespace("/prefix", "/games/a");
        const std::string b = base + "/" + wgdi::cache_namespace("/prefix", "/games/b");
        CHECK(a != b);
        ContentCache cacheA(ContentCache::Mode::persistent, 0, 4ull << 30, a);
        ContentCache cacheB(ContentCache::Mode::persistent, 0, 4ull << 30, b);
        cacheA.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        got.assign(outA.size(), 0);
        CHECK(!cacheB.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        CHECK(wgdi::cache_namespace("/prefix", nullptr) ==
              wgdi::cache_namespace("/prefix", ""));
    }

    {
        const std::string dir = root + "/promotion";
        {
            ContentCache writer(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
            writer.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        }
        ContentCache reader(ContentCache::Mode::persistent, 1 << 20, 4ull << 30, dir);
        got.assign(outA.size(), 0);
        CHECK(reader.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        CHECK(reader.stats().diskHits == 1);
        CHECK(unlink(record_path(dir, scene, inA).c_str()) == 0);
        got.assign(outA.size(), 0);
        CHECK(reader.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        CHECK(got == outA);
        CHECK(reader.stats().memoryHits == 1);
    }

    {
        const std::string dir = root + "/accounting";
        const uint64_t record = 88 + outA.size();
        ContentCache cache(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
        cache.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        CHECK(cache.disk_bytes() == record);
        auto outA2 = bytes(33, outA.size());
        cache.put(scene, inA.data(), inA.size(), outA2.data(), outA2.size());
        CHECK(cache.disk_bytes() == record);
        CHECK(cache.disk_entries() == 1);
        auto small = bytes(9, 128);
        cache.put(scene, inA.data(), inA.size(), small.data(), small.size());
        CHECK(cache.disk_bytes() == 88 + small.size());
        got.assign(small.size(), 0);
        CHECK(cache.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        CHECK(got == small);
    }

    {
        const std::string dir = root + "/quota";
        const uint64_t per = 88 + 1024;
        ContentCache cache(ContentCache::Mode::persistent, 0, per * 3, dir);
        auto io = [&](uint8_t seed) {
            auto in = bytes(seed, 512), out = bytes(seed ^ 0x5A, 1024);
            cache.put(scope("q"), in.data(), in.size(), out.data(), out.size());
            usleep(15000);
            return std::pair{in, out};
        };
        auto [k1, v1] = io(11);
        io(12);
        auto [k3, v3] = io(13);
        CHECK(cache.disk_bytes() <= per * 3);
        auto [k4, v4] = io(14);
        CHECK(cache.disk_bytes() <= per * 3);
        got.assign(v1.size(), 0);
        CHECK(!cache.get(scope("q"), k1.data(), k1.size(), got.data(), got.size()));
        CHECK(cache.get(scope("q"), k3.data(), k3.size(), got.data(), got.size()));
        CHECK(cache.get(scope("q"), k4.data(), k4.size(), got.data(), got.size()));
        const std::string foreign = dir + "/" + std::string(64, 'z') + ".bin";
        { FILE *f = fopen(foreign.c_str(), "w"); fputs("keep", f); fclose(f); }
        const std::string alsoForeign = dir + "/notes.txt";
        { FILE *f = fopen(alsoForeign.c_str(), "w"); fputs("keep", f); fclose(f); }
        auto big = bytes(5, 1 << 20), bigOut = bytes(6, 1 << 20);
        cache.put(scope("q"), big.data(), big.size(), bigOut.data(), bigOut.size());
        CHECK(!cache.get(scope("q"), big.data(), big.size(), got.data(), got.size()));
        CHECK(cache.get(scope("q"), k3.data(), k3.size(), got.data(), got.size()));
        std::error_code ec;
        CHECK(std::filesystem::exists(foreign, ec));
        CHECK(std::filesystem::exists(alsoForeign, ec));
    }

    {
        const std::string dir = root + "/two-helpers";
        const uint64_t per = 88 + 1024;
        ContentCache cacheA(ContentCache::Mode::persistent, 0, per * 2, dir);
        auto io = [](uint8_t seed) {
            return std::pair{bytes(seed, 512), bytes(seed ^ 0x5A, 1024)};
        };
        auto [k1, v1] = io(21);
        cacheA.put(scope("t"), k1.data(), k1.size(), v1.data(), v1.size());
        ContentCache cacheB(ContentCache::Mode::persistent, 0, per * 2, dir);
        auto [k2, v2] = io(22);
        auto [k3, v3] = io(23);
        cacheA.put(scope("t"), k2.data(), k2.size(), v2.data(), v2.size());
        cacheA.put(scope("t"), k3.data(), k3.size(), v3.data(), v3.size());
        CHECK(cacheA.disk_bytes() <= per * 2);
        auto [k4, v4] = io(24);
        cacheB.put(scope("t"), k4.data(), k4.size(), v4.data(), v4.size());
        CHECK(cacheB.disk_bytes() <= per * 2);
        ContentCache reader(ContentCache::Mode::persistent, 0, per * 2, dir);
        got.assign(v1.size(), 0);
        CHECK(!reader.get(scope("t"), k1.data(), k1.size(), got.data(), got.size()));
        CHECK(!reader.get(scope("t"), k2.data(), k2.size(), got.data(), got.size()));
        CHECK(reader.get(scope("t"), k3.data(), k3.size(), got.data(), got.size()));
        CHECK(reader.get(scope("t"), k4.data(), k4.size(), got.data(), got.size()));
        CHECK(count_records(dir) <= 2);
    }

    {
        const std::string dir = root + "/lock-held";
        ContentCache cache(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
        const int lock = open((dir + "/.lock").c_str(), O_RDWR);
        CHECK(lock >= 0);
        CHECK(flock(lock, LOCK_EX | LOCK_NB) == 0);
        cache.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        CHECK(count_records(dir) == 0);
        got.assign(outA.size(), 0);
        CHECK(!cache.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        flock(lock, LOCK_UN);
        close(lock);
        cache.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        CHECK(count_records(dir) == 1);
        CHECK(cache.get(scene, inA.data(), inA.size(), got.data(), got.size()));
        CHECK(got == outA);
    }

    {
        const std::string dir = root + "/concurrent";
        std::vector<std::thread> workers;
        for (int t = 0; t < 4; ++t) {
            workers.emplace_back([&, t] {
                ContentCache cache(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
                for (int i = 0; i < 12; ++i) {
                    auto in = bytes(uint8_t(t * 16 + i), 512);
                    auto out = bytes(uint8_t(200 - t * 16 - i), 1024);
                    cache.put(scope("w"), in.data(), in.size(), out.data(), out.size());
                }
            });
        }
        for (auto &worker : workers) worker.join();
        ContentCache reader(ContentCache::Mode::persistent, 0, 4ull << 30, dir);
        size_t verified = 0;
        for (int t = 0; t < 4; ++t) {
            for (int i = 0; i < 12; ++i) {
                auto in = bytes(uint8_t(t * 16 + i), 512);
                auto out = bytes(uint8_t(200 - t * 16 - i), 1024);
                got.assign(out.size(), 0);
                if (reader.get(scope("w"), in.data(), in.size(), got.data(), got.size())) {
                    CHECK(got == out);
                    ++verified;
                }
            }
        }
        CHECK(verified > 0);
        CHECK(count_records(dir) == verified);
    }

    {
        CHECK(wgdi::cache_mode("off") == ContentCache::Mode::off);
        CHECK(wgdi::cache_mode("persistent") == ContentCache::Mode::persistent);
        CHECK(wgdi::cache_mode("memory") == ContentCache::Mode::memory);
        CHECK(wgdi::cache_mode("surprise") == ContentCache::Mode::memory);
        CHECK(wgdi::cache_mode(nullptr) == ContentCache::Mode::memory);
        CHECK(wgdi::cache_limit_bytes("0", 4096).value() == 0);
        CHECK(wgdi::cache_limit_bytes("256", 4096).value() == (256ull << 20));
        CHECK(wgdi::cache_limit_bytes("5000", 4096).value() == (4096ull << 20));
        CHECK(wgdi::cache_limit_bytes("70000", 65536).value() == (65536ull << 20));
        CHECK(!wgdi::cache_limit_bytes("-1", 4096));
        CHECK(!wgdi::cache_limit_bytes("12x", 4096));
        CHECK(!wgdi::cache_limit_bytes("99999999999999999999999999", 4096));
        CHECK(!wgdi::cache_limit_bytes("", 4096));
        CHECK(!wgdi::cache_limit_bytes(nullptr, 4096));
        setenv("WINE_GDI_CACHE_MODE", "persistent", 1);
        setenv("WINE_GDI_CACHE_DIRECTORY", (root + "/env").c_str(), 1);
        setenv("WINEPREFIX", "/bottle", 1);
        setenv("WINE_GDI_CACHE_GAME", "/games/t.exe", 1);
        auto cache = wgdi::content_cache_from_environment();
        CHECK(cache.mode() == ContentCache::Mode::persistent);
        CHECK(cache.directory().find("/bottle") == std::string::npos);
        CHECK(cache.directory().find("/games/t.exe") == std::string::npos);
        CHECK(cache.directory().rfind(root + "/env/", 0) == 0);
        unsetenv("WINE_GDI_CACHE_MODE");
        unsetenv("WINE_GDI_CACHE_DIRECTORY");
        unsetenv("WINEPREFIX");
        unsetenv("WINE_GDI_CACHE_GAME");
        auto fallback = wgdi::content_cache_from_environment();
        CHECK(fallback.mode() == ContentCache::Mode::memory);
    }

    {
        const std::string one = root + "/model-one", two = root + "/model-two";
        std::filesystem::create_directories(one + "/sub");
        std::filesystem::create_directories(two + "/sub");
        for (const std::string *rootPath : {&one, &two}) {
            FILE *f = fopen((*rootPath + "/weights.bin").c_str(), "wb");
            fputs("weights", f); fclose(f);
            f = fopen((*rootPath + "/sub/meta.plist").c_str(), "wb");
            fputs("meta", f); fclose(f);
        }
        const auto h1 = wgdi::hash_directory(one), h2 = wgdi::hash_directory(two);
        CHECK(h1 && h2 && *h1 == *h2);
        FILE *f = fopen((one + "/weights.bin").c_str(), "ab");
        fputc(0, f); fclose(f);
        const auto h3 = wgdi::hash_directory(one);
        CHECK(h3 && *h3 != *h1);
        CHECK(wgdi::hash_directory(one + "/missing") == std::nullopt);
        assert(!symlink((one + "/weights.bin").c_str(), (one + "/linked.bin").c_str()));
        const auto h4 = wgdi::hash_directory(one);
        CHECK(h4 && *h4 == *h3);
    }

    {
        const std::string dir = root + "/fdleak";
        const auto countFds = [] {
            DIR *d = opendir("/dev/fd");
            size_t n = 0;
            struct dirent *e;
            while ((e = readdir(d))) if (e->d_name[0] != '.') ++n;
            closedir(d);
            return n;
        };
        const size_t before = countFds();
        for (int i = 0; i < 12; ++i) {
            ContentCache cache(ContentCache::Mode::persistent, 0, 1ull << 30, dir);
            cache.put(scene, inA.data(), inA.size(), outA.data(), outA.size());
        }
        CHECK(countFds() == before);
        {
            ContentCache held(ContentCache::Mode::persistent, 0, 1ull << 30, dir);
            const int lock = open((dir + "/.lock").c_str(), O_RDWR);
            CHECK(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0);
            for (int i = 0; i < 8; ++i)
                held.put(scene, inB.data(), inB.size(), outB.data(), outB.size());
            flock(lock, LOCK_UN); close(lock);
        }
        CHECK(countFds() == before);
    }

    {
        const std::string dir = root + "/replace-quota";
        const uint64_t recA = 88 + 1024, recB = 88 + 2048;
        auto io = [](uint8_t seed) {
            return std::pair{bytes(seed, 512), bytes(seed ^ 0x5A, 1024)};
        };
        auto [k1, v1] = io(31);
        auto [k2, v2] = io(32);
        ContentCache cache(ContentCache::Mode::persistent, 0, recA * 2, dir);
        usleep(15000);
        cache.put(scope("r"), k1.data(), k1.size(), v1.data(), v1.size());
        usleep(15000);
        cache.put(scope("r"), k2.data(), k2.size(), v2.data(), v2.size());
        CHECK(cache.disk_bytes() == recA * 2);
        auto bigOut = bytes(77, 2048);
        cache.put(scope("r"), k1.data(), k1.size(), bigOut.data(), bigOut.size());
        CHECK(cache.disk_bytes() <= recA * 2);
        CHECK(cache.disk_bytes() == recB || cache.disk_bytes() == recA);
        ContentCache reader(ContentCache::Mode::persistent, 0, recA * 2, dir);
        got.assign(bigOut.size(), 0);
        CHECK(reader.get(scope("r"), k1.data(), k1.size(), got.data(), got.size()));
        CHECK(got == bigOut);
        got.assign(1024, 0);
        if (cache.disk_bytes() == recB)
            CHECK(!reader.get(scope("r"), k2.data(), k2.size(), got.data(), got.size()));
        else
            CHECK(reader.get(scope("r"), k2.data(), k2.size(), got.data(), got.size()));
    }

    if (failures) {
        std::fprintf(stderr, "%d cache checks failed\n", failures);
        return 1;
    }
    std::puts("content-cache: all checks passed");
    return 0;
}
