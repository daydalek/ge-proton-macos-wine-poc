/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "backend.h"
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <vector>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static unsigned calls;
static unsigned creates;
static bool cpu_broken;
class CPU final : public UpscaleBackend {
    std::vector<uint8_t> upscale2x(const wgdi_image &input) override {
        ++calls;
        return std::vector<uint8_t>(size_t(input.width) * input.height * 16, 42);
    }
};
std::unique_ptr<UpscaleBackend> create_realcugan_cpu(const std::string &, unsigned)
{
    ++creates;
    if (cpu_broken) throw std::runtime_error("cpu model broken");
    return std::make_unique<CPU>();
}
std::unique_ptr<UpscaleBackend> create_realesrgan_cpu(const std::string &, unsigned)
{
    ++creates;
    if (cpu_broken) throw std::runtime_error("cpu model broken");
    return std::make_unique<CPU>();
}

static const char *FAKE_HELPER = R"PY(#!/usr/bin/env python3
import mmap, os, struct
OLD = 288 + 4*1024*1024*20
log = os.environ.get('WGDI_FAKE_LOG')
if log:
    open(log, 'a').write('spawn\n')
size = os.fstat(3).st_size
mode = os.environ.get('WGDI_FAKE_MODE', 'v2')
if mode == 'legacy' and size != OLD: os._exit(3)
if mode == 'v2' and size not in (OLD, OLD + 32): os._exit(3)
m = mmap.mmap(3, 0)
while True:
    try: cmd = os.read(4, 1)
    except OSError: break
    if not cmd: break
    magic, ver, seq, w, h, status, ns = struct.unpack_from('=IIIIIIQ', m, 0)
    cols, rows = (w + 255) // 256, (h + 255) // 256
    if mode in ('model-error', 'tamper-width', 'tamper-version') or magic != 0x5747434D:
        if mode == 'tamper-width':
            struct.pack_into('=I', m, 20, 0); struct.pack_into('=I', m, 12, w + 16)
        elif mode == 'tamper-version':
            struct.pack_into('=I', m, 20, 0); struct.pack_into('=I', m, 4, ver ^ 3)
        else:
            struct.pack_into('=I', m, 20, 1); m[32:43] = b'model error'
        os.write(4, b'D'); continue
    sel = [1] * 256
    if ver == 2:
        words = struct.unpack_from('=8I', m, OLD)
        sel = [int(bool(words[i // 32] & (1 << (i % 32)))) for i in range(256)]
        if not any(sel[:cols * rows]) or any(sel[cols * rows:]):
            struct.pack_into('=I', m, 20, 1); m[32:40] = b'bad mask'; os.write(4, b'D'); continue
    off = 288 + w * h * 4
    for ty in range(rows):
        for tx in range(cols):
            x0, x1 = tx * 512, min(tx * 512 + 512, w * 2)
            mark = ty * cols + tx + 1 if sel[ty * cols + tx] else 0xa5
            row = bytes([mark]) * ((x1 - x0) * 4)
            for y in range(ty * 512, min(ty * 512 + 512, h * 2)):
                at = off + (y * w * 2 + x0) * 4
                m[at:at + len(row)] = row
    struct.pack_into('=I', m, 20, 0)
    os.write(4, b'D')
)PY";

static void check_regions(UpscaleBackend *backend, bool from_helper)
{
    const unsigned w = 2049, h = 769;
    const size_t cols = (w + 255) / 256, rows = (h + 255) / 256;
    std::vector<uint8_t> in(size_t(w) * 4 * h, 0x11), out(size_t(w) * 8 * h * 2, 0xa5);
    wgdi_image rin{in.data(), in.size(), w * 4, w, h};
    wgdi_image rout{out.data(), out.size(), w * 8, w * 2, h * 2};
    uint32_t sel[36] = {};
    sel[0] = sel[7] = sel[8] = sel[31] = sel[32] = sel[35] = 1;
    assert(!backend->upscale_regions(rin, rout, nullptr, cols * rows));
    assert(!backend->upscale_regions(rin, rout, sel, cols * rows - 1));
    assert(!backend->upscale_regions(rin, rout, sel, 257));
    assert(backend->upscale_regions(rin, rout, sel, cols * rows));
    for (size_t ty = 0; ty < rows; ++ty)
        for (size_t tx = 0; tx < cols; ++tx)
            for (size_t y = ty * 512; y < std::min(ty * 512 + 512, size_t(h) * 2); ++y)
                for (size_t x = tx * 512; x < std::min(tx * 512 + 512, size_t(w) * 2); ++x)
                {
                    const uint8_t *pixel = out.data() + y * w * 8 + x * 4;
                    if (sel[ty * cols + tx])
                        assert(from_helper ? pixel[0] == ty * cols + tx + 1 : pixel[0] == 42);
                    else assert(pixel[0] == 0xa5);
                }
}

static unsigned spawn_count(const std::string &root)
{
    std::ifstream log(root + "/spawns.log");
    unsigned count = 0; std::string line;
    while (std::getline(log, line)) ++count;
    return count;
}

int main()
{
    char path[] = "/tmp/wgdi-client-test-XXXXXX";
    assert(mkdtemp(path));
    const std::string root(path);
    uint8_t pixels[16] = {};
    wgdi_image input{pixels, sizeof(pixels), 8, 2, 2};
    // Missing model: preserve automatic CPU fallback.
    auto backend = create_realcugan(root, 2, NeuralModel::RealCUGAN);
    assert(backend->upscale2x(input) == std::vector<uint8_t>(64, 42));
    // Model present, helper absent: failed spawn releases all handles.
    std::filesystem::create_directories(root + "/coreml/realcugan-2x2.mlmodelc");
    assert(backend->upscale2x(input)[0] == 42);
    backend.reset();
    // Peer exits while a request is in flight: survive EOF/SIGPIPE, reap child,
    // and retain the CPU backend for subsequent frames.
    std::ofstream(root + "/winegdi-coreml-helper") << "#!/bin/sh\nexit 0\n";
    chmod((root + "/winegdi-coreml-helper").c_str(), 0700);
    backend = create_realcugan(root, 2, NeuralModel::RealCUGAN);
    assert(backend->upscale2x(input)[0] == 42);
    assert(backend->upscale2x(input)[0] == 42);
    backend.reset();
    assert(calls == 4);
    // The AnimeVideo-v3 selection shares the same helper protocol and fallback.
    backend = create_realcugan(root, 2, NeuralModel::AnimeVideoV3);
    assert(backend->upscale2x(input)[0] == 42);
    backend.reset();
    assert(calls == 5);
    std::ofstream(root + "/winegdi-coreml-helper") << FAKE_HELPER;
    chmod((root + "/winegdi-coreml-helper").c_str(), 0700);
    setenv("WGDI_FAKE_LOG", (root + "/spawns.log").c_str(), 1);
    setenv("WGDI_FAKE_MODE", "v2", 1);
    const unsigned createsBefore = creates;
    backend = create_realcugan(root, 2, NeuralModel::RealCUGAN);
    check_regions(backend.get(), true);
    assert(calls == 5 && creates == createsBefore);
    assert(backend->upscale2x(input).size() == 64);
    assert(calls == 5 && creates == createsBefore);
    backend.reset();
    assert(spawn_count(root) == 1);
    setenv("WGDI_FAKE_MODE", "legacy", 1);
    backend = create_realcugan(root, 2, NeuralModel::RealCUGAN);
    check_regions(backend.get(), true);
    assert(calls == 5 && creates == createsBefore);
    backend.reset();
    assert(spawn_count(root) == 3);
    setenv("WGDI_FAKE_MODE", "model-error", 1);
    backend = create_realcugan(root, 2, NeuralModel::RealCUGAN);
    check_regions(backend.get(), false);
    assert(calls == 6 && creates == createsBefore + 1);
    check_regions(backend.get(), false);
    assert(calls == 7 && creates == createsBefore + 1);
    backend.reset();
    assert(spawn_count(root) == 4);
    for (const char *mode : {"tamper-width", "tamper-version"}) {
        setenv("WGDI_FAKE_MODE", mode, 1);
        backend = create_realcugan(root, 2, NeuralModel::RealCUGAN);
        check_regions(backend.get(), false);
        backend.reset();
    }
    assert(calls == 9 && spawn_count(root) == 6);
    cpu_broken = true;
    backend = create_realcugan(root, 2, NeuralModel::RealCUGAN);
    {
        std::vector<uint8_t> big(size_t(2049) * 4 * 769, 0x11);
        wgdi_image bin{big.data(), big.size(), 2049 * 4, 2049, 769};
        bool threw = false;
        try { backend->upscale2x(bin); } catch (const std::exception &) { threw = true; }
        assert(threw);
    }
    cpu_broken = false;
    backend.reset();
    setenv("WINE_GDI_REALCUGAN_BACKEND", "cpu", 1);
    const unsigned eager = creates;
    backend = create_realcugan(root, 2, NeuralModel::RealCUGAN);
    assert(creates == eager + 1);
    backend.reset();
    unsetenv("WINE_GDI_REALCUGAN_BACKEND");
    int status;
    assert(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
    std::filesystem::remove_all(root);
}
