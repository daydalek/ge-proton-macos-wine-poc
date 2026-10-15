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
from poc_common import WORK, CROSSOVER_PORT, SETTINGS, DEPLOYMENT_TARGET, sha256_file, version_tuple

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
assert version_tuple(DEPLOYMENT_TARGET) == version_tuple('27.0'), 'Expected macOS 27.0 build configuration'
assert platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Requires Apple Silicon host'
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=project, text=True).strip()
source_dirs = [CROSSOVER_PORT / 'sources/wine']
crossover_lock = json.loads((project / 'configs/crossover-source-lock.json').read_text())
locks = json.loads((project / 'configs/dependency-lock.json').read_text())
archives = [item for item in locks if item['archive'] in
            ('ffmpeg.tar.gz', 'freetype.tar.gz', 'vulkan-headers.tar.gz', 'MoltenVK-macos.tar',
             'gmp.tar.xz', 'nettle.tar.gz', 'libtasn1.tar.gz', 'libunistring.tar.xz', 'gnutls.tar.xz')]
archives.insert(0, {'archive': SETTINGS['POC_CROSSOVER_ARCHIVE'],
                   'url': crossover_lock['source_url'], 'sha256': crossover_lock['source_sha256']})
archive_paths = {item['archive']: (CROSSOVER_PORT if item['archive'] == SETTINGS['POC_CROSSOVER_ARCHIVE'] else WORK) / item['archive']
                 for item in archives}
for item in archives:
    assert sha256_file(archive_paths[item['archive']]) == item['sha256'], item['archive']
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
        tf.add(archive_paths[item['archive']], arcname='archives/' + item['archive'], filter=source_filter)
    for directory in source_dirs:
        tf.add(directory, arcname='prepared/' + directory.name, filter=source_filter)
project_archive.unlink()
manifest = {'commit': commit, 'target': 'macOS 27+ Apple Silicon', 'host_architecture': platform.machine(),
            'wine_core_architecture': 'x86_64', 'windows_architectures': ['i386', 'x86_64'],
            'execution': 'Rosetta 2', 'signing': 'ad-hoc; Apple notarization not performed',
             'runtime_tests': 'Wine/game playback not run; file architectures, signatures, dependencies and native FFmpeg capabilities checked by the release pipeline',
            'core': 'crossover-ge-media', 'wine_base': 'CrossOver 26.3.0',
            'crossover_source_sha256': crossover_lock['source_sha256'],
            'runtime_asset': 'Libraries.tar.gz', 'source_asset': sources.name,
            'source_archives': archives, 'github_run_id': os.environ.get('GITHUB_RUN_ID')}
(output / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(output / 'RELEASE-NOTES.md').write_text('Whisky Libraries runtime for macOS 27+ Apple Silicon. Requires Rosetta 2; Wine core is x86_64.\n\nIncludes CrossOver 26.3 Wine with GE media and fullscreen fixes, DXVK, corresponding prepared sources, locked source archives, recipes and license notices. Game playback requires target-device acceptance. Binaries use local ad-hoc signatures and have no Apple notarization.\n')
checks = [(sha256_file(path), path.name) for path in sorted(output.iterdir())]
(output / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for digest, name in checks))
print(output)
