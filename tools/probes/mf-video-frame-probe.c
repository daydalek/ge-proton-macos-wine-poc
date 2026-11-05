/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Probe Source Reader video output: media types, decode/readback timing,
 * and per-band pixel statistics of decoded frames. */
#define COBJMACROS
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <d3d11.h>
#include <d3d10.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static void print_fourcc(unsigned long fcc, char *out)
{
    unsigned int i;
    for (i = 0; i < 4; ++i)
    {
        unsigned char c = (unsigned char)((fcc >> (8 * i)) & 0xff);
        out[i] = (c >= 0x20 && c < 0x7f) ? (char)c : '.';
    }
    out[4] = 0;
}

static void print_aperture(IMFMediaType *type, const GUID *attr, const char *name)
{
    MFVideoArea area;
    UINT32 size = 0;
    HRESULT hr = IMFMediaType_GetBlob(type, attr, (UINT8 *)&area, sizeof(area), &size);
    if (SUCCEEDED(hr) && size == sizeof(area))
        printf("  %s: offset=%d.%u,%d.%u area=%ldx%ld\n", name,
                (int)area.OffsetX.value, (unsigned int)area.OffsetX.fract,
                (int)area.OffsetY.value, (unsigned int)area.OffsetY.fract,
                (long)area.Area.cx, (long)area.Area.cy);
    else
        printf("  %s: absent\n", name);
}

static void print_media_type(IMFMediaType *type, const char *label)
{
    char fourcc[5];
    UINT64 framesize;
    UINT32 stride;
    GUID subtype;

    printf("%s:\n", label);
    if (SUCCEEDED(IMFMediaType_GetGUID(type, &MF_MT_SUBTYPE, &subtype)))
    {
        print_fourcc(subtype.Data1, fourcc);
        printf("  subtype=0x%08lx ('%s')\n", subtype.Data1, fourcc);
    }
    else
        printf("  subtype: absent\n");
    if (SUCCEEDED(IMFMediaType_GetUINT64(type, &MF_MT_FRAME_SIZE, &framesize)))
        printf("  frame_size=%ux%u\n", (unsigned int)(framesize >> 32),
                (unsigned int)(framesize & 0xffffffffu));
    else
        printf("  frame_size: absent\n");
    print_aperture(type, &MF_MT_MINIMUM_DISPLAY_APERTURE, "min_display_aperture");
    print_aperture(type, &MF_MT_GEOMETRIC_APERTURE, "geometric_aperture");
    if (SUCCEEDED(IMFMediaType_GetUINT32(type, &MF_MT_DEFAULT_STRIDE, &stride)))
        printf("  default_stride=%d\n", (int)stride);
    else
        printf("  default_stride: absent\n");
}

static void update_frame_size(IMFMediaType *type, UINT32 *w, UINT32 *h)
{
    UINT64 framesize;
    if (SUCCEEDED(IMFMediaType_GetUINT64(type, &MF_MT_FRAME_SIZE, &framesize)))
    {
        *w = (UINT32)(framesize >> 32);
        *h = (UINT32)(framesize & 0xffffffffu);
    }
}

static void band_mean_rgb(const BYTE *data, UINT32 pitch, UINT32 width,
        UINT32 start, UINT32 rows, double *mb, double *mg, double *mr, double *ma)
{
    UINT64 sb = 0, sg = 0, sr = 0, sa = 0;
    UINT32 x, y;
    for (y = start; y < start + rows; ++y)
    {
        const BYTE *row = data + (size_t)y * pitch;
        for (x = 0; x < width; ++x)
        {
            sb += row[4 * x];
            sg += row[4 * x + 1];
            sr += row[4 * x + 2];
            sa += row[4 * x + 3];
        }
    }
    *mb = (double)sb / ((double)rows * width);
    *mg = (double)sg / ((double)rows * width);
    *mr = (double)sr / ((double)rows * width);
    *ma = (double)sa / ((double)rows * width);
}

