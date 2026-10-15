#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Prepare and audit a privacy-clean copy of an assembled GE Wine runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile

PRIVATE_PREFIX = re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/|/(?:private/)?var/folders/[A-Za-z0-9_/.-]+/')
CREDENTIAL = re.compile(rb'-----BEGIN (?:RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----|\bAKIA[A-Z0-9]{16}\b|\b(?:ghp_|github_pat_)[A-Za-z0-9_]{30,}\b|\bsk-(?:proj-)?[A-Za-z0-9_-]{30,}\b')
MACHO = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')

# Public, deliberately embedded GnuTLS 3.8.13 crypto self-test vectors, NOT
# deployment credentials. Hash the complete PEM including both delimiters,
# excluding only the trailing newline, as compiled from lib/crypto-selftests-pk.c.
# Source SHA-256: 6e596be00754107fd7f7d1f132c2dc8cd0ff12bbdfc6de08c162a1dd5eedc7e8
# https://gitlab.com/gnutls/gnutls/-/blob/3.8.13/lib/crypto-selftests-pk.c
# Never exempt an entire library, arbitrary PEM bodies, or token patterns.
GNUTLS_SELFTEST_PEMS = {
    'd039c8119a029ab9f9c83c04d67002d887b6bc6026c4264402ab27cdf24cf138': 'rsa_2048_privkey',
    '7c4c63ee462e0e700cd9e29c8e0f730b3f1b484c4abdd83f1e69fcd477c061fa': 'dsa_2048_privkey',
    '91ea1699ff6b1a34b4a1d500a9c75a808441e47b9ea68da6fb0195e01ce1dc61': 'ecdsa_secp256r1_privkey',
    '934b3e9bfd9936c5e30c7f0ed7d36a05e2044f755c0aa433e1d6bef6a68d1391': 'ecdsa_secp192r1_privkey',
    'a0b9679665e29ac220dfb0b366317e1b9dd5fe31e9def8b2e511669a041389ae': 'ecdsa_secp224r1_privkey',
    '293216817f0d585f0b54f225582f59e7b2e2a795b5f8002e2d71c5e3d49ce9b0': 'ecdsa_secp384r1_privkey',
    'f8766749b0c6f9b5661364568226af0ba7ae8d87c0073df24e440de4417521cd': 'ecdsa_secp521r1_privkey',
    'ef237ea8db4f2ae9ee100e8ced96d29b5dceb0e6a948443e6b8a00b1791f9ec9': 'gost01_privkey',
    'fa0b06a72461ec0a963dcfccb8d5b61bd88a6074fc7271573bff68ab86b8c1af': 'gost12_256_privkey',
    'a4d138d7ef9748464117b44fb9c0a4b5b85a1599a127d02690abaa96d03c16e6': 'gost12_512_privkey',
    '5a09eb5df3674472eda0077d83cbccef72692c3d052ab393368ac57295439c58': 'eddsa_ed25519_privkey',
    'fed7079dd4491609e4c996e232f366ac434fa4cc9df19df363391d079d470964': 'eddsa_ed448_privkey',
}
PRIVATE_PEM = re.compile(rb'-----BEGIN ((?:RSA |DSA |EC |OPENSSH )?PRIVATE KEY)-----'
                         rb'[^\x00]*?-----END \1-----')


def credential_findings(data, relative_path):
    """Scan raw and UTF-16-like views, masking only reviewed public vectors."""
    reviewed = 0

    def mask_public_vector(match):
        nonlocal reviewed
        if hashlib.sha256(match.group()).hexdigest() in GNUTLS_SELFTEST_PEMS:
            reviewed += 1
            return b'_' * len(match.group())
        return match.group()

    scan = data
    if str(relative_path) == 'Wine/lib/libgnutls.30.dylib' and data[:4] in MACHO:
        scan = PRIVATE_PEM.sub(mask_public_vector, data)
    return any(CREDENTIAL.search(view) for view in (scan, scan.replace(b'\x00', b''))), reviewed


def public_prefix(match):
    # Fixed-size substitution preserves offsets in compiled diagnostic strings.
    count = len(match.group())
    return b'/build/' + b'_' * (count - 8) + b'/'


def private_identifier(data, account, hosted_ci=False):
    # The hosted runner account is public infrastructure; ordinary Wine symbols
    # such as queue_runner and upstream CI comments legitimately contain it.
    personal_name = not (hosted_ci and account == 'runner') and account.encode() in data
    return bool(PRIVATE_PREFIX.search(data)) or personal_name


