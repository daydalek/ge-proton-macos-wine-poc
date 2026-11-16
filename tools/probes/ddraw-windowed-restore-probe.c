/* SPDX-License-Identifier: LGPL-2.1-or-later
 * A windowed DirectDraw primary must reach its window after the application
 * leaves an exclusive mode smaller than the desktop. SetCooperativeLevel()
 * recreates the swapchain before it restores the display mode.
 * Exit code: 0 pass, 1 fail, 2 not exercised (mode unavailable).
 */
#define COBJMACROS
#define DIRECTDRAW_VERSION 0x0700
#include <windows.h>
#include <ddraw.h>
#include <stdio.h>

static IDirectDraw7 *ddraw;
static HWND window;
static int failures;

static void check(int ok, const char *name)
{
    printf("%s: %s\n", name, ok ? "PASS" : "FAIL");
    if (!ok) ++failures;
}

static void pump(DWORD ms)
{
    DWORD start = GetTickCount();
    MSG msg;

    do
    {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
        Sleep(10);
    } while (GetTickCount() - start < ms);
}

/* Present a solid colour to the client area through a clipped primary, the
 * way a windowed DirectDraw application does. Returns the primary Blt result;
 * *shown reports whether the colour reached the window. */
static HRESULT present(DWORD colour, COLORREF expected, BOOL *shown)
{
    IDirectDrawSurface7 *primary = NULL, *offscreen = NULL;
    IDirectDrawClipper *clipper = NULL;
    DDSURFACEDESC2 desc = {0};
    DDBLTFX fx = {0};
    RECT rect = {0, 0, 64, 64};
    HRESULT hr;
    HDC dc;
    int i;

    *shown = FALSE;
    desc.dwSize = sizeof(desc);
    desc.dwFlags = DDSD_CAPS;
    desc.ddsCaps.dwCaps = DDSCAPS_PRIMARYSURFACE;
    if (FAILED(hr = IDirectDraw7_CreateSurface(ddraw, &desc, &primary, NULL))) goto done;
    if (FAILED(hr = IDirectDraw7_CreateClipper(ddraw, 0, &clipper, NULL))) goto done;
    if (FAILED(hr = IDirectDrawClipper_SetHWnd(clipper, 0, window))) goto done;
    if (FAILED(hr = IDirectDrawSurface7_SetClipper(primary, clipper))) goto done;
    desc.dwFlags = DDSD_CAPS | DDSD_WIDTH | DDSD_HEIGHT;
    desc.dwWidth = desc.dwHeight = 64;
    desc.ddsCaps.dwCaps = DDSCAPS_OFFSCREENPLAIN | DDSCAPS_SYSTEMMEMORY;
    if (FAILED(hr = IDirectDraw7_CreateSurface(ddraw, &desc, &offscreen, NULL))) goto done;
    fx.dwSize = sizeof(fx);
    fx.dwFillColor = colour;
    if (FAILED(hr = IDirectDrawSurface7_Blt(offscreen, NULL, NULL, NULL, DDBLT_COLORFILL | DDBLT_WAIT, &fx))) goto done;
    MapWindowPoints(window, NULL, (POINT *)&rect, 2);
    hr = IDirectDrawSurface7_Blt(primary, &rect, offscreen, NULL, DDBLT_WAIT, NULL);
    for (i = 0; SUCCEEDED(hr) && !*shown && i < 50; ++i)
    {
        dc = GetDC(window);
        *shown = GetPixel(dc, 32, 32) == expected;
        ReleaseDC(window, dc);
        if (!*shown) Sleep(20);
    }
done:
    if (offscreen) IDirectDrawSurface7_Release(offscreen);
    if (primary) IDirectDrawSurface7_Release(primary);
    if (clipper) IDirectDrawClipper_Release(clipper);
    return hr;
}

int main(void)
{
    WNDCLASSA class = {0};
    DEVMODEA original = {0}, current = {0};
    BOOL readback, shown;
    RECT work;
    HRESULT hr;
    int result = 2;

    setbuf(stdout, NULL);
    original.dmSize = current.dmSize = sizeof(original);
    if (!EnumDisplaySettingsA(NULL, ENUM_CURRENT_SETTINGS, &original)) return 2;
    /* The client area has to lie outside an 800x600 screen. */
    if (original.dmBitsPerPel != 32 || original.dmPelsWidth < 1200) return 2;
    if (!SystemParametersInfoA(SPI_GETWORKAREA, 0, &work, 0)) return 2;
    class.lpfnWndProc = DefWindowProcA;
    class.hInstance = GetModuleHandleA(NULL);
    class.lpszClassName = "ddraw-windowed-restore-probe";
    if (!RegisterClassA(&class)) return 2;
    window = CreateWindowA(class.lpszClassName, "DirectDraw windowed restore probe",
            WS_OVERLAPPEDWINDOW | WS_VISIBLE, work.right - 340, work.bottom - 340, 320, 320,
            NULL, NULL, class.hInstance, NULL);
    if (!window) return 2;
    pump(200);
    if (FAILED(DirectDrawCreateEx(NULL, (void **)&ddraw, &IID_IDirectDraw7, NULL))) goto done;
    if (FAILED(IDirectDraw7_SetCooperativeLevel(ddraw, window, DDSCL_NORMAL))) goto done;
    /* Control: only renderers that present through the window DC can be read back. */
    if (FAILED(present(0x00ff0000, RGB(255, 0, 0), &readback))) goto done;
    printf("window readback: %s\n", readback ? "available" : "unavailable");
    if (FAILED(IDirectDraw7_SetCooperativeLevel(ddraw, window, DDSCL_EXCLUSIVE | DDSCL_FULLSCREEN))) goto done;
    if (FAILED(IDirectDraw7_SetDisplayMode(ddraw, 800, 600, 32, 0, 0))) goto done;
    pump(200);

    hr = IDirectDraw7_SetCooperativeLevel(ddraw, window, DDSCL_NORMAL);
    check(hr == DD_OK, "leave exclusive mode");
    pump(200);
    EnumDisplaySettingsA(NULL, ENUM_CURRENT_SETTINGS, &current);
    check(current.dmPelsWidth == original.dmPelsWidth && current.dmPelsHeight == original.dmPelsHeight,
            "display mode restored");
    SetWindowLongA(window, GWL_STYLE, WS_OVERLAPPEDWINDOW | WS_VISIBLE);
    SetWindowPos(window, HWND_NOTOPMOST, work.right - 340, work.bottom - 340, 320, 320,
            SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    pump(200);
    hr = present(0x0000ff00, RGB(0, 255, 0), &shown);
    printf("windowed blit after exclusive mode: %#lx (expected 0)\n", (unsigned long)hr);
    check(hr == DD_OK, "windowed blit succeeds");
    if (readback) check(shown, "windowed blit reaches the window");
    printf("failures=%d\n", failures);
    result = !!failures;
done:
    if (ddraw)
    {
        IDirectDraw7_SetCooperativeLevel(ddraw, window, DDSCL_NORMAL);
        IDirectDraw7_RestoreDisplayMode(ddraw);
        IDirectDraw7_Release(ddraw);
    }
    DestroyWindow(window);
    return result;
}
