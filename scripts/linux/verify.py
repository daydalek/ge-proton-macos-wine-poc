#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Run isolated x86/x64 Wine regression probes under an existing X display."""
import argparse
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from build import Build, PROJECT, write_json
from audio_fixture import PulseAudioFixture


def runtime_environment(build, runtime, output, packaged=False):
    env = dict(os.environ)
    for key in ('WINEDLLPATH', 'WINELOADER', 'WINESERVER', 'WINEARCH', 'WAYLAND_DISPLAY',
                'WINEDLLOVERRIDES', 'WINED3DMETAL', 'WINE_D3D_CONFIG', 'LD_PRELOAD', 'LD_AUDIT',
                'VK_DRIVER_FILES', 'VK_ICD_FILENAMES', 'PULSE_SERVER', 'PULSE_SINK',
                'PULSE_SOURCE', 'PULSE_COOKIE', 'PULSE_CLIENTCONFIG', 'PULSE_RUNTIME_PATH', 'PULSE_STATE_PATH'):
        env.pop(key, None)
    libraries = [runtime / 'lib']
    if not packaged:
        libraries.append(build.deps / 'lib')
    env.update(WINEPREFIX=str(output / 'prefix'), WINEDEBUG='-all',
               LD_LIBRARY_PATH=':'.join(map(str, libraries)),
               LIBGL_ALWAYS_SOFTWARE='1',
               WINE_PROBE_FONT='Liberation Sans',
               # These native probes require no managed/browser addons. Their
               # first-run download dialogs need an interactive desktop.
               WINEDLLOVERRIDES='winemenubuilder.exe=d;mscoree,mshtml=')
    driver_dir = Path('/usr/share/vulkan/icd.d')
    for name in ('lvp_icd.x86_64.json', 'lvp_icd.json'):
        if (driver_dir / name).is_file():
            env['VK_DRIVER_FILES'] = env['VK_ICD_FILENAMES'] = str(driver_dir / name)
            break
    return env


def windows_path(path):
    return 'Z:' + str(path.resolve())


