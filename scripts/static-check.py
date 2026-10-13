#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Inspect delivered files without executing Wine or Windows binaries."""
import argparse
import hashlib
import json
import re
import struct
import subprocess
from pathlib import Path

script_dir = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--package', type=Path, default=(script_dir if (script_dir / 'baseline').is_dir() else script_dir.parent / 'outputs/wine-poc'))
parser.add_argument('--libraries', action='store_true', help='Check the final Whisky Libraries tree')
parser.add_argument('--max-minimum-macos', help='Reject binaries requiring a newer macOS than this version')
args = parser.parse_args()
root = args.package.resolve()
records = []
for item in ([] if args.libraries else json.loads((root / 'probe-and-sample-manifest.json').read_text())):
    file = root / item['file']
    assert hashlib.sha256(file.read_bytes()).hexdigest() == item['sha256'], file
for file in root.rglob('*'):
    if file.is_symlink():
        assert file.resolve().is_relative_to(root.resolve()), ('External symlink', file)
        assert file.exists(), ('Broken symlink', file)
moltenvk = root / ('Wine/lib/libMoltenVK.dylib' if args.libraries else 'deps/lib/libMoltenVK.dylib')
assert moltenvk.is_file(), 'Missing MoltenVK runtime'
description = subprocess.check_output(['/usr/bin/file', '-b', str(moltenvk)], text=True)
assert 'Mach-O 64-bit' in description and 'x86_64' in description, description
records.append({'file': str(moltenvk.relative_to(root)), 'type': description.strip()})
pe_count = 0
for variant in (('Wine',) if args.libraries else ('baseline', 'media')):
    for program in ('wine', 'wineserver'):
        file = root / variant / 'bin' / program
        description = subprocess.check_output(['/usr/bin/file', '-b', str(file)], text=True)
        assert 'Mach-O 64-bit executable x86_64' in description, (file, description)
        records.append({'file': str(file.relative_to(root)), 'type': description.strip()})
    native_modules = ['ntdll.so', 'win32u.so', 'winemac.so', 'winecoreaudio.so', 'winevulkan.so']
    if variant in ('media', 'Wine'):
        native_modules.append('winedmo.so')
    for module in native_modules:
        file = root / variant / 'lib/wine/x86_64-unix' / module
        description = subprocess.check_output(['/usr/bin/file', '-b', str(file)], text=True)
        assert 'Mach-O 64-bit' in description and 'x86_64' in description, (file, description)
        records.append({'file': str(file.relative_to(root)), 'type': description.strip()})
    assert b'libMoltenVK.dylib' in (root / variant / 'lib/wine/x86_64-unix/win32u.so').read_bytes(), ('Vulkan backend not compiled', variant)
    for arch, machine in (('i386', 0x14c), ('x86_64', 0x8664)):
        folder = root / variant / 'lib/wine' / (arch + '-windows')
        for file in folder.iterdir():
            if not file.is_file():
                continue
            with file.open('rb') as stream:
                if stream.read(2) != b'MZ':
                    continue
                stream.seek(0)
                data = stream.read()
            offset = struct.unpack_from('<I', data, 0x3c)[0]
            assert data[offset:offset + 4] == b'PE\0\0', file
            assert struct.unpack_from('<H', data, offset + 4)[0] == machine, file
            sections = struct.unpack_from('<H', data, offset + 6)[0]
            optional_size = struct.unpack_from('<H', data, offset + 20)[0]
            table = offset + 24 + optional_size
            assert table + sections * 40 <= len(data), file
            for index in range(sections):
                size, position = struct.unpack_from('<II', data, table + index * 40 + 16)
                assert size == 0 or position + size <= len(data), (file, index)
            pe_count += 1
    modules = ['ntdll', 'kernel32', 'quartz', 'qasf', 'wmvcore', 'winevulkan']
    if variant in ('media', 'Wine'):
        modules.append('winedmo')
    for arch, machine in (('i386', 0x14c), ('x86_64', 0x8664)):
        for module in modules:
            matches = list((root / variant / 'lib/wine' / (arch + '-windows')).glob(module + '.dll'))
            assert len(matches) == 1, (variant, arch, module, matches)
            file = matches[0]
            data = file.read_bytes()
            assert data[:2] == b'MZ', file
            offset = struct.unpack_from('<I', data, 0x3c)[0]
            assert data[offset:offset + 4] == b'PE\0\0', file
            assert struct.unpack_from('<H', data, offset + 4)[0] == machine, file
            records.append({'file': str(file.relative_to(root)), 'machine': hex(machine),
                            'sha256': hashlib.sha256(data).hexdigest()})
