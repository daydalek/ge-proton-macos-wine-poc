/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * d3d11 video-device shim for DXVK-backed Wine prefixes.
 *
 * Problem: applications that decode video through Media Foundation create a
 * second, video-capable D3D11 device, let MF decode into textures on it, and
 * then pass those textures to the rendering device with
 * IDXGIResource::GetSharedHandle + ID3D11Device::OpenSharedResource.  DXVK on
 * macOS has no VK_KHR_external_memory_win32, so GetSharedHandle fails with
 * E_INVALIDARG and video playback never reaches the screen.
 *
 * This DLL is installed next to an application as d3d11.dll, with DXVK's own
 * d3d11.dll renamed to d3d11_original.dll next to it.  It forwards everything
 * to the original and adds two behaviours:
 *
 *  1. When a D3D11_CREATE_DEVICE_VIDEO_SUPPORT device is requested for the
 *     adapter of an already created rendering device, it returns a distinct
 *     ID3D11Device pointer that delegates every call to the rendering device.
 *     QueryInterface returns the rendering device's interfaces, so both
 *     pointers share one IUnknown identity and no real cross-device sharing is
 *     required.
 *  2. For textures of the rendering device whose GetSharedHandle fails, it
 *     hands out a process-local token, and OpenSharedResource resolves the
 *     token back to the same texture.  Real shared handles are untouched.
 *
 * Environment:
 *   D3D11_VIDEO_SHIM=0          pure pass-through
 *   D3D11_VIDEO_SHIM_LOG=<path> append diagnostics to a file (off by default)
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <wchar.h>

#define ORIGINAL_DLL L"d3d11_original.dll"

typedef HRESULT (WINAPI *create_fn)(
    IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT,
    const D3D_FEATURE_LEVEL *, UINT, UINT,
    ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);

typedef HRESULT (WINAPI *swap_fn)(
    IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT,
    const D3D_FEATURE_LEVEL *, UINT, UINT,
    const DXGI_SWAP_CHAIN_DESC *, IDXGISwapChain **,
    ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);

static HMODULE g_self;
static INIT_ONCE g_once = INIT_ONCE_STATIC_INIT;
static SRWLOCK g_lock = SRWLOCK_INIT;
static HMODULE g_original;
static ID3D11Device *g_main_device;
static BOOL g_disabled;
static char g_log_path[MAX_PATH];
static LONG g_log_lines;

static void vlog(const char *fmt, ...)
{
    char buf[256];
    va_list ap;
    HANDLE f;
    DWORD w;
    int n;

    if (!g_log_path[0] || InterlockedIncrement(&g_log_lines) > 500)
        return;

    va_start(ap, fmt);
    n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n <= 0)
        return;
    if ((size_t)n >= sizeof(buf))
        n = (int)sizeof(buf) - 1;

    f = CreateFileA(g_log_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                    NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f != INVALID_HANDLE_VALUE)
    {
        WriteFile(f, buf, (DWORD)n, &w, NULL);
        CloseHandle(f);
    }
}

/* Load d3d11_original.dll from the directory this shim was loaded from, so the
 * result does not depend on the process working directory or search path. */
static BOOL CALLBACK load_original(INIT_ONCE *o, void *p, void **c)
{
    WCHAR path[MAX_PATH];
    WCHAR *slash;
    DWORD n;

    (void)o; (void)p; (void)c;
    n = GetModuleFileNameW(g_self, path, MAX_PATH);
    if (n && n < MAX_PATH && (slash = wcsrchr(path, L'\\')) &&
        (size_t)(slash + 1 - path) + wcslen(ORIGINAL_DLL) < MAX_PATH)
    {
        wcscpy(slash + 1, ORIGINAL_DLL);
        g_original = LoadLibraryW(path);
    }
    if (!g_original)
        g_original = LoadLibraryW(ORIGINAL_DLL);
    if (!g_original)
        vlog("failed to load %ls\r\n", ORIGINAL_DLL);
    return g_original != NULL;
}

static BOOL same_object(IUnknown *a, IUnknown *b)
{
    IUnknown *ua = NULL, *ub = NULL;
    BOOL same = FALSE;

    if (SUCCEEDED(IUnknown_QueryInterface(a, &IID_IUnknown, (void **)&ua)) &&
        SUCCEEDED(IUnknown_QueryInterface(b, &IID_IUnknown, (void **)&ub)))
        same = ua == ub;
    if (ua) IUnknown_Release(ua);
    if (ub) IUnknown_Release(ub);
    return same;
}

