/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef WINE_GDI_UPSCALER_H
#define WINE_GDI_UPSCALER_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WGDI_UPSCALER_ABI 1u
enum wgdi_algorithm { WGDI_ANIME4K = 1, WGDI_REALCUGAN = 2 };

/* Opaque sRGB BGRA8, top row first. Padding bytes belong to the caller.
 * The caller owns all pixels; process() retains zero caller pointers. */
struct wgdi_image
{
    uint8_t *pixels;
    size_t buffer_bytes;
    size_t stride;
    uint32_t width, height;
};

struct wgdi_options
{
    uint32_t size;
    uint32_t algorithm;
    const char *resource_directory;
    uint32_t cpu_threads;
};

/* A context is confined to one worker. Every function catches C++ exceptions.
 * create/process report errors through a caller-owned, NUL-terminated buffer.
 * process returns 0 on success and -1 on failure, preserving Wine's fallback. */
struct wgdi_upscaler_api
{
    uint32_t abi_version;
    uint32_t size;
    void *(*create)(const struct wgdi_options *, char *error, size_t error_size);
    int (*process)(void *, const struct wgdi_image *, struct wgdi_image *, char *, size_t);
    void (*destroy)(void *);
};

const struct wgdi_upscaler_api *wgdi_upscaler_get_api(uint32_t abi_version);

#ifdef __cplusplus
}
#endif
#endif
