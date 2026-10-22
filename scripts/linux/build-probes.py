#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Cross-compile the existing Windows regression probes on Linux."""
import argparse
from pathlib import Path
import shutil
import subprocess

from build import Build, PROJECT


PROBES = {
    'backend-switch-probe': ['-ldxguid', '-luser32'],
    'crypto-probe': ['-lbcrypt', '-lsecur32'],
    'fullscreen-state-probe': ['-luser32'],
    'media-probe': ['-municode', '-lole32', '-loleaut32', '-lstrmiids', '-luuid'],
    'child-window-probe': ['-municode', '-lole32', '-loleaut32', '-lstrmiids', '-luuid'],
    'repeated-seek-probe': ['-municode', '-static', '-lole32', '-loleaut32', '-lstrmiids', '-luuid'],
    'exception-probe': [],
    'syscall-boolean-probe': [],
    'directory-compat-probe': [],
    'hotpatch-probe': ['-lgdi32', '-luser32'],
    'reconnect-probe': ['-municode', '-lole32', '-loleaut32', '-lstrmiids', '-luuid'],
    'mpeg-audio-format-probe': ['-municode', '-lole32', '-loleaut32', '-lstrmiids', '-luuid'],
    'command-line-probe': ['-municode', '-ladvapi32'],
    'device-notify-probe': ['-luser32'],
    'dbghelp-probe': ['-ldbghelp'],
    'dwarf-divisor-probe': ['-municode', '-ldbghelp'],
    'vulkan-probe': ['-luser32'],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True)
    args = parser.parse_args()
    build = Build(args.work_dir, 1)
    output = build.work / 'probes'
    output.mkdir(exist_ok=True)
    headers = build.work / 'probe-headers'
    headers.mkdir(exist_ok=True)
    for name in ('vulkan', 'vk_video'):
        shutil.copytree(Path('/usr/include') / name, headers / name, dirs_exist_ok=True)
    for arch, bits in (('i686', 'x86'), ('x86_64', 'x64')):
        for name, libraries in PROBES.items():
            suffix = '.cpp' if name == 'repeated-seek-probe' else '.c'
            compiler = arch + '-w64-mingw32-' + ('clang++' if suffix == '.cpp' else 'clang')
            command = [build.toolchain / 'bin' / compiler, '-Wall', '-O2', '-I' + str(headers),
                       PROJECT / 'tools/probes' / (name + suffix), '-o',
                       output / (name + '-' + bits + '.exe'), *libraries]
            subprocess.run(list(map(str, command)), check=True)
        subprocess.run(list(map(str, [build.toolchain / 'bin' / (arch + '-w64-mingw32-clang'),
            '-shared', '-nostdlib', '-Wl,--entry,fixture', PROJECT / 'tools/probes/dwarf-divisor-fixture.S',
            '-o', output / ('dwarf-divisor-fixture-' + bits + '.dll')])), check=True)


if __name__ == '__main__':
    main()
