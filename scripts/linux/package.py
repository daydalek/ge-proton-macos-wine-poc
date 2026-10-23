#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Assemble a relocatable Linux Wine runtime and its corresponding sources."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import sys
import tarfile

from build import Build, PROJECT, patch_plan, sha256_file, write_json

privacy_spec = importlib.util.spec_from_file_location('runtime_privacy', PROJECT / 'scripts/ci/prepare-libraries.py')
privacy = importlib.util.module_from_spec(privacy_spec)
privacy_spec.loader.exec_module(privacy)


def is_elf(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open('rb') as stream:
        return stream.read(4) == b'\x7fELF'


def relocate_elf(path):
    dynamic = subprocess.check_output(['readelf', '-d', str(path)], text=True)
    # Wine's static-PIE preloader relocates itself and has no DT_NEEDED entries.
    # Preserve its loader layout; dependency-bearing ELFs use relative lookup.
    if '(NEEDED)' in dynamic:
        subprocess.run(['patchelf', '--set-rpath',
                        '$ORIGIN:$ORIGIN/..:$ORIGIN/../lib:$ORIGIN/../..', str(path)], check=True)


def archive_filter(info):
    if any(part in ('.git', '__pycache__', 'autom4te.cache') for part in Path(info.name).parts):
        return None
    info.uid = info.gid = 0
    info.uname = info.gname = ''
    info.mtime = 0
    info.pax_headers = {}
    return info


def validate_provenance(stage):
    provenance = json.loads((stage / 'build-provenance.json').read_text())
    if provenance['patches'] != patch_plan():
        raise ValueError('Installed Wine patch provenance differs from the current Linux profile')
    for name, digest in provenance['compiled_modules'].items():
        if sha256_file(stage / name) != digest:
            raise ValueError('Installed module changed: ' + name)
    return provenance


def validate_pe(root):
    records = []
    for arch, machine in (('i386', 0x14c), ('x86_64', 0x8664)):
        for name in ('ntdll', 'kernelbase', 'quartz', 'winedmo', 'wow64win'):
            # The WoW64 dispatcher itself is an x86_64 Windows module.
            if name == 'wow64win' and arch == 'i386':
                continue
            path = root / 'lib/wine' / (arch + '-windows') / (name + '.dll')
            with path.open('rb') as stream:
                dos = stream.read(64)
                if len(dos) != 64 or dos[:2] != b'MZ':
                    raise ValueError('Invalid DOS header: ' + str(path))
                stream.seek(struct.unpack_from('<I', dos, 60)[0])
                pe = stream.read(6)
            if len(pe) != 6 or pe[:4] != b'PE\0\0' or struct.unpack_from('<H', pe, 4)[0] != machine:
                raise ValueError('Wrong PE architecture: ' + str(path))
            records.append({'file': path.relative_to(root).as_posix(), 'sha256': sha256_file(path)})
    return records


def validate_elf(root, env):
    records = []
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            if not path.resolve().is_relative_to(root.resolve()) or not path.exists():
                raise ValueError('Broken or external symlink: ' + str(path))
        if not is_elf(path):
            continue
        header = subprocess.check_output(['readelf', '-h', str(path)], text=True)
        if 'Advanced Micro Devices X86-64' not in header:
            raise ValueError('Expected x86_64 ELF: ' + str(path))
        dynamic = subprocess.check_output(['readelf', '-d', str(path)], text=True)
        for value in re.findall(r'\((?:RUNPATH|RPATH)\).*?\[(.*?)\]', dynamic):
            if any(part.startswith('/') for part in value.split(':')):
                raise ValueError('Absolute ELF library search path: ' + str(path))
        linked = subprocess.run(['ldd', str(path)], env=env, capture_output=True, text=True)
        if 'not found' in linked.stdout + linked.stderr:
            raise ValueError('Missing runtime dependency: ' + str(path) + '\n' + linked.stdout)
        versions = subprocess.check_output(['readelf', '--version-info', str(path)], text=True)
        glibc = sorted(set(re.findall(r'\bGLIBC_(\d+(?:\.\d+)+)\b', versions)),
                       key=lambda value: tuple(map(int, value.split('.'))))
        records.append({'file': path.relative_to(root).as_posix(), 'sha256': sha256_file(path),
                        'glibc_symbol_versions': glibc,
                        'needed': re.findall(r'\(NEEDED\).*?\[(.*?)\]', dynamic)})
    if not records:
        raise ValueError('Runtime contains no ELF binaries')
    return records


def prepare_runtime(root, objcopy):
    stripped = rewritten = checked = 0
    for path in sorted(root.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        if path.name in {'system.reg', 'user.reg', 'userdef.reg', '.DS_Store', 'Metadata.plist'}:
            raise ValueError('Runtime contains user state: ' + str(path))
        data = path.read_bytes()
        pe = False
        if len(data) >= 64 and data[:2] == b'MZ':
            pe_offset = struct.unpack_from('<I', data, 60)[0]
            pe = data[pe_offset:pe_offset + 4] == b'PE\0\0'
        if pe or data[:4] == b'\x7fELF':
            marker = data[64:80]
            subprocess.run([str(objcopy), '--strip-debug', str(path)], check=True, capture_output=True)
            data = path.read_bytes()
            if pe and marker == b'Wine builtin DLL' and data[64:80] != marker:
                raise ValueError('Wine builtin marker changed: ' + str(path))
            stripped += 1
        cleaned = privacy.PRIVATE_PREFIX.sub(privacy.public_prefix, data)
        if b'/\x00h\x00o\x00m\x00e\x00/' in cleaned or b'/\x00U\x00s\x00e\x00r\x00s\x00/' in cleaned:
            wide = re.compile(rb'(?:[^\x00]\x00){1,2048}')
            cleaned = wide.sub(lambda m: privacy.PRIVATE_PREFIX.sub(privacy.public_prefix, m.group()[::2])
                               .decode('latin1').encode('utf-16le'), cleaned)
        if cleaned != data:
            path.write_bytes(cleaned)
            rewritten += 1
        if privacy.PRIVATE_PREFIX.search(cleaned.replace(b'\x00', b'')):
            raise ValueError('Private build path remains: ' + str(path))
        finding, _ = privacy.credential_findings(cleaned, path.relative_to(root))
        if finding:
            raise ValueError('Credential pattern requires review: ' + str(path))
        checked += 1
    return {'result': 'passed', 'files_checked': checked, 'debug_stripped': stripped,
            'files_with_path_remapping': rewritten, 'private_paths': 0,
            'scope': 'Runtime files; ASCII/UTF-16 home paths and common credential patterns'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build = Build(args.work_dir, 1)
    provenance = validate_provenance(build.stage)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    # Release assets carry the -linux-amd64 suffix so they can share a release
    # with the macOS Libraries packages.
    runtime = output / 'wine-linux-amd64'
    shutil.copytree(build.stage, runtime, symlinks=True)
    for directory in (runtime / 'include', runtime / 'lib/pkgconfig'):
        if directory.exists():
            shutil.rmtree(directory)
    for archive in runtime.rglob('*.a'):
        archive.unlink()
    for path in (build.deps / 'lib').glob('*.so*'):
        target = runtime / 'lib' / path.name
        if path.is_symlink():
            target.symlink_to(os.readlink(path))
        else:
            shutil.copy2(path, target)
    for path in runtime.rglob('*'):
        if is_elf(path):
            relocate_elf(path)
    launcher = runtime / 'run'
    launcher.write_text('''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
export LD_LIBRARY_PATH="$root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export WINEPREFIX="${WINEPREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/ge-wine-linux/prefix}"
mkdir -p "$(dirname -- "$WINEPREFIX")"
exec "$root/bin/wine" "$@"
''')
    launcher.chmod(0o755)
    notices = runtime / 'share/ge-wine'
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copytree(PROJECT / 'licenses', notices / 'licenses')
    for name in ('COPYING.LIB', 'UPSTREAMS.md'):
        shutil.copy2(PROJECT / name, notices / name)
    shutil.copy2(build.source / 'LICENSE', notices / 'WINE-LICENSE')
    ffmpeg = next((build.work / 'source').glob('FFmpeg-*'))
    shutil.copy2(ffmpeg / 'COPYING.LGPLv2.1', notices / 'FFMPEG-COPYING.LGPLv2.1')
    write_json(notices / 'patches.json', patch_plan())
    audit = prepare_runtime(runtime, build.toolchain / 'bin/llvm-objcopy')
    write_json(output / 'linux-privacy-audit.json', audit)
    # Relocation changes binaries; keep source-build and shipped hashes separately.
    env = dict(os.environ, LD_LIBRARY_PATH=str(runtime / 'lib'))
    elf = validate_elf(runtime, env)
    pe = validate_pe(runtime)
    subprocess.run([sys.executable, str(PROJECT / 'scripts/ci/check-ffmpeg.py'),
                    '--library-dir', str(runtime / 'lib'),
                    '--output', str(output / 'linux-ffmpeg-capabilities.json')], env=env, check=True)
    write_json(output / 'linux-static-check.json', {'result': 'passed', 'elf_files': elf, 'pe_files': pe,
        'build_host_libc': list(platform.libc_ver()),
        'scope': 'ELF architecture, relative search paths, symlinks, and dependencies on the build distro'})
    manifest = {'target': 'Ubuntu 24.04 x86_64', 'baseline': provenance['baseline'],
                'windows_architectures': provenance['windows_architectures'],
                'prefix_architecture': 'win64',
                'runtime_asset': 'wine-linux-amd64.tar.gz',
                'source_asset': 'wine-linux-amd64-sources.tar.gz',
                'entrypoints': {'wine': 'run', 'loader': 'bin/wine', 'wineserver': 'bin/wineserver'},
                'kernel_requirements': 'x86_64 execution with the Linux i386 compatibility syscall entry (int 0x80)',
                'system_dependencies': 'glibc, GnuTLS, X11/Wayland, graphics and audio libraries from the host distro',
                'system_fonts': ['Liberation', 'Noto CJK'],
                'bundled_dependencies': ['FFmpeg'], 'patches': patch_plan(),
                'toolchain': provenance['toolchain'],
                'ffmpeg_source': next(item for item in build.dependencies if item['archive'] == 'ffmpeg.tar.gz'),
                'validation': 'See the separate linux-runtime-check.json; desktop/GPU/game acceptance is external'}
    write_json(output / 'linux-release-manifest.json', manifest)
    with tarfile.open(output / 'wine-linux-amd64.tar.gz', 'w:gz') as tf:
        tf.add(runtime, arcname=runtime.name, filter=archive_filter)
    with tarfile.open(output / 'wine-linux-amd64-sources.tar.gz', 'w:gz') as tf:
        tf.add(build.source, arcname='prepared/wine', filter=archive_filter)
        for path in sorted((build.work / 'archives').iterdir()):
            tf.add(path, arcname='archives/' + path.name, filter=archive_filter)
        names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=PROJECT).decode().split('\0')
        for name in filter(None, names):
            path = PROJECT / name
            if path.is_file():
                tf.add(path, arcname='project/' + name, filter=archive_filter)
    (output / 'SHA256SUMS-linux-amd64').write_text(''.join(
        f'{sha256_file(path)}  {path.name}\n' for path in sorted(output.iterdir())
        if path.is_file() and path.name != 'SHA256SUMS-linux-amd64'))
    print(output)


if __name__ == '__main__':
    main()
