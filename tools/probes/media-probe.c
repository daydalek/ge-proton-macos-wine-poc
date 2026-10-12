/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define COBJMACROS
#include <windows.h>
#include <dshow.h>
#include <wmsdk.h>
#include <nserror.h>
#include <stdio.h>
#include <wchar.h>

static void result(const char *step, HRESULT hr)
{
    printf("%s: 0x%08lx\n", step, (unsigned long)hr);
    fflush(stdout);
}

static int reader(const wchar_t *file)
{
    IWMSyncReader *r = NULL;
    DWORD outputs = 0, count = 0;
    HMODULE module = LoadLibraryW(L"wmvcore.dll");
    HRESULT (WINAPI *create)(IUnknown *, DWORD, IWMSyncReader **) =
        module ? (void *)GetProcAddress(module, "WMCreateSyncReader") : NULL;
    if (!create) { puts("WMCreateSyncReader export unavailable"); return 1; }
    HRESULT hr = create(NULL, 0, &r);
    result("WMCreateSyncReader", hr);
    if (FAILED(hr)) return 1;
    hr = IWMSyncReader_Open(r, file);
    result("IWMSyncReader::Open", hr);
    if (FAILED(hr)) { IWMSyncReader_Release(r); return 1; }
    IWMSyncReader_GetOutputCount(r, &outputs);
    printf("outputs: %lu\n", (unsigned long)outputs);
    for (;;) {
        INSSBuffer *sample = NULL;
        QWORD time = 0, duration = 0;
        DWORD flags = 0, output = 0, length = 0;
        WORD stream = 0;
        hr = IWMSyncReader_GetNextSample(r, 0, &sample, &time,
                                        &duration, &flags, &output, &stream);
        if (FAILED(hr)) break;
        INSSBuffer_GetLength(sample, &length);
        if (count < 12 || count % 100 == 0)
            printf("sample=%lu stream=%u output=%lu bytes=%lu pts=%llu\n",
                   (unsigned long)count, stream, (unsigned long)output,
                   (unsigned long)length, (unsigned long long)time);
        INSSBuffer_Release(sample);
        ++count;
    }
    result("reader end", hr);
    printf("samples: %lu\n", (unsigned long)count);
    IWMSyncReader_Close(r);
    IWMSyncReader_Release(r);
    return count && hr == NS_E_NO_MORE_SAMPLES ? 0 : 1;
}

static void filters(IGraphBuilder *graph)
{
    IEnumFilters *enumerator = NULL;
    IBaseFilter *filter;
    if (FAILED(IGraphBuilder_EnumFilters(graph, &enumerator))) return;
    while (IEnumFilters_Next(enumerator, 1, &filter, NULL) == S_OK) {
        FILTER_INFO info;
        if (SUCCEEDED(IBaseFilter_QueryFilterInfo(filter, &info))) {
            wprintf(L"filter: %ls\n", info.achName);
            if (info.pGraph) IFilterGraph_Release(info.pGraph);
        }
        IBaseFilter_Release(filter);
    }
    IEnumFilters_Release(enumerator);
}

