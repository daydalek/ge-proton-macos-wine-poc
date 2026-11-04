/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef WINE_GDI_EXCLUSIONS_H
#define WINE_GDI_EXCLUSIONS_H
#include <ctype.h>
#include "wine_gdi_frame_diff.h"
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#define WGDI_EXCLUSION_LIMIT 16
struct wgdi_exclusion { unsigned x, y, width, height; };
struct wgdi_exclusions { unsigned count, relative; struct wgdi_exclusion rects[WGDI_EXCLUSION_LIMIT]; };

/* Source pixels, top-left origin. Invalid input disables the entire mask. */
static inline int wgdi_parse_exclusions(const char *text, struct wgdi_exclusions *mask)
{
    struct wgdi_exclusions parsed = {0, 0, {{0, 0, 0, 0}}};
    *mask = parsed;
    if (!text) return 1;
    if (!strncmp(text, "relative:", 9)) { parsed.relative = 1; text += 9; }
    while (*text)
    {
        long values[4]; unsigned i;
        while (isspace((unsigned char)*text)) ++text;
        if (!*text) break;
        if (parsed.count == WGDI_EXCLUSION_LIMIT) return 0;
        for (i = 0; i < 4; ++i)
        {
            char *end;
            values[i] = strtol(text, &end, 10);
            if (text == end || values[i] < 0 || values[i] > (parsed.relative ? 10000 : 8192)) return 0;
            text = end;
            while (isspace((unsigned char)*text)) ++text;
            if (i < 3) { if (*text != ',') return 0; ++text; }
        }
        if (!values[2] || !values[3] || values[0] + values[2] > (parsed.relative ? 10000 : 8192) || values[1] + values[3] > (parsed.relative ? 10000 : 8192))
            return 0;
        parsed.rects[parsed.count++] = (struct wgdi_exclusion){
            (unsigned)values[0], (unsigned)values[1], (unsigned)values[2], (unsigned)values[3]};
        if (*text && *text != ';') return 0;
        if (*text) ++text;
    }
    *mask = parsed;
    return 1;
}

/* Resolve a saved relative selection against the current game surface. */
static inline void wgdi_resolve_exclusions(struct wgdi_exclusions *mask, unsigned width, unsigned height)
{
    unsigned i;
    if (!mask->relative) return;
    for (i = 0; i < mask->count; ++i)
    {
        struct wgdi_exclusion *r = &mask->rects[i];
        unsigned right = ((r->x + r->width) * width + 9999) / 10000;
        unsigned bottom = ((r->y + r->height) * height + 9999) / 10000;
        r->x = r->x * width / 10000; r->y = r->y * height / 10000;
        r->width = right - r->x; r->height = bottom - r->y;
    }
    mask->relative = 0;
}

/* A game profile overrides the legacy bottle mask, including an empty profile.
 * Both presenter and helper re-read it so selections take effect immediately. */
static inline int wgdi_load_exclusions(struct wgdi_exclusions *mask, unsigned width, unsigned height)
{
    const char *mode = getenv("WINE_GDI_UPSCALER_PICK");
    const char *path = getenv("WINE_GDI_UPSCALER_EXCLUDE_PROFILE");
    int valid;
    if (mode && !strcmp(mode, "off")) return wgdi_parse_exclusions(NULL, mask);
    if (path && *path)
    {
        static pthread_mutex_t cache_lock = PTHREAD_MUTEX_INITIALIZER;
        static char *cache_path;
        static int cached, cache_valid;
        static dev_t cache_dev;
        static ino_t cache_ino;
        static off_t cache_size;
        static struct timespec cache_mtime, cache_ctime;
        static struct wgdi_exclusions cache_raw;
        struct stat info;
        if (!stat(path, &info))
        {
            FILE *file;
            pthread_mutex_lock(&cache_lock);
            if (cached && !strcmp(cache_path, path) && cache_dev == info.st_dev &&
                cache_ino == info.st_ino && cache_size == info.st_size &&
                cache_mtime.tv_sec == info.st_mtimespec.tv_sec &&
                cache_mtime.tv_nsec == info.st_mtimespec.tv_nsec &&
                cache_ctime.tv_sec == info.st_ctimespec.tv_sec &&
                cache_ctime.tv_nsec == info.st_ctimespec.tv_nsec)
            {
                *mask = cache_raw;
                valid = cache_valid;
                pthread_mutex_unlock(&cache_lock);
                wgdi_resolve_exclusions(mask, width, height);
                return valid;
            }
            pthread_mutex_unlock(&cache_lock);
            file = fopen(path, "r");
            if (file)
            {
                struct stat opened_info;
                int have_stat = !fstat(fileno(file), &opened_info);
                char line[4096]; int found = 0;
                struct wgdi_exclusions raw;
                while (fgets(line, sizeof(line), file))
                    if (line[0] != '#') { found = 1; break; }
                fclose(file);
                valid = wgdi_parse_exclusions(found ? line : "", &raw);
                if (have_stat)
                {
                    char *copy = (char *)malloc(strlen(path) + 1);
                    if (copy)
                    {
                        strcpy(copy, path);
                        pthread_mutex_lock(&cache_lock);
                        free(cache_path);
                        cache_path = copy;
                        cache_dev = opened_info.st_dev; cache_ino = opened_info.st_ino;
                        cache_size = opened_info.st_size;
                        cache_mtime = opened_info.st_mtimespec; cache_ctime = opened_info.st_ctimespec;
                        cache_raw = raw; cache_valid = valid; cached = 1;
                        pthread_mutex_unlock(&cache_lock);
                    }
                }
                *mask = raw;
                wgdi_resolve_exclusions(mask, width, height);
                return valid;
            }
        }
    }
    valid = wgdi_parse_exclusions(getenv("WINE_GDI_UPSCALER_EXCLUDE"), mask);
    wgdi_resolve_exclusions(mask, width, height);
    return valid;
}

