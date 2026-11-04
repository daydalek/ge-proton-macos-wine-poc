#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Compare cached and uncached tiled inference with real Core ML predictions.
Usage: coreml-cache-test.py HELPER RESOURCES [WIDTH HEIGHT]
"""
import hashlib
import mmap
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile

SIZE = 288 + 4 * 1024 * 1024 * 20
SCENES = [
    None, None, 'middle', 'middle', 'edge', 'corner', None,
    'smaller', 'smaller', None, None,
]


def scene(frames, width, height, index):
    spec = frames[index]
    if spec == 'smaller':
        return width - 2, height - 2, None
    change = {
        'middle': (width // 2, height // 2),
        'edge': (min(265, width - 1), 0),
        'corner': (0, 0),
    }.get(spec)
    return width, height, change


def exercise(helper, resources, enabled, width, height, family='realcugan',
             frames=None, env_extra=None):
    frames = frames if frames is not None else SCENES
    results, times = [], []
    with tempfile.TemporaryFile() as shared, tempfile.TemporaryFile() as log:
        shared.truncate(SIZE)
        with mmap.mmap(shared.fileno(), SIZE) as frame:
            client, server = socket.socketpair()
            fd, peer = os.dup(shared.fileno()), os.dup(server.fileno())
            def setup():
                os.dup2(fd, 3)
                os.dup2(peer, 4)
            env = dict(os.environ, WINE_GDI_COREML_TRACE='1')
            env.pop('WINE_GDI_CACHE_MODE', None)
            env.pop('WINE_GDI_CACHE_DIRECTORY', None)
            env.pop('WINE_GDI_COREML_DISABLE_TILE_CACHE', None)
            if not enabled:
                env['WINE_GDI_COREML_DISABLE_TILE_CACHE'] = '1'
            if env_extra:
                env.update(env_extra)
            process = subprocess.Popen([helper, '--serve', resources, family], preexec_fn=setup,
                                       close_fds=False, env=env, stderr=log)
            os.close(fd)
            os.close(peer)
            server.close()
            client.settimeout(60)
            try:
                # Sparse changes, identical repeats, revert, geometry change.
                for seq in range(1, len(frames) + 1):
                    w, h, change = scene(frames, width, height, seq - 1)
                    pixels = bytearray(value for y in range(h) for x in range(w)
                                       for value in ((x*7+y*3)%256, (x+y*11)%256, (x*13+y)%256, 255))
                    if change:
                        index = (change[1]*w+change[0])*4
                        pixels[index:index+3] = bytes((255, 0, 255))
                    struct.pack_into('=6IQ', frame, 0, 0x5747434D, 1, seq, w, h, 1, 0)
                    frame[288:288+len(pixels)] = pixels
                    client.sendall(b'R')
                    assert client.recv(1) == b'D'
                    assert struct.unpack_from('=I', frame, 20)[0] == 0, frame[32:288]
                    start = 288+len(pixels)
                    results.append(hashlib.sha256(frame[start:start+w*h*16]).hexdigest())
                    times.append(struct.unpack_from('=Q', frame, 24)[0]/1e6)
            finally:
                client.close()
                process.wait(timeout=10)
            assert process.returncode == 0
        log.seek(0)
        trace = log.read().decode()
    counts = [tuple(map(int, match)) for match in re.findall(r'inferred=(\d+) reused=(\d+)', trace)]
    assert len(counts) == len(frames), trace
    return results, times, counts


def persistent_env(directory):
    return {
        'WINE_GDI_CACHE_MODE': 'persistent',
        'WINE_GDI_CACHE_DIRECTORY': str(directory),
        'WINEPREFIX': '/tmp/wgdi-cache-test-prefix',
        'WINE_GDI_CACHE_GAME': '/tmp/wgdi-cache-test-prefix/drive_c/game.exe',
    }


def persistence_check(helper, resources, width, height, family, frames, label):
    with tempfile.TemporaryDirectory() as store:
        env = persistent_env(store)
        cold, _, cold_counts = exercise(helper, resources, True, width, height, family, frames, env)
        entries = sorted(Path(store).rglob('*.bin'))
        assert cold_counts[0][0] > 0, cold_counts
        assert cold_counts[-1][0] == 0, cold_counts
        assert entries, 'persistent mode wrote no records'
        for record in entries:
            assert oct(record.stat().st_mode & 0o777) == '0o600', record
        reference, _, _ = exercise(helper, resources, False, width, height, family, frames, env)
        warm, _, warm_counts = exercise(helper, resources, True, width, height, family, frames, env)
        assert warm == cold == reference, 'persistent output differs from uncached reference'
        assert all(inferred == 0 for inferred, _ in warm_counts), warm_counts
        for index, counts in enumerate(warm_counts):
            print(f'persistent {label} frame {index+1}: inferred={counts[0]} reused={counts[1]}')
        print(f'persistent {label}: fresh helper served {len(warm)} frames from disk '
              f'({len(entries)} records, 0600), byte-identical to uncached output')


def family_test(helper, resources, family, width, height):
    cached, times, counts = exercise(helper, resources, True, width, height, family)
    reference, _, baseline = exercise(helper, resources, False, width, height, family)
    assert cached == reference, 'cached output differs from full tiled inference'
    assert counts[0][0] > 1 and counts[0][1] == 0
    for index in (1, 3, 10):
        assert counts[index][0] == 0 and counts[index][1] > 1, counts
    assert counts[2][0] > 0, counts
    assert counts[6][0] == 0 and counts[6][1] > 0, counts
    assert counts[7][0] > 0, counts
    assert counts[9][0] == 0 and counts[9][1] > 0, counts
    assert all(reused == 0 for _, reused in baseline)
    for index, ((inferred, reused), ms) in enumerate(zip(counts, times), 1):
        print(f'{family} frame {index}: inferred={inferred} reused={reused} {ms:.2f} ms')
    print(f'{family}: all cached outputs match full tiled inference byte for byte.')
    persistence_check(helper, resources, width, height, family, [None, 'middle', None], family)


def exact_frame_test(helper, source_resources, family, width, height):
    with tempfile.TemporaryDirectory() as isolated:
        bundle = Path(source_resources) / 'coreml' / f'{family}-{width}x{height}.mlmodelc'
        target = Path(isolated) / 'coreml'
        target.mkdir()
        shutil.copytree(bundle, target / bundle.name)
        frames = [None, None]
        cold, _, cold_counts = exercise(helper, isolated, True, width, height, family, frames)
        assert cold_counts[0] == (1, 0) and cold_counts[1] == (0, 1), cold_counts
        with tempfile.TemporaryDirectory() as store:
            env = persistent_env(store)
            exercise(helper, isolated, True, width, height, family, frames, env)
            reference, _, _ = exercise(helper, isolated, False, width, height, family, frames, env)
            warm, _, warm_counts = exercise(helper, isolated, True, width, height, family, frames, env)
            assert warm == cold == reference, 'exact-frame store output differs from uncached'
            assert all(inferred == 0 for inferred, _ in warm_counts), warm_counts
        print(f'{family} exact {width}x{height}: repeated frame served from the content store, '
              'again after a helper restart, byte-identical to uncached output')


def main():
    helper, resources = [str(Path(p).resolve()) for p in sys.argv[1:3]]
    width, height = map(int, sys.argv[3:5]) if len(sys.argv) > 3 else (257, 193)
    bundles = sorted(p for p in (Path(resources) / 'coreml').iterdir() if p.suffix == '.mlmodelc')
    if not bundles:
        sys.exit(f'no .mlmodelc bundles under {resources}/coreml')
    models = {p.name.split('-')[0] for p in bundles}
    tested = False
    if 'realcugan' in models:
        family_test(helper, resources, 'realcugan', width, height)
        tested = True
    else:
        print('realcugan models not present; tiled realcugan checks skipped')
    if 'animevideov3' in models:
        family_test(helper, resources, 'animevideov3', width, height)
        tested = True
    else:
        print('animevideov3 models not present; tiled animevideov3 checks skipped')
    for p in bundles:
        family, _, dims = p.stem.partition('-')
        w, _, h = dims.partition('x')
        if w.isdigit() and h.isdigit() and (int(w) & 1 or int(h) & 1):
            exact_frame_test(helper, resources, family, int(w), int(h))
            tested = True
    if not tested:
        sys.exit('no supported model family found; nothing was verified')


if __name__ == '__main__':
    main()