static int play(const wchar_t *file, const wchar_t *renderer, DWORD skip_ms)
{
    IGraphBuilder *graph = NULL;
    IMediaControl *control = NULL;
    IMediaEvent *events = NULL;
    IVideoWindow *window = NULL;
    IBaseFilter *filter = NULL;
    HRESULT hr;
    int exit_code = 1;
    hr = CoCreateInstance(&CLSID_FilterGraph, NULL, CLSCTX_INPROC_SERVER,
                          &IID_IGraphBuilder, (void **)&graph);
    result("FilterGraph", hr);
    if (FAILED(hr)) return 1;
    if (renderer && wcscmp(renderer, L"default")) {
        const CLSID *id = !wcscmp(renderer, L"gdi") ? &CLSID_VideoRenderer :
            !wcscmp(renderer, L"vmr9") ? &CLSID_VideoMixingRenderer9 : &CLSID_VideoMixingRenderer;
        hr = CoCreateInstance(id, NULL, CLSCTX_INPROC_SERVER,
                              &IID_IBaseFilter, (void **)&filter);
        result("renderer create", hr);
        if (FAILED(hr)) goto done;
        hr = IGraphBuilder_AddFilter(graph, filter, L"PoC renderer");
        result("renderer add", hr);
        if (FAILED(hr)) goto done;
    }
    hr = IGraphBuilder_RenderFile(graph, file, NULL);
    result("RenderFile", hr);
    if (FAILED(hr)) goto done;
    filters(graph);
    hr = IGraphBuilder_QueryInterface(graph, &IID_IMediaControl, (void **)&control);
    if (FAILED(hr)) goto done;
    hr = IGraphBuilder_QueryInterface(graph, &IID_IMediaEvent, (void **)&events);
    if (FAILED(hr)) goto done;
    hr = IGraphBuilder_QueryInterface(graph, &IID_IVideoWindow, (void **)&window);
    result("VideoWindow query", hr);
    if (SUCCEEDED(hr)) {
        BSTR caption = SysAllocString(L"GE macOS Wine media probe");
        if (caption) {
            result("VideoWindow caption", IVideoWindow_put_Caption(window, caption));
            SysFreeString(caption);
        }
        result("VideoWindow style", IVideoWindow_put_WindowStyle(window, WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN));
        result("VideoWindow position", IVideoWindow_SetWindowPosition(window, 100, 100, 680, 540));
        result("VideoWindow visible", IVideoWindow_put_Visible(window, OATRUE));
    }
    hr = IMediaControl_Run(control);
    result("Run", hr);
    if (FAILED(hr)) goto done;
    if (window) {
        LONG left = 0, top = 0, width = 0, height = 0, visible = 0;
        result("VideoWindow foreground", IVideoWindow_SetWindowForeground(window, OATRUE));
        result("VideoWindow position query", IVideoWindow_GetWindowPosition(window, &left, &top, &width, &height));
        result("VideoWindow visibility query", IVideoWindow_get_Visible(window, &visible));
        printf("video window: left=%ld top=%ld width=%ld height=%ld visible=%ld\n", left, top, width, height, visible);
    }
    DWORD started = GetTickCount();
    for (;;) {
        MSG msg;
        long code;
        LONG_PTR p1, p2;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (IMediaEvent_GetEvent(events, &code, &p1, &p2, 0) == S_OK) {
            printf("event: %ld\n", code);
            IMediaEvent_FreeEventParams(events, code, p1, p2);
            if (code == EC_COMPLETE) { exit_code = 0; break; }
            if (code == EC_ERRORABORT || code == EC_USERABORT) break;
        }
        DWORD elapsed = GetTickCount() - started;
        if (skip_ms && elapsed >= skip_ms) { puts("requested stop"); exit_code = 0; break; }
        if (elapsed > 120000) { puts("timeout after 120s"); break; }
        Sleep(10);
    }
    result("Stop", IMediaControl_Stop(control));
done:
    if (window) { IVideoWindow_put_Visible(window, OAFALSE); IVideoWindow_Release(window); }
    if (events) IMediaEvent_Release(events);
    if (control) IMediaControl_Release(control);
    if (filter) IBaseFilter_Release(filter);
    IGraphBuilder_Release(graph);
    return exit_code;
}

int wmain(int argc, wchar_t **argv)
{
    if (argc < 3) {
        puts("media-probe.exe play|reader FILE [default|gdi|vmr7|vmr9] [skip_ms]");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) return 1;
    printf("process bits: %u\n", (unsigned)(sizeof(void *) * 8));
    int ret = !wcscmp(argv[1], L"reader") ? reader(argv[2]) :
        play(argv[2], argc > 3 ? argv[3] : L"default",
             argc > 4 ? wcstoul(argv[4], NULL, 10) : 0);
    CoUninitialize();
    return ret;
}
