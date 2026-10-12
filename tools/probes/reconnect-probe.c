/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define COBJMACROS
#include <windows.h>
#include <dshow.h>
#include <stdio.h>
static HWND video;
static BOOL CALLBACK find_video(HWND w, LPARAM unused)
{
    wchar_t name[64]; GetClassNameW(w, name, 64);
    if (!wcscmp(name, L"wine_quartz_window")) video = w;
    return TRUE;
}
static int check(HWND parent, LONG x, LONG y)
{
    POINT origin = {0,0}; RECT rect;
    ClientToScreen(parent, &origin); GetWindowRect(video, &rect);
    printf("child=(%ld,%ld) expected=(%ld,%ld)\n", rect.left-origin.x,
            rect.top-origin.y, x, y);
    return rect.left-origin.x == x && rect.top-origin.y == y;
}
static int reconnect(IGraphBuilder *graph, HWND parent)
{
    IBaseFilter *filter = NULL; IEnumPins *pins = NULL; IPin *input = NULL, *peer = NULL;
    AM_MEDIA_TYPE mt = {0}; PIN_DIRECTION direction; RECT rect; HRESULT hr; int ok = 0;
    hr = IGraphBuilder_FindFilterByName(graph, L"Video Renderer", &filter);
    if (FAILED(hr)) goto done;
    hr = IBaseFilter_EnumPins(filter, &pins); if (FAILED(hr)) goto done;
    while (IEnumPins_Next(pins, 1, &input, NULL) == S_OK)
    {
        IPin_QueryDirection(input, &direction);
        if (direction == PINDIR_INPUT) break;
        IPin_Release(input); input = NULL;
    }
    if (!input) goto done;
    hr = IPin_ConnectedTo(input, &peer); if (FAILED(hr)) goto done;
    hr = IPin_ConnectionMediaType(input, &mt); if (FAILED(hr)) goto done;
    hr = IGraphBuilder_Disconnect(graph, input); if (FAILED(hr)) goto done;
    hr = IGraphBuilder_Disconnect(graph, peer); if (FAILED(hr)) goto done;
    hr = IGraphBuilder_ConnectDirect(graph, peer, input, &mt); if (FAILED(hr)) goto done;
    GetClientRect(video, &rect);
    printf("reconnect client size: %ldx%ld; expected 350x250\n", rect.right, rect.bottom);
    ok = rect.right == 350 && rect.bottom == 250 && check(parent, 25, 35);
done:
    if (mt.cbFormat) CoTaskMemFree(mt.pbFormat);
    if (mt.pUnk) IUnknown_Release(mt.pUnk);
    if (peer) IPin_Release(peer); if (input) IPin_Release(input);
    if (pins) IEnumPins_Release(pins); if (filter) IBaseFilter_Release(filter);
    printf("reconnect regression: %s, HRESULT=%#lx\n", ok ? "PASS" : "FAIL", hr);
    return ok;
}
int wmain(int argc, wchar_t **argv)
{
    IGraphBuilder *graph = NULL; IVideoWindow *window = NULL;
    HRESULT hr; int ok = 0;
    if (argc < 2 || argc > 3) return 2;
    CoInitialize(NULL);
    HWND parent = CreateWindowW(L"STATIC", L"Child position regression",
            WS_OVERLAPPEDWINDOW, 200, 150, 800, 600, NULL, NULL, NULL, NULL);
    hr = CoCreateInstance(&CLSID_FilterGraph, NULL, CLSCTX_INPROC_SERVER,
            &IID_IGraphBuilder, (void **)&graph);
    if (FAILED(hr)) goto done;
    if (argc == 3)
    {
        IBaseFilter *renderer = NULL;
        const CLSID *clsid = !wcscmp(argv[2], L"vmr9") ? &CLSID_VideoMixingRenderer9 : &CLSID_VideoRenderer;
        hr = CoCreateInstance(clsid, NULL, CLSCTX_INPROC_SERVER, &IID_IBaseFilter, (void **)&renderer);
        if (FAILED(hr)) goto done;
        hr = IGraphBuilder_AddFilter(graph, renderer, L"Video Renderer");
        IBaseFilter_Release(renderer);
        if (FAILED(hr)) goto done;
    }
    hr = IGraphBuilder_RenderFile(graph, argv[1], NULL);
    if (FAILED(hr)) goto done;
    hr = IGraphBuilder_QueryInterface(graph, &IID_IVideoWindow, (void **)&window);
    if (FAILED(hr)) goto done;
    IVideoWindow_put_Owner(window, (OAHWND)parent);
    IVideoWindow_put_WindowStyle(window, WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS);
    IVideoWindow_put_Left(window, 0); IVideoWindow_put_Top(window, 0);
    IVideoWindow_put_Width(window, 400); IVideoWindow_put_Height(window, 300);
    EnumChildWindows(parent, find_video, 0);
    if (!video) goto done;
    ok = check(parent, 0, 0);
    IVideoWindow_put_Left(window, 25); ok &= check(parent, 25, 0);
    IVideoWindow_put_Top(window, 35); ok &= check(parent, 25, 35);
    IVideoWindow_put_Width(window, 350); IVideoWindow_put_Height(window, 250);
    ok &= check(parent, 25, 35);
    ok &= reconnect(graph, parent);
done:
    printf("position regression: %s, last HRESULT=%#lx\n", ok ? "PASS" : "FAIL", hr);
    if (window) IVideoWindow_Release(window);
    if (graph) IGraphBuilder_Release(graph);
    DestroyWindow(parent); CoUninitialize(); return ok ? 0 : 1;
}
