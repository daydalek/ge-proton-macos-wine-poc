#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Regions (version-2) requests against the real Core ML helper: selected tile
output must be byte-identical to a full version-1 frame, unselected output
must stay untouched, malformed masks must fail without killing the helper.
Usage: coreml-regions-test.py HELPER RESOURCES
"""
import mmap
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import tempfile

OLD = 288 + 4 * 1024 * 1024 * 20
EXT = OLD + 32
W, H = 800, 600
COLS, ROWS = (W + 255) // 256, (H + 255) // 256


def pixels():
    return bytearray(v for y in range(H) for x in range(W)
                     for v in ((x * 7 + y * 3) % 256, (x + y * 11) % 256,
                               (x * 13 + y) % 256, 255))


def serve(helper, resources, family, size):
    shared = tempfile.TemporaryFile()
    shared.truncate(size)
    frame = mmap.mmap(shared.fileno(), size)
    log = tempfile.TemporaryFile()
    client, server = socket.socketpair()
    fd, peer = os.dup(shared.fileno()), os.dup(server.fileno())
    def setup():
        os.dup2(fd, 3)
        os.dup2(peer, 4)
    env = dict(os.environ, WINE_GDI_COREML_TRACE='1')
    env.pop('WINE_GDI_CACHE_MODE', None)
    env.pop('WINE_GDI_CACHE_DIRECTORY', None)
    env.pop('WINE_GDI_COREML_DISABLE_TILE_CACHE', None)
    process = subprocess.Popen([helper, '--serve', resources, family],
                               preexec_fn=setup, close_fds=False, env=env, stderr=log)
    os.close(fd)
    os.close(peer)
    server.close()
    client.settimeout(120)
    return shared, frame, log, client, process


def issue(frame, client, seq, version, bitset=None):
    frame[288:288 + W * H * 4] = pixels()
    out = 288 + W * H * 4
    frame[out:out + W * H * 16] = bytes([0xa5]) * (W * H * 16)
    struct.pack_into('=6IQ', frame, 0, 0x5747434D, version, seq, W, H, 1, 0)
    if bitset is not None:
        frame[OLD:OLD + 32] = bitset
    client.sendall(b'R')
    assert client.recv(1) == b'D', 'helper disconnected'
    status = struct.unpack_from('=I', frame, 20)[0]
    return status, bytes(frame[out:out + W * H * 16])


def mask(tiles):
    words = [0] * 8
    for i in tiles:
        words[i // 32] |= 1 << (i % 32)
    return struct.pack('=8I', *words)


def compare(part, full, tiles, label):
    for ty in range(ROWS):
        for tx in range(COLS):
            index = ty * COLS + tx
            for y in range(ty * 512, min(ty * 512 + 512, H * 2)):
                x0, x1 = tx * 512, min(tx * 512 + 512, W * 2)
                a = (y * W * 2 + x0) * 4
                b = a + (x1 - x0) * 4
                if index in tiles:
                    assert part[a:b] == full[a:b], f'{label} tile {index} differs'
                else:
                    assert part[a:b] == bytes([0xa5]) * (x1 - x0) * 4, \
                        f'{label} unselected tile {index} was written'


def counts(trace):
    return [tuple(map(int, m)) for m in
            re.findall(r'inferred=(\d+) reused=(\d+) stored=\d+ served=(\d+)', trace)]


def family_test(helper, resources, family):
    shared, frame, log, client, process = serve(helper, resources, family, EXT)
    try:
        status, full = issue(frame, client, 1, 1)
        assert status == 0, 'v1 reference frame failed'
        status, single = issue(frame, client, 2, 2, mask({0}))
        assert status == 0, 'v2 single-tile request failed'
        compare(single, full, {0}, f'{family} single')
        status, multi = issue(frame, client, 3, 2, mask({5, 11}))
        assert status == 0, 'v2 multi-tile request failed'
        compare(multi, full, {5, 11}, f'{family} multi')
        status, _ = issue(frame, client, 4, 2, mask({COLS * ROWS + 9}))
        assert status != 0, 'out-of-grid mask accepted'
        status, after = issue(frame, client, 5, 2, mask({3}))
        assert status == 0, 'helper did not recover after a bad mask'
        compare(after, full, {3}, f'{family} recovery')
        status, _ = issue(frame, client, 6, 2, bytes(32))
        assert status != 0, 'empty mask accepted'
        status, again = issue(frame, client, 7, 2, mask({6}))
        assert status == 0, 'helper did not recover after an empty mask'
        compare(again, full, {6}, f'{family} second recovery')
    finally:
        client.close()
        process.wait(timeout=10)
    assert process.returncode == 0, process.returncode
    log.seek(0)
    runs = counts(log.read().decode())
    assert len(runs) == 5, runs
    for run in runs:
        assert run[0] + run[1] == run[2], run
    full_windows = runs[0][2]
    assert runs[0][0] > 0 and full_windows > 4, runs
    for index in (1, 2, 3, 4):
        assert runs[index][2] < full_windows, \
            f'{family}: served {runs[index][2]} windows, full {full_windows}'
    print(f'{family}: v2 selected output byte-identical to v1, '
          f'1/2-tile frames served fewer windows than {full_windows}-window full frame, '
          'bad masks rejected and helper recovered on the same connection')


def legacy_test(helper, resources, family):
    shared, frame, log, client, process = serve(helper, resources, family, OLD)
    try:
        status, _ = issue(frame, client, 1, 1)
        assert status == 0, 'v1 request on legacy mapping failed'
    finally:
        client.close()
        process.wait(timeout=10)
    assert process.returncode == 0, process.returncode
    print(f'{family}: v1 request on the original mapping still works')


def main():
    helper, resources = [str(Path(p).resolve()) for p in sys.argv[1:3]]
    bundles = sorted(p for p in (Path(resources) / 'coreml').iterdir()
                     if p.suffix == '.mlmodelc' and '256x256' in p.name)
    families = sorted({p.name.split('-')[0] for p in bundles})
    if not families:
        sys.exit(f'no tiled .mlmodelc bundles under {resources}/coreml')
    for family in families:
        family_test(helper, resources, family)
        legacy_test(helper, resources, family)


if __name__ == '__main__':
    main()
