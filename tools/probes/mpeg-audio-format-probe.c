/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define COBJMACROS
#include <windows.h>
#include <dshow.h>
#include <mmreg.h>
#include <stdio.h>

static IPin *find_pin(IBaseFilter *filter, PIN_DIRECTION direction)
{
    IEnumPins *enumerator; IPin *pin; PIN_DIRECTION actual;
    if (FAILED(IBaseFilter_EnumPins(filter, &enumerator))) return NULL;
    while (IEnumPins_Next(enumerator, 1, &pin, NULL) == S_OK)
    {
        if (SUCCEEDED(IPin_QueryDirection(pin, &actual)) && actual == direction)
        { IEnumPins_Release(enumerator); return pin; }
        IPin_Release(pin);
    }
    IEnumPins_Release(enumerator); return NULL;
}

static void free_type(AM_MEDIA_TYPE *type)
{
    CoTaskMemFree(type->pbFormat);
    if (type->pUnk) IUnknown_Release(type->pUnk);
    CoTaskMemFree(type);
}

int wmain(int argc, wchar_t **argv)
{
    IGraphBuilder *graph = NULL; IBaseFilter *reader = NULL, *splitter = NULL, *decoder = NULL;
    IFileSourceFilter *file = NULL; IPin *source = NULL, *sink = NULL, *decoder_input = NULL, *pin;
    IEnumPins *pins = NULL; IEnumMediaTypes *types; AM_MEDIA_TYPE *type;
    PIN_DIRECTION direction; HRESULT hr; int ok = 0, found = 0;
    if (argc != 2) { printf("Usage: mpeg-audio-format-probe.exe file.mpg\n"); return 2; }
    if (FAILED(hr = CoInitialize(NULL))) return 1;
    if (FAILED(hr = CoCreateInstance(&CLSID_FilterGraph, NULL, CLSCTX_INPROC_SERVER, &IID_IGraphBuilder, (void **)&graph))) goto done;
    if (FAILED(hr = CoCreateInstance(&CLSID_AsyncReader, NULL, CLSCTX_INPROC_SERVER, &IID_IBaseFilter, (void **)&reader))) goto done;
    if (FAILED(hr = IBaseFilter_QueryInterface(reader, &IID_IFileSourceFilter, (void **)&file))) goto done;
    if (FAILED(hr = IFileSourceFilter_Load(file, argv[1], NULL))) goto done;
    if (FAILED(hr = CoCreateInstance(&CLSID_MPEG1Splitter, NULL, CLSCTX_INPROC_SERVER, &IID_IBaseFilter, (void **)&splitter))) goto done;
    if (FAILED(hr = CoCreateInstance(&CLSID_CMpegAudioCodec, NULL, CLSCTX_INPROC_SERVER, &IID_IBaseFilter, (void **)&decoder))) goto done;
    if (FAILED(hr = IGraphBuilder_AddFilter(graph, reader, L"Reader"))) goto done;
    if (FAILED(hr = IGraphBuilder_AddFilter(graph, splitter, L"Splitter"))) goto done;
    if (FAILED(hr = IGraphBuilder_AddFilter(graph, decoder, L"Decoder"))) goto done;
    source = find_pin(reader, PINDIR_OUTPUT); sink = find_pin(splitter, PINDIR_INPUT);
    decoder_input = find_pin(decoder, PINDIR_INPUT);
    if (!source || !sink || !decoder_input) { hr = E_FAIL; goto done; }
    if (FAILED(hr = IGraphBuilder_ConnectDirect(graph, source, sink, NULL))) goto done;
    if (FAILED(hr = IBaseFilter_EnumPins(splitter, &pins))) goto done;
    while (!found && IEnumPins_Next(pins, 1, &pin, NULL) == S_OK)
    {
        if (SUCCEEDED(IPin_QueryDirection(pin, &direction)) && direction == PINDIR_OUTPUT
                && SUCCEEDED(IPin_EnumMediaTypes(pin, &types)))
        {
            while (!found && IEnumMediaTypes_Next(types, 1, &type, NULL) == S_OK)
            {
                if (IsEqualGUID(&type->majortype, &MEDIATYPE_Audio)
                        && IsEqualGUID(&type->formattype, &FORMAT_WaveFormatEx)
                        && type->cbFormat >= sizeof(WAVEFORMATEX)
                        && ((WAVEFORMATEX *)type->pbFormat)->wFormatTag == WAVE_FORMAT_MPEG)
                {
                    MPEG1WAVEFORMAT *format = (MPEG1WAVEFORMAT *)type->pbFormat;
                    found = 1;
                    printf("MPEG format size: %lu; expected at least %u\n", type->cbFormat, (unsigned)sizeof(*format));
                    if (type->cbFormat >= sizeof(*format)
                            && (format->fwHeadLayer == ACM_MPEG_LAYER1 || format->fwHeadLayer == ACM_MPEG_LAYER2))
                    {
                        printf("Layer flags: %#x; bitrate: %lu\n", format->fwHeadLayer, format->dwHeadBitrate);
                        hr = IPin_QueryAccept(decoder_input, type);
                        if (hr == S_OK) hr = IGraphBuilder_ConnectDirect(graph, pin, decoder_input, type);
                        ok = hr == S_OK;
                    }
                    else hr = VFW_E_TYPE_NOT_ACCEPTED;
                }
                free_type(type);
            }
            IEnumMediaTypes_Release(types);
        }
        IPin_Release(pin);
    }
done:
    printf("MPEG audio format regression: %s, HRESULT=%#lx\n", ok ? "PASS" : "FAIL", hr);
    if (pins) IEnumPins_Release(pins);
    if (decoder_input) IPin_Release(decoder_input);
    if (sink) IPin_Release(sink);
    if (source) IPin_Release(source);
    if (file) IFileSourceFilter_Release(file);
    if (graph) IGraphBuilder_Release(graph);
    if (decoder) IBaseFilter_Release(decoder);
    if (splitter) IBaseFilter_Release(splitter);
    if (reader) IBaseFilter_Release(reader);
    CoUninitialize(); return ok ? 0 : 1;
}
