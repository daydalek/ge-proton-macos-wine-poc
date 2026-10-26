/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define COBJMACROS
#define DIRECTDRAW_VERSION 0x0700
#include <windows.h>
#include <ddraw.h>
#include <stdio.h>

int main(void)
{
    IDirectDraw7 *ddraw = NULL;
    IDirectDrawSurface7 *primary = NULL, *offscreen = NULL;
    DDSURFACEDESC2 desc = {0};
    DEVMODEA original = {0}, mode;
    HWND window = NULL;
    HRESULT hr;
    RECT rect = {0, 0, 100, 100};
    int failures = 0, changed = 0, result = 2;

    setbuf(stdout, NULL);
    original.dmSize = sizeof(original);
    if (!EnumDisplaySettingsA(NULL, ENUM_CURRENT_SETTINGS, &original)) goto done;
    if (original.dmPelsWidth == 800 && original.dmPelsHeight == 600) goto done;
    mode = original;
    mode.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL;
    mode.dmPelsWidth = 800;
    mode.dmPelsHeight = 600;
    mode.dmBitsPerPel = 32;
    if (ChangeDisplaySettingsA(&mode, CDS_TEST)) goto done;
    window = CreateWindowA("STATIC", "DirectDraw mode loss probe", WS_OVERLAPPEDWINDOW,
            0, 0, 100, 100, NULL, NULL, NULL, NULL);
    if (!window) goto done;
    if (FAILED(DirectDrawCreateEx(NULL, (void **)&ddraw, &IID_IDirectDraw7, NULL))) goto done;
    if (FAILED(IDirectDraw7_SetCooperativeLevel(ddraw, window, DDSCL_NORMAL))) goto done;
    desc.dwSize = sizeof(desc);
    desc.dwFlags = DDSD_CAPS;
    desc.ddsCaps.dwCaps = DDSCAPS_PRIMARYSURFACE;
    if (FAILED(IDirectDraw7_CreateSurface(ddraw, &desc, &primary, NULL))) goto done;
    desc.dwFlags = DDSD_CAPS | DDSD_WIDTH | DDSD_HEIGHT;
    desc.dwWidth = 100;
    desc.dwHeight = 100;
    desc.ddsCaps.dwCaps = DDSCAPS_OFFSCREENPLAIN | DDSCAPS_SYSTEMMEMORY;
    if (FAILED(IDirectDraw7_CreateSurface(ddraw, &desc, &offscreen, NULL))) goto done;
    if (ChangeDisplaySettingsA(&mode, CDS_FULLSCREEN)) goto done;
    changed = 1;
    hr = IDirectDrawSurface7_Blt(primary, &rect, offscreen, NULL, DDBLT_WAIT, NULL);
    printf("blit after external mode change: %#lx (expected %#lx)\n",
            (unsigned long)hr, (unsigned long)DDERR_SURFACELOST);
    failures += hr != DDERR_SURFACELOST;
    hr = IDirectDrawSurface7_IsLost(primary);
    printf("primary after external mode change: %#lx (expected %#lx)\n",
            (unsigned long)hr, (unsigned long)DDERR_SURFACELOST);
    failures += hr != DDERR_SURFACELOST;
    hr = IDirectDrawSurface7_IsLost(offscreen);
    printf("system-memory surface: %#lx (expected 0)\n", (unsigned long)hr);
    failures += hr != DD_OK;
    hr = IDirectDrawSurface7_Restore(primary);
    printf("restore in different mode: %#lx (expected %#lx)\n",
            (unsigned long)hr, (unsigned long)DDERR_WRONGMODE);
    failures += hr != DDERR_WRONGMODE;
    if (ChangeDisplaySettingsA(&original, 0)) goto done;
    changed = 0;
    hr = IDirectDrawSurface7_IsLost(primary);
    printf("primary remains lost until restore: %#lx (expected %#lx)\n",
            (unsigned long)hr, (unsigned long)DDERR_SURFACELOST);
    failures += hr != DDERR_SURFACELOST;
    hr = IDirectDrawSurface7_Restore(primary);
    printf("restore in original mode: %#lx (expected 0)\n", (unsigned long)hr);
    failures += hr != DD_OK;
    hr = IDirectDrawSurface7_Blt(primary, &rect, offscreen, NULL, DDBLT_WAIT, NULL);
    printf("blit after restore: %#lx (expected 0)\n", (unsigned long)hr);
    failures += hr != DD_OK;
    printf("failures=%d\n", failures);
    result = !!failures;
done:
    if (changed && ChangeDisplaySettingsA(&original, 0)) result = 2;
    if (offscreen) IDirectDrawSurface7_Release(offscreen);
    if (primary) IDirectDrawSurface7_Release(primary);
    if (ddraw) IDirectDraw7_Release(ddraw);
    if (window) DestroyWindow(window);
    return result;
}
