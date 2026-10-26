#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Repair one known translation DLL's cache-reload reference count.

Writes a new file; the caller controls backup and installation. The complete
input and output hashes constrain the repair to the verified binary version.
"""
import argparse
import hashlib
from pathlib import Path
import struct

ORIGINAL_SHA256 = "699e1c51f74b46a8f34397203a4da0318808fcd7393815abda7f570ffc046648"
PATCHED_SHA256 = "5b5677650f304c49338b2b54afe6af5a4f050959bf81b14a67d43d70f614fcab"


def repair(data):
    if hashlib.sha256(data).hexdigest() != ORIGINAL_SHA256:
        raise ValueError("Unsupported input: original Game.dll SHA-256 required")
    result = bytearray(data)
    site, cave = 0x5e2d, 0x25f00
    if result[site:site + 8] != bytes.fromhex("3b de 89 5c 24 10 75 35"):
        raise ValueError("Unexpected reload instructions")
    if result[cave:cave + 32] != bytes(32):
        raise ValueError("Expected unused executable-section padding")

    # Preserve descriptor lookup and its stack local. A new descriptor follows
    # the original allocation path; a reused descriptor acquires its reference
    # through the same InterlockedIncrement helper as the allocation path.
    stub = bytearray.fromhex("3b de 89 5c 24 10")
    stub += b"\x0f\x84" + struct.pack("<i", 0x5e35 - (cave + len(stub) + 6))
    stub += bytes.fromhex("8b cb")
    stub += b"\xe8" + struct.pack("<i", 0x33f0 - (cave + len(stub) + 5))
    stub += b"\xe9" + struct.pack("<i", 0x5e6a - (cave + len(stub) + 5))
    result[site:site + 8] = b"\xe9" + struct.pack("<i", cave - site - 5) + b"\x90" * 3
    result[cave:cave + len(stub)] = stub

    pe = struct.unpack_from("<I", result, 60)[0]
    section = pe + 24 + struct.unpack_from("<H", result, pe + 20)[0]
    if result[section:section + 8] != b".text\0\0\0":
        raise ValueError("Unexpected PE section layout")
    virtual_size, rva, raw_size, raw_offset = struct.unpack_from("<IIII", result, section + 8)
    if rva != 0x1000 or raw_offset != rva or cave + len(stub) > raw_offset + raw_size:
        raise ValueError("Unexpected .text mapping")
    struct.pack_into("<I", result, section + 8, max(virtual_size, cave + len(stub) - rva))
    if hashlib.sha256(result).hexdigest() != PATCHED_SHA256:
        raise ValueError("Patched output hash differs from the verified repair")
    return bytes(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="original, matching Game.dll")
    parser.add_argument("output", type=Path, help="new output file, created exclusively")
    args = parser.parse_args()
    try:
        patched = repair(args.input.read_bytes())
        with args.output.open("xb") as output:
            output.write(patched)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")
    print(f"{PATCHED_SHA256}  {args.output}")


if __name__ == "__main__":
    main()
