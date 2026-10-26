/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define COBJMACROS
#include <windows.h>
#include <wmsdk.h>
#include <nserror.h>
#include <stdio.h>
#include <stdlib.h>

int wmain(int argc, wchar_t **argv)
{
    IWMSyncReader *reader = NULL;
    HMODULE module;
    HRESULT (WINAPI *create)(IUnknown *, DWORD, IWMSyncReader **);
    HRESULT hr;
    DWORD outputs, i, count, limit;
    WORD stream = 0;
    QWORD restart_pts = 0;
    unsigned int run, runs;
    int ret = 1;

    if (argc < 2 || argc > 4)
    {
        puts("Usage: wm-reader-video-probe.exe VIDEO [samples=120] [runs=2]");
        puts("Reads video silently; 0 samples reads to EOF. Each run checks restart timestamps.");
        return 2;
    }
    limit = argc > 2 ? wcstoul(argv[2], NULL, 10) : 120;
    runs = argc > 3 ? wcstoul(argv[3], NULL, 10) : 2;
    if (limit == 1 || !runs) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    module = LoadLibraryW(L"wmvcore.dll");
    create = module ? (void *)GetProcAddress(module, "WMCreateSyncReader") : NULL;
    if (!create) goto done;
    if (FAILED(hr = create(NULL, 0, &reader))) goto done;
    if (FAILED(hr = IWMSyncReader_Open(reader, argv[1]))) goto done;
    if (FAILED(hr = IWMSyncReader_GetOutputCount(reader, &outputs))) goto done;
    for (i = 0; i < outputs; ++i)
    {
        IWMOutputMediaProps *props;
        WM_MEDIA_TYPE *type;
        DWORD size = 0;
        if (FAILED(hr = IWMSyncReader_GetOutputProps(reader, i, &props))) goto done;
        hr = IWMOutputMediaProps_GetMediaType(props, NULL, &size);
        if (FAILED(hr)) { IWMOutputMediaProps_Release(props); goto done; }
        type = malloc(size);
        if (!type) { IWMOutputMediaProps_Release(props); goto done; }
        hr = IWMOutputMediaProps_GetMediaType(props, type, &size);
        if (SUCCEEDED(hr) && IsEqualGUID(&type->majortype, &WMMEDIATYPE_Video))
            hr = IWMSyncReader_GetStreamNumberForOutput(reader, i, &stream);
        free(type);
        IWMOutputMediaProps_Release(props);
        if (FAILED(hr)) goto done;
        if (stream) break;
    }
    if (!stream) { puts("video output missing"); goto done; }
    printf("video stream=%u output=%lu\n", stream, i);
    for (run = 0; run < runs; ++run)
    {
        QWORD previous = 0, first = 0, last = 0;
        if (FAILED(hr = IWMSyncReader_SetRange(reader, 0, 0))) goto done;
        for (count = 0; !limit || count < limit; ++count)
        {
            INSSBuffer *sample = NULL;
            QWORD pts, duration;
            DWORD flags, output, length = 0;
            WORD returned_stream;
            hr = IWMSyncReader_GetNextSample(reader, stream, &sample,
                    &pts, &duration, &flags, &output, &returned_stream);
            if (FAILED(hr))
            {
                if (!limit && hr == NS_E_NO_MORE_SAMPLES && count >= 2) break;
                printf("run=%u sample=%lu read failed=%#lx\n", run, count, hr);
                goto done;
            }
            hr = INSSBuffer_GetLength(sample, &length);
            INSSBuffer_Release(sample);
            if (FAILED(hr) || !length || returned_stream != stream
                    || (count && pts <= previous) || !duration)
            {
                printf("invalid sample=%lu pts=%llu previous=%llu duration=%llu bytes=%lu\n",
                        count, pts, previous, duration, length);
                goto done;
            }
            if (!count) first = pts;
            last = previous = pts;
        }
        printf("run=%u samples=%lu first=%llu last=%llu\n", run, count, first, last);
        if (!run) restart_pts = first;
        if (first != restart_pts || last <= first) goto done;
    }
    ret = 0;
done:
    if (reader) { IWMSyncReader_Close(reader); IWMSyncReader_Release(reader); }
    if (module) FreeLibrary(module);
    CoUninitialize();
    printf("result=%d\n", ret);
    return ret;
}