static BOOL adapter_matches(ID3D11Device *device, IDXGIAdapter *candidate)
{
    IDXGIDevice *dxgi = NULL;
    IDXGIAdapter *current = NULL;
    DXGI_ADAPTER_DESC a, b;
    BOOL same = FALSE;

    if (!candidate)
        return TRUE;
    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi)))
    {
        if (SUCCEEDED(IDXGIDevice_GetAdapter(dxgi, &current)))
        {
            if (SUCCEEDED(IDXGIAdapter_GetDesc(current, &a)) &&
                SUCCEEDED(IDXGIAdapter_GetDesc(candidate, &b)))
            {
                same = (a.AdapterLuid.LowPart == b.AdapterLuid.LowPart &&
                        a.AdapterLuid.HighPart == b.AdapterLuid.HighPart);
            }
            IDXGIAdapter_Release(current);
        }
        IDXGIDevice_Release(dxgi);
    }
    return same;
}

/* --- Process-local shared handle tokens ---
 *
 * A token is FAKE_TAG | serial (16 bit, never 0).  The table keeps a strong
 * reference to each registered resource and recycles the oldest slot, so a
 * decoder's small sample pool stays resolvable while old samples are released
 * instead of leaking.  A stale token fails to resolve (its serial is gone). */
#define FAKE_SLOTS 32
#define FAKE_MASK  ((uintptr_t)0xffff)
#define FAKE_TAG   ((uintptr_t)0x56440000u)

struct fake_slot
{
    ID3D11Resource *res;
    unsigned int serial;
};

static SRWLOCK g_fake_lock = SRWLOCK_INIT;
static struct fake_slot g_fake[FAKE_SLOTS];
static unsigned int g_fake_next, g_fake_serial;

static BOOL is_fake_handle(HANDLE h)
{
    return ((uintptr_t)h & ~FAKE_MASK) == FAKE_TAG && ((uintptr_t)h & FAKE_MASK);
}

static HANDLE fake_register(ID3D11Resource *res)
{
    ID3D11Resource *evicted;
    unsigned int i, serial, slot;

    AcquireSRWLockExclusive(&g_fake_lock);
    for (i = 0; i < FAKE_SLOTS; ++i)
    {
        if (g_fake[i].res == res)
        {
            serial = g_fake[i].serial;
            ReleaseSRWLockExclusive(&g_fake_lock);
            return (HANDLE)(FAKE_TAG | serial);
        }
    }
    do serial = ++g_fake_serial & FAKE_MASK; while (!serial);
    slot = g_fake_next++ % FAKE_SLOTS;
    evicted = g_fake[slot].res;
    ID3D11Resource_AddRef(res);
    g_fake[slot].res = res;
    g_fake[slot].serial = serial;
    ReleaseSRWLockExclusive(&g_fake_lock);

    if (evicted)
        ID3D11Resource_Release(evicted);
    return (HANDLE)(FAKE_TAG | serial);
}

static ID3D11Resource *fake_lookup(HANDLE h)
{
    unsigned int i, serial = (unsigned int)((uintptr_t)h & FAKE_MASK);
    ID3D11Resource *res = NULL;

    AcquireSRWLockShared(&g_fake_lock);
    for (i = 0; i < FAKE_SLOTS; ++i)
    {
        if (g_fake[i].res && g_fake[i].serial == serial)
        {
            res = g_fake[i].res;
            ID3D11Resource_AddRef(res);
            break;
        }
    }
    ReleaseSRWLockShared(&g_fake_lock);
    return res;
}

static HRESULT (STDMETHODCALLTYPE *old_GetSharedHandle)(IDXGIResource *, HANDLE *);
static HRESULT (STDMETHODCALLTYPE *old_OpenSharedResource)(ID3D11Device *, HANDLE, REFIID, void **);

