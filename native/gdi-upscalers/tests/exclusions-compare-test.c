/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _DEFAULT_SOURCE
#include "../include/wine_gdi_exclusions.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static void px(unsigned char *f, unsigned w, unsigned x, unsigned y, unsigned char v){f[(y*w+x)*4]=v;}
static struct wgdi_image img(unsigned char *p, unsigned w, unsigned h){
    struct wgdi_image i = {p, (size_t)w*h*4, w*4, w, h}; return i;
}
static void write_file(const char *path, const char *text){
    FILE *f = fopen(path, "w"); assert(f); fputs(text, f); assert(!fclose(f));
}
int main(void)
{
    unsigned char a[4*4*4]={0}, b[4*4*4]={0};
    struct wgdi_image ia = img(a,4,4), ib = img(b,4,4);
    struct wgdi_exclusions mask;
    assert(wgdi_parse_exclusions("0,2,4,2", &mask) && mask.count == 1);
    px(a,4,1,3,9); px(b,4,1,3,9);
    assert(wgdi_frames_equal_excluding(&ia,&ib,&mask));
    px(a,4,0,0,7);
    assert(!wgdi_frames_equal_excluding(&ia,&ib,&mask));
    px(a,4,0,0,0); px(a,4,2,3,5);
    assert(wgdi_frames_equal_excluding(&ia,&ib,&mask));
    assert(!wgdi_frames_equal_excluding(&ia,&ib,NULL));
    assert(wgdi_region_equal_excluding(&ia,&ib,&mask,0,2,4,2));
    px(a,4,1,0,8);
    assert(!wgdi_region_equal_excluding(&ia,&ib,&mask,0,0,4,2));
    assert(!wgdi_frames_equal_excluding(&ia,&ib,&mask));
    px(a,4,1,0,0);
    struct wgdi_exclusions rel;
    assert(wgdi_parse_exclusions("relative:0,5000,10000,5000",&rel) && rel.relative);
    wgdi_resolve_exclusions(&rel,4,4);
    assert(rel.rects[0].y==2 && rel.rects[0].height==2 && !rel.relative);
    struct wgdi_exclusions bad;
    assert(!wgdi_parse_exclusions("1,2,3",&bad));
    assert(wgdi_parse_exclusions("",&bad) && !bad.count);
    unsigned char small[2*2*4]={0};
    struct wgdi_image is = img(small,2,2);
    assert(!wgdi_frames_equal_excluding(&is,&ia,&mask));
    assert(!wgdi_region_equal_excluding(&ia,&ib,&mask,3,3,2,2));
    assert(!wgdi_region_equal_excluding(&ia,&ib,&mask,0,0,0,4));
    unsigned char padded[4*4*5]={0};
    struct wgdi_image ip = {padded, sizeof(padded), 20, 4, 4};
    assert(wgdi_frame_bounds_valid(&ip));
    {
        char dir[] = "/tmp/wgdi-excl-test-XXXXXX";
        char profile[512], staging[512];
        struct wgdi_exclusions m;
        assert(mkdtemp(dir));
        snprintf(profile, sizeof(profile), "%s/profile.txt", dir);
        snprintf(staging, sizeof(staging), "%s/staging.txt", dir);
        unsetenv("WINE_GDI_UPSCALER_PICK");
        setenv("WINE_GDI_UPSCALER_EXCLUDE", "5,5,3,3", 1);
        setenv("WINE_GDI_UPSCALER_EXCLUDE_PROFILE", profile, 1);
        assert(wgdi_load_exclusions(&m,4,4) && m.count == 1 && m.rects[0].x == 5);
        write_file(profile, "relative:0,5000,10000,5000\n");
        assert(wgdi_load_exclusions(&m,4,4) && m.count == 1 && !m.relative &&
            m.rects[0].y == 2 && m.rects[0].height == 2);
        assert(wgdi_load_exclusions(&m,100,80) && m.rects[0].y == 40 &&
            m.rects[0].height == 40);
        assert(wgdi_load_exclusions(&m,4,4) && m.rects[0].y == 2 &&
            m.rects[0].height == 2);
        write_file(staging, "relative:0,0,5000,5000\n");
        assert(!rename(staging, profile));
        assert(wgdi_load_exclusions(&m,4,4) && m.rects[0].width == 2 &&
            m.rects[0].height == 2);
        write_file(profile, "0,0,2,2\n");
        assert(wgdi_load_exclusions(&m,9,9) && !m.relative &&
            m.rects[0].x == 0 && m.rects[0].width == 2);
        write_file(profile, "not-a-mask\n");
        assert(!wgdi_load_exclusions(&m,4,4) && !m.count);
        write_file(profile, "0,1,3,2\n");
        assert(wgdi_load_exclusions(&m,4,4) && m.rects[0].y == 1 &&
            m.rects[0].height == 2);
        write_file(profile, "# nothing selected\n");
        assert(wgdi_load_exclusions(&m,4,4) && !m.count);
        write_file(profile, "0,0,1,1\n");
        assert(!chmod(profile, 0000));
        assert(wgdi_load_exclusions(&m,4,4) && m.count == 1 && m.rects[0].x == 5);
        assert(!chmod(profile, 0600));
        assert(wgdi_load_exclusions(&m,4,4) && m.rects[0].width == 1);
        assert(!remove(profile));
        assert(wgdi_load_exclusions(&m,4,4) && m.rects[0].x == 5);
        write_file(profile, "0,0,4,4\n");
        assert(wgdi_load_exclusions(&m,4,4) && m.rects[0].width == 4);
        setenv("WINE_GDI_UPSCALER_PICK", "off", 1);
        assert(wgdi_load_exclusions(&m,4,4) && !m.count);
        unsetenv("WINE_GDI_UPSCALER_PICK");
        assert(wgdi_load_exclusions(&m,4,4) && m.rects[0].width == 4);
        unsetenv("WINE_GDI_UPSCALER_EXCLUDE");
        unsetenv("WINE_GDI_UPSCALER_EXCLUDE_PROFILE");
        assert(!remove(profile));
        assert(!rmdir(dir));
    }
    puts("exclusions-compare: all checks passed");
    return 0;
}
