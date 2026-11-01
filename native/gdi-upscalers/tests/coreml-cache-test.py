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
import socket
import struct
import subprocess
import sys
import tempfile

SIZE = 288 + 4 * 1024 * 1024 * 20


def exercise(helper, resources, enabled, width, height):
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
            env.pop('WINE_GDI_COREML_DISABLE_TILE_CACHE', None)
            if not enabled:
                env['WINE_GDI_COREML_DISABLE_TILE_CACHE'] = '1'
            process = subprocess.Popen([helper, '--serve', resources], preexec_fn=setup,
                                       close_fds=False, env=env, stderr=log)
            os.close(fd)
            os.close(peer)
            server.close()
            client.settimeout(60)
            try:
                # Sparse changes, identical repeats, revert, geometry change.
                for seq, (w, h, change) in enumerate([
                    (width, height, None), (width, height, None),
                    (width, height, (width//2, height//2)),
                    (width, height, (width//2, height//2)),
                    (width, height, (min(265, width-1), 0)),
                    (width, height, (0, 0)), (width, height, None),
                    (width-2, height-2, None), (width-2, height-2, None),
                ], 1):
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
    assert len(counts) == 9, trace
    return results, times, counts


def main():
    helper, resources = [str(Path(p).resolve()) for p in sys.argv[1:3]]
    width, height = map(int, sys.argv[3:5]) if len(sys.argv) > 3 else (257, 193)
    cached, times, counts = exercise(helper, resources, True, width, height)
    reference, _, baseline = exercise(helper, resources, False, width, height)
    assert cached == reference, 'cached output differs from full tiled inference'
    assert counts[0][0] > 1 and counts[0][1] == 0
    for index in (1, 3, 8):
        assert counts[index][0] == 0 and counts[index][1] > 1, counts
    assert counts[2][0] > 0 and counts[2][1] > 0, counts
    assert counts[7][1] == 0, counts
    assert all(reused == 0 for _, reused in baseline)
    for index, ((inferred, reused), ms) in enumerate(zip(counts, times), 1):
        print(f'frame {index}: inferred={inferred} reused={reused} {ms:.2f} ms')
    print('All cached outputs match full tiled inference byte for byte.')


if __name__ == '__main__':
    main()