static HRESULT STDMETHODCALLTYPE hook_GetSharedHandle(IDXGIResource *iface, HANDLE *out)
{
    ID3D11Resource *res = NULL;
    ID3D11Device *device = NULL;
    HRESULT hr;

    if (!out)
        return E_INVALIDARG;

    hr = old_GetSharedHandle(iface, out);
    if (SUCCEEDED(hr) && *out)
        return hr;

    /* Only resources of the rendering device can be resolved in-process. */
    if (FAILED(IDXGIResource_QueryInterface(iface, &IID_ID3D11Resource, (void **)&res)))
        return hr;
    ID3D11Resource_GetDevice(res, &device);
    if (device && g_main_device && same_object((IUnknown *)device, (IUnknown *)g_main_device))
    {
        *out = fake_register(res);
        hr = S_OK;
        vlog("GetSharedHandle res=%p -> token=%p\r\n", res, *out);
    }
    if (device)
        ID3D11Device_Release(device);
    ID3D11Resource_Release(res);
    return hr;
}

static HRESULT STDMETHODCALLTYPE hook_OpenSharedResource(
    ID3D11Device *device, HANDLE handle, REFIID riid, void **out)
{
    if (is_fake_handle(handle))
    {
        ID3D11Resource *res = fake_lookup(handle);
        HRESULT hr = E_INVALIDARG;

        if (res)
        {
            hr = ID3D11Resource_QueryInterface(res, riid, out);
            ID3D11Resource_Release(res);
        }
        vlog("OpenSharedResource token=%p -> %p hr=%#lx\r\n", handle, res, (long)hr);
        return hr;
    }
    return old_OpenSharedResource(device, handle, riid, out);
}

static BOOL patch_slot(void **slot, void *hook, void **old)
{
    DWORD prev, tmp;

    if (!VirtualProtect(slot, sizeof(void *), PAGE_READWRITE, &prev))
        return FALSE;
    *old = InterlockedExchangePointer(slot, hook);
    VirtualProtect(slot, sizeof(void *), prev, &tmp);
    return TRUE;
}

/* DXVK shares one vtable per class, so patching the rendering device's
 * OpenSharedResource and one texture's GetSharedHandle covers every object. */
static void attach_device_hooks(ID3D11Device *device)
{
    D3D11_TEXTURE2D_DESC desc = { 1, 1, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, { 1, 0 },
                                  D3D11_USAGE_DEFAULT, D3D11_BIND_SHADER_RESOURCE, 0, 0 };
    ID3D11Texture2D *texture = NULL;
    IDXGIResource *dxgi = NULL;

    if (!patch_slot((void **)&device->lpVtbl->OpenSharedResource,
                    hook_OpenSharedResource, (void **)&old_OpenSharedResource))
        return;
    if (SUCCEEDED(ID3D11Device_CreateTexture2D(device, &desc, NULL, &texture)))
    {
        if (SUCCEEDED(ID3D11Texture2D_QueryInterface(texture, &IID_IDXGIResource, (void **)&dxgi)))
        {
            if (patch_slot((void **)&dxgi->lpVtbl->GetSharedHandle,
                           hook_GetSharedHandle, (void **)&old_GetSharedHandle))
                vlog("hooked rendering device %p\r\n", device);
            IDXGIResource_Release(dxgi);
        }
        ID3D11Texture2D_Release(texture);
    }
}