static void band_mean_y(const BYTE *data, UINT32 pitch, UINT32 width,
        UINT32 start, UINT32 rows, double *my)
{
    UINT64 sum = 0;
    UINT32 x, y;
    for (y = start; y < start + rows; ++y)
    {
        const BYTE *row = data + (size_t)y * pitch;
        for (x = 0; x < width; ++x)
            sum += row[x];
    }
    *my = (double)sum / ((double)rows * width);
}

static void band_mean_uv(const BYTE *chroma, UINT32 pitch, UINT32 width,
        UINT32 start, UINT32 rows, double *mu, double *mv)
{
    UINT64 su = 0, sv = 0;
    UINT32 x, y;
    for (y = start; y < start + rows; ++y)
    {
        const BYTE *row = chroma + (size_t)y * pitch;
        for (x = 0; x + 1 < width; x += 2)
        {
            su += row[x];
            sv += row[x + 1];
        }
    }
    *mu = (double)su / ((double)rows * (width / 2));
    *mv = (double)sv / ((double)rows * (width / 2));
}

static void print_band_stats(const BYTE *data, UINT32 pitch, UINT32 width,
        UINT32 height, int nv12, unsigned int frame_index)
{
    UINT32 starts[6];
    const char *names[6] = {"top", "band1", "band2", "middle", "last-1", "last"};
    UINT32 i;

    starts[0] = 0;
    starts[1] = 8;
    starts[2] = 16;
    starts[3] = height > 12 ? height / 2 - 4 : 0;
    starts[4] = height > 16 ? height - 16 : 0;
    starts[5] = height > 8 ? height - 8 : 0;

    printf("frame %u band stats (width=%u height=%u pitch=%u):\n",
            frame_index, width, height, pitch);
    for (i = 0; i < 6; ++i)
    {
        if (starts[i] + 8 > height)
            continue;
        if (nv12)
        {
            double my, mu, mv, au, av;
            band_mean_y(data, pitch, width, starts[i], 8, &my);
            band_mean_uv(data + (size_t)pitch * height, pitch, width,
                    starts[i] / 2, 4, &mu, &mv);
            band_mean_uv(data + (size_t)pitch * 1080, pitch, width,
                    starts[i] / 2, 4, &au, &av);
            printf("  %-6s rows %4u-%4u: Y=%.1f U=%.1f V=%.1f (alt1080 U=%.1f V=%.1f)\n",
                    names[i], starts[i], starts[i] + 7, my, mu, mv, au, av);
        }
        else
        {
            double mb, mg, mr, ma;
            band_mean_rgb(data, pitch, width, starts[i], 8, &mb, &mg, &mr, &ma);
            printf("  %-6s rows %4u-%4u: B=%.1f G=%.1f R=%.1f A=%.1f\n",
                    names[i], starts[i], starts[i] + 7, mb, mg, mr, ma);
        }
    }
}

static int dump_frame(const BYTE *data, UINT32 pitch, UINT32 width, UINT32 height,
        int nv12, const WCHAR *path)
{
    FILE *f = _wfopen(path, L"wb");
    UINT32 x, y;
    if (!f)
        return 0;
    if (nv12)
    {
        fprintf(f, "P5\n%u %u\n255\n", width, height);
        for (y = 0; y < height; ++y)
        {
            const BYTE *row = data + (size_t)y * pitch;
            for (x = 0; x < width; ++x)
                fputc(row[x], f);
        }
    }
    else
    {
        fprintf(f, "P6\n%u %u\n255\n", width, height);
        for (y = 0; y < height; ++y)
        {
            const BYTE *row = data + (size_t)y * pitch;
            for (x = 0; x < width; ++x)
            {
                fputc(row[4 * x + 2], f);
                fputc(row[4 * x + 1], f);
                fputc(row[4 * x + 0], f);
            }
        }
    }
    fclose(f);
    return 1;
}

static int cmp_double(const void *a, const void *b)
{
    double d = *(const double *)a - *(const double *)b;
    return (d > 0) - (d < 0);
}