def safe_header(member):
    member.uid = member.gid = 0
    member.uname = member.gname = ''
    member.mtime = 0
    member.pax_headers = {}
    return member


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True, help='Assembled Libraries directory')
    parser.add_argument('--output', type=Path, required=True, help='Fresh release directory')
    parser.add_argument('--objcopy', type=Path, required=True, help='LLVM objcopy executable')
    parser.add_argument('--private-name', required=True, help='Local account name to detect; stays in local audit only')
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists():
        parser.error('output already exists')
    out.mkdir(parents=True)
    root = out / 'Libraries'
    shutil.copytree(args.input, root, symlinks=True)
    # Headers, import archives and pkg-config files are development-only payloads.
    for directory in (root / 'Wine/include', root / 'Wine/lib/pkgconfig'):
        if directory.exists():
            shutil.rmtree(directory)
    for file in root.rglob('*.a'):
        file.unlink()
    stripped = rewritten = checked = reviewed_vectors = 0
    forbidden = {'system.reg', 'user.reg', 'userdef.reg', 'BottleVM.plist', 'Metadata.plist', '.DS_Store', '.git'}
    for file in sorted(root.rglob('*')):
        if file.name == '.DS_Store':
            file.unlink()
            continue
        if file.name in forbidden:
            raise RuntimeError(f'Unexpected private-state file: {file.relative_to(root)}')
        if file.is_symlink():
            target = file.resolve()
            if root not in target.parents or not target.exists():
                raise RuntimeError(f'Nonportable symlink: {file.relative_to(root)}')
            continue
        if not file.is_file():
            continue
        data = file.read_bytes()
        macho = data[:4] in MACHO
        pe = data[:2] == b'MZ' and file.suffix.lower() in {'.dll', '.exe', '.sys', '.cpl', '.drv', '.ocx', '.acm'}
        if pe:
            marker = data[64:80]
            subprocess.run([str(args.objcopy), '--strip-debug', str(file)], check=True, capture_output=True)
            data = file.read_bytes()
            if marker == b'Wine builtin DLL' and data[64:80] != marker:
                raise RuntimeError(f'Builtin marker changed: {file.relative_to(root)}')
            stripped += 1
        elif macho:
            subprocess.run(['/usr/bin/strip', '-S', str(file)], check=True, capture_output=True)
            data = file.read_bytes()
            stripped += 1
        cleaned = PRIVATE_PREFIX.sub(public_prefix, data)
        # PE diagnostic strings can also carry UTF-16LE source paths.
        if b'/\x00U\x00s\x00e\x00r\x00s\x00/' in cleaned or b'/\x00h\x00o\x00m\x00e\x00/' in cleaned:
            wide = re.compile(rb'(?:[^\x00]\x00){1,2048}')
            cleaned = wide.sub(lambda m: PRIVATE_PREFIX.sub(public_prefix, m.group()[::2])
                               .decode('latin1').encode('utf-16le'), cleaned)
        if cleaned != data:
            file.write_bytes(cleaned)
            rewritten += 1
        if macho:
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(file)], check=True, capture_output=True)
            subprocess.run(['/usr/bin/codesign', '--verify', str(file)], check=True, capture_output=True)
        # Audit the final bytes, including newly produced signatures.
        data = file.read_bytes()
        flattened = data.replace(b'\x00', b'')
        for view in (data, flattened):
            if private_identifier(view, args.private_name, os.environ.get('GITHUB_ACTIONS') == 'true'):
                raise RuntimeError(f'Private identifier remains: {file.relative_to(root)}')
        finding, reviewed = credential_findings(data, file.relative_to(root))
        reviewed_vectors += reviewed
        if finding:
            raise RuntimeError(f'Credential pattern requires review: {file.relative_to(root)}')
        checked += 1
    print(f'Audited {checked} files; stripped {stripped}; remapped {rewritten}', flush=True)
    archive = out / 'Libraries.tar.gz'
    with tarfile.open(archive, 'w:gz', compresslevel=6) as tf:
        tf.add(root, arcname='Libraries', filter=safe_header)
    hasher = hashlib.sha256()
    with archive.open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            hasher.update(block)
    info = plistlib.loads((root / 'WhiskyWineVersion.plist').read_bytes())
    info['sha256'] = hasher.hexdigest()
    metadata = out / 'WhiskyWineVersion.plist'
    metadata.write_bytes(plistlib.dumps(info))
    for view in (metadata.read_bytes(), metadata.read_bytes().replace(b'\x00', b'')):
        assert not PRIVATE_PREFIX.search(view) and not CREDENTIAL.search(view)
    with tarfile.open(archive) as tf:
        headers = list(tf)
        assert all(m.uid == m.gid == 0 and m.uname == m.gname == '' and not m.pax_headers for m in headers)
        assert all(m.name == 'Libraries' or m.name.startswith('Libraries/') for m in headers)
    report = {'result': 'passed', 'files_checked': checked, 'debug_stripped': stripped,
              'files_with_build_path_remapping': rewritten, 'archive_entries': len(headers),
              'archive_owner_fields': 'anonymous', 'private_paths': 0, 'local_account_names': 0,
              'credential_pattern_findings': 0, 'user_prefix_or_bottle_state': 0,
              'reviewed_gnutls_public_selftest_vectors': reviewed_vectors,
              'sha256': info['sha256'],
              'scope': 'Entire payload and tar headers; ASCII/UTF-16 private paths, local account name and common credential patterns'}
    (out / 'privacy-audit.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2), flush=True)


if __name__ == '__main__':
    main()
