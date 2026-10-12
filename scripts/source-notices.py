#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Record upstream file notices and mark source files changed by supplied patches."""
import argparse
import hashlib
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--patch', type=Path, action='append', default=[])
args = parser.parse_args()
source = args.source.resolve()
paths = set()
for patch in args.patch:
    text = patch.read_text()
    paths.update(re.findall(r'^\+\+\+ b/(.+)$', text, flags=re.M))
marker = 'GE macOS Wine PoC modification notice: 2026-10-12'
records = []
for name in sorted(paths):
    file = source / name
    if not file.resolve().is_relative_to(source):
        raise SystemExit(f'Patch path outside source: {name}')
    if not file.is_file():
        continue
    text = file.read_text()
    header = text[:16000]
    copyrights = [line.strip(' /*') for line in header.splitlines() if ('Copyright' in line or 'copyright' in line) and marker not in line]
    notice = marker + '; GE media integration and macOS adaptations. Original copyright and license retained. See MODIFICATIONS.json.'
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
    records.append({'file': name, 'modification_date': '2026-10-12',
                    'original_copyright_notices': copyrights,
                    'sha256': hashlib.sha256(file.read_bytes()).hexdigest()})
(source / 'MODIFICATIONS.json').write_text(json.dumps({
    'project': 'GE-Proton macOS Wine PoC',
    'date': '2026-10-12',
    'scope': 'Files changed by the supplied GE and macOS patches',
    'licenses': 'Original per-file licenses and upstream LICENSE/COPYING/AUTHORS remain applicable',
    'files': records,
}, indent=2, ensure_ascii=False) + '\n')
print(f'Modification notices recorded: {len(records)} files')
