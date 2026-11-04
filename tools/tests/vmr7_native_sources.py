# SPDX-License-Identifier: LGPL-2.1-or-later
"""Extract production code from the maintained CrossOver patch files.

The patches are unified diffs that may lack 'diff --git' lines; each file
section is a '--- a/path' or '--- /dev/null' header followed by '+++ b/path'
and one or more '@@' hunks.  Headless tests read the reviewed production
code from these patches instead of any local source checkout, so they run
in a clean tree with no work/ directory.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NATIVE_PATCH = ROOT / 'patches/crossover/quartz-vmr7-native-presentation.patch'
WINEDMO_SEEK_PATCH = ROOT / 'patches/crossover/winedmo-seek-read-flushing.patch'

_HEADER = re.compile(r'^--- (a/\S+|/dev/null)[^\n]*\n\+\+\+ b/(\S+)[^\n]*\n', re.M)


def _sections(patch):
    """Map 'b/path' -> {'new': bool, 'body': hunk text} for a patch file."""
    text = Path(patch).read_text()
    matches = list(_HEADER.finditer(text))
    out = {}
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        out[m.group(2)] = {'new': m.group(1) == '/dev/null',
                           'body': text[m.end():end]}
    return out


def new_file(path_key, patch=NATIVE_PATCH):
    """Full text of a file added by the patch (all '+' payload lines)."""
    body = _sections(patch)[path_key]['body']
    return ''.join(l[1:] + '\n' for l in body.splitlines() if l[:1] == '+')


def added_text(path_key, patch=NATIVE_PATCH):
    """New-side text of a modified file: context + added lines in order.

    Suitable for extracting functions that are entirely new in the patch.
    """
    body = _sections(patch)[path_key]['body']
    return ''.join(l[1:] + '\n' for l in body.splitlines() if l[:1] in (' ', '+'))


def added_lines(path_key, patch=NATIVE_PATCH):
    body = _sections(patch)[path_key]['body']
    return [l[1:] for l in body.splitlines() if l[:1] == '+']


def flush_guard_condition(path_key, patch=WINEDMO_SEEK_PATCH):
    """The verbatim new flush/abort branch condition added by the seek patch,
    e.g. 'if (source->demux_thread_shutdown || (source->read_flushing &&
    GetCurrentThreadId() == source->demux_thread_id))'."""
    lines = added_lines(path_key, patch)
    for i, line in enumerate(lines):
        if 'read_flushing' not in line or 'demux_thread_id' not in line:
            continue
        start = i
        while start > 0 and 'if (' not in lines[start]:
            start -= 1
        cond = ' '.join(lines[k].strip() for k in range(start, i + 1))
        if not cond.rstrip().endswith(')'):
            # continue collecting until the condition closes
            k = i + 1
            while k < len(lines):
                cond += ' ' + lines[k].strip()
                k += 1
                if cond.rstrip().endswith(')'):
                    break
        return cond
    raise ValueError('flush guard not found in ' + path_key)