static inline int wgdi_excluded_window(const struct wgdi_exclusions *mask,
    unsigned x, unsigned y, unsigned width, unsigned height)
{
    unsigned i;
    for (i = 0; i < mask->count; ++i)
    {
        const struct wgdi_exclusion *r = &mask->rects[i];
        if (x >= r->x && y >= r->y && x + width <= r->x + r->width && y + height <= r->y + r->height)
            return 1;
    }
    return 0;
}

static inline int wgdi_pixel_excluded(const struct wgdi_exclusions *mask, unsigned x, unsigned y)
{
    unsigned i;
    for (i = 0; i < mask->count; ++i)
    {
        const struct wgdi_exclusion *r = &mask->rects[i];
        if (x >= r->x && x < r->x + r->width && y >= r->y && y < r->y + r->height)
            return 1;
    }
    return 0;
}

static inline int wgdi_frames_equal_excluding(const struct wgdi_image *previous,
    const struct wgdi_image *current, const struct wgdi_exclusions *mask)
{
    size_t row;
    unsigned x, y;
    if (!wgdi_frame_bounds_valid(previous) || !wgdi_frame_bounds_valid(current) ||
        previous->width != current->width || previous->height != current->height)
        return 0;
    row = (size_t)previous->width * 4;
    if (!mask || !mask->count) return wgdi_frames_equal(previous, current);
    for (y = 0; y < previous->height; ++y)
    {
        const unsigned char *pa = previous->pixels + (size_t)y * previous->stride;
        const unsigned char *pb = current->pixels + (size_t)y * current->stride;
        if (!memcmp(pa, pb, row)) continue;
        for (x = 0; x < previous->width; ++x)
            if (memcmp(pa + (size_t)x * 4, pb + (size_t)x * 4, 4) &&
                !wgdi_pixel_excluded(mask, x, y))
                return 0;
    }
    return 1;
}

static inline int wgdi_region_equal_excluding(const struct wgdi_image *previous,
    const struct wgdi_image *current, const struct wgdi_exclusions *mask,
    unsigned rx, unsigned ry, unsigned rw, unsigned rh)
{
    unsigned x, y;
    if (!wgdi_frame_bounds_valid(previous) || !wgdi_frame_bounds_valid(current) ||
        previous->width != current->width || previous->height != current->height)
        return 0;
    if (!rw || !rh || rx > previous->width || rw > previous->width - rx ||
        ry > previous->height || rh > previous->height - ry) return 0;
    if (mask && !mask->count) mask = NULL;
    for (y = ry; y < ry + rh; ++y)
    {
        const unsigned char *pa = previous->pixels + (size_t)y * previous->stride + (size_t)rx * 4;
        const unsigned char *pb = current->pixels + (size_t)y * current->stride + (size_t)rx * 4;
        if (!memcmp(pa, pb, (size_t)rw * 4)) continue;
        for (x = rx; x < rx + rw; ++x)
            if (memcmp(pa + (size_t)(x - rx) * 4, pb + (size_t)(x - rx) * 4, 4) &&
                !(mask && wgdi_pixel_excluded(mask, x, y)))
                return 0;
    }
    return 1;
}
#endif
