/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Check Source Reader sample and returned timestamps after absolute seeks. */
#define COBJMACROS
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <stdio.h>

int wmain(int argc, WCHAR **argv)
{
    static const LONGLONG targets[] = {5000000, 15000000, 0, 8000000};
    IMFSourceReader *reader = NULL;
    IMFByteStream *stream = NULL;
    IMFMediaType *type = NULL;
    unsigned int i, j, failures = 0;
    LONGLONG timestamp, sample_time;
    DWORD index, flags;
    IMFSample *sample;
    PROPVARIANT position;
    HRESULT hr;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc != 2)
    {
        fprintf(stderr, "usage: mf-source-reader-seek-probe.exe <all-keyframe-h264.mp4>\n");
        return 2;
    }
    if (FAILED(hr = CoInitializeEx(NULL, COINIT_MULTITHREADED)))
        return 1;
    if (FAILED(hr = MFStartup(MF_VERSION, MFSTARTUP_FULL)))
        goto fail;
    if (FAILED(hr = MFCreateFile(MF_ACCESSMODE_READ, MF_OPENMODE_FAIL_IF_NOT_EXIST,
            MF_FILEFLAGS_NONE, argv[1], &stream)))
        goto fail;
    hr = MFCreateSourceReaderFromByteStream(stream, NULL, &reader);
    IMFByteStream_Release(stream);
    if (FAILED(hr))
        goto fail;
    if (FAILED(hr = IMFSourceReader_SetStreamSelection(reader, MF_SOURCE_READER_ALL_STREAMS, FALSE))
            || FAILED(hr = IMFSourceReader_SetStreamSelection(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE))
            || FAILED(hr = MFCreateMediaType(&type)))
        goto fail;
    hr = IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    if (SUCCEEDED(hr))
        hr = IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, &MFVideoFormat_NV12);
    if (SUCCEEDED(hr))
        hr = IMFSourceReader_SetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, type);
    IMFMediaType_Release(type);
    if (FAILED(hr))
        goto fail;

    for (i = 0; i < sizeof(targets) / sizeof(targets[0]); ++i)
    {
        PropVariantInit(&position);
        position.vt = VT_I8;
        position.hVal.QuadPart = targets[i];
        if (FAILED(hr = IMFSourceReader_SetCurrentPosition(reader, &GUID_NULL, &position)))
            goto fail;
        for (j = 0; j < 4; ++j)
        {
            sample = NULL;
            index = flags = 0;
            timestamp = sample_time = -1;
            hr = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0,
                    &index, &flags, &timestamp, &sample);
            if (SUCCEEDED(hr) && sample)
                hr = IMFSample_GetSampleTime(sample, &sample_time);
            if (FAILED(hr) || !sample)
            {
                if (sample) IMFSample_Release(sample);
                goto fail;
            }
            printf("seek=%lld frame=%u response=%lld sample=%lld flags=%#lx\n",
                    (long long)targets[i], j, (long long)timestamp, (long long)sample_time, flags);
            if (timestamp != sample_time || (j == 0 && (timestamp < targets[i] - 400000
                    || timestamp > targets[i] + 400000)))
                ++failures;
            IMFSample_Release(sample);
        }
    }
    IMFSourceReader_Release(reader);
    MFShutdown();
    CoUninitialize();
    printf("failures=%u\n", failures);
    return failures ? 1 : 0;

fail:
    fprintf(stderr, "Media Foundation operation failed: %#lx\n", hr);
    if (reader) IMFSourceReader_Release(reader);
    MFShutdown();
    CoUninitialize();
    return 1;
}