/* --- Distinct ID3D11Device wrapper for s_VideoD3D11Device --- */
static HRESULT STDMETHODCALLTYPE video_QueryInterface(ID3D11Device *iface, REFIID riid, void **ppv)
{
    (void)iface;
    return ID3D11Device_QueryInterface(g_main_device, riid, ppv);
}
static ULONG STDMETHODCALLTYPE video_AddRef(ID3D11Device *iface)
{
    (void)iface;
    return ID3D11Device_AddRef(g_main_device);
}
static ULONG STDMETHODCALLTYPE video_Release(ID3D11Device *iface)
{
    (void)iface;
    return ID3D11Device_Release(g_main_device);
}
static HRESULT STDMETHODCALLTYPE video_CreateBuffer(ID3D11Device *iface, const D3D11_BUFFER_DESC *a, const D3D11_SUBRESOURCE_DATA *b, ID3D11Buffer **c)
{ (void)iface; return ID3D11Device_CreateBuffer(g_main_device, a, b, c); }
static HRESULT STDMETHODCALLTYPE video_CreateTexture1D(ID3D11Device *iface, const D3D11_TEXTURE1D_DESC *a, const D3D11_SUBRESOURCE_DATA *b, ID3D11Texture1D **c)
{ (void)iface; return ID3D11Device_CreateTexture1D(g_main_device, a, b, c); }
static HRESULT STDMETHODCALLTYPE video_CreateTexture2D(ID3D11Device *iface, const D3D11_TEXTURE2D_DESC *a, const D3D11_SUBRESOURCE_DATA *b, ID3D11Texture2D **c)
{ (void)iface; return ID3D11Device_CreateTexture2D(g_main_device, a, b, c); }
static HRESULT STDMETHODCALLTYPE video_CreateTexture3D(ID3D11Device *iface, const D3D11_TEXTURE3D_DESC *a, const D3D11_SUBRESOURCE_DATA *b, ID3D11Texture3D **c)
{ (void)iface; return ID3D11Device_CreateTexture3D(g_main_device, a, b, c); }
static HRESULT STDMETHODCALLTYPE video_CreateShaderResourceView(ID3D11Device *iface, ID3D11Resource *a, const D3D11_SHADER_RESOURCE_VIEW_DESC *b, ID3D11ShaderResourceView **c)
{ (void)iface; return ID3D11Device_CreateShaderResourceView(g_main_device, a, b, c); }
static HRESULT STDMETHODCALLTYPE video_CreateUnorderedAccessView(ID3D11Device *iface, ID3D11Resource *a, const D3D11_UNORDERED_ACCESS_VIEW_DESC *b, ID3D11UnorderedAccessView **c)
{ (void)iface; return ID3D11Device_CreateUnorderedAccessView(g_main_device, a, b, c); }
static HRESULT STDMETHODCALLTYPE video_CreateRenderTargetView(ID3D11Device *iface, ID3D11Resource *a, const D3D11_RENDER_TARGET_VIEW_DESC *b, ID3D11RenderTargetView **c)
{ (void)iface; return ID3D11Device_CreateRenderTargetView(g_main_device, a, b, c); }
static HRESULT STDMETHODCALLTYPE video_CreateDepthStencilView(ID3D11Device *iface, ID3D11Resource *a, const D3D11_DEPTH_STENCIL_VIEW_DESC *b, ID3D11DepthStencilView **c)
{ (void)iface; return ID3D11Device_CreateDepthStencilView(g_main_device, a, b, c); }
static HRESULT STDMETHODCALLTYPE video_CreateInputLayout(ID3D11Device *iface, const D3D11_INPUT_ELEMENT_DESC *a, UINT b, const void *c, SIZE_T d, ID3D11InputLayout **e)
{ (void)iface; return ID3D11Device_CreateInputLayout(g_main_device, a, b, c, d, e); }
static HRESULT STDMETHODCALLTYPE video_CreateVertexShader(ID3D11Device *iface, const void *a, SIZE_T b, ID3D11ClassLinkage *c, ID3D11VertexShader **d)
{ (void)iface; return ID3D11Device_CreateVertexShader(g_main_device, a, b, c, d); }
static HRESULT STDMETHODCALLTYPE video_CreateGeometryShader(ID3D11Device *iface, const void *a, SIZE_T b, ID3D11ClassLinkage *c, ID3D11GeometryShader **d)
{ (void)iface; return ID3D11Device_CreateGeometryShader(g_main_device, a, b, c, d); }
static HRESULT STDMETHODCALLTYPE video_CreateGeometryShaderWithStreamOutput(ID3D11Device *iface, const void *a, SIZE_T b, const D3D11_SO_DECLARATION_ENTRY *c, UINT d, const UINT *e, UINT f, UINT g, ID3D11ClassLinkage *h, ID3D11GeometryShader **i)
{ (void)iface; return ID3D11Device_CreateGeometryShaderWithStreamOutput(g_main_device, a, b, c, d, e, f, g, h, i); }
static HRESULT STDMETHODCALLTYPE video_CreatePixelShader(ID3D11Device *iface, const void *a, SIZE_T b, ID3D11ClassLinkage *c, ID3D11PixelShader **d)
{ (void)iface; return ID3D11Device_CreatePixelShader(g_main_device, a, b, c, d); }
static HRESULT STDMETHODCALLTYPE video_CreateHullShader(ID3D11Device *iface, const void *a, SIZE_T b, ID3D11ClassLinkage *c, ID3D11HullShader **d)
{ (void)iface; return ID3D11Device_CreateHullShader(g_main_device, a, b, c, d); }
static HRESULT STDMETHODCALLTYPE video_CreateDomainShader(ID3D11Device *iface, const void *a, SIZE_T b, ID3D11ClassLinkage *c, ID3D11DomainShader **d)
{ (void)iface; return ID3D11Device_CreateDomainShader(g_main_device, a, b, c, d); }
static HRESULT STDMETHODCALLTYPE video_CreateComputeShader(ID3D11Device *iface, const void *a, SIZE_T b, ID3D11ClassLinkage *c, ID3D11ComputeShader **d)
{ (void)iface; return ID3D11Device_CreateComputeShader(g_main_device, a, b, c, d); }
static HRESULT STDMETHODCALLTYPE video_CreateClassLinkage(ID3D11Device *iface, ID3D11ClassLinkage **a)
{ (void)iface; return ID3D11Device_CreateClassLinkage(g_main_device, a); }
static HRESULT STDMETHODCALLTYPE video_CreateBlendState(ID3D11Device *iface, const D3D11_BLEND_DESC *a, ID3D11BlendState **b)
{ (void)iface; return ID3D11Device_CreateBlendState(g_main_device, a, b); }
static HRESULT STDMETHODCALLTYPE video_CreateDepthStencilState(ID3D11Device *iface, const D3D11_DEPTH_STENCIL_DESC *a, ID3D11DepthStencilState **b)
{ (void)iface; return ID3D11Device_CreateDepthStencilState(g_main_device, a, b); }
static HRESULT STDMETHODCALLTYPE video_CreateRasterizerState(ID3D11Device *iface, const D3D11_RASTERIZER_DESC *a, ID3D11RasterizerState **b)
{ (void)iface; return ID3D11Device_CreateRasterizerState(g_main_device, a, b); }
static HRESULT STDMETHODCALLTYPE video_CreateSamplerState(ID3D11Device *iface, const D3D11_SAMPLER_DESC *a, ID3D11SamplerState **b)
{ (void)iface; return ID3D11Device_CreateSamplerState(g_main_device, a, b); }
static HRESULT STDMETHODCALLTYPE video_CreateQuery(ID3D11Device *iface, const D3D11_QUERY_DESC *a, ID3D11Query **b)
{ (void)iface; return ID3D11Device_CreateQuery(g_main_device, a, b); }
static HRESULT STDMETHODCALLTYPE video_CreatePredicate(ID3D11Device *iface, const D3D11_QUERY_DESC *a, ID3D11Predicate **b)
{ (void)iface; return ID3D11Device_CreatePredicate(g_main_device, a, b); }
static HRESULT STDMETHODCALLTYPE video_CreateCounter(ID3D11Device *iface, const D3D11_COUNTER_DESC *a, ID3D11Counter **b)
{ (void)iface; return ID3D11Device_CreateCounter(g_main_device, a, b); }
static HRESULT STDMETHODCALLTYPE video_CreateDeferredContext(ID3D11Device *iface, UINT a, ID3D11DeviceContext **b)
{ (void)iface; return ID3D11Device_CreateDeferredContext(g_main_device, a, b); }
static HRESULT STDMETHODCALLTYPE video_OpenSharedResource(ID3D11Device *iface, HANDLE a, REFIID b, void **c)
{ (void)iface; return ID3D11Device_OpenSharedResource(g_main_device, a, b, c); }
static HRESULT STDMETHODCALLTYPE video_CheckFormatSupport(ID3D11Device *iface, DXGI_FORMAT a, UINT *b)
{ (void)iface; return ID3D11Device_CheckFormatSupport(g_main_device, a, b); }
static HRESULT STDMETHODCALLTYPE video_CheckMultisampleQualityLevels(ID3D11Device *iface, DXGI_FORMAT a, UINT b, UINT *c)
{ (void)iface; return ID3D11Device_CheckMultisampleQualityLevels(g_main_device, a, b, c); }
static void STDMETHODCALLTYPE video_CheckCounterInfo(ID3D11Device *iface, D3D11_COUNTER_INFO *a)
{ (void)iface; ID3D11Device_CheckCounterInfo(g_main_device, a); }
static HRESULT STDMETHODCALLTYPE video_CheckCounter(ID3D11Device *iface, const D3D11_COUNTER_DESC *a, D3D11_COUNTER_TYPE *b, UINT *c, LPSTR d, UINT *e, LPSTR f, UINT *g, LPSTR h, UINT *i)
{ (void)iface; return ID3D11Device_CheckCounter(g_main_device, a, b, c, d, e, f, g, h, i); }
static HRESULT STDMETHODCALLTYPE video_CheckFeatureSupport(ID3D11Device *iface, D3D11_FEATURE a, void *b, UINT c)
{ (void)iface; return ID3D11Device_CheckFeatureSupport(g_main_device, a, b, c); }
static HRESULT STDMETHODCALLTYPE video_GetPrivateData(ID3D11Device *iface, REFGUID a, UINT *b, void *c)
{ (void)iface; return ID3D11Device_GetPrivateData(g_main_device, a, b, c); }
static HRESULT STDMETHODCALLTYPE video_SetPrivateData(ID3D11Device *iface, REFGUID a, UINT b, const void *c)
{ (void)iface; return ID3D11Device_SetPrivateData(g_main_device, a, b, c); }
static HRESULT STDMETHODCALLTYPE video_SetPrivateDataInterface(ID3D11Device *iface, REFGUID a, const IUnknown *b)
{ (void)iface; return ID3D11Device_SetPrivateDataInterface(g_main_device, a, b); }
static D3D_FEATURE_LEVEL STDMETHODCALLTYPE video_GetFeatureLevel(ID3D11Device *iface)
{ (void)iface; return ID3D11Device_GetFeatureLevel(g_main_device); }
static UINT STDMETHODCALLTYPE video_GetCreationFlags(ID3D11Device *iface)
{ (void)iface; return ID3D11Device_GetCreationFlags(g_main_device); }
static HRESULT STDMETHODCALLTYPE video_GetDeviceRemovedReason(ID3D11Device *iface)
{ (void)iface; return ID3D11Device_GetDeviceRemovedReason(g_main_device); }
static void STDMETHODCALLTYPE video_GetImmediateContext(ID3D11Device *iface, ID3D11DeviceContext **a)
{ (void)iface; ID3D11Device_GetImmediateContext(g_main_device, a); }
static HRESULT STDMETHODCALLTYPE video_SetExceptionMode(ID3D11Device *iface, UINT a)
{ (void)iface; return ID3D11Device_SetExceptionMode(g_main_device, a); }
static UINT STDMETHODCALLTYPE video_GetExceptionMode(ID3D11Device *iface)
{ (void)iface; return ID3D11Device_GetExceptionMode(g_main_device); }

