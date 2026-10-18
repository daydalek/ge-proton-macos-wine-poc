#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Assemble a patched Wine stage as Whisky's Libraries.tar.gz (macOS)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from wined3d_builtins import preserve_wined3d_builtins


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--poc', type=Path, default=Path(__file__).resolve().parents[2], help='GE Wine source/build repository')
    parser.add_argument('--stage', type=Path, required=True, help='Current build stage containing media and deps-x64')
    parser.add_argument('--wine-stage', type=Path, help='Wine install tree; default is stage/media')
    parser.add_argument('--core', default='media', choices=('media', 'crossover-ge-media'))
    parser.add_argument('--base-libraries', type=Path, required=True, help='Existing Libraries tree providing DXVK')
    parser.add_argument('--version', required=True, help='Runtime release version X.Y.Z; independent of Wine version')
    parser.add_argument('--output', type=Path, required=True, help='Fresh output directory')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.version):
        parser.error('version must be X.Y.Z')
    poc, base, out = args.poc.resolve(), args.base_libraries.resolve(), args.output.resolve()
    stage = args.stage.resolve()
    wine_stage = args.wine_stage.resolve() if args.wine_stage else stage / 'media'
    required = [wine_stage / 'bin/wine', wine_stage / 'bin/wineserver',
                stage / 'deps-x64/lib/libMoltenVK.dylib', base / 'WhiskyWineVersion.plist',
                poc / 'licenses', poc / 'COPYING.LIB', poc / 'UPSTREAMS.md']
    required += [base / 'DXVK' / arch / dll for arch in ('x64', 'x32')
                 for dll in ('d3d11.dll', 'd3d10core.dll')]
    for path in required:
        if not path.exists():
            parser.error(f'missing input: {path}')
    if out.exists():
        parser.error(f'output already exists: {out}')
    base_info = plistlib.loads((base / 'WhiskyWineVersion.plist').read_bytes())
    if not base_info.get('dxvkVersion'):
        parser.error('base runtime must record its DXVK version')
    out.mkdir(parents=True)
    lib = out / 'Libraries'
    lib.mkdir()
    wine = lib / 'Wine'
    print('Copying GE media core and dependencies', flush=True)
    shutil.copytree(wine_stage, wine, symlinks=True)
    shutil.copytree(stage / 'deps-x64/lib', wine / 'lib', symlinks=True, dirs_exist_ok=True)
    if args.core == 'crossover-ge-media':
        preserve_wined3d_builtins(wine, source=wine_stage)
    wine64 = wine / 'bin/wine64'
    if wine64.exists() or wine64.is_symlink():
        wine64.unlink()
    wine64.symlink_to('wine')
    shutil.copytree(base / 'DXVK', lib / 'DXVK', symlinks=True)
    notices = lib / 'GE-Media'
    notices.mkdir()
    for name in ('COPYING.LIB', 'LICENSE', 'UPSTREAMS.md'):
        shutil.copy2(poc / name, notices / name)
    for name in ('licenses', 'patches'):
        shutil.copytree(poc / name, notices / name, symlinks=True)
    (notices / 'configs').mkdir()
    for name in ('source-lock.json', 'dependency-lock.json', 'source-license-inventory.json',
                 'vulkan-generation-lock.json', 'crossover-source-lock.json', 'crossover-patch-series.txt', 'build.env'):
        shutil.copy2(poc / 'configs' / name, notices / 'configs' / name)

    # Every shipped symlink must resolve within Libraries after installation.
    for path in lib.rglob('*'):
        if path.is_symlink():
            target = path.resolve()
            if lib not in target.parents or not target.exists():
                raise RuntimeError(f'nonportable symlink: {path} -> {os.readlink(path)}')

    magics = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
    audit = []
    minimum = (0, 0, 0)
    for path in sorted(wine.rglob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as stream:
            if stream.read(4) not in magics:
                continue
        dependencies = run('/usr/bin/otool', '-L', str(path)).splitlines()[1:]
        for line in dependencies:
            dep = line.strip().split(' (')[0]
            if dep.startswith('/') and not dep.startswith(('/usr/lib/', '/System/Library/')):
                if not (wine / 'lib' / Path(dep).name).exists():
                    raise RuntimeError(f'unbundled dependency: {path}: {dep}')
                run('/usr/bin/install_name_tool', '-change', dep, '@rpath/' + Path(dep).name, str(path))
        ids = run('/usr/bin/otool', '-D', str(path)).splitlines()[1:]
        for name in ids:
            if name.startswith('/') and not name.startswith(('/usr/lib/', '/System/Library/')):
                run('/usr/bin/install_name_tool', '-id', '@rpath/' + path.name, str(path))
        commands = run('/usr/bin/otool', '-l', str(path))
        old_paths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands)
        rpath = '@loader_path/' + os.path.relpath(wine / 'lib', path.parent)
        desired_paths = (rpath, '@loader_path')
        for old in old_paths:
            if old not in desired_paths:
                run('/usr/bin/install_name_tool', '-delete_rpath', old, str(path))
        for desired in desired_paths:
            if desired not in old_paths:
                run('/usr/bin/install_name_tool', '-add_rpath', desired, str(path))
        run('/usr/bin/codesign', '--force', '--sign', '-', str(path))
        run('/usr/bin/codesign', '--verify', str(path))
        commands = run('/usr/bin/otool', '-l', str(path))
        version_commands = re.findall(
            r'cmd LC_(BUILD_VERSION|VERSION_MIN_MACOSX)\n(.*?)(?=\nLoad command|\Z)',
            commands, re.S)
        for command, body in version_commands:
            field = 'minos' if command == 'BUILD_VERSION' else 'version'
            value = re.search(r'\b' + field + r' (\d+\.\d+(?:\.\d+)?)', body).group(1)
            parts = tuple(int(n) for n in value.split('.'))
            minimum = max(minimum, parts + (0,) * (3 - len(parts)))
        audit.append({'file': str(path.relative_to(lib)), 'rpath': rpath,
                      'dependencies': run('/usr/bin/otool', '-L', str(path)).splitlines()[1:]})
    # Local D3DMetal 3.0 device/present probes passed on the CrossOver core.
    # Do not advertise this capability for the legacy Valve packaging check.
    info = {'version': dict(zip(('major', 'minor', 'patch'), map(int, args.version.split('.')))),
            'dxvkVersion': base_info['dxvkVersion'], 'gptkCapable': args.core == 'crossover-ge-media'}
    (lib / 'WhiskyWineVersion.plist').write_bytes(plistlib.dumps(info))
    manifest = {'runtime_version': args.version, 'wine_version': run(str(wine64), '--version').strip(),
                'core': args.core, 'poc_commit': run('git', '-C', str(poc), 'rev-parse', 'HEAD').strip(),
                'poc_dirty': bool(run('git', '-C', str(poc), 'status', '--porcelain').strip()),
                'minimum_macos': '.'.join(map(str, minimum)), 'architecture': 'x86_64 / Rosetta 2',
                'graphics': ['DXVK', 'wined3d'], 'target_device_acceptance': 'pending', 'mach_o': audit}
    (notices / 'runtime-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Checked and signed {len(audit)} Mach-O files; macOS >= {manifest["minimum_macos"]}', flush=True)
    archive = out / 'Libraries.tar.gz'
    with tarfile.open(archive, 'w:gz', compresslevel=6) as tf:
        tf.add(lib, arcname='Libraries')
    info['sha256'] = digest(archive)
    (out / 'WhiskyWineVersion.plist').write_bytes(plistlib.dumps(info))
    (out / 'SHA256SUMS').write_text(f'{info["sha256"]}  Libraries.tar.gz\n')
    print(f'Archive: {archive}\nSHA-256: {info["sha256"]}', flush=True)


if __name__ == '__main__':
    main()