int wmain(int argc, WCHAR **argv)
{
    IMFDXGIDeviceManager *manager = NULL;
    ID3D11DeviceContext *context = NULL;
    ID3D11Texture2D *staging = NULL;
    ID3D10Multithread *mt = NULL;
    ID3D11Device *device = NULL;
    IMFSourceReader *reader = NULL;
    IMFAttributes *attrs = NULL;
    IMFMediaType *type = NULL;
    D3D11_TEXTURE2D_DESC sdesc;
    LARGE_INTEGER freq, t0, t1;
    PROPVARIANT position;
    const GUID *wanted;
    unsigned int frames_wanted, got = 0, iter = 0;
    unsigned int stat_idx[3];
    UINT32 cur_w = 0, cur_h = 0;
    int use_d3d, is_nv12, use_url = 0;
    double *lat, *rb;
    HRESULT hr;
    UINT token = 0;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc != 6 && !(argc == 7 && !wcscmp(argv[6], L"url")))
    {
        fprintf(stderr,
                "usage: mf-video-frame-probe.exe <file.mp4> <d3d|cpu> <rgb32|argb32|nv12> <frames> <dump> [url]\n");
        return 2;
    }
    if (argc == 7)
        use_url = 1;
    if (!wcscmp(argv[2], L"d3d"))
        use_d3d = 1;
    else if (!wcscmp(argv[2], L"cpu"))
        use_d3d = 0;
    else
        return 2;
    if (!wcscmp(argv[3], L"rgb32"))
    {
        wanted = &MFVideoFormat_RGB32;
        is_nv12 = 0;
    }
    else if (!wcscmp(argv[3], L"argb32"))
    {
        wanted = &MFVideoFormat_ARGB32;
        is_nv12 = 0;
    }
    else if (!wcscmp(argv[3], L"nv12"))
    {
        wanted = &MFVideoFormat_NV12;
        is_nv12 = 1;
    }
    else
        return 2;
    frames_wanted = wcstoul(argv[4], NULL, 10);
    if (!frames_wanted || frames_wanted > 100000)
        return 2;
    lat = calloc(frames_wanted, sizeof(*lat));
    rb = calloc(frames_wanted, sizeof(*rb));
    if (!lat || !rb)
        return 1;
    stat_idx[0] = 0;
    stat_idx[1] = frames_wanted / 2;
    stat_idx[2] = frames_wanted - 1;

    printf("mode=%s subtype=%s frames=%u file=%ls\n", use_d3d ? "d3d" : "cpu",
            is_nv12 ? "nv12" : (wanted == &MFVideoFormat_RGB32 ? "rgb32" : "argb32"),
            frames_wanted, argv[1]);

    if (FAILED(hr = CoInitializeEx(NULL, COINIT_MULTITHREADED)))
        return 1;
    if (FAILED(hr = MFStartup(MF_VERSION, MFSTARTUP_FULL)))
        goto fail;

    if (use_d3d)
    {
        hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL,
                D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                NULL, 0, D3D11_SDK_VERSION, &device, NULL, &context);
        if (FAILED(hr))
        {
            fprintf(stderr, "D3D11CreateDevice failed: %#lx\n", hr);
            goto fail;
        }
        if (SUCCEEDED(hr = ID3D11Device_QueryInterface(device,
                &IID_ID3D10Multithread, (void **)&mt)))
        {
            ID3D10Multithread_SetMultithreadProtected(mt, TRUE);
            ID3D10Multithread_Release(mt);
        }
        if (FAILED(hr = MFCreateDXGIDeviceManager(&token, &manager))
                || FAILED(hr = IMFDXGIDeviceManager_ResetDevice(manager,
                        (IUnknown *)device, token)))
            goto fail;
        printf("d3d11 device created, dxgi manager reset\n");
    }

    if (FAILED(hr = MFCreateAttributes(&attrs, 4)))
        goto fail;
    if (use_d3d)
    {
        IMFAttributes_SetUINT32(attrs, &MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1);
        IMFAttributes_SetUnknown(attrs, &MF_SOURCE_READER_D3D_MANAGER, (IUnknown *)manager);
    }
    else
    {
        IMFAttributes_SetUINT32(attrs, &MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1);
    }

    if (use_url)
    {
        /* Exercises the resolver + file scheme handler end to end; plain
         * paths and file: URLs are all routed through this call. */
        hr = MFCreateSourceReaderFromURL(argv[1], attrs, &reader);
    }
    else
    {
        IMFByteStream *stream = NULL;

        hr = MFCreateFile(MF_ACCESSMODE_READ, MF_OPENMODE_FAIL_IF_NOT_EXIST,
                MF_FILEFLAGS_NONE, argv[1], &stream);
        if (SUCCEEDED(hr))
            hr = MFCreateSourceReaderFromByteStream(stream, attrs, &reader);
        if (stream)
            IMFByteStream_Release(stream);
    }
    IMFAttributes_Release(attrs);
    attrs = NULL;
    if (FAILED(hr))
        goto fail;
    printf("reader created\n");

    if (FAILED(hr = IMFSourceReader_SetStreamSelection(reader, MF_SOURCE_READER_ALL_STREAMS, FALSE))
            || FAILED(hr = IMFSourceReader_SetStreamSelection(reader,
                    MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE)))
        goto fail;

    if (SUCCEEDED(hr = IMFSourceReader_GetNativeMediaType(reader,
            MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &type)))
    {
        print_media_type(type, "native media type");
        IMFMediaType_Release(type);
        type = NULL;
    }
    else
        printf("native media type: unavailable %#lx\n", hr);

    if (FAILED(hr = MFCreateMediaType(&type)))
        goto fail;
    hr = IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    if (SUCCEEDED(hr))
        hr = IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, wanted);
    if (SUCCEEDED(hr))
        hr = IMFSourceReader_SetCurrentMediaType(reader,
                MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, type);
    IMFMediaType_Release(type);
    type = NULL;
    if (FAILED(hr))
        goto fail;

    if (SUCCEEDED(hr = IMFSourceReader_GetCurrentMediaType(reader,
            MF_SOURCE_READER_FIRST_VIDEO_STREAM, &type)))
    {
        print_media_type(type, "current media type (after set)");
        update_frame_size(type, &cur_w, &cur_h);
        IMFMediaType_Release(type);
        type = NULL;
    }
    else
        printf("current media type: unavailable %#lx\n", hr);

    PropVariantInit(&position);
    position.vt = VT_I8;
    position.hVal.QuadPart = 100000000; /* 10 s */
    hr = IMFSourceReader_SetCurrentPosition(reader, &GUID_NULL, &position);
    PropVariantClear(&position);
    if (FAILED(hr))
        goto fail;
    printf("seek to 10 s done\n");

    QueryPerformanceFrequency(&freq);
    {
        LONGLONG prev_ts = -1, delta_sum = 0;
        unsigned int i, over17 = 0, over33 = 0;
        int eof = 0;

        while (got < frames_wanted && iter < frames_wanted * 4 + 32)
        {
            DWORD index = 0, flags = 0;
            LONGLONG timestamp = -1;
            IMFSample *sample = NULL;
            IMFMediaBuffer *buffer = NULL;
            IMFDXGIBuffer *dxgi = NULL;
            const BYTE *data = NULL;
            UINT32 pitch = 0, height = 0, width = 0;
            IMF2DBuffer *buffer2d = NULL;
            ID3D11Texture2D *tex = NULL;
            D3D11_MAPPED_SUBRESOURCE mapped;
            BYTE *locked = NULL;
            LONG locked_pitch = 0;
            int via_dxgi = 0;

            ++iter;
            QueryPerformanceCounter(&t0);
            hr = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM,
                    0, &index, &flags, &timestamp, &sample);
            QueryPerformanceCounter(&t1);
            if (FAILED(hr))
                goto fail;
            if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED)
            {
                printf("media type changed at sample %u (flags=%#lx)\n", got, flags);
                if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType(reader,
                        MF_SOURCE_READER_FIRST_VIDEO_STREAM, &type)))
                {
                    print_media_type(type, "current media type (changed)");
                    update_frame_size(type, &cur_w, &cur_h);
                    IMFMediaType_Release(type);
                    type = NULL;
                }
            }
            if (flags & MF_SOURCE_READERF_ENDOFSTREAM)
            {
                printf("end of stream after %u samples\n", got);
                eof = 1;
                if (sample)
                    IMFSample_Release(sample);
                break;
            }
            if (!sample)
                continue;

            lat[got] = (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart;
            if (prev_ts >= 0)
                delta_sum += timestamp - prev_ts;
            prev_ts = timestamp;

            hr = IMFSample_GetBufferByIndex(sample, 0, &buffer);
            if (SUCCEEDED(hr))
                hr = IMFMediaBuffer_QueryInterface(buffer,
                        &IID_IMFDXGIBuffer, (void **)&dxgi);

            QueryPerformanceCounter(&t0);
            if (SUCCEEDED(hr) && dxgi)
            {
                UINT subresource = 0;
                D3D11_TEXTURE2D_DESC desc;

                via_dxgi = 1;
                IMFDXGIBuffer_GetSubresourceIndex(dxgi, &subresource);
                if (FAILED(hr = IMFDXGIBuffer_GetResource(dxgi,
                        &IID_ID3D11Texture2D, (void **)&tex)))
                {
                    fprintf(stderr, "dxgi buffer resource failed %#lx\n", hr);
                    IMFDXGIBuffer_Release(dxgi);
                    IMFMediaBuffer_Release(buffer);
                    IMFSample_Release(sample);
                    goto fail;
                }
                ID3D11Texture2D_GetDesc(tex, &desc);
                if (got == 0)
                    printf("dxgi texture: %ux%u format=%u usage=%u bind=%#lx misc=%#lx subresource=%u\n",
                            desc.Width, desc.Height, desc.Format, desc.Usage,
                            (unsigned long)desc.BindFlags,
                            (unsigned long)desc.MiscFlags, subresource);
                memset(&sdesc, 0, sizeof(sdesc));
                sdesc.Width = desc.Width;
                sdesc.Height = desc.Height;
                sdesc.MipLevels = 1;
                sdesc.ArraySize = 1;
                sdesc.Format = desc.Format;
                sdesc.SampleDesc.Count = 1;
                sdesc.Usage = D3D11_USAGE_STAGING;
                sdesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                if (!staging
                        && FAILED(hr = ID3D11Device_CreateTexture2D(device,
                                &sdesc, NULL, &staging)))
                {
                    fprintf(stderr, "staging texture creation failed %#lx\n", hr);
                    ID3D11Texture2D_Release(tex);
                    IMFDXGIBuffer_Release(dxgi);
                    IMFMediaBuffer_Release(buffer);
                    IMFSample_Release(sample);
                    goto fail;
                }
                ID3D11DeviceContext_CopySubresourceRegion(context,
                        (ID3D11Resource *)staging, 0, 0, 0, 0,
                        (ID3D11Resource *)tex, subresource, NULL);
                if (FAILED(hr = ID3D11DeviceContext_Map(context,
                        (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped)))
                {
                    ID3D11Texture2D_Release(tex);
                    IMFDXGIBuffer_Release(dxgi);
                    IMFMediaBuffer_Release(buffer);
                    IMFSample_Release(sample);
                    goto fail;
                }
                data = mapped.pData;
                pitch = mapped.RowPitch;
                width = desc.Width;
                height = desc.Height;
            }
            else if (buffer)
            {
                DWORD maxlen = 0, curlen = 0;

                if (SUCCEEDED(IMFMediaBuffer_QueryInterface(buffer,
                        &IID_IMF2DBuffer, (void **)&buffer2d)))
                {
                    hr = IMF2DBuffer_Lock2D(buffer2d, &locked, &locked_pitch);
                }
                else
                {
                    hr = IMFMediaBuffer_Lock(buffer, &locked, &maxlen, &curlen);
                    locked_pitch = (LONG)cur_w * (is_nv12 ? 1 : 4);
                    if (got == 0)
                        printf("1d buffer: maxlen=%lu\n", (unsigned long)maxlen);
                }
                if (FAILED(hr))
                {
                    IMFMediaBuffer_Release(buffer);
                    IMFSample_Release(sample);
                    goto fail;
                }
                data = locked;
                pitch = locked_pitch < 0 ? (UINT32)(-locked_pitch) : (UINT32)locked_pitch;
                if (locked_pitch < 0 && got == 0)
                    printf("note: negative stride (bottom-up)\n");
                width = cur_w;
                height = cur_h;
                if (got == 0
                        && SUCCEEDED(IMFMediaBuffer_GetCurrentLength(buffer, &curlen)))
                    printf("cpu buffer: length=%lu pitch=%d rows=%lu\n",
                            (unsigned long)curlen, (int)locked_pitch,
                            (unsigned long)(pitch ? curlen / pitch : 0));
            }
            QueryPerformanceCounter(&t1);
            rb[got] = (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart;

            if (data)
            {
                unsigned int s;
                for (s = 0; s < 3; ++s)
                    if (got == stat_idx[s])
                        print_band_stats(data, pitch, width, height, is_nv12, got);
                if (got == frames_wanted / 2)
                    printf("dump %s: %ls\n",
                            dump_frame(data, pitch, width, height, is_nv12, argv[5])
                                    ? "written" : "FAILED",
                            argv[5]);
            }

            if (via_dxgi)
            {
                ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
                ID3D11Texture2D_Release(tex);
                IMFDXGIBuffer_Release(dxgi);
            }
            else if (buffer)
            {
                if (buffer2d)
                {
                    IMF2DBuffer_Unlock2D(buffer2d);
                    IMF2DBuffer_Release(buffer2d);
                }
                else
                    IMFMediaBuffer_Unlock(buffer);
            }
            if (buffer)
                IMFMediaBuffer_Release(buffer);
            IMFSample_Release(sample);
            ++got;
        }
        (void)eof;

        if (got)
        {
            double sum = 0;
            qsort(rb, got, sizeof(*rb), cmp_double);
            for (i = 0; i < got; ++i)
                sum += rb[i];
            printf("readback ms: avg=%.2f max=%.2f p95=%.2f\n",
                    sum / got, rb[got - 1],
                    rb[(size_t)((got - 1) * 0.95 + 0.5)]);

            sum = 0;
            qsort(lat, got, sizeof(*lat), cmp_double);
            for (i = 0; i < got; ++i)
            {
                sum += lat[i];
                if (lat[i] > 16.7)
                    ++over17;
                if (lat[i] > 33.0)
                    ++over33;
            }
            printf("readsample ms: avg=%.2f max=%.2f p95=%.2f over16.7=%u over33=%u\n",
                    sum / got, lat[got - 1],
                    lat[(size_t)((got - 1) * 0.95 + 0.5)], over17, over33);
            if (got > 1)
                printf("timestamp delta avg=%.2f ms\n",
                        (double)delta_sum / (got - 1) / 10000.0);
            printf("frames read=%u (requested %u)\n", got, frames_wanted);
        }
    }

    free(lat);
    free(rb);
    if (staging) ID3D11Texture2D_Release(staging);
    if (reader) IMFSourceReader_Release(reader);
    if (manager) IMFDXGIDeviceManager_Release(manager);
    if (context) ID3D11DeviceContext_Release(context);
    if (device) ID3D11Device_Release(device);
    MFShutdown();
    CoUninitialize();
    return 0;

fail:
    fprintf(stderr, "operation failed: %#lx\n", hr);
    free(lat);
    free(rb);
    if (staging) ID3D11Texture2D_Release(staging);
    if (reader) IMFSourceReader_Release(reader);
    if (manager) IMFDXGIDeviceManager_Release(manager);
    if (context) ID3D11DeviceContext_Release(context);
    if (device) ID3D11Device_Release(device);
    MFShutdown();
    CoUninitialize();
    return 1;
}
