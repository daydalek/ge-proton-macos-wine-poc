#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Package local Wine installs and rewrite private dependency paths for relocation."""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

scripts_dir = Path(__file__).resolve().parent
project = scripts_dir.parent
sys.path.insert(0, str(scripts_dir / 'lib'))
from poc_common import STAGE, DEPS, DEPLOYMENT_TARGET, minimum_macos, version_text, version_tuple
stage = STAGE
probes = project / 'tools/probes'
samples = project / 'tools/samples'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=project / 'outputs/wine-poc')
parser.add_argument('--check-inputs', action='store_true', help='Check packaging inputs and exit before copying files')
args = parser.parse_args()
package = args.output.resolve()
inputs = {}
for stem in ('media-probe', 'child-window-probe', 'exception-probe',
             'reconnect-probe', 'mpeg-audio-format-probe', 'vulkan-probe', 'command-line-probe', 'device-notify-probe', 'dbghelp-probe', 'dwarf-divisor-probe'):
    for suffix in ('.c', '-x86.exe', '-x64.exe'):
        inputs[stem + suffix] = probes / (stem + suffix)
for suffix in ('.S', '-x86.dll', '-x64.dll'):
    inputs['dwarf-divisor-fixture' + suffix] = probes / ('dwarf-divisor-fixture' + suffix)
for file in sorted(samples.glob('test-*')):
    if file.is_file():
        inputs['samples/' + file.name] = file
for file in sorted((project / 'licenses').iterdir()):
    if file.is_file():
        inputs['licenses/' + file.name] = file
for name in ('crossover-source-lock.json', 'dependency-lock.json',
             'source-license-inventory.json', 'source-lock.json', 'vulkan-generation-lock.json'):
    inputs[name] = project / 'configs' / name
for file in sorted((project / 'patches/wine-ge').glob('*.patch')):
    inputs[file.name] = file
inputs['build.env'] = project / 'configs/build.env'
inputs.update({'run.sh': scripts_dir / 'run-packaged.sh',
               'probe.sh': scripts_dir / 'probe-packaged.sh',
               'README.md': scripts_dir / 'ci/RUNTIME-README.md',
               'LICENSE': project / 'LICENSE', 'COPYING.LIB': project / 'COPYING.LIB',
               'UPSTREAMS.md': project / 'UPSTREAMS.md'})
required = list(inputs.values()) + [stage / variant / 'bin' / name
    for variant in ('baseline', 'media') for name in ('wine', 'wineserver')]
missing = [str(file) for file in required if not file.is_file()]
if not (stage / 'deps-x64/lib').is_dir():
    missing.append(str(stage / 'deps-x64/lib'))
for name in ('wmv2.wmv', 'mpeg1.mpg', 'pcm.wav'):
    if not (samples / ('test-' + name)).is_file():
        missing.append(str(samples / ('test-' + name)))
if missing:
    raise SystemExit('Missing packaging inputs:\n' + '\n'.join(missing))
if args.check_inputs:
    print(f'Packaging inputs ready: {len(inputs)} files; output: {package}')
    raise SystemExit(0)
if package.exists():
    raise SystemExit(f'Package directory already exists: {package}')
package.mkdir(parents=True)
for variant in ('baseline', 'media'):
    shutil.copytree(stage / variant, package / variant, symlinks=True)
shutil.copytree(stage / 'deps-x64/lib', package / 'deps/lib', symlinks=True)
for name, source in inputs.items():
    destination = package / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