for bits, machine in (() if args.libraries else (('x86', 0x14c), ('x64', 0x8664))):
    file = root / ('media-probe-' + bits + '.exe')
    data = file.read_bytes()
    assert data[:2] == b'MZ', file
    offset = struct.unpack_from('<I', data, 0x3c)[0]
    assert data[offset:offset + 4] == b'PE\0\0', file
    assert struct.unpack_from('<H', data, offset + 4)[0] == machine, file
    records.append({'file': file.name, 'machine': hex(machine),
                    'sha256': hashlib.sha256(data).hexdigest()})
audit = []
if args.libraries:
    # Inspect the final stripped and signed payload directly.
    for file in (root / 'Wine').rglob('*'):
        if not file.is_file() or file.is_symlink():
            continue
        with file.open('rb') as stream:
            magic = stream.read(4)
        if magic not in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
            continue
        audit.append({'file': str(file.relative_to(root)),
                      'dependencies': subprocess.check_output(['/usr/bin/otool', '-L', str(file)], text=True),
                      'load_commands': subprocess.check_output(['/usr/bin/otool', '-l', str(file)], text=True)})
else:
    audit = json.loads((root / 'packaging-audit.json').read_text())
for item in audit:
    file = root / item['file']
    for line in item['dependencies'].splitlines()[1:]:
        dependency = line.strip().split(' (')[0]
        identity = re.search(r'cmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.*?) \(offset', item['load_commands'])
        if identity and dependency == identity.group(1):
            continue
        if dependency.startswith('@rpath/'):
            rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', item['load_commands'])
            candidates = []
            for rpath in rpaths:
                if rpath == '@loader_path':
                    candidates.append(file.parent / dependency[7:])
                elif rpath.startswith('@loader_path/'):
                    candidates.append(file.parent / rpath[13:] / dependency[7:])
                elif rpath.startswith('/'):
                    candidates.append(Path(rpath) / dependency[7:])
            assert any(candidate.is_file() for candidate in candidates), (file, dependency, candidates)
        elif dependency.startswith('/'):
            assert dependency.startswith(('/usr/lib/', '/System/Library/')), (file, dependency)
        elif dependency.startswith('@loader_path/'):
            assert (file.parent / dependency[13:]).is_file(), (file, dependency)
    subprocess.run(['/usr/bin/codesign', '--verify', str(file)], check=True, capture_output=True)
minimum_versions = []
for item in audit:
    text = subprocess.check_output(['/usr/bin/otool', '-l', str(root / item['file'])], text=True)
    found = re.findall(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform 1\s+minos ([\d.]+)', text)
    found += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([\d.]+)', text)
    minimum_versions.extend(found)
def version(value):
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * max(0, 3 - len(parts))
actual_minimum = max(minimum_versions, key=version) if minimum_versions else None
if args.max_minimum_macos:
    assert actual_minimum and version(actual_minimum) <= version(args.max_minimum_macos), ('Minimum macOS exceeds limit', actual_minimum, args.max_minimum_macos)
if args.libraries:
    claimed = json.loads((root / 'GE-Media/runtime-manifest.json').read_text())['minimum_macos']
    assert actual_minimum and version(claimed) == version(actual_minimum), ('Minimum macOS metadata mismatch', claimed, actual_minimum)
if (root / 'portability.json').exists():
    claimed = json.loads((root / 'portability.json').read_text())['minimum_macos_actual']
    assert actual_minimum and version(claimed) == version(actual_minimum), ('Minimum macOS metadata mismatch', claimed, actual_minimum)
for script in (() if args.libraries else ('run.sh', 'probe.sh')):

    subprocess.run(['/bin/bash', '-n', str(root / script)], check=True)
(root / 'static-check.json').write_text(json.dumps({
    'scope': 'File architectures, PE modules, dependencies, signatures and shell syntax only',
    'runtime_acceptance': 'User-owned; Wine and Windows binaries were not executed',
    'files': records,
    'minimum_macos_actual': actual_minimum,
    'macho_files': len(audit),
    'all_pe_files_checked': pe_count,
}, indent=2) + '\n')
print('Static package checks passed:', len(records), 'key files')
