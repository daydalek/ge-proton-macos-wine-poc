/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Verify Wine cursor clip policy (WINE_CLIP_CURSOR) and automatic clearing of
 * stale cursor clips and exclusive present rects across fullscreen/windowed
 * geometry transitions.
 */
#include <windows.h>
#include <stdlib.h>
#include <stdio.h>

struct escape_params
{
    UINT adapter, device, type, flags;
    void *data;
    UINT size, context;
};

struct rect_params
{
    RECT *rect;
    UINT dpi;
};

static LONG (WINAPI *escape_call)(const struct escape_params *);
static ULONG_PTR (WINAPI *call_param)(HWND, ULONG_PTR, UINT);
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

static void set_present_rect(HWND window, RECT *rect)
{
    struct escape_params escape = {0};
    escape.type = 0x80000001; /* D3DKMT_ESCAPE_SET_PRESENT_RECT_WINE */
    escape.context = (UINT)(ULONG_PTR)window;
    escape.data = rect;
    escape.size = sizeof(*rect);
    if (escape_call(&escape)) ++failures;
}

static int has_present_rect(HWND window)
{
    RECT rect = {0};
    struct rect_params params = {&rect, 96};
    return !!call_param(window, (ULONG_PTR)&params, 15);
}

int main(void)
{
    HMODULE user = LoadLibraryA("win32u.dll"), gdi = LoadLibraryA("gdi32.dll");
    const char *clip_env = getenv("WINE_CLIP_CURSOR");
    BOOL clip_disabled = clip_env && (!strcmp(clip_env, "off") || !strcmp(clip_env, "0"));
    RECT virtual_rect, clip_rect, target_clip, client_rect;
    HWND window;

    setbuf(stdout, NULL);
    escape_call = (void *)GetProcAddress(gdi, "D3DKMTEscape");
    call_param = (void *)GetProcAddress(user, "NtUserCallHwndParam");
    if (!escape_call || !call_param) return 2;

    SetRect(&virtual_rect,
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_XVIRTUALSCREEN) + GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN) + GetSystemMetrics(SM_CYVIRTUALSCREEN));

    window = CreateWindowExA(WS_EX_TOPMOST, "STATIC", "Mouse Clip Fullscreen Probe",
                             WS_POPUP | WS_VISIBLE, 0, 0, 640, 480,
                             NULL, NULL, GetModuleHandleA(NULL), NULL);
    if (!window) return 2;
    SetForegroundWindow(window);
    pump(80);

    SetRect(&target_clip, 0, 0, 640, 480);
    check(ClipCursor(&target_clip), "ClipCursor valid rect returns TRUE");
    check(GetClipCursor(&clip_rect), "GetClipCursor succeeds");

    if (clip_disabled)
    {
        check(EqualRect(&clip_rect, &virtual_rect),
              "WINE_CLIP_CURSOR=off suppresses server cursor clamping");
    }
    else
    {
        check(EqualRect(&clip_rect, &target_clip),
              "default policy applies requested cursor clip");

        /* Simulate leaving 640x480 fullscreen to a moved windowed rect (200,120)-(840,600)
         * without calling ClipCursor(NULL) first: stale (0,0)-(640,480) clip must clear. */
        SetWindowPos(window, HWND_NOTOPMOST, 200, 120, 640, 480, SWP_SHOWWINDOW);
        pump(80);
        check(GetClipCursor(&clip_rect) && EqualRect(&clip_rect, &virtual_rect),
              "window transition clears stale fullscreen cursor clip");
    }

    /* Simulate uncaptioned window leaving exclusive fullscreen via HWND_NOTOPMOST + offset
     * BEFORE WS_CAPTION is restored: present_rect must drop and client size must be 640x480. */
    {
        RECT present = {0, 0, 1280, 800};
        SetWindowPos(window, HWND_TOPMOST, 0, 0, 640, 480, SWP_SHOWWINDOW);
        set_present_rect(window, &present);
        check(has_present_rect(window) == 1, "exclusive present rect armed");
        SetWindowPos(window, HWND_NOTOPMOST, 120, 80, 640, 480, SWP_SHOWWINDOW);
        check(has_present_rect(window) == 0,
              "HWND_NOTOPMOST windowed transition drops stale present rect");
        GetClientRect(window, &client_rect);
        check(client_rect.right == 640 && client_rect.bottom == 480,
              "windowed client rect matches requested 640x480");
    }

    ClipCursor(NULL);
    DestroyWindow(window);
    printf("failures=%d\n", failures);
    return failures ? 1 : 0;
}
