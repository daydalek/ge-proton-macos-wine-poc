#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Exercise the CI Libraries contract on a hosted Mac without rebuilding Wine."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import urllib.request

PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT / 'scripts/lib'))
from poc_common import WORK, SETTINGS, sha256_file, extract_tar, download_verified

URL = 'https://github.com/daydalek/ge-proton-macos-wine-poc/releases/download/v0.1.0/wine-macos27-apple-silicon-rosetta.tar.gz'
DIGEST = 'd8e6ef1996b558e6eafb3395da751a02ed4bb3841f6a44f99c32933c1b73cf85'


def main():
    WORK.mkdir(parents=True)
    archive = WORK / 'released-core.tar.gz'
    with urllib.request.urlopen(URL, timeout=120) as source, archive.open('wb') as output:
        shutil.copyfileobj(source, output)
    if sha256_file(archive) != DIGEST:
        raise ValueError('Released core digest mismatch')
    unpack = WORK / 'released'
    extract_tar(archive, unpack)
    package = unpack / 'wine-macos27-apple-silicon-rosetta'
    stage = WORK / 'poc/stage'
    stage.mkdir(parents=True)
    shutil.copytree(package / 'media', stage / 'media', symlinks=True)
    shutil.copytree(package / 'deps/lib', stage / 'deps-x64/lib', symlinks=True)
    tools = WORK / 'poc/tools'
    tools.mkdir()
    lock = json.loads((PROJECT / 'configs/dependency-lock.json').read_text())
    llvm = next(item for item in lock if item['archive'] == 'llvm-mingw.tar.xz')
    tool_archive = download_verified(llvm['url'], WORK / llvm['archive'], llvm['sha256'])
    extract_tar(tool_archive, tools)
    if not (tools / SETTINGS['POC_LLVM_MINGW_DIR'] / 'bin/llvm-objcopy').is_file():
        raise ValueError('Locked llvm-mingw toolchain layout mismatch')
    release = WORK / 'release'
    release.mkdir()
    (release / 'release-manifest.json').write_text(json.dumps({
        'validation_scope': 'packaging the already released media core', 'input_archive_sha256': DIGEST}) + '\n')
    (release / 'RELEASE-NOTES.md').write_text('Libraries integration check; Actions artifact only.\n')
    version = '11.0.' + str(int(os.environ['GITHUB_RUN_NUMBER']) + 1)
    subprocess.run([sys.executable, str(PROJECT / 'scripts/ci/build-libraries.py'),
                    '--version', version, '--output', str(release)], check=True)
    install = WORK / 'install'
    extract_tar(release / 'Libraries.tar.gz', install)
    core = install / 'Libraries/Wine'
    info = plistlib.loads((release / 'WhiskyWineVersion.plist').read_bytes())
    if sha256_file(release / 'Libraries.tar.gz') != info['sha256']:
        raise ValueError('Whisky package digest mismatch')
    subprocess.run([str(core / 'bin/wine64'), '--version'], check=True)
    env = os.environ.copy()
    env.update(WINEPREFIX=str(WORK / 'probe-prefix'), WINEDEBUG='+timestamp,+pid,+tid,+seh',
               WINEDLLOVERRIDES='winemenubuilder.exe=d',
               WINELOADER=str(core / 'bin/wine64'), WINESERVER=str(core / 'bin/wineserver'),
               DYLD_FALLBACK_LIBRARY_PATH=str(core / 'lib') + ':/usr/lib')
    # Keep bootstrap separate so a hosted prefix failure has an identifiable log.
    logs = WORK / 'diagnostics'
    logs.mkdir()
    commands = [('wineboot', ['wineboot', '-u'])] + [
        (bits, [str(package / f'command-line-probe-{bits}.exe')]) for bits in ('x86', 'x64')]
    try:
        for name, args in commands:
            print('Running Libraries smoke phase:', name, flush=True)
            log = logs / (name + '.log')
            try:
                with log.open('wb') as stream:
                    subprocess.run([str(core / 'bin/wine64'), *args], env=env,
                                   stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=300)
            finally:
                print(log.read_text(errors='replace')[-16000:], flush=True)
    finally:
        with (logs / 'processes.txt').open('w') as stream:
            subprocess.run(['ps', '-axo', 'pid,ppid,state,etime,command'], stdout=stream)
        subprocess.run([str(core / 'bin/wineserver'), '-k'], env=env, timeout=30)
    print('Whisky Libraries archive, metadata, relocation and x86/x64 launches: PASS')


if __name__ == '__main__':
    main()