static ID3D11DeviceVtbl g_video_device_vtbl = {
    video_QueryInterface,
    video_AddRef,
    video_Release,
    video_CreateBuffer,
    video_CreateTexture1D,
    video_CreateTexture2D,
    video_CreateTexture3D,
    video_CreateShaderResourceView,
    video_CreateUnorderedAccessView,
    video_CreateRenderTargetView,
    video_CreateDepthStencilView,
    video_CreateInputLayout,
    video_CreateVertexShader,
    video_CreateGeometryShader,
    video_CreateGeometryShaderWithStreamOutput,
    video_CreatePixelShader,
    video_CreateHullShader,
    video_CreateDomainShader,
    video_CreateComputeShader,
    video_CreateClassLinkage,
    video_CreateBlendState,
    video_CreateDepthStencilState,
    video_CreateRasterizerState,
    video_CreateSamplerState,
    video_CreateQuery,
    video_CreatePredicate,
    video_CreateCounter,
    video_CreateDeferredContext,
    video_OpenSharedResource,
    video_CheckFormatSupport,
    video_CheckMultisampleQualityLevels,
    video_CheckCounterInfo,
    video_CheckCounter,
    video_CheckFeatureSupport,
    video_GetPrivateData,
    video_SetPrivateData,
    video_SetPrivateDataInterface,
    video_GetFeatureLevel,
    video_GetCreationFlags,
    video_GetDeviceRemovedReason,
    video_GetImmediateContext,
    video_SetExceptionMode,
    video_GetExceptionMode
};

