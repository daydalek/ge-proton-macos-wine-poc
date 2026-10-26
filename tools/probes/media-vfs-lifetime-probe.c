/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Usage: probe.exe render|source|missing <absolute media path> [hook DLL]
 * For hooks gated on the executable name, use the expected basename in an
 * isolated directory containing the hook's read-only resource fixtures.
 * Creates a graph without starting playback. source verifies a readable pin.
 */
#define COBJMACROS
#include <windows.h>
#include <dshow.h>
#include <stdio.h>
#include <wchar.h>

int wmain(int argc, wchar_t **argv)
{
    IGraphBuilder *graph = NULL;
    IBaseFilter *source = NULL;
    IEnumPins *pins = NULL;
    IPin *pin = NULL;
    IAsyncReader *reader = NULL;
    HRESULT hr;
    int result = 1;

    if (argc < 3 || argc > 4
            || (wcscmp(argv[1], L"render") && wcscmp(argv[1], L"source")
                && wcscmp(argv[1], L"missing")))
    {
        fputs("Usage: probe.exe render|source|missing <absolute media path> [hook DLL]\n", stderr);
        return 2;
    }
    if (argc == 4 && !LoadLibraryW(argv[3])) return 3;
    hr = CoInitialize(NULL);
    if (FAILED(hr)) return 4;
    hr = CoCreateInstance(&CLSID_FilterGraph, NULL, CLSCTX_INPROC_SERVER,
            &IID_IGraphBuilder, (void **)&graph);
    printf("FilterGraph=%08lx\n", (unsigned long)hr);
    if (FAILED(hr)) goto done;

    if (!wcscmp(argv[1], L"source"))
    {
        BYTE bytes[32] = {0};
        unsigned int i;
        hr = IGraphBuilder_AddSourceFilter(graph, argv[2], L"Source", &source);
        printf("AddSourceFilter=%08lx\n", (unsigned long)hr);
        if (FAILED(hr)) goto done;
        hr = IBaseFilter_EnumPins(source, &pins);
        if (FAILED(hr) || IEnumPins_Next(pins, 1, &pin, NULL) != S_OK) goto done;
        hr = IPin_QueryInterface(pin, &IID_IAsyncReader, (void **)&reader);
        if (FAILED(hr)) goto done;
        hr = IAsyncReader_SyncRead(reader, 0, sizeof(bytes), bytes);
        printf("SyncRead=%08lx header=", (unsigned long)hr);
        for (i = 0; i < sizeof(bytes); ++i) printf("%02x", bytes[i]);
        puts("");
        /* The fixture is an MPEG program stream. S_FALSE means a short read. */
        result = hr != S_OK || bytes[0] || bytes[1] || bytes[2] != 1 || bytes[3] != 0xba;
    }
    else
    {
        hr = IGraphBuilder_RenderFile(graph, argv[2], NULL);
        printf("RenderFile=%08lx\n", (unsigned long)hr);
        result = !wcscmp(argv[1], L"missing") ? SUCCEEDED(hr) : hr != S_OK;
    }
done:
    if (reader) IAsyncReader_Release(reader);
    if (pin) IPin_Release(pin);
    if (pins) IEnumPins_Release(pins);
    if (source) IBaseFilter_Release(source);
    if (graph) IGraphBuilder_Release(graph);
    CoUninitialize();
    return result;
}
