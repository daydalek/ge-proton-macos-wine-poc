/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include <windows.h>
#include <dshow.h>
#include <qedit.h>
#include <stdio.h>
#include <wchar.h>

struct Capture : ISampleGrabberCB
{
    LONG armed = 0;
    HANDLE ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    REFERENCE_TIME first = 0;
    DWORD arrived = 0;
    ~Capture() { CloseHandle(ready); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override
    {
        if (iid == IID_IUnknown || iid == IID_ISampleGrabberCB) { *out = this; return S_OK; }
        *out = NULL; return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return 2; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }
    HRESULT STDMETHODCALLTYPE SampleCB(double, IMediaSample *sample) override
    {
        if (InterlockedCompareExchange(&armed, 0, 1) == 1)
        {
            REFERENCE_TIME end;
            sample->GetTime(&first, &end);
            arrived = GetTickCount();
            SetEvent(ready);
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE BufferCB(double, BYTE *, long) override { return E_NOTIMPL; }
    void arm() { ResetEvent(ready); InterlockedExchange(&armed, 1); }
};

static HRESULT observe(IGraphBuilder *graph, const wchar_t *renderer, Capture *capture)
{
    IBaseFilter *sink = NULL, *grab_filter = NULL;
    IEnumPins *pins = NULL; IPin *in = NULL, *upstream = NULL, *grab_in = NULL, *grab_out = NULL;
    ISampleGrabber *grab = NULL; HRESULT hr; AM_MEDIA_TYPE mt = {};
    hr = graph->FindFilterByName(renderer, &sink);
    if (FAILED(hr)) return hr;
    sink->EnumPins(&pins);
    while (pins->Next(1, &in, NULL) == S_OK)
    {
        PIN_DIRECTION dir; in->QueryDirection(&dir);
        if (dir == PINDIR_INPUT && SUCCEEDED(in->ConnectedTo(&upstream))) break;
        in->Release(); in = NULL;
    }
    if (!upstream) { hr = E_FAIL; goto done; }
    hr = in->ConnectionMediaType(&mt); if (FAILED(hr)) goto done;
    hr = CoCreateInstance(CLSID_SampleGrabber, NULL, CLSCTX_INPROC_SERVER, IID_IBaseFilter, (void **)&grab_filter);
    if (FAILED(hr)) goto done;
    hr = graph->AddFilter(grab_filter, capture ? L"Timestamp observer" : L"Observer");
    if (FAILED(hr)) goto done;
    hr = grab_filter->QueryInterface(IID_ISampleGrabber, (void **)&grab); if (FAILED(hr)) goto done;
    grab->SetMediaType(&mt); grab->SetCallback(capture, 0);
    grab_filter->FindPin(L"In", &grab_in); grab_filter->FindPin(L"Out", &grab_out);
    if (!grab_in || !grab_out) { hr = E_FAIL; goto done; }
    graph->Disconnect(upstream); graph->Disconnect(in);
    hr = graph->ConnectDirect(upstream, grab_in, &mt);
    if (SUCCEEDED(hr)) hr = graph->ConnectDirect(grab_out, in, &mt);
done:
    if (mt.pbFormat) CoTaskMemFree(mt.pbFormat);
    if (mt.pUnk) mt.pUnk->Release();
    if (grab_out) grab_out->Release(); if (grab_in) grab_in->Release();
    if (grab) grab->Release(); if (grab_filter) grab_filter->Release();
    if (upstream) upstream->Release(); if (in) in->Release();
    if (pins) pins->Release(); sink->Release(); return hr;
}
static void pump(DWORD ms)
{
    DWORD start = GetTickCount(); MSG msg;
    do { while(PeekMessageW(&msg,NULL,0,0,PM_REMOVE)) {TranslateMessage(&msg);DispatchMessageW(&msg);} Sleep(5); }
    while(GetTickCount()-start < ms);
}
int wmain(int argc, wchar_t **argv)
{
    if (argc != 2) return 2;
    setvbuf(stdout,NULL,_IONBF,0);
    CoInitialize(NULL);
    IGraphBuilder *graph = NULL; IMediaControl *control = NULL; IMediaSeeking *seek = NULL;
    Capture video, audio; int failures = 0; HRESULT hr;
    CoCreateInstance(CLSID_FilterGraph,NULL,CLSCTX_INPROC_SERVER,IID_IGraphBuilder,(void **)&graph);
    if (!graph) return 2;
    hr=graph->RenderFile(argv[1],NULL); printf("RenderFile=%#lx\n",hr); if(FAILED(hr)) return 2;
    hr=observe(graph,L"Video Renderer",&video); printf("observe video=%#lx\n",hr); if(FAILED(hr)) return 2;
    hr=observe(graph,L"Default DirectSound Device",&audio); printf("observe audio=%#lx\n",hr); if(FAILED(hr)) return 2;
    graph->QueryInterface(IID_IMediaControl,(void **)&control);
    graph->QueryInterface(IID_IMediaSeeking,(void **)&seek);
    control->Run(); pump(1100);
    // Rewind after read-ahead, including the same target twice; then seek in both directions.
    const LONGLONG targets[] = {0,0,30000000,10000000,0};
    for (unsigned int i=0;i<sizeof(targets)/sizeof(*targets);i++)
    {
        printf("CASE %u target=%lld\n",i,targets[i]);
        // Alternate paused and running seeks to cover blocking downstream Receive.
        if (!(i&1)) control->Pause();
        LONGLONG target=targets[i]; DWORD started=GetTickCount();
        hr=seek->SetPositions(&target,AM_SEEKING_AbsolutePositioning,NULL,AM_SEEKING_NoPositioning);
        video.arm(); audio.arm();
        control->Run();
        DWORD until=GetTickCount();
        while ((WaitForSingleObject(video.ready,0)!=WAIT_OBJECT_0 || WaitForSingleObject(audio.ready,0)!=WAIT_OBJECT_0)
                && GetTickCount()-until<2500) pump(10);
        bool ok=SUCCEEDED(hr) && WaitForSingleObject(video.ready,0)==WAIT_OBJECT_0
                && WaitForSingleObject(audio.ready,0)==WAIT_OBJECT_0
                && video.first<8000000 && video.first>-20000000
                && audio.first<8000000 && audio.first>-20000000;
        printf("RESULT %u %s hr=%#lx video=%.6f audio=%.6f elapsed=%lu\n",i,ok?"PASS":"FAIL",hr,
                video.first/1e7,audio.first/1e7,GetTickCount()-started);
        if(!ok) ++failures;
        pump(1100);
    }
    LONGLONG before = 0, after = 0, ignored = 123;
    seek->GetCurrentPosition(&before);
    hr = seek->SetPositions(&ignored, AM_SEEKING_NoPositioning, NULL, AM_SEEKING_NoPositioning);
    control->Pause(); pump(150); control->Run(); pump(300);
    seek->GetCurrentPosition(&after);
    bool resume = SUCCEEDED(hr) && after >= before && after - before < 10000000;
    printf("pause-resume/no-position %s before=%.6f after=%.6f\n",resume?"PASS":"FAIL",before/1e7,after/1e7);
    if (!resume) ++failures;
    control->Stop();
    video.arm(); audio.arm();
    LONGLONG zero=0;
    hr=seek->SetPositions(&zero,AM_SEEKING_AbsolutePositioning,NULL,0);
    control->Run();pump(1500);
    bool restart=SUCCEEDED(hr) && WaitForSingleObject(video.ready,0)==WAIT_OBJECT_0 && video.first<8000000;
    printf("stop-restart %s video=%.6f\n",restart?"PASS":"FAIL",video.first/1e7);
    if(!restart) ++failures;
    control->Stop(); control->Release(); seek->Release(); graph->Release();
    printf("failures=%d\n",failures);CoUninitialize();return failures?1:0;
}