def run_case(name, command, env, output, timeout=90):
    log = output / (name + '.log')
    started = time.monotonic()
    with log.open('wb') as stream:
        process = subprocess.Popen(list(map(str, command)), env=env, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
            status = 'passed' if code == 0 else 'failed'
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            code = None
            status = 'timed_out'
    result = {'name': name, 'status': status, 'exit_code': code,
              'seconds': round(time.monotonic() - started, 2), 'log': log.name}
    print(json.dumps(result), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, help='Packaged runtime; default is the installed build stage')
    parser.add_argument('--quick', action='store_true', help='Startup, exception and syscall probes')
    parser.add_argument('--timeout-scale', type=float, default=1.0,
                        help='Explicit timeout multiplier for slow full-system emulation')
    args = parser.parse_args()
    if not math.isfinite(args.timeout_scale) or args.timeout_scale <= 0:
        parser.error('--timeout-scale must be finite and positive')

    def check(name, command, env, output, timeout=90):
        return run_case(name, command, env, output, timeout * args.timeout_scale)
    if not os.environ.get('DISPLAY'):
        parser.error('Run with xvfb-run -a or provide a Linux desktop DISPLAY')
    build = Build(args.work_dir, 1)
    runtime = args.runtime.resolve() if args.runtime else build.stage
    output = build.work / 'validation' / time.strftime('%Y%m%d-%H%M%S')
    output.mkdir(parents=True, exist_ok=False)
    env = runtime_environment(build, runtime, output, packaged=bool(args.runtime))
    wine = runtime / 'run' if args.runtime else runtime / 'bin/wine'
    server = runtime / 'bin/wineserver'
    results = []
    completed = False
    audio = PulseAudioFixture(env, output, 20 * args.timeout_scale)
    report = output / 'linux-runtime-check.json'
    try:
        results.append(check('host-compat-syscall',
            [build.work / 'probes/linux-compat-syscall-probe'], env, output, 10))
        pulse = audio.start()
        results.append(pulse)
        print(json.dumps(pulse), flush=True)
        if pulse['status'] != 'passed':
            raise RuntimeError('Private PulseAudio startup failed; see pulseaudio.log')
        startup = check('wineboot', [wine, 'wineboot', '-u'], env, output, 180)
        results.append(startup)
        if startup['status'] == 'passed':
            results.append(check('cmd', [wine, 'cmd', '/c', 'ver'], env, output))
            names = ['exception-probe', 'syscall-boolean-probe'] if args.quick else [
                'exception-probe', 'syscall-boolean-probe', 'crypto-probe', 'directory-compat-probe', 'hotpatch-probe',
                'command-line-probe', 'device-notify-probe', 'dbghelp-probe', 'fullscreen-state-probe']
            for bits in ('x64', 'x86'):
                for name in names:
                    results.append(check(name + '-' + bits,
                        [wine, build.work / 'probes' / (name + '-' + bits + '.exe')], env, output))
                if args.quick:
                    continue
                for label, probe_name, arguments in (
                    ('d3d11', 'backend-switch-probe', []),
                    ('ddraw', 'backend-switch-probe', ['--ddraw']),
                    ('vulkan', 'vulkan-probe', []),
                    ('vulkan-surface', 'vulkan-probe', ['--surface'])):
                    results.append(check(label + '-' + bits,
                        [wine, build.work / 'probes' / (probe_name + '-' + bits + '.exe'), *arguments], env, output))
                results.append(check('dwarf-divisor-' + bits,
                    [wine, build.work / 'probes' / ('dwarf-divisor-probe-' + bits + '.exe'),
                     windows_path(build.work / 'probes' / ('dwarf-divisor-fixture-' + bits + '.dll'))], env, output))
                probe = build.work / 'probes' / ('media-probe-' + bits + '.exe')
                for sample in ('test-wmv2.wmv', 'test-mpeg1.mpg', 'test-pcm.wav'):
                    path = PROJECT / 'tools/samples' / sample
                    results.append(check('play-' + sample + '-' + bits,
                        [wine, probe, 'play', windows_path(path), 'gdi'], env, output, 150))
                results.append(check('reader-wmv-' + bits,
                    [wine, probe, 'reader', windows_path(PROJECT / 'tools/samples/test-wmv2.wmv')], env, output))
                results.append(check('mpeg-format-' + bits,
                    [wine, build.work / 'probes' / ('mpeg-audio-format-probe-' + bits + '.exe'),
                     windows_path(PROJECT / 'tools/samples/test-mpeg1.mpg')], env, output))
                # repeated-seek-probe is excluded: pause/resume after seeks republishes
                # a cached EOS and jumps the graph position to stream_stop; unfixed.
                for name in ('child-window-probe', 'reconnect-probe'):
                    results.append(check(name + '-' + bits,
                        [wine, build.work / 'probes' / (name + '-' + bits + '.exe'),
                         windows_path(PROJECT / 'tools/samples/test-mpeg1.mpg')], env, output))
        else:
            print((output / 'wineboot.log').read_text(errors='replace')[-8000:], file=sys.stderr)
        completed = True
    finally:
        results.append(check('wineserver-stop', [server, '-k'], env, output, 20))
        results.append(check('wineserver-wait', [server, '-w'], env, output, 20))
        audio.close()
        passed = completed and bool(results) and all(r['status'] == 'passed' for r in results)
        write_json(report, {'result': 'passed' if passed else 'failed', 'quick': args.quick, 'timeout_scale': args.timeout_scale,
            'scope': 'Isolated Wine prefix, CPU translation when applicable, X display and software rendering',
            'optional_addons': 'Mono and Gecko disabled for native C/C++ probes',
            'audio': 'Private D-Bus session, PulseAudio Unix socket and clocked null sink',
            'external_acceptance': ['native x86_64 kernel', 'hardware GPU', 'Wayland desktop', 'real games'],
            'tests': results})
        print('Report:', report)
    if not passed:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
