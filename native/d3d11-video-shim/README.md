# d3d11 video shim

A drop-in `d3d11.dll` replacement for applications running on a D3D11
implementation without `VK_KHR_external_memory_win32` — notably DXVK on
macOS (Whisky/CrossOver).  It repairs Media Foundation video playback in
titles that create a second D3D11 device for decoding and share decoded
textures with the render device through `IDXGIResource::GetSharedHandle`
and `ID3D11Device::OpenSharedResource`.  Unity's `WindowsVideoMedia`
back-end works exactly this way; without the shim, `GetSharedHandle`
fails with `E_INVALIDARG` and opening movies never produce frames.

## What it does

1. **Device reuse.** When a device is requested with
   `D3D11_CREATE_DEVICE_VIDEO_SUPPORT` on the same adapter as an already
   created device, the shim returns a distinct `ID3D11Device` pointer
   backed by the existing device (COM-identity safe through
   `QueryInterface`).  Decoded textures therefore live on the render
   device itself and need no real cross-device sharing.
2. **In-process shared handles.** The shim vtable-patches
   `GetSharedHandle`/`OpenSharedResource` on the retained device.
   When the underlying implementation cannot produce a real shared
   handle, the resource is registered in a process-local token table
   (64 slots, oldest-evicted) and `OpenSharedResource` resolves tokens
   back to the resource.  Real shared handles pass through untouched.

Everything else forwards to the original `d3d11.dll`.

## Install

```sh
native/d3d11-video-shim/build.sh                 # builds x32 + x64 dlls
native/d3d11-video-shim/install.sh --dir <app-dir> --arch x64
native/d3d11-video-shim/install.sh --dir <app-dir> --remove
```

Install renames the existing `d3d11.dll` next to the executable to
`d3d11_original.dll` and writes the shim as `d3d11.dll`.  `--source`
points at a build output tree (default `$POC_WORK/d3d11-video-shim`),
`--dll` at a specific shim file, and `--original` supplies a `d3d11.dll`
to wrap when the target directory has none.

## Shipped DXVK payload

`scripts/ci/assemble-libraries.py` and `scripts/whisky/install-runtime.py`
weave the shim into the DXVK payload at packaging/install time via
`poc_common.weave_d3d11_video_shim`: each arch's `d3d11.dll` becomes the
shim and the payload's own DLL is kept as `d3d11_original.dll`.  Whisky
copies every `.dll` in `Libraries/DXVK/<arch>` into `system32`/`syswow64`
on each DXVK-enabled launch, so bottles pick the shim up automatically;
the per-app install above is only needed to wrap a different d3d11.dll
placed next to a specific executable.

## Environment

| Variable | Effect |
| --- | --- |
| `D3D11_VIDEO_SHIM=0` | pure pass-through (device reuse and hooks off) |
| `D3D11_VIDEO_SHIM_LOG=<path>` | append diagnostics to the file (off by default, capped at 500 lines); a Wine path such as `Z:\tmp\shim.log` works |

## Limitations

- Only helps *intra-process* sharing.  Real cross-process handles are
  forwarded, but nothing synthesizes them.
- The shim retains the first non-`VIDEO_SUPPORT` device as the render
  device.  Applications that create the render device with
  `D3D11_CREATE_DEVICE_VIDEO_SUPPORT`, or on a different adapter, are
  not repaired (behaviour stays as broken as without the shim).
- Vtable patching targets DXVK-style shared vtables; the fallback is
  harmless if the vtable cannot be patched (pass-through).
- Verified with Unity 2020.3/2022.3 titles (32-bit and 64-bit).
