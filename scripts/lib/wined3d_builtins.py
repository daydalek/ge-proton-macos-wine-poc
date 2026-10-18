#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Preserve same-build Wine graphics DLLs before GPTK replaces the defaults."""
from pathlib import Path
import shutil


GRAPHICS_DLLS = ('dxgi.dll', 'd3d10.dll', 'd3d10core.dll', 'd3d11.dll', 'd3d12.dll')
ARCHITECTURES = ('x86_64-windows', 'i386-windows')


def preserve_wined3d_builtins(wine, source=None):
    """Copy from a clean install tree, never from an Apple-deployed runtime.

    The destination is runtime-owned, not a rollback backup. It is installed
    with the engine and deliberately independent of Whisky's GPTK store.
    """
    wine = Path(wine)
    source = Path(source) if source is not None else wine
    sources = [(source / 'lib/wine' / arch / name, arch, name)
               for arch in ARCHITECTURES for name in GRAPHICS_DLLS]
    # Check all inputs before changing the destination.
    for path, _, _ in sources:
        if not path.is_file() or path.is_symlink():
            raise ValueError(f'Missing regular Wine graphics builtin: {path}')
        if path.read_bytes()[0x40:0x50] != b'Wine builtin DLL':
            raise ValueError(f'Not a Wine builtin DLL: {path}')
    for path, arch, name in sources:
        target = wine / 'lib/wine/wined3d' / arch / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