static ID3D11Device g_video_device = { &g_video_device_vtbl };

static void remember(ID3D11Device *d, UINT flags)
{
    if (!d || (flags & D3D11_CREATE_DEVICE_VIDEO_SUPPORT))
        return;
    AcquireSRWLockExclusive(&g_lock);
    if (!g_main_device)
    {
        g_main_device = d;
        ID3D11Device_AddRef(d);
        attach_device_hooks(d);
    }
    ReleaseSRWLockExclusive(&g_lock);
}

HRESULT WINAPI D3D11CreateDevice(
    IDXGIAdapter *adapter, D3D_DRIVER_TYPE type, HMODULE software, UINT flags,
    const D3D_FEATURE_LEVEL *levels, UINT count, UINT sdk,
    ID3D11Device **device, D3D_FEATURE_LEVEL *level, ID3D11DeviceContext **context)
{
    create_fn f;
    HRESULT hr;
    UINT i;

    if (!InitOnceExecuteOnce(&g_once, load_original, NULL, NULL))
        return E_FAIL;
    f = (create_fn)GetProcAddress(g_original, "D3D11CreateDevice");
    if (!f)
        return E_FAIL;
    if (g_disabled)
        return f(adapter, type, software, flags, levels, count, sdk, device, level, context);

    if ((flags & D3D11_CREATE_DEVICE_VIDEO_SUPPORT) &&
        (type == D3D_DRIVER_TYPE_HARDWARE || (adapter && type == D3D_DRIVER_TYPE_UNKNOWN)) &&
        !software && sdk == D3D11_SDK_VERSION)
    {
        AcquireSRWLockShared(&g_lock);
        if (g_main_device && adapter_matches(g_main_device, adapter))
        {
            D3D_FEATURE_LEVEL current = ID3D11Device_GetFeatureLevel(g_main_device);
            BOOL compatible = !levels;

            for (i = 0; levels && i < count; i++)
                if (levels[i] == current)
                    compatible = TRUE;
            if (compatible)
            {
                if (device)
                {
                    *device = &g_video_device;
                    ID3D11Device_AddRef(&g_video_device);
                }
                if (context)
                    ID3D11Device_GetImmediateContext(g_main_device, context);
                if (level)
                    *level = current;
                vlog("video device %p reuses rendering device %p\r\n",
                     (void *)&g_video_device, (void *)g_main_device);
                ReleaseSRWLockShared(&g_lock);
                return S_OK;
            }
        }
        ReleaseSRWLockShared(&g_lock);
    }

    hr = f(adapter, type, software, flags, levels, count, sdk, device, level, context);
    if (SUCCEEDED(hr) && device)
        remember(*device, flags);
    return hr;
}

