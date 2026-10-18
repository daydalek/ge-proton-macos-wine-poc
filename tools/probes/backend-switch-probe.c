/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* D3D11 routing and DirectDraw GDI presentation smoke probe. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <ddraw.h>
#include <stdio.h>
#include <string.h>

static int test_ddraw(HWND hwnd)
{
    typedef HRESULT (WINAPI *create_fn)(GUID *, void **, REFIID, IUnknown *);
    HMODULE module = LoadLibraryA("ddraw.dll");
    create_fn create;
    IDirectDraw7 *ddraw = NULL;
    IDirectDrawSurface7 *primary = NULL;
    DDSURFACEDESC2 desc = {0};
    DDBLTFX fx = {0};
    RECT rect;
    HRESULT hr;
    if (!module) return 3;
    create = (create_fn)GetProcAddress(module, "DirectDrawCreateEx");
    if (!create) return 4;
    hr = create(NULL, (void **)&ddraw, &IID_IDirectDraw7, NULL);
    if (SUCCEEDED(hr)) hr = IDirectDraw7_SetCooperativeLevel(ddraw, hwnd, DDSCL_NORMAL);
    desc.dwSize = sizeof(desc);
    desc.dwFlags = DDSD_CAPS;
    desc.ddsCaps.dwCaps = DDSCAPS_PRIMARYSURFACE;
    if (SUCCEEDED(hr)) hr = IDirectDraw7_CreateSurface(ddraw, &desc, &primary, NULL);
    printf("DDRAW_PRIMARY=%#lx\n", (unsigned long)hr); fflush(stdout);
    if (SUCCEEDED(hr))
    {
        GetClientRect(hwnd, &rect);
        MapWindowPoints(hwnd, NULL, (POINT *)&rect, 2);
        fx.dwSize = sizeof(fx);
        fx.dwFillColor = 0x003388;
        hr = IDirectDrawSurface7_Blt(primary, &rect, NULL, NULL, DDBLT_COLORFILL | DDBLT_WAIT, &fx);
        printf("DDRAW_BLT=%#lx\n", (unsigned long)hr); fflush(stdout);
        Sleep(300);
    }
    printf("WINED3D_LOADED=%d\n", GetModuleHandleA("wined3d.dll") != NULL); fflush(stdout);
    if (primary) IDirectDrawSurface7_Release(primary);
    if (ddraw) IDirectDraw7_Release(ddraw);
    DestroyWindow(hwnd);
    return FAILED(hr);
}

int main(int argc, char **argv)
{
    typedef HRESULT (WINAPI *create_fn)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT,
        const D3D_FEATURE_LEVEL *, UINT, UINT, const DXGI_SWAP_CHAIN_DESC *,
        IDXGISwapChain **, ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
    WNDCLASSA cls = {0};
    HWND hwnd;
    HMODULE module;
    create_fn create;
    DXGI_SWAP_CHAIN_DESC desc = {0};
    IDXGISwapChain *swap = NULL;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HRESULT hr;
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    cls.lpfnWndProc = DefWindowProcA;
    cls.hInstance = GetModuleHandleA(NULL);
    cls.lpszClassName = "BackendSwitchProbe";
    RegisterClassA(&cls);
    hwnd = CreateWindowA(cls.lpszClassName, "Isolated backend switch probe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT, CW_USEDEFAULT, 660, 400, NULL, NULL, cls.hInstance, NULL);
    if (!hwnd) return 2;
    if (argc > 1 && !strcmp(argv[1], "--ddraw")) return test_ddraw(hwnd);
    module = LoadLibraryA("d3d11.dll");
    if (!module) { printf("LOAD FAIL %lu\n", GetLastError()); return 3; }
    create = (create_fn)GetProcAddress(module, "D3D11CreateDeviceAndSwapChain");
    if (!create) return 4;
    desc.BufferDesc.Width = 640;
    desc.BufferDesc.Height = 360;
    desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.OutputWindow = hwnd;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    hr = create(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
        &desc, &swap, &device, &level, &context);
    printf("D3D11_CREATE=%#lx FEATURE_LEVEL=%#x\n", (unsigned long)hr, level); fflush(stdout);
    if (SUCCEEDED(hr))
    {
        ID3D11Texture2D *buffer = NULL;
        ID3D11RenderTargetView *rtv = NULL;
        const FLOAT color[4] = {0.3f, 0.3f, 0.7f, 1.0f};
        hr = IDXGISwapChain_GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&buffer);
        if (SUCCEEDED(hr)) hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)buffer, NULL, &rtv);
        if (SUCCEEDED(hr))
        {
            ID3D11DeviceContext_ClearRenderTargetView(context, rtv, color);
            hr = IDXGISwapChain_Present(swap, 1, 0);
        }
        printf("CLEAR_PRESENT=%#lx\n", (unsigned long)hr); fflush(stdout);
        Sleep(300);
        if (rtv) ID3D11RenderTargetView_Release(rtv);
        if (buffer) ID3D11Texture2D_Release(buffer);
        IDXGISwapChain_Release(swap);
        ID3D11DeviceContext_Release(context);
        ID3D11Device_Release(device);
    }
    printf("WINED3D_LOADED=%d\n", GetModuleHandleA("wined3d.dll") != NULL); fflush(stdout);
    DestroyWindow(hwnd);
    return FAILED(hr);
}
