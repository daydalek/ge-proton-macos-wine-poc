#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Reproduce source-only validation in a fresh directory; no builds or installs."""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
from poc_common import CONFIGS, SETTINGS, WORK, download_verified, extract_tar  # noqa: E402

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--root', type=Path, default=Path(os.environ.get('POC_SOURCE_ROOT', WORK / 'repro')))
ap.add_argument('--cache', type=Path, default=WORK)
args = ap.parse_args()
root, cache = args.root.resolve(), args.cache.resolve()
root.mkdir(parents=True, exist_ok=False)
lock = json.loads((CONFIGS / 'source-lock.json').read_text())
for item in lock['sources']:
    archive = download_verified(item['url'], cache / item['archive'], item['sha256'])
    extract_tar(archive, root)
ge = root / SETTINGS['POC_GE_DIR']
wine = root / SETTINGS['POC_MEDIA_WINE_DIR']
subprocess.run(['git', 'init', '-q', str(wine)], check=True)
log = []

def apply(patch, excludes=()):
    extra = [f'--exclude={x}' for x in excludes]
    subprocess.run(['git', 'apply', '--check', *extra, str(patch)], cwd=wine, check=True)
    subprocess.run(['git', 'apply', *extra, str(patch)], cwd=wine, check=True)
    log.append({'patch': patch.name, 'excluded_paths': list(excludes)})
    print('Applied:', patch.name, flush=True)

apply(ge / 'patches/wine-hotfixes/wine-wayland/0134-winegstreamer-Don-t-force-x11-display-type.patch')
for patch in sorted((ge / 'patches/ge-video-rework').glob('*.patch')):
    if patch.name.startswith('0006-'):
        apply(patch, ('loader/wine.inf.in',))
        inf = wine / 'loader/wine.inf.in'
        text = inf.read_text()
        old = '11,,winegstreamer.dll,1'
        assert text.count(old) == 1
        inf.write_text(text.replace(old, '11,,winedmo.dll,1'))
        log[-1]['adaptation'] = 'Replace the single winegstreamer registration with winedmo.'
    elif patch.name.startswith('0011-'):
        apply(patch, ('configure',))
        log[-1]['adaptation'] = 'Regenerate configure from configure.ac before building.'
    else:
        apply(patch)
notice_args = [sys.executable, str(Path(__file__).resolve().parent / 'source-notices.py'), '--source', str(wine)]
for patch in sorted((ge / 'patches/ge-video-rework').glob('*.patch')):
    notice_args.extend(['--patch', str(patch)])
subprocess.run(notice_args, check=True)
(root / 'application-log.json').write_text(json.dumps(log, indent=2) + '\n')
print('Prepared source:', wine)
print('Build status: source preparation only; configure regeneration required.')
