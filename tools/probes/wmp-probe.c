/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define COBJMACROS
#include <windows.h>
#include <ole2.h>
#include <ocidl.h>
#include <initguid.h>
#include <wmp.h>
#include <stdio.h>
#include <math.h>

static const GUID player2_iid = {0x0e6b01d1, 0xd407, 0x4c85, {0xbf,0x5f,0x1c,0x01,0xf6,0x15,0x02,0x80}};
static unsigned failures;
static void check(const char *name, HRESULT hr)
{
    printf("%s: %#lx\n", name, hr);
    fflush(stdout);
    if (FAILED(hr)) ++failures;
}

static BOOL CALLBACK check_video_child(HWND hwnd, LPARAM param)
{
    wchar_t name[64];
    RECT rect;
    GetClassNameW(hwnd, name, (sizeof(name) / sizeof(name[0])));
    if (wcscmp(name, L"wine_quartz_window")) return TRUE;
    GetClientRect(hwnd, &rect);
    printf("video child=%p parent=%p visible=%d size=%ldx%ld\n", hwnd,
           GetParent(hwnd), IsWindowVisible(hwnd), rect.right, rect.bottom);
    if (IsWindowVisible(hwnd) && rect.right > 0 && rect.bottom > 0)
        ++*(unsigned *)param;
    return TRUE;
}