manifest = [{'file': name, 'bytes': source.stat().st_size,
             'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}
            for name, source in inputs.items()
            if name.startswith(('samples/', 'dwarf-divisor-fixture')) or name.startswith(('media-probe', 'child-window-probe', 'exception-probe',
             'reconnect-probe', 'mpeg-audio-format-probe', 'vulkan-probe', 'command-line-probe', 'device-notify-probe', 'dbghelp-probe', 'dwarf-divisor-probe'))]
(package / 'probe-and-sample-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
for script in ('run.sh', 'probe.sh'):
    (package / script).chmod(0o755)
deps_prefix = str(DEPS)

def private_library(name):
    # Existing stage files may predate a relocation of the repository.
    return name.startswith(deps_prefix + '/') or Path(name).parent.as_posix().endswith('/poc/stage/deps-x64/lib')

macho_magics = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
audit = []
for file in sorted(package.rglob('*')):
    if not file.is_file() or file.is_symlink():
        continue
    with file.open('rb') as stream:
        if stream.read(4) not in macho_magics:
            continue
    def output(*args):
        return subprocess.check_output(args, text=True)
    original = output('/usr/bin/otool', '-L', str(file))
    changes = []
    for line in original.splitlines()[1:]:
        dependency = line.strip().split(' (')[0]
        if private_library(dependency):
            replacement = '@rpath/' + Path(dependency).name
            subprocess.run(['/usr/bin/install_name_tool', '-change', dependency,
                            replacement, str(file)], check=True, capture_output=True)
            changes.append([dependency, replacement])
    id_lines = output('/usr/bin/otool', '-D', str(file)).splitlines()[1:]
    for name in id_lines:
        if private_library(name):
            subprocess.run(['/usr/bin/install_name_tool', '-id', '@rpath/' + Path(name).name,
                            str(file)], check=True, capture_output=True)
    rpath = '@loader_path/' + os.path.relpath(package / 'deps/lib', file.parent)
    load_commands = output('/usr/bin/otool', '-l', str(file))
    # Free the old command space before adding the package-relative dependency path.
    for old_rpath in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', load_commands):
        if old_rpath == deps_prefix + '/lib' or old_rpath.endswith('/poc/stage/deps-x64/lib'):
            subprocess.run(['/usr/bin/install_name_tool', '-delete_rpath', old_rpath,
                            str(file)], check=True, capture_output=True)
    if 'path ' + rpath + ' ' not in load_commands:
        subprocess.run(['/usr/bin/install_name_tool', '-add_rpath', rpath, str(file)],
                       check=True, capture_output=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(file)],
                   check=True, capture_output=True)
    relocated = output('/usr/bin/otool', '-L', str(file))
    if deps_prefix in relocated:
        raise SystemExit(f'Unrelocated dependency in {file}')
    for line in relocated.splitlines()[1:]:
        dependency = line.strip().split(' (')[0]
        if dependency.startswith('/') and not dependency.startswith(('/usr/lib/', '/System/Library/')):
            raise SystemExit(f'External runtime dependency in {file}: {dependency}')
    subprocess.run(['/usr/bin/codesign', '--verify', str(file)], check=True, capture_output=True)
    audit.append({'file': str(file.relative_to(package)), 'changes': changes,
                  'rpath': rpath, 'dependencies': relocated,
                  'load_commands': output('/usr/bin/otool', '-l', str(file))})
versions = [minimum_macos(package / item['file']) for item in audit]
actual_minimum = max((v for v in versions if v is not None), default=None)
(package / 'portability.json').write_text(json.dumps({
    'requested_deployment_target': DEPLOYMENT_TARGET,
    'minimum_macos_actual': version_text(actual_minimum),
    'host_architecture': 'x86_64',
    'apple_silicon_execution': 'Rosetta 2',
    'runtime_acceptance': 'Pending target-device validation',
}, indent=2) + '\n')
if actual_minimum and actual_minimum > version_tuple(DEPLOYMENT_TARGET):
    print(f'Build minimum macOS {version_text(actual_minimum)} exceeds requested {DEPLOYMENT_TARGET}; rebuild Wine and dependencies for the requested target.')
(package / 'packaging-audit.json').write_text(json.dumps(audit, indent=2) + '\n')
print(f'Packaged {len(audit)} Mach-O files: {package}')
