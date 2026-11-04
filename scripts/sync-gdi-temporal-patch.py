#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Regenerate canonical GDI presentation files inside the maintained Wine patch."""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'native/gdi-upscalers'
FILES = {
    'cocoa_upscaler.h': NATIVE / 'presentation/cocoa_upscaler.h',
    'cocoa_upscaler.m': NATIVE / 'presentation/cocoa_upscaler.m',
    'cocoa_region_picker.h': NATIVE / 'presentation/cocoa_region_picker.h',
    'wine_gdi_exclusions.h': NATIVE / 'include/wine_gdi_exclusions.h',
    'wine_gdi_temporal_presenter.h': NATIVE / 'include/wine_gdi_temporal_presenter.h',
    'wine_gdi_upscaler.h': NATIVE / 'include/wine_gdi_upscaler.h',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--source-tree', type=Path, help='Also refresh these generated files in an existing Wine source tree')
    args = parser.parse_args()
    groups = [('macos-gdi-upscalers.patch', FILES),
              ('macos-wined3d-temporal.patch', {'cocoa_gl_temporal.h': NATIVE / 'presentation/cocoa_gl_temporal.h'})]
    for patch_name, files in groups:
        sync_patch(ROOT / 'patches/wine-ge' / patch_name, files, args, parser)


def sync_patch(patch, files, args, parser):
    original = patch.read_text()
    updated = original
    for name, source in files.items():
        content = source.read_text()
        marker = f'diff --git a/dlls/winemac.drv/{name} b/dlls/winemac.drv/{name}\n'
        section = (marker + 'new file mode 100644\n--- /dev/null\n' +
                   f'+++ b/dlls/winemac.drv/{name}\n@@ -0,0 +1,{len(content.splitlines())} @@\n' +
                   ''.join('+' + line + '\n' for line in content.splitlines()))
        if marker in updated:
            start = updated.index(marker)
            end = updated.find('diff --git ', start + len(marker))
            if end < 0:
                end = len(updated)
            updated = updated[:start] + section + updated[end:]
        else:
            updated += '\n' + section
        if args.source_tree and not args.check:
            target = args.source_tree.resolve() / 'dlls/winemac.drv' / name
            if not target.parent.is_dir():
                parser.error('Expected an existing Wine source tree')
            old = target.read_text() if target.exists() else ''
            notice = old.split('\n', 1)[0] + '\n' if old.startswith('/* GE macOS Wine PoC modification notice:') else ''
            target.write_text(notice + content)
    if args.check:
        if original != updated:
            raise SystemExit('GDI presentation patch requires regeneration')
    else:
        patch.write_text(updated)


if __name__ == '__main__':
    main()