int wmain(int argc, wchar_t **argv)
{
    IOleObject *object = NULL;
    HWND host = NULL, container = NULL;
    HMODULE atl = NULL;
    BOOL embedded = argc > 1 && !wcscmp(argv[1], L"--embed");
    const wchar_t *file = argc > (embedded ? 2 : 1) ? argv[embedded ? 2 : 1] : NULL;
    /* IWMPPlayer2 shares the complete IWMPPlayer prefix. Use the SDK's
     * typed methods here so vtable offsets and stdcall signatures are checked. */
    IWMPPlayer *player = NULL;
    IWMPSettings *settings = NULL;
    IWMPControls *controls = NULL;
    VARIANT_BOOL enabled = VARIANT_TRUE;
    if (argc > (embedded ? 3 : 2) || (argc > 1 && !wcscmp(argv[1], L"--help"))) {
        puts("Usage: wmp-probe.exe [--embed] [video-path]");
        puts("Video mode plays silently for three seconds; use a video longer than five seconds.");
        puts("--embed also verifies ATL site rebinding and Wine's video child window.");
        return argc > (embedded ? 3 : 2) ? 2 : 0;
    }
    HRESULT hr = OleInitialize(NULL);
    if (FAILED(hr)) return 1;
    if (embedded) {
        BOOL (WINAPI *init)(void);
        HRESULT (WINAPI *get_control)(HWND, IUnknown **);
        IUnknown *unknown = NULL;
        IOleWindow *window = NULL;
        IObjectWithSite *with_site = NULL;
        IUnknown *site = NULL;
        HWND before = NULL, after = NULL;
        atl = LoadLibraryW(L"atl.dll");
        init = atl ? (void *)GetProcAddress(atl, "AtlAxWinInit") : NULL;
        get_control = atl ? (void *)GetProcAddress(atl, "AtlAxGetControl") : NULL;
        if (!init || !get_control || !init()) { ++failures; goto done; }
        host = CreateWindowW(L"STATIC", L"WMP embedding probe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                             100, 100, 680, 420, NULL, NULL, NULL, NULL);
        container = CreateWindowW(L"AtlAxWin", L"{6BF52A52-394A-11D3-B153-00C04F79FAA6}",
                                  WS_CHILD | WS_VISIBLE, 0, 0, 640, 360, host, NULL, NULL, NULL);
        hr = get_control(container, &unknown);
        check("AtlAxGetControl", hr);
        if (FAILED(hr)) goto done;
        hr = IUnknown_QueryInterface(unknown, &IID_IOleObject, (void **)&object);
        IUnknown_Release(unknown);
        check("QI IOleObject", hr);
        if (FAILED(hr)) goto done;
        check("QI IOleWindow", IOleObject_QueryInterface(object, &IID_IOleWindow, (void **)&window));
        check("QI IObjectWithSite", IOleObject_QueryInterface(object, &IID_IObjectWithSite, (void **)&with_site));
        if (window && with_site) {
            check("GetWindow before SetSite", IOleWindow_GetWindow(window, &before));
            check("GetSite", IObjectWithSite_GetSite(with_site, &IID_IUnknown, (void **)&site));
            if (site) {
                check("SetSite same host", IObjectWithSite_SetSite(with_site, site));
                IUnknown_Release(site);
            }
            check("GetWindow after SetSite", IOleWindow_GetWindow(window, &after));
            printf("embedded HWND before=%p after=%p parent=%p container=%p\n",
                   before, after, GetParent(after), container);
            if (!before || before != after || !IsWindow(after) || GetParent(after) != container)
                ++failures;
        }
        if (window) IOleWindow_Release(window);
        if (with_site) IObjectWithSite_Release(with_site);
    } else {
        hr = CoCreateInstance(&CLSID_WindowsMediaPlayer, NULL, CLSCTX_INPROC_SERVER,
                             &IID_IOleObject, (void **)&object);
        check("CoCreateInstance", hr);
        if (FAILED(hr)) goto done;
    }
    hr = IOleObject_QueryInterface(object, &player2_iid, (void **)&player);
    check("QI IWMPPlayer2", hr);
    if (FAILED(hr)) goto done;
    check("put_enableContextMenu(FALSE)", IWMPPlayer_put_enableContextMenu(player, VARIANT_FALSE));
    check("get_enableContextMenu", IWMPPlayer_get_enableContextMenu(player, &enabled));
    if (enabled != VARIANT_FALSE) ++failures;
    check("put_enableContextMenu(TRUE)", IWMPPlayer_put_enableContextMenu(player, VARIANT_TRUE));
    check("get_enableContextMenu(TRUE)", IWMPPlayer_get_enableContextMenu(player, &enabled));
    if (enabled != VARIANT_TRUE) ++failures;
    if (IWMPPlayer_get_enableContextMenu(player, NULL) != E_POINTER) ++failures;
    check("put_enabled(FALSE)", IWMPPlayer_put_enabled(player, VARIANT_FALSE));
    check("get_enabled", IWMPPlayer_get_enabled(player, &enabled));
    if (enabled != VARIANT_FALSE) ++failures;
    check("put_enabled(TRUE)", IWMPPlayer_put_enabled(player, VARIANT_TRUE));
    check("get_enabled(TRUE)", IWMPPlayer_get_enabled(player, &enabled));
    if (enabled != VARIANT_TRUE) ++failures;
    if (IWMPPlayer_get_enabled(player, NULL) != E_POINTER) ++failures;
    check("get_settings", IWMPPlayer_get_settings(player, &settings));
    if (settings) {
        check("autoStart(FALSE)", IWMPSettings_put_autoStart(settings, VARIANT_FALSE));
        check("volume(0)", IWMPSettings_put_volume(settings, 0));
    }
    check("get_controls", IWMPPlayer_get_controls(player, &controls));
    if (file && controls && settings) {
        BSTR url = SysAllocString(file);
        check("put_URL", IWMPPlayer_put_URL(player, url));
        SysFreeString(url);
        check("play", IWMPControls_play(controls));
        DWORD start = GetTickCount();
        while (GetTickCount() - start < 3000) {
            MSG msg;
            while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            Sleep(10);
        }
        WMPPlayState state = wmppsUndefined;
        check("get_playState", IWMPPlayer_get_playState(player, &state));
        printf("playState=%u\n", state);
        if (state != wmppsPlaying) ++failures;
        DOUBLE position = 0;
        check("currentPosition", IWMPControls_get_currentPosition(controls, &position));
        printf("position=%f\n", position);
        if (!isfinite(position) || position < 1.0) ++failures;
        if (embedded) {
            unsigned video_children = 0;
            EnumChildWindows(host, check_video_child, (LPARAM)&video_children);
            if (video_children != 1) ++failures;
        }
        check("stop", IWMPControls_stop(controls));
    }
    check("close", IWMPPlayer_close(player));
    check("close again", IWMPPlayer_close(player));
    BSTR closed_url = NULL;
    check("get_URL after close", IWMPPlayer_get_URL(player, &closed_url));
    if (!closed_url || SysStringLen(closed_url)) ++failures;
    SysFreeString(closed_url);
done:
    if (controls) IWMPControls_Release(controls);
    if (settings) IWMPSettings_Release(settings);
    if (player) IWMPPlayer_Release(player);
    if (object) IOleObject_Release(object);
    if (host) DestroyWindow(host);
    if (atl) FreeLibrary(atl);
    OleUninitialize();
    printf("failures=%u\n", failures);
    return failures ? 1 : 0;
}
