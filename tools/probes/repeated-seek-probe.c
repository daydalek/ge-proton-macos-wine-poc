/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define COBJMACROS
#include <windows.h>
#include <dshow.h>
#include <stdio.h>

#define SECOND ((LONGLONG)10000000)
#define REQUIRE(call) do { hr = (call); if (FAILED(hr)) { \
    printf("%s failed: %#lx\n", #call, hr); goto done; } } while (0)

static int monitor(IMediaEvent *events, DWORD milliseconds, int expect_end, DWORD earliest_end)
{
    ULONGLONG start = GetTickCount64();
    do
    {
        MSG message;
        long code;
        LONG_PTR first, second;
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        while (IMediaEvent_GetEvent(events, &code, &first, &second, 0) == S_OK)
        {
            IMediaEvent_FreeEventParams(events, code, first, second);
            if (code == EC_ERRORABORT || code == EC_USERABORT)
            {
                printf("aborted: event %ld\n", code);
                return 0;
            }
            if (code == EC_COMPLETE)
            {
                DWORD elapsed = (DWORD)(GetTickCount64() - start);
                printf("EC_COMPLETE after %lu ms (minimum %lu)\n", elapsed, earliest_end);
                return expect_end && elapsed >= earliest_end;
            }
        }
        Sleep(5);
    } while (GetTickCount64() - start < milliseconds);
    if (expect_end) puts("timed out waiting for EC_COMPLETE");
    return !expect_end;
}

static int position_near(IMediaSeeking *seeking, LONGLONG target)
{
    LONGLONG position = -1;
    HRESULT hr = IMediaSeeking_GetCurrentPosition(seeking, &position);
    printf("position=%lld target=%lld hr=%#lx\n", position, target, hr);
    return SUCCEEDED(hr) && position >= target - SECOND / 4 && position < target + 2 * SECOND;
}

int wmain(int argc, wchar_t **argv)
{
    IGraphBuilder *graph = NULL;
    IBaseFilter *renderer = NULL;
    IMediaControl *control = NULL;
    IMediaSeeking *seeking = NULL;
    IMediaEvent *events = NULL;
    LONGLONG duration, target, paused, current;
    OAFilterState state;
    HRESULT hr;
    int ok = 0;
    unsigned int i;
    const unsigned int fractions[] = {1, 1, 3, 1};

    if (argc != 2) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) return 1;
    REQUIRE(CoCreateInstance(&CLSID_FilterGraph, NULL, CLSCTX_INPROC_SERVER,
            &IID_IGraphBuilder, (void **)&graph));
    REQUIRE(CoCreateInstance(&CLSID_VideoRenderer, NULL, CLSCTX_INPROC_SERVER,
            &IID_IBaseFilter, (void **)&renderer));
    REQUIRE(IGraphBuilder_AddFilter(graph, renderer, L"Seek regression renderer"));
    REQUIRE(IGraphBuilder_RenderFile(graph, argv[1], NULL));
    REQUIRE(IGraphBuilder_QueryInterface(graph, &IID_IMediaControl, (void **)&control));
    REQUIRE(IGraphBuilder_QueryInterface(graph, &IID_IMediaSeeking, (void **)&seeking));
    REQUIRE(IGraphBuilder_QueryInterface(graph, &IID_IMediaEvent, (void **)&events));
    REQUIRE(IMediaSeeking_GetDuration(seeking, &duration));
    printf("process bits=%u duration=%lld\n", (unsigned int)(sizeof(void *) * 8), duration);
    if (duration < 6 * SECOND || duration > 30 * SECOND) goto done;
    REQUIRE(IMediaControl_Run(control));
    if (!monitor(events, 500, 0, 0)) goto done;

    for (i = 0; i < sizeof(fractions) / sizeof(*fractions); ++i)
    {
        target = fractions[i] * duration / 8;
        REQUIRE(IMediaSeeking_SetPositions(seeking, &target, AM_SEEKING_AbsolutePositioning,
                NULL, AM_SEEKING_NoPositioning));
        if (!monitor(events, 300, 0, 0) || !position_near(seeking, target)) goto done;
        current = 0;
        REQUIRE(IMediaSeeking_SetPositions(seeking, &current,
                AM_SEEKING_NoPositioning | AM_SEEKING_ReturnTime, NULL, AM_SEEKING_NoPositioning));
        if (!monitor(events, 100, 0, 0) || !position_near(seeking, target)) goto done;
        REQUIRE(IMediaControl_Pause(control));
        REQUIRE(IMediaControl_GetState(control, 3000, &state));
        if (state != State_Paused || hr != S_OK) goto done;
        REQUIRE(IMediaSeeking_GetCurrentPosition(seeking, &paused));
        if (!monitor(events, 150, 0, 0)) goto done;
        REQUIRE(IMediaSeeking_GetCurrentPosition(seeking, &current));
        if (current < paused - SECOND / 10 || current > paused + SECOND / 10) goto done;
        REQUIRE(IMediaControl_Run(control));
        if (!monitor(events, 300, 0, 0) || !position_near(seeking, target)) goto done;
    }

    REQUIRE(IMediaSeeking_GetCurrentPosition(seeking, &current));
    {
        DWORD remaining = (DWORD)((duration - current) / 10000);
        if (!monitor(events, remaining + 5000, 1, remaining > 1500 ? remaining - 1500 : 0)) goto done;
    }
    /* A seek after genuine EOS must reset the renderer before Pause/Run. */
    REQUIRE(IMediaControl_Pause(control));
    target = duration / 8;
    REQUIRE(IMediaSeeking_SetPositions(seeking, &target, AM_SEEKING_AbsolutePositioning,
            NULL, AM_SEEKING_NoPositioning));
    REQUIRE(IMediaControl_Run(control));
    if (!monitor(events, 500, 0, 0) || !position_near(seeking, target)) goto done;
    ok = 1;
done:
    if (control) IMediaControl_Stop(control);
    if (events) IMediaEvent_Release(events);
    if (seeking) IMediaSeeking_Release(seeking);
    if (control) IMediaControl_Release(control);
    if (renderer) IBaseFilter_Release(renderer);
    if (graph) IGraphBuilder_Release(graph);
    CoUninitialize();
    printf("repeated seek, no-position and pause/resume timeline: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
