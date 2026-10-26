#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Apply or verify an ordered Wine patch series, preserving generated notices.

Later patches can replace earlier hunks. Verify a prepared prefix by rolling it
back in reverse order in a temporary file tree, then applying the complete
series forward. The real source is updated only after the whole plan succeeds.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

NOTICE = re.compile(
    r'^(?:/\* |# |// |; )(?:GE macOS Wine PoC|GE Wine Linux) modification notice: .*(?:\*/)?\n?$'
)


def normalize(data):
    lines = data.decode().splitlines(keepends=True)
    notices = [line for line in lines[:8] if NOTICE.match(line)]
    return ''.join(line for index, line in enumerate(lines) if index >= 8 or not NOTICE.match(line)).encode(), notices


def restore_notices(data, notices):
    if not notices:
        return data
    text = data.decode()
    if text.split('\n', 1)[0].find('SPDX-License-Identifier:') >= 0 or text.startswith('#!'):
        first, separator, tail = text.partition('\n')
        return (first + separator + ''.join(notices) + tail).encode()
    return (''.join(notices) + text).encode()


def paths_for(patches):
    paths = set()
    for patch in patches:
        text = patch.read_text()
        paths.update(re.findall(r'^(?:--- a/|\+\+\+ b/)(.+)$', text, re.M))
        for old, new in re.findall(r'^diff --git a/(.+) b/(.+)$', text, re.M):
            paths.update((old, new))
    for name in paths:
        path = Path(name)
        if path.is_absolute() or '..' in path.parts:
            raise ValueError('Patch path escapes source tree: ' + name)
    return sorted(paths)


def apply_patch(tree, patch, reverse=False):
    args = ['git', 'apply']
    if reverse:
        args.append('--reverse')
    return subprocess.run([*args, str(patch)], cwd=tree, capture_output=True, text=True)


def apply_series(source, patches):
    source = source.resolve()
    patches = [patch.resolve() for patch in patches]
    paths = paths_for(patches)
    original, normalized, notices, modes = {}, {}, {}, {}
    for name in paths:
        path = source / name
        if not path.resolve().is_relative_to(source):
            raise ValueError('Source symlink escapes tree: ' + name)
        original[name] = path.read_bytes() if path.is_file() else None
        if original[name] is not None:
            normalized[name], notices[name] = normalize(original[name])
            modes[name] = path.stat().st_mode & 0o777
    patch_inputs = [hashlib.sha256(p.read_bytes()).hexdigest() for p in patches]
    stamp = source / '.ge-patch-series.json'
    expected_files = {name: hashlib.sha256(data).hexdigest() if data is not None else None
                      for name, data in ((name, normalized.get(name)) for name in paths)}
    if stamp.is_file():
        saved = json.loads(stamp.read_text())
        if saved == {'patch_sha256': patch_inputs, 'files': expected_files, 'file_modes': modes}:
            return len(patches), 0
    with tempfile.TemporaryDirectory(prefix='wine-patch-series-') as temporary:
        base = Path(temporary) / 'current'
        base.mkdir()
        for name, data in normalized.items():
            path = base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(modes[name])
        final = None
        previous = 0
        last_error = ''
        # A prepared source contains a prefix; newly appended patches form its
        # tail. Starting with the longest prefix makes normal rebuilds cheap.
        for prefix in range(len(patches), -1, -1):
            candidate = Path(temporary) / ('prefix-' + str(prefix))
            shutil.copytree(base, candidate)
            valid = True
            for patch in reversed(patches[:prefix]):
                result = apply_patch(candidate, patch, reverse=True)
                if result.returncode:
                    last_error = result.stderr
                    valid = False
                    break
            if valid:
                for patch in patches:
                    result = apply_patch(candidate, patch)
                    if result.returncode:
                        last_error = result.stderr
                        valid = False
                        break
            if valid:
                final, previous = candidate, prefix
                break
            shutil.rmtree(candidate)
        if final is None:
            raise ValueError('Source matches no complete prepared prefix; source preserved.\n' + last_error)
        changed = []
        final_hashes, final_modes = {}, {}
        for name in paths:
            candidate = final / name
            data = candidate.read_bytes() if candidate.is_file() else None
            final_hashes[name] = hashlib.sha256(data).hexdigest() if data is not None else None
            if data is not None:
                final_modes[name] = candidate.stat().st_mode & 0o777
            if data != normalized.get(name) or final_modes.get(name) != modes.get(name):
                changed.append((name, restore_notices(data, notices.get(name, [])) if data is not None else None,
                                final_modes.get(name)))
        written = []
        try:
            for name, data, mode in changed:
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                written.append(name)
                if data is None:
                    path.unlink()
                else:
                    path.write_bytes(data)
                    path.chmod(mode)
            stamp.write_text(json.dumps({'patch_sha256': patch_inputs, 'files': final_hashes,
                                         'file_modes': final_modes}, indent=2) + '\n')
        except BaseException:
            for name in reversed(written):
                path = source / name
                if original[name] is None:
                    path.unlink(missing_ok=True)
                else:
                    path.write_bytes(original[name])
                    path.chmod(modes[name])
            raise
        return previous, len(changed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--patch', type=Path, required=True, action='append')
    args = parser.parse_args()
    previous, changed = apply_series(args.source, args.patch)
    print(f'Patch series verified: {previous} prepared entries, {len(args.patch)} total, {changed} changed files')


if __name__ == '__main__':
    main()
