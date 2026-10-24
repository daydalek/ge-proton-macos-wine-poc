/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Exercise the exclusive-present-rectangle ABI in this project's Wine builds.
 * The escape code and call index are Wine-specific, pinned by the Wine 11
 * and CrossOver Wine source baselines.
 */
#include <windows.h>
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

static void set_present_rect(HWND window, RECT *rect)
{
    struct escape_params escape = {0};
    escape.type = 0x80000001; /* D3DKMT_ESCAPE_SET_PRESENT_RECT_WINE */
    escape.context = (UINT)(ULONG_PTR)window;
    escape.data = rect;
    escape.size = sizeof(*rect);
    if (escape_call(&escape)) ++failures;
}

static void check_present_rect(HWND window, int expected, const char *name)
{
    RECT rect = {0};
    struct rect_params params = {&rect, 96};
    int present = !!call_param(window, (ULONG_PTR)&params, 15); /* GetPresentRect */
    printf("%s: %s\n", name, present == expected ? "PASS" : "FAIL");
    if (present != expected) ++failures;
}

int main(void)
{
    HMODULE user = LoadLibraryA("win32u.dll"), gdi = LoadLibraryA("gdi32.dll");
    RECT present = {0, 0, 2000, 1200}, client;
    LONG expected_width, expected_height;
    HWND window;

    setbuf(stdout, NULL);
    escape_call = (void *)GetProcAddress(gdi, "D3DKMTEscape");
    call_param = (void *)GetProcAddress(user, "NtUserCallHwndParam");
    if (!escape_call || !call_param) return 2;

    window = CreateWindowA("STATIC", "Fullscreen state probe", WS_POPUP | WS_VISIBLE,
            0, 0, 320, 240, NULL, NULL, NULL, NULL);
    if (!window) return 2;
    set_present_rect(window, &present);
    SetWindowPos(window, NULL, 0, 0, 640, 360, SWP_NOZORDER | SWP_NOACTIVATE);
    check_present_rect(window, 1, "fullscreen logical resize retains present rect");
    GetClientRect(window, &client);
    expected_width = GetModuleHandleW(L"winemac.drv") ? 2000 : 640;
    expected_height = GetModuleHandleW(L"winemac.drv") ? 1200 : 360;
    printf("fullscreen hit-test geometry: %s (%ldx%ld)\n",
            client.right == expected_width && client.bottom == expected_height ? "PASS" : "FAIL",
            client.right, client.bottom);
    if (client.right != expected_width || client.bottom != expected_height) ++failures;
    DestroyWindow(window);

    window = CreateWindowA("STATIC", "Fullscreen state probe", WS_OVERLAPPEDWINDOW,
            0, 0, 320, 240, NULL, NULL, NULL, NULL);
    if (!window) return 2;
    set_present_rect(window, &present);
    SetWindowPos(window, NULL, 0, 0, 640, 360, SWP_NOZORDER | SWP_NOACTIVATE);
    check_present_rect(window, 1, "hidden resize retains present rect");
    ShowWindow(window, SW_SHOW);
    set_present_rect(window, &present);
    ShowWindow(window, SW_MINIMIZE);
    check_present_rect(window, 1, "minimize retains present rect");
    ShowWindow(window, SW_RESTORE);
    set_present_rect(window, &present);
    SetWindowPos(window, NULL, 50, 50, 640, 360, SWP_NOZORDER | SWP_NOACTIVATE);
    check_present_rect(window, 0, "restored captioned window clears present rect");
    DestroyWindow(window);
    printf("failures=%d\n", failures);
    return failures ? 1 : 0;
}
