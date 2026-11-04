/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "backend.h"
#include "wine_gdi_coreml_protocol.h"
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <spawn.h>
#include <poll.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <set>
#include <chrono>

extern char **environ;

class CoreMLBackend final : public UpscaleBackend
{
    std::string resources;
    std::string family;
    NeuralModel model;
    unsigned threads;
    std::unique_ptr<UpscaleBackend> fallback;
    std::set<uint64_t> failedShapes;
    std::set<uint64_t> reportedShapes;
    pid_t child = -1;
    int socket = -1;
    wgdi_coreml_frame *frame = nullptr;
    size_t mappingBytes = 0;
    uint32_t sequence = 0;
    unsigned previousWidth = 0, previousHeight = 0;
    bool disabled = false;
    bool legacy = false;
    bool answered = false;

    void stop()
    {
        if (socket >= 0) { close(socket); socket = -1; }
        if (child > 0) {
            // Closing the socket permits normal exit; SIGKILL bounds cleanup
            // even when a system model load or prediction is still in flight.
            kill(child, SIGKILL);
            while (waitpid(child, nullptr, 0) < 0 && errno == EINTR) {}
            child = -1;
        }
        if (frame) { munmap(frame, mappingBytes); frame = nullptr; mappingBytes = 0; }
    }

    void start()
    {
        const size_t bytes = legacy ? (size_t)WGDI_COREML_BYTES : (size_t)WGDI_COREML_EXTENDED_BYTES;
        char path[] = "/tmp/whisky-coreml-XXXXXX";
        int original = mkstemp(path);
        if (original < 0) throw std::runtime_error("Core ML shared memory creation failed");
        unlink(path);
        int shared = fcntl(original, F_DUPFD_CLOEXEC, 10);
        close(original);
        if (shared < 0) throw std::runtime_error("Core ML shared descriptor duplication failed");
        if (ftruncate(shared, off_t(bytes))) { close(shared); throw std::runtime_error("Core ML shared memory sizing failed"); }
        void *mapping = mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, shared, 0);
        if (mapping == MAP_FAILED) { close(shared); throw std::runtime_error("Core ML mapping failed"); }
        frame = static_cast<wgdi_coreml_frame *>(mapping);
        mappingBytes = bytes;
        previousWidth = previousHeight = 0;
        int pair[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) { close(shared); throw std::runtime_error("Core ML socket failed"); }
        socket = pair[0];
        fcntl(socket, F_SETFD, FD_CLOEXEC);
        int remote = fcntl(pair[1], F_DUPFD_CLOEXEC, 10);
        close(pair[1]);
        if (remote < 0) { close(shared); throw std::runtime_error("Core ML socket duplication failed"); }
        int enabled = 1;
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_adddup2(&actions, shared, 3);
        posix_spawn_file_actions_adddup2(&actions, remote, 4);
        posix_spawn_file_actions_addclose(&actions, shared);
        posix_spawn_file_actions_addclose(&actions, remote);
        const std::string executable = resources + "/winegdi-coreml-helper";
        char *args[] = {const_cast<char *>(executable.c_str()), const_cast<char *>("--serve"),
                        const_cast<char *>(resources.c_str()), const_cast<char *>(family.c_str()), nullptr};
        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
        int error = posix_spawn(&child, executable.c_str(), &actions, &attr, args, environ);
        posix_spawnattr_destroy(&attr);
        posix_spawn_file_actions_destroy(&actions);
        close(shared);
        close(remote);
        if (error) { child = -1; throw std::runtime_error("Core ML arm64 helper launch failed"); }
    }

    void issue(const wgdi_image &input, uint32_t version, const uint32_t *selection, size_t count)
    {
        frame->magic = WGDI_COREML_MAGIC;
        frame->version = version;
        frame->sequence = ++sequence;
        frame->width = input.width;
        frame->height = input.height;
        frame->status = 1;
        auto *pixels = reinterpret_cast<uint8_t *>(frame + 1);
        const bool full = input.width != previousWidth || input.height != previousHeight;
        for (unsigned y = 0; y < input.height; ++y)
            if (full || memcmp(pixels + size_t(y) * input.width * 4,
                               input.pixels + y * input.stride, input.width * 4))
                memcpy(pixels + size_t(y) * input.width * 4,
                       input.pixels + y * input.stride, input.width * 4);
        previousWidth = input.width;
        previousHeight = input.height;
        if (version == WGDI_COREML_VERSION_REGIONS) {
            auto *bits = reinterpret_cast<uint32_t *>(pixels + size_t(WGDI_COREML_PIXELS) * 20);
            memset(bits, 0, WGDI_COREML_SELECTION_WORDS * 4);
            for (size_t i = 0; i < count; ++i)
                if (selection[i]) bits[i / 32] |= 1u << (i % 32);
        }
        char command = 'R', reply = 0;
        if (send(socket, &command, 1, 0) != 1) throw std::runtime_error("Core ML request failed");
        pollfd descriptor{socket, POLLIN, 0};
        int ready;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(45);
        do {
            const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
                deadline - std::chrono::steady_clock::now()).count();
            if (remaining <= 0) { ready = 0; break; }
            ready = poll(&descriptor, 1, int(remaining));
        } while (ready < 0 && errno == EINTR);
        if (ready != 1 || recv(socket, &reply, 1, 0) != 1 || reply != 'D')
            throw std::runtime_error("Core ML helper timeout or disconnect");
        answered = true;
        if (frame->sequence != sequence || frame->magic != WGDI_COREML_MAGIC ||
            frame->width != input.width || frame->height != input.height ||
            frame->version != version)
            throw std::runtime_error("Core ML helper returned a malformed response");
    }

    const uint8_t *sharedOutput(const wgdi_image &input) const
    {
        return reinterpret_cast<const uint8_t *>(frame + 1) +
               size_t(input.width) * input.height * 4;
    }

    void copySelected(const wgdi_image &input, wgdi_image &output,
                      const uint32_t *selection, const uint8_t *result)
    {
        const size_t columns = (size_t(input.width) + 255) / 256;
        const size_t rows = (size_t(input.height) + 255) / 256;
        for (size_t ty = 0; ty < rows; ++ty)
            for (size_t tx = 0; tx < columns; ++tx) {
                if (!selection[ty * columns + tx]) continue;
                const size_t x0 = tx * 512, x1 = std::min(tx * 512 + 512, size_t(input.width) * 2);
                const size_t y1 = std::min(ty * 512 + 512, size_t(input.height) * 2);
                for (size_t y = ty * 512; y < y1; ++y)
                    memcpy(output.pixels + y * output.stride + x0 * 4,
                           result + (y * size_t(input.width) * 2 + x0) * 4, (x1 - x0) * 4);
            }
    }

    void serve(const wgdi_image &input, uint32_t version, const uint32_t *selection, size_t count)
    {
        // No access() probe for an exact-size model: the helper tiles a frame with
        // whichever model does ship, and only it knows whether one exists. Asking
        // here would send every other window size straight to the CPU network.
        if (!frame) start();
        for (unsigned attempt = 0;; ++attempt) {
            try {
                issue(input, legacy ? WGDI_COREML_VERSION : version, selection, count);
                return;
            } catch (const std::exception &) {
                if (legacy || answered || attempt) throw;
                stop();
                legacy = true;
                start();
            }
        }
    }

