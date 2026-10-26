/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "backend.h"
#include <cassert>
#include <cerrno>
#include <filesystem>
#include <fstream>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static unsigned calls;
class CPU final : public UpscaleBackend {
    std::vector<uint8_t> upscale2x(const wgdi_image &input) override {
        ++calls;
        return std::vector<uint8_t>(size_t(input.width) * input.height * 16, 42);
    }
};
std::unique_ptr<UpscaleBackend> create_realcugan_cpu(const std::string &, unsigned)
{
    return std::make_unique<CPU>();
}

int main()
{
    char path[] = "/tmp/wgdi-client-test-XXXXXX";
    assert(mkdtemp(path));
    const std::string root(path);
    uint8_t pixels[16] = {};
    wgdi_image input{pixels, sizeof(pixels), 8, 2, 2};
    // Missing model: preserve automatic CPU fallback.
    auto backend = create_realcugan(root, 2);
    assert(backend->upscale2x(input) == std::vector<uint8_t>(64, 42));
    // Model present, helper absent: failed spawn releases all handles.
    std::filesystem::create_directories(root + "/coreml/realcugan-2x2.mlmodelc");
    assert(backend->upscale2x(input)[0] == 42);
    backend.reset();
    // Peer exits while a request is in flight: survive EOF/SIGPIPE, reap child,
    // and retain the CPU backend for subsequent frames.
    std::ofstream(root + "/winegdi-coreml-helper") << "#!/bin/sh\nexit 0\n";
    chmod((root + "/winegdi-coreml-helper").c_str(), 0700);
    backend = create_realcugan(root, 2);
    assert(backend->upscale2x(input)[0] == 42);
    assert(backend->upscale2x(input)[0] == 42);
    backend.reset();
    assert(calls == 4);
    int status;
    assert(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
    std::filesystem::remove_all(root);
}
