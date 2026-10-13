#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Build the independent Whisky Libraries asset from this CI run's Wine stage."""
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
import urllib.request

PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT / 'scripts/lib'))
from poc_common import STAGE, WORK, SETTINGS, sha256_file

# Bootstrap only the pinned DXVK payload. Wine always comes from the current build.
DXVK_BASE_URL = 'https://github.com/daydalek/ge-proton-macos-wine-poc/releases/download/v0.1.0/Libraries.tar.gz'
DXVK_BASE_SHA256 = 'bb5f2f3d49e528e9200c02beb5b1e004c06ad00969a790285faa9ed46f900c60'


def extract_dxvk(archive, destination):
    with tarfile.open(archive) as tf:
        for member in tf:
            if member.name == 'Libraries/WhiskyWineVersion.plist' or member.name.startswith('Libraries/DXVK/'):
                if member.isfile():
                    if Path(member.name).is_absolute() or '..' in Path(member.name).parts:
                        raise ValueError('Unexpected DXVK archive path')
                    target = destination / member.name
                    if destination.resolve() not in target.resolve().parents:
                        raise ValueError('Unexpected DXVK archive path')
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with tf.extractfile(member) as source, target.open('wb') as output:
                        shutil.copyfileobj(source, output)
    base = destination / 'Libraries'
    info = plistlib.loads((base / 'WhiskyWineVersion.plist').read_bytes())
    if info['dxvkVersion'] != '1.10.3':
        raise ValueError('Unexpected DXVK version')
    for arch in ('x32', 'x64'):
        for name in ('d3d11.dll', 'd3d10core.dll'):
            if not (base / 'DXVK' / arch / name).is_file():
                raise ValueError('Incomplete DXVK payload')
    return base


def update_checksums(output):
    files = [p for p in sorted(output.iterdir()) if p.is_file() and p.name != 'SHA256SUMS']
    (output / 'SHA256SUMS').write_text(''.join(f'{sha256_file(p)}  {p.name}\n' for p in files))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True, help='Monotonically increasing runtime version X.Y.Z')
    parser.add_argument('--output', type=Path, required=True, help='Existing CI release output directory')
    parser.add_argument('--base-archive', type=Path, help='Pinned DXVK bootstrap archive (local verification)')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.version):
        parser.error('version must be X.Y.Z')
    output = args.output.resolve()
    if not output.is_dir():
        parser.error('create the normal release output first')
    archive = args.base_archive.resolve() if args.base_archive else WORK / 'whisky-dxvk-bootstrap.tar.gz'
    if not archive.exists():
        request = urllib.request.Request(DXVK_BASE_URL, headers={'User-Agent': 'Wine-Libraries-CI'})
        with urllib.request.urlopen(request, timeout=120) as source, archive.open('wb') as dest:
            shutil.copyfileobj(source, dest)
    if sha256_file(archive) != DXVK_BASE_SHA256:
        raise ValueError('DXVK bootstrap archive digest mismatch')
    staging = WORK / 'whisky-libraries-staging'
    staging.mkdir()
    base = extract_dxvk(archive, staging / 'dxvk-base')
    assembled = staging / 'assembled'
    public = staging / 'public'
    subprocess.run([sys.executable, str(PROJECT / 'scripts/ci/assemble-libraries.py'),
                    '--stage', str(STAGE), '--base-libraries', str(base),
                    '--version', args.version, '--output', str(assembled)], check=True)
    provenance_path = assembled / 'Libraries/GE-Media/runtime-manifest.json'
    provenance = json.loads(provenance_path.read_text())
    provenance['packaging_commit'] = provenance.pop('poc_commit')
    provenance['packaging_checkout_dirty'] = provenance.pop('poc_dirty')
    release_context = json.loads((output / 'release-manifest.json').read_text())
    provenance['source_kind'] = 'released-core validation' if 'validation_scope' in release_context else 'current CI Wine build'
    if 'input_archive_sha256' in release_context:
        provenance['input_archive_sha256'] = release_context['input_archive_sha256']
    provenance_path.write_text(json.dumps(provenance, indent=2) + '\n')
    objcopy = WORK / 'poc/tools' / SETTINGS['POC_LLVM_MINGW_DIR'] / 'bin/llvm-objcopy'
    subprocess.run([sys.executable, str(PROJECT / 'scripts/ci/prepare-libraries.py'),
                    '--input', str(assembled / 'Libraries'), '--output', str(public),
                    '--objcopy', str(objcopy), '--private-name', os.environ.get('USER', 'runner')], check=True)
    subprocess.run([sys.executable, str(PROJECT / 'scripts/static-check.py'),
                    '--libraries', '--package', str(public / 'Libraries'),
                    '--max-minimum-macos', '27.0'], check=True)
    static = json.loads((public / 'Libraries/static-check.json').read_text())
    shutil.move(public / 'Libraries/static-check.json', output / 'Libraries-static-check.json')
    for name in ('Libraries.tar.gz', 'WhiskyWineVersion.plist'):
        shutil.copy2(public / name, output / name)
    # Anonymous report belongs beside the package; detailed local logs stay out.
    shutil.copy2(public / 'privacy-audit.json', output / 'Libraries-privacy-audit.json')
    manifest = json.loads((output / 'release-manifest.json').read_text())
    manifest['minimum_macos_actual'] = static['minimum_macos_actual']
    manifest['static_checks'] = static
    manifest['whisky_runtime'] = {'version': args.version, 'core': 'media', 'archive': 'Libraries.tar.gz',
                                  'dxvk_version': '1.10.3', 'privacy_audit': 'Libraries-privacy-audit.json',
                                  'bootstrap_sha256': DXVK_BASE_SHA256}
    (output / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    notes = output / 'RELEASE-NOTES.md'
    with notes.open('a') as f:
        source_description = 'released media core' if 'validation_scope' in manifest else "this CI run's media build"
        f.write('\nWhisky-compatible runtime: Libraries.tar.gz and WhiskyWineVersion.plist.\n'
                f'The Wine core is from {source_description}; DXVK-macOS 1.10.3 is digest-pinned.\n'
                'Runtime version: ' + args.version + '.\n')
    update_checksums(output)
    print('Whisky Libraries assets ready:', output)


if __name__ == '__main__':
    main()
