#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Build locked Anime4K/Real-CUGAN backends into an isolated Wine stage.

Downloads source archives only. Runtime model downloads and installed-app
replacement are separate operations. --test runs bounded, window-free CPU tests.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request

PROJECT = Path(__file__).resolve().parents[1]
NATIVE = PROJECT / 'native/gdi-upscalers'
LOCK_PATH = NATIVE / 'dependencies.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare_archive(item, work, cache=None, offline=False):
    archive = work / 'archives' / item['archive']
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists() and cache and (cache / item['archive']).is_file():
        candidate = cache / item['archive']
        if digest(candidate) != item['sha256']:
            raise ValueError('Source archive cache digest mismatch: ' + item['id'])
        shutil.copy2(candidate, archive)
    if not archive.exists():
        if offline:
            raise FileNotFoundError('Offline source archive missing: ' + item['archive'])
        pending = archive.with_suffix('.download')
        request = urllib.request.Request(item['url'], headers={'User-Agent': 'Wine-GDI-Upscalers-build'})
        with urllib.request.urlopen(request, timeout=90) as response, pending.open('wb') as output:
            shutil.copyfileobj(response, output)
        if digest(pending) != item['sha256']:
            raise ValueError('Downloaded source archive digest mismatch: ' + item['id'])
        pending.replace(archive)
    if digest(archive) != item['sha256']:
        raise ValueError('Source archive digest mismatch: ' + item['id'])
    destination = work / 'sources' / item['directory']
    marker = destination / '.wgdi-source-sha256'
    if destination.exists():
        if not marker.is_file() or marker.read_text().strip() != item['sha256']:
            raise ValueError('Use a fresh work directory for changed dependency inputs')
        return destination
    (work / 'sources').mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as source:
        members = source.getmembers()
        # These pinned archives contain ordinary files/directories. Reject links
        # before extraction so an archive can never redirect a later member.
        for member in members:
            name = Path(member.name)
            if (name.is_absolute() or '..' in name.parts or name.parts[0] != item['directory'] or
                    not (member.isfile() or member.isdir())):
                raise ValueError('Unsafe source archive member: ' + member.name)
        source.extractall(work / 'sources', members=members)
    marker.write_text(item['sha256'] + '\n')
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', required=True, type=Path)
    parser.add_argument('--stage', required=True, type=Path)
    parser.add_argument('--archive-cache', type=Path)
    parser.add_argument('--arch', choices=('x86_64', 'arm64'), default='x86_64')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--test', action='store_true')
    parser.add_argument('--coreml-python', type=Path, default=os.environ.get('WGDI_COREML_PYTHON'),
                        help='Arm64 Python with requirements-coreml.txt; enables optional Core ML bundle')
    parser.add_argument('--coreml-size', action='append', help='Core ML source WxH; repeat to customize sizes')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('macOS build host required')
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    # Resolve the optional Xcode Metal toolchain before fetching dependencies.
    subprocess.run(['xcrun', '--sdk', 'macosx', '--find', 'metal'], check=True, stdout=subprocess.DEVNULL)
    work, stage = args.work.resolve(), args.stage.resolve()
    lock = json.loads(LOCK_PATH.read_text())
    glsl = NATIVE / 'vendor/anime4k' / lock['algorithms']['anime4k']['shader']
    if digest(glsl) != lock['algorithms']['anime4k']['sha256']:
        raise ValueError('Pinned Anime4K shader changed; review the source lock')
    sources = {item['id']: prepare_archive(item, work, args.archive_cache, args.offline)
               for item in lock['archives']}
    for name, expected in lock['model_sha256'].items():
        if digest(sources['realcugan'] / name) != expected:
            raise ValueError('Real-CUGAN model digest mismatch: ' + name)
    build = work / ('build-' + args.arch)
    unix_dir = 'lib/wine/' + args.arch + '-unix'
    coreml_bundle = ''
    if args.coreml_python:
        # Each conversion build gets a fresh output, avoiding stale model files
        # when the source graph, compiler, or selected dimensions change.
        import tempfile
        work.mkdir(parents=True, exist_ok=True)
        parent = Path(tempfile.mkdtemp(prefix='coreml-', dir=work))
        bundle = parent / 'bundle'
        # A virtualenv is identified by its executable path, including symlinks.
        command = [str(args.coreml_python.absolute()), str(PROJECT / 'scripts/build-realcugan-coreml.py'),
                   '--model-dir', str(sources['realcugan'] / 'models/models-se'), '--output', str(bundle)]
        for size in args.coreml_size or []:
            command += ['--size', size]
        subprocess.run(command, check=True)
        coreml_bundle = str(bundle)
    subprocess.run(['cmake', '-S', str(NATIVE), '-B', str(build),
                    '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=' + args.arch,
                    '-DCMAKE_SYSTEM_NAME=Darwin', '-DCMAKE_SYSTEM_PROCESSOR=' + args.arch,
                    '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
                    '-DCMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG',
                    '-DCMAKE_C_COMPILER=/usr/bin/clang', '-DCMAKE_CXX_COMPILER=/usr/bin/clang++',
                    '-DCMAKE_OBJCXX_COMPILER=/usr/bin/clang++',
                    '-DCMAKE_C_COMPILER_ARG1=', '-DCMAKE_CXX_COMPILER_ARG1=', '-DCMAKE_OBJCXX_COMPILER_ARG1=',
                    '-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0', '-DCMAKE_INSTALL_PREFIX=' + str(stage),
                    '-DNCNN_SOURCE_DIR=' + str(sources['ncnn']),
                    '-DWGDI_MODEL_DIR=' + str(sources['realcugan'] / 'models/models-se'),
                    '-DWINE_UNIX_DIR=' + unix_dir,
                    '-DWGDI_COREML_BUNDLE=' + coreml_bundle,
                    '-DBUILD_TESTING=' + ('ON' if args.test else 'OFF')], check=True)
    subprocess.run(['cmake', '--build', str(build), '--parallel', str(args.jobs)], check=True)
    if args.test:
        subprocess.run(['ctest', '--test-dir', str(build), '--output-on-failure'], check=True)
    subprocess.run(['cmake', '--install', str(build)], check=True)
    library = stage / unix_dir / 'libwinegdiupscalers.dylib'
    subprocess.run(['codesign', '--force', '--sign', '-', str(library)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(library)], check=True)
    resource_dir = stage / unix_dir / 'gdi-upscalers'
    files = [library, *[p for p in sorted(resource_dir.rglob('*')) if p.is_file()]]
    source_files = [p for p in sorted(NATIVE.rglob('*')) if p.is_file()]
    source_files += [Path(__file__), PROJECT / 'scripts/generate-anime4k-metal.py',
                     PROJECT / 'scripts/build-realcugan-coreml.py', PROJECT / 'scripts/convert-realcugan-coreml.py',
                     PROJECT / 'scripts/requirements-coreml.txt']
    manifest = {'abi_version': 1, 'architecture': args.arch, 'algorithms': lock['algorithms'],
                'dependency_archives': lock['archives'],
                'source_sha256': {str(p.relative_to(PROJECT)): digest(p) for p in source_files},
                'files': {str(p.relative_to(stage)): digest(p) for p in files},
                'verification': 'headless CPU inference tests passed' if args.test else 'compiled; runtime validation pending'}
    (stage / '.gdi-upscalers-build.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('GDI upscalers built in isolated stage:', stage)


if __name__ == '__main__':
    main()
