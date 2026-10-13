#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Archive corresponding prepared sources and initialize the Libraries release metadata."""
import argparse
import json
import os
import platform
import subprocess
import sys
import tarfile
from pathlib import Path

project = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(project / 'scripts/lib'))
from poc_common import WORK, SETTINGS, DEPLOYMENT_TARGET, sha256_file, version_tuple

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
assert version_tuple(DEPLOYMENT_TARGET) == version_tuple('27.0'), 'Expected macOS 27.0 build configuration'
assert platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Requires Apple Silicon host'
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=project, text=True).strip()
prepared = WORK / 'repro'
source_dirs = [prepared / SETTINGS['POC_MEDIA_WINE_DIR']]
locks = []
for filename in ('source-lock.json', 'dependency-lock.json'):
    data = json.loads((project / 'configs' / filename).read_text())
    locks.extend(data['sources'] if isinstance(data, dict) else data)
# Toolchain binaries are fetched by the recipes, while source libraries accompany the runtime.
archives = [item for item in locks if item['archive'] in ('wine11.tar.gz', 'valve-wine.tar.gz', 'ge11-7.tar.gz', 'ffmpeg.tar.gz', 'freetype.tar.gz', 'vulkan-headers.tar.gz', 'MoltenVK-macos.tar')]
for item in archives:
    assert sha256_file(WORK / item['archive']) == item['sha256'], item['archive']
for directory in source_dirs:
    assert (directory / 'LICENSE').is_file(), directory
assert (source_dirs[0] / 'MODIFICATIONS.json').is_file()
assert not output.exists(), 'Release output directory must be fresh'
output.mkdir(parents=True)
project_archive = output / 'project-source.tar'
subprocess.run(['git', 'archive', '--format=tar', '--prefix=project/', '-o', str(project_archive), 'HEAD'], cwd=project, check=True)
sources = output / 'Libraries-sources.tar.gz'

def source_filter(info):
    parts = Path(info.name).parts
    if '.git' in parts or 'autom4te.cache' in parts or '__pycache__' in parts:
        return None
    info.uid = info.gid = 0
    info.uname = info.gname = ''
    info.pax_headers = {}
    info.mtime = 0
    return info

with tarfile.open(sources, 'w:gz') as tf:
    tf.add(project_archive, arcname='project-source.tar', filter=source_filter)
    for item in archives:
        tf.add(WORK / item['archive'], arcname='archives/' + item['archive'], filter=source_filter)
    for directory in source_dirs:
        tf.add(directory, arcname='prepared/' + directory.name, filter=source_filter)
project_archive.unlink()
manifest = {'commit': commit, 'target': 'macOS 27+ Apple Silicon', 'host_architecture': platform.machine(),
            'wine_core_architecture': 'x86_64', 'windows_architectures': ['i386', 'x86_64'],
            'execution': 'Rosetta 2', 'signing': 'ad-hoc; Apple notarization not performed',
            'runtime_tests': 'Not run; file architectures, signatures and dependencies checked',
            'runtime_asset': 'Libraries.tar.gz', 'source_asset': sources.name,
            'source_archives': archives, 'github_run_id': os.environ.get('GITHUB_RUN_ID')}
(output / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(output / 'RELEASE-NOTES.md').write_text('Whisky Libraries runtime for macOS 27+ Apple Silicon. Requires Rosetta 2; Wine core is x86_64.\n\nIncludes the GE media core, DXVK, corresponding prepared sources, locked source archives, recipes and license notices. Game playback requires target-device acceptance. Binaries use local ad-hoc signatures and have no Apple notarization.\n')
checks = [(sha256_file(path), path.name) for path in sorted(output.iterdir())]
(output / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for digest, name in checks))
print(output)
