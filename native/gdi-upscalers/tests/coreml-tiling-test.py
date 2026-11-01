#!/usr/bin/env python3
"""Exercise the real helper protocol with a compiled fixed-size model bundle.
Usage: python3 coreml-tiling-test.py HELPER RESOURCES [WxH ...]
Select a small model bundle for fast regression runs.
"""
import mmap
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile

HEADER = 288
SIZE = HEADER + 4 * 1024 * 1024 * 20


def main():
    helper, resources = map(lambda s: str(Path(s).resolve()), sys.argv[1:3])
    sizes = [tuple(map(int, size.split('x'))) for size in sys.argv[3:]]
    sizes = sizes or [(1, 1), (65, 49), (129, 97), (65, 49)]
    with tempfile.TemporaryFile() as shared:
        shared.truncate(SIZE)
        with mmap.mmap(shared.fileno(), SIZE) as frame:
            client, server = socket.socketpair()
            # Preserve source descriptors while assigning the helper's ABI slots.
            shared_fd = os.dup(shared.fileno())
            server_fd = os.dup(server.fileno())
            def setup():
                os.dup2(shared_fd, 3)
                os.dup2(server_fd, 4)
            process = subprocess.Popen([helper, '--serve', resources],
                                       close_fds=False, preexec_fn=setup)
            os.close(shared_fd)
            os.close(server_fd)
            server.close()
            client.settimeout(60)
            sequence = 0
            try:
                for width, height in sizes:
                    previous = None
                    for repeat in range(2):
                        sequence += 1
                        struct.pack_into('=6IQ', frame, 0, 0x5747434D, 1,
                                         sequence, width, height, 1, 0)
                        pixels = bytes((80, 120, 160, 255)) * (width * height)
                        frame[HEADER:HEADER + len(pixels)] = pixels
                        client.sendall(b'R')
                        assert client.recv(1) == b'D', 'helper disconnected'
                        status = struct.unpack_from('=I', frame, 20)[0]
                        error = frame[32:288].split(b'\0')[0].decode()
                        assert status == 0, error
                        start = HEADER + len(pixels)
                        result = frame[start:start + width * height * 16]
                        assert all(value == 255 for value in result[3::4]), 'uncovered pixel'
                        for channel in range(3):
                            values = result[channel::4]
                            assert max(values) - min(values) <= 3, 'constant frame seam/padding artifact'
                        if previous is not None:
                            assert result == previous, 'cached buffer changed output'
                        previous = result
                        milliseconds = struct.unpack_from('=Q', frame, 24)[0] / 1e6
                        print(f'{width}x{height} pass {repeat + 1}: {milliseconds:.2f} ms', flush=True)
            finally:
                client.close()
                process.wait(timeout=10)
            assert process.returncode == 0


if __name__ == '__main__':
    main()