HRESULT WINAPI D3D11CreateDeviceAndSwapChain(
    IDXGIAdapter *adapter, D3D_DRIVER_TYPE type, HMODULE software, UINT flags,
    const D3D_FEATURE_LEVEL *levels, UINT count, UINT sdk,
    const DXGI_SWAP_CHAIN_DESC *desc, IDXGISwapChain **swap,
    ID3D11Device **device, D3D_FEATURE_LEVEL *level, ID3D11DeviceContext **context)
{
    swap_fn f;
    HRESULT hr;

    if (!InitOnceExecuteOnce(&g_once, load_original, NULL, NULL))
        return E_FAIL;
    f = (swap_fn)GetProcAddress(g_original, "D3D11CreateDeviceAndSwapChain");
    if (!f)
        return E_FAIL;

    hr = f(adapter, type, software, flags, levels, count, sdk, desc, swap, device, level, context);
    if (SUCCEEDED(hr) && device && !g_disabled)
        remember(*device, flags);
    return hr;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    char value[8];
    DWORD n;

    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH)
    {
        g_self = inst;
        DisableThreadLibraryCalls(inst);
        n = GetEnvironmentVariableA("D3D11_VIDEO_SHIM", value, sizeof(value));
        g_disabled = n && n < sizeof(value) && value[0] == '0';
        n = GetEnvironmentVariableA("D3D11_VIDEO_SHIM_LOG", g_log_path, sizeof(g_log_path));
        if (!n || n >= sizeof(g_log_path))
            g_log_path[0] = 0;
    }
    return TRUE;
}
