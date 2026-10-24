#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Record upstream file notices and mark source files changed by supplied patches."""
import argparse
from datetime import date
import hashlib
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--patch', type=Path, action='append', default=[])
parser.add_argument('--platform', choices=('macos', 'linux'), default='macos')
parser.add_argument('--date', dest='change_date', help='ISO modification date; required for Linux notices')
args = parser.parse_args()
if args.platform == 'linux' and not args.change_date:
    parser.error('--date is required for Linux notices')
change_date = args.change_date or '2026-10-12'
try:
    if date.fromisoformat(change_date).isoformat() != change_date:
        raise ValueError('Expected YYYY-MM-DD')
except ValueError:
    parser.error('--date must be an ISO date')
source = args.source.resolve()
paths = set()
for patch in args.patch:
    text = patch.read_text()
    paths.update(re.findall(r'^\+\+\+ b/(.+)$', text, flags=re.M))
prefixes = ('GE macOS Wine PoC modification notice:', 'GE Wine Linux modification notice:')
marker = (prefixes[1] if args.platform == 'linux' else prefixes[0]) + ' ' + change_date
manifest_name = 'LINUX_MODIFICATIONS.json' if args.platform == 'linux' else 'MODIFICATIONS.json'
records = []
for name in sorted(paths):
    file = source / name
    if not file.resolve().is_relative_to(source):
        raise SystemExit(f'Patch path outside source: {name}')
    if not file.is_file():
        continue
    text = file.read_text()
    header = text[:16000]
    copyrights = [line.strip(' /*') for line in header.splitlines()
                  if ('Copyright' in line or 'copyright' in line) and not any(prefix in line for prefix in prefixes)]
    changes = 'Linux integration and platform adaptations' if args.platform == 'linux' else 'GE media integration and macOS adaptations'
    notice = marker + '; ' + changes + '. Original copyright and license retained. See ' + manifest_name + '.'
    if marker not in text:
        if file.suffix in ('.c', '.h', '.idl', '.rc'):
            prefix = '/* ' + notice + ' */\n'
            if text.split('\n', 1)[0].find('SPDX-License-Identifier:') >= 0:
                first, remaining = text.split('\n', 1)
                text = first + '\n' + prefix + remaining
            else:
                text = prefix + text
        elif file.suffix == '.rgs':
            text = '// ' + notice + '\n' + text
        elif file.name.endswith('.inf.in'):
            text = '; ' + notice + '\n' + text
        elif file.name == 'MAINTAINERS':
            text = notice + '\n\n' + text
        else:
            prefix = '# ' + notice + '\n'
            if text.startswith('#!'):
                first, remaining = text.split('\n', 1)
                text = first + '\n' + prefix + remaining
            else:
                text = prefix + text
        file.write_text(text)
    dates = re.findall(r'(?:GE macOS Wine PoC|GE Wine Linux) modification notice: (\d{4}-\d{2}-\d{2})', text)
    records.append({'file': name, 'modification_date': max([change_date, *dates]),
                    'original_copyright_notices': copyrights,
                    'sha256': hashlib.sha256(file.read_bytes()).hexdigest()})
(source / manifest_name).write_text(json.dumps({
    'project': 'GE Wine Linux integration' if args.platform == 'linux' else 'GE-Proton macOS Wine PoC',
    'date': change_date,
    'scope': 'Files changed by Linux-specific patches' if args.platform == 'linux' else 'Files changed by the supplied GE and macOS patches',
    'licenses': 'Original per-file licenses and upstream LICENSE/COPYING/AUTHORS remain applicable',
    'files': records,
}, indent=2, ensure_ascii=False) + '\n')
print(f'Modification notices recorded: {len(records)} files')
