#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Build the shared CrossOver/GE patch stack for x86_64 Linux and new WoW64."""
import argparse
import hashlib
import inspect
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT / 'scripts/lib'))
from poc_common import crossover_patch_series, download_verified, extract_tar, sha256_file


def patch_plan(project=PROJECT):
    profile = json.loads((project / 'configs/linux-build.json').read_text())
    series = crossover_patch_series(project)
    excluded = profile['platform_exclusions']
    if not set(excluded) <= set(series):
        raise ValueError('Linux exclusion refers to a patch outside the shared series')
    return [{'path': name, 'sha256': sha256_file(project / name),
             'applied': name not in excluded, 'reason': excluded.get(name, 'Shared source patch')}
            for name in series]


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


class Build:
    def __init__(self, work, jobs, archive_cache=None):
        self.work = work.resolve()
        self.jobs = jobs
        self.cache = archive_cache
        self.profile = json.loads((PROJECT / 'configs/linux-build.json').read_text())
        self.lock = json.loads((PROJECT / 'configs/crossover-source-lock.json').read_text())
        self.dependencies = json.loads((PROJECT / 'configs/dependency-lock.json').read_text())
        self.source = self.work / 'source/wine'
        self.deps = self.work / 'deps'
        self.stage = self.work / 'stage'
        self.toolchain = self.work / 'tools' / self.profile['toolchain']['directory']
        self.work.mkdir(parents=True, exist_ok=True)
        (self.work / 'logs').mkdir(exist_ok=True)

    def run(self, args, log, cwd=None, env=None):
        print('Running', ' '.join(map(str, args)), '->', log, flush=True)
        with (self.work / 'logs' / log).open('w') as output:
            result = subprocess.run(list(map(str, args)), cwd=cwd, env=env,
                                    stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            print((self.work / 'logs' / log).read_text(errors='replace')[-12000:], file=sys.stderr)
            raise subprocess.CalledProcessError(result.returncode, args)

    def fetch(self, item):
        target = self.work / 'archives' / item['archive']
        if not target.exists() and self.cache:
            for candidate in (self.cache / item['archive'], self.cache / 'crossover-port' / item['archive']):
                if candidate.is_file() and sha256_file(candidate) == item['sha256']:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(candidate, target)
                    break
        return download_verified(item['url'], target, item['sha256'])

    def prepare(self):
        plan = patch_plan()
        inputs = {'source_sha256': self.lock['source_sha256'], 'patches': plan}
        marker = self.work / 'source-inputs.json'
        if self.source.exists():
            if not marker.exists() or json.loads(marker.read_text()) != inputs:
                raise SystemExit('Source inputs changed; select a fresh POC_LINUX_WORK_DIR')
            return
        item = {'archive': 'crossover-sources-26.3.0.tar.gz', 'url': self.lock['source_url'],
                'sha256': self.lock['source_sha256']}
        archive = self.fetch(item)
        # Extract into a temporary sibling so an interrupted preparation can be retried.
        scratch = self.work / 'source-preparing'
        if scratch.exists():
            shutil.rmtree(scratch)
        scratch.mkdir()
        extract_tar(archive, scratch, members=['sources/wine'])
        tree = scratch / 'sources/wine'
        self.run(['git', 'init', '-q', tree], 'source-init.log')
        notice_args = []
        for entry in plan:
            if entry['applied']:
                patch = PROJECT / entry['path']
                self.run(['git', 'apply', '--check', patch], 'patch-check.log', cwd=tree)
                self.run(['git', 'apply', patch], 'patch-apply.log', cwd=tree)
                notice_args += ['--patch', patch]
        self.run([sys.executable, PROJECT / 'scripts/source-notices.py', '--source', tree, *notice_args],
                 'source-notices.log')
        self.source.parent.mkdir(parents=True, exist_ok=True)
        tree.rename(self.source)
        write_json(marker, inputs)
        shutil.rmtree(scratch)

    def build_deps(self):
        item = self.profile['toolchain']
        archive = self.fetch(item)
        if not self.toolchain.exists():
            extract_tar(archive, self.work / 'tools')
        ffmpeg = next(x for x in self.dependencies if x['archive'] == 'ffmpeg.tar.gz')
        archive = self.fetch(ffmpeg)
        inputs = {'ffmpeg': ffmpeg, 'toolchain': item, 'recipe_sha256':
                  hashlib.sha256(inspect.getsource(Build.build_deps).encode()).hexdigest()}
        marker = self.work / 'dependency-inputs.json'
        if marker.exists() and json.loads(marker.read_text()) == inputs:
            return
        source_root = self.work / 'source'
        source_root.mkdir(exist_ok=True)
        ffsource = source_root / 'FFmpeg-9047fa1b084f76b1b4d065af2d743df1b40dfb56'
        if not ffsource.exists():
            extract_tar(archive, source_root)
        build = self.work / 'build/ffmpeg'
        build.mkdir(parents=True, exist_ok=True)
        self.run([ffsource / 'configure', '--prefix=' + str(self.deps), '--cc=cc',
                  '--arch=x86_64', '--target-os=linux', '--enable-shared', '--disable-static',
                  '--disable-autodetect', '--disable-x86asm', '--disable-doc', '--disable-debug',
                  '--disable-network', '--disable-everything', '--disable-gpl', '--disable-nonfree',
                  '--disable-version3', '--disable-hwaccels', '--enable-avcodec', '--enable-avformat',
                  '--enable-avutil', '--enable-swscale', '--enable-swresample', '--enable-avfilter',
                  '--enable-indev=lavfi', '--enable-filter=testsrc2,color,format,aresample,sine,scale',
                  '--enable-demuxers', '--enable-decoders', '--enable-parsers',
                  '--enable-encoder=wmv1,wmv2,wmav2,mpeg1video,mp2,pcm_s16le',
                  '--enable-muxer=asf,mpeg1system,vob,wav,avi', '--enable-protocol=file', '--enable-bsfs'],
                 'ffmpeg-configure.log', cwd=build)
        self.run(['make', '-j' + str(self.jobs)], 'ffmpeg-build.log', cwd=build)
        self.run(['make', 'install'], 'ffmpeg-install.log', cwd=build)
        write_json(marker, inputs)

    def environment(self):
        env = dict(os.environ)
        for key in ('WINEPREFIX', 'WINEDLLPATH', 'WINELOADER', 'WINESERVER', 'WINEARCH',
                    'LD_LIBRARY_PATH', 'DYLD_LIBRARY_PATH', 'CPPFLAGS', 'CFLAGS', 'CXXFLAGS', 'LDFLAGS'):
            env.pop(key, None)
        env['PATH'] = str(self.toolchain / 'bin') + ':' + env['PATH']
        env['PKG_CONFIG_PATH'] = str(self.deps / 'lib/pkgconfig')
        env['LD_LIBRARY_PATH'] = str(self.deps / 'lib')
        env['CC'] = 'gcc'
        env['CXX'] = 'g++'
        # Keep installed paths reproducible; runtime wrappers locate bundled FFmpeg.
        env['CFLAGS'] = '-O2 -g -ffile-prefix-map=' + str(self.work) + '=/usr/src/ge-wine'
        env['CXXFLAGS'] = env['CFLAGS']
        env['CROSSCFLAGS'] = env['CFLAGS']
        return env

    def build_wine(self):
        self.prepare()
        self.build_deps()
        build = self.work / 'build/wine'
        build.mkdir(parents=True, exist_ok=True)
        env = self.environment()
        self.run([self.source / 'configure', '--prefix=' + str(self.stage),
                  '--enable-archs=i386,x86_64', '--with-mingw=llvm-mingw', '--with-ffmpeg',
                  '--with-gnutls', '--with-freetype', '--with-x', '--with-wayland',
                  '--with-pulse', '--with-alsa', '--with-vulkan', '--with-opengl', '--disable-tests'],
                 'wine-configure.log', cwd=build, env=env)
        self.run(['make', '-j' + str(self.jobs)], 'wine-build.log', cwd=build, env=env)
        self.run(['make', 'install'], 'wine-install.log', cwd=build, env=env)
        modules = ['bin/wine', 'bin/wineserver', 'lib/wine/x86_64-unix/ntdll.so',
                   'lib/wine/x86_64-unix/win32u.so', 'lib/wine/x86_64-unix/winedmo.so',
                   'lib/wine/i386-windows/ntdll.dll', 'lib/wine/x86_64-windows/ntdll.dll']
        write_json(self.stage / 'build-provenance.json', {
            'target': self.profile['target'], 'baseline': self.profile['baseline'],
            'windows_architectures': self.profile['windows_architectures'],
            'source_sha256': self.lock['source_sha256'], 'patches': patch_plan(),
            'toolchain': self.profile['toolchain'],
            'compiled_modules': {name: sha256_file(self.stage / name) for name in modules},
            'configure_log_sha256': sha256_file(self.work / 'logs/wine-configure.log'),
            'build_log_sha256': sha256_file(self.work / 'logs/wine-build.log'),
        })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('step', choices=['prepare', 'deps', 'wine', 'all'])
    parser.add_argument('--work-dir', type=Path, default=Path(os.environ.get(
        'POC_LINUX_WORK_DIR', str(Path.home() / '.cache/ge-wine-linux'))))
    parser.add_argument('--archive-cache', type=Path)
    parser.add_argument('--jobs', type=int, default=int(os.environ.get('POC_JOBS', '4')))
    args = parser.parse_args()
    if platform.system() != 'Linux' or platform.machine() not in ('x86_64', 'AMD64'):
        parser.error('Run inside an x86_64 Linux userspace')
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    build = Build(args.work_dir, args.jobs, args.archive_cache)
    if args.step == 'prepare':
        build.prepare()
    elif args.step == 'deps':
        build.build_deps()
    else:
        build.build_wine()


if __name__ == '__main__':
    main()
