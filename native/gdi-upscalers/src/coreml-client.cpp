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
    unsigned threads;
    std::unique_ptr<UpscaleBackend> fallback;
    std::set<uint64_t> failedShapes;
    std::set<uint64_t> reportedShapes;
    pid_t child = -1;
    int socket = -1;
    wgdi_coreml_frame *frame = nullptr;
    uint32_t sequence = 0;
    bool disabled = false;

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
        if (frame) { munmap(frame, WGDI_COREML_BYTES); frame = nullptr; }
    }

    void start()
    {
        char path[] = "/tmp/whisky-coreml-XXXXXX";
        int original = mkstemp(path);
        if (original < 0) throw std::runtime_error("Core ML shared memory creation failed");
        unlink(path);
        int shared = fcntl(original, F_DUPFD_CLOEXEC, 10);
        close(original);
        if (shared < 0) throw std::runtime_error("Core ML shared descriptor duplication failed");
        if (ftruncate(shared, WGDI_COREML_BYTES)) { close(shared); throw std::runtime_error("Core ML shared memory sizing failed"); }
        void *mapping = mmap(nullptr, WGDI_COREML_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, shared, 0);
        if (mapping == MAP_FAILED) { close(shared); throw std::runtime_error("Core ML mapping failed"); }
        frame = static_cast<wgdi_coreml_frame *>(mapping);
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
                        const_cast<char *>(resources.c_str()), nullptr};
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

public:
    CoreMLBackend(const std::string &directory, unsigned count) : resources(directory), threads(count)
    {
        const char *backend = std::getenv("WINE_GDI_REALCUGAN_BACKEND");
        disabled = backend && std::strcmp(backend, "cpu") == 0;
        // Preserve ABI create-time model validation and keep a ready fallback.
        fallback = create_realcugan_cpu(resources, threads);
    }
    ~CoreMLBackend() override { stop(); }

    std::vector<uint8_t> upscale2x(const wgdi_image &input) override
    {
        const uint64_t shape = (uint64_t(input.width) << 32) | input.height;
        const std::string model = resources + "/coreml/realcugan-" + std::to_string(input.width) +
            "x" + std::to_string(input.height) + ".mlmodelc";
        if (!disabled && !failedShapes.count(shape) && access(model.c_str(), R_OK) == 0) {
            try {
                if (!frame) start();
                frame->magic = WGDI_COREML_MAGIC;
                frame->version = WGDI_COREML_VERSION;
                frame->sequence = ++sequence;
                frame->width = input.width;
                frame->height = input.height;
                frame->status = 1;
                auto *pixels = reinterpret_cast<uint8_t *>(frame + 1);
                for (unsigned y = 0; y < input.height; ++y)
                    memcpy(pixels + size_t(y) * input.width * 4, input.pixels + y * input.stride, input.width * 4);
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
                if (ready != 1 || recv(socket, &reply, 1, 0) != 1 || reply != 'D' || frame->sequence != sequence)
                    throw std::runtime_error("Core ML helper timeout or disconnect");
                if (frame->status) {
                    failedShapes.insert(shape);
                    fprintf(stderr, "winegdi: Core ML %ux%u fallback: %.255s\n", input.width, input.height, frame->error);
                } else {
                    if (reportedShapes.insert(shape).second)
                        fprintf(stderr, "winegdi: Real-CUGAN Core ML arm64 %ux%u CPU_AND_NE, prediction %.3f ms\n",
                                input.width, input.height, frame->inference_ns / 1000000.0);
                    const uint8_t *out = pixels + size_t(input.width) * input.height * 4;
                    return std::vector<uint8_t>(out, out + size_t(input.width) * input.height * 16);
                }
            } catch (const std::exception &e) {
                fprintf(stderr, "winegdi: Core ML fallback: %s\n", e.what());
                disabled = true;
                stop();
            }
        }
        return fallback->upscale2x(input);
    }
};

std::unique_ptr<UpscaleBackend> create_realcugan(const std::string &resources, unsigned threads)
{
    return std::make_unique<CoreMLBackend>(resources, threads);
}