public:
    CoreMLBackend(const std::string &directory, unsigned count, NeuralModel selection)
        : resources(directory),
          family(selection == NeuralModel::AnimeVideoV3 ? "animevideov3" : "realcugan"),
          model(selection), threads(count)
    {
        const char *backend = std::getenv("WINE_GDI_REALCUGAN_BACKEND");
        disabled = backend && std::strcmp(backend, "cpu") == 0;
        // Only an explicit CPU choice validates the model at create time; the
        // default path loads it lazily on the first Core ML fallback.
        if (disabled) cpu();
    }
    ~CoreMLBackend() override { stop(); }

    UpscaleBackend *cpu()
    {
        if (!fallback)
            fallback = model == NeuralModel::AnimeVideoV3 ? create_realesrgan_cpu(resources, threads)
                                                          : create_realcugan_cpu(resources, threads);
        return fallback.get();
    }

    bool predict(const wgdi_image &input, uint32_t version,
                 const uint32_t *selection, size_t count)
    {
        const uint64_t shape = (uint64_t(input.width) << 32) | input.height;
        if (disabled || failedShapes.count(shape)) return false;
        try {
            serve(input, version, selection, count);
        } catch (const std::exception &e) {
            fprintf(stderr, "winegdi: Core ML fallback: %s\n", e.what());
            disabled = true;
            stop();
            return false;
        }
        if (frame->status) {
            failedShapes.insert(shape);
            fprintf(stderr, "winegdi: Core ML %ux%u fallback: %.255s\n",
                    input.width, input.height, frame->error);
            return false;
        }
        return true;
    }

public:
    std::vector<uint8_t> upscale2x(const wgdi_image &input) override
    {
        const uint64_t shape = (uint64_t(input.width) << 32) | input.height;
        if (predict(input, WGDI_COREML_VERSION, nullptr, 0)) {
            if (reportedShapes.insert(shape).second)
                fprintf(stderr, "winegdi: %s Core ML arm64 %ux%u CPU_AND_NE, prediction %.3f ms\n",
                        model == NeuralModel::AnimeVideoV3 ? "AnimeVideo-v3" : "Real-CUGAN",
                        input.width, input.height, frame->inference_ns / 1000000.0);
            const uint8_t *out = sharedOutput(input);
            return std::vector<uint8_t>(out, out + size_t(input.width) * input.height * 16);
        }
        return cpu()->upscale2x(input);
    }

    bool upscale_regions(const wgdi_image &input, wgdi_image &output,
                         const uint32_t *selection, size_t count) override
    {
        const size_t columns = (size_t(input.width) + 255) / 256;
        const size_t rows = (size_t(input.height) + 255) / 256;
        if (!selection || count != columns * rows || count > WGDI_COREML_SELECTION_WORDS * 32u)
            return false;
        if (predict(input, WGDI_COREML_VERSION_REGIONS, selection, count)) {
            copySelected(input, output, selection, sharedOutput(input));
            return true;
        }
        auto pixels = cpu()->upscale2x(input);
        if (pixels.size() != size_t(input.width) * input.height * 16)
            throw std::runtime_error("fallback returned an invalid output buffer");
        copySelected(input, output, selection, pixels.data());
        return true;
    }
};

std::unique_ptr<UpscaleBackend> create_realcugan(const std::string &resources, unsigned threads, NeuralModel model)
{
    return std::make_unique<CoreMLBackend>(resources, threads, model);
}
