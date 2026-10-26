#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Build a signed arm64 helper and fixed-resolution Real-CUGAN Core ML models.

Run with an arm64 Python environment containing requirements-coreml.txt.
The output directory is fresh; the ordinary upscalers builder incorporates it
with --coreml-python. End users receive compiled models with their runtime.
"""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'native/gdi-upscalers'
DEFAULT_SIZES = ('640x480', '800x600', '1024x768', '1280x720', '1920x1080')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-dir', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--size', action='append', help='Exact source WxH; repeat for additional models')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('Use native arm64 Python on macOS')
    versions = {name: importlib.metadata.version(name) for name in ('numpy', 'coremltools')}
    if versions != {'numpy': '1.26.4', 'coremltools': '8.3.0'}:
        parser.error('Install scripts/requirements-coreml.txt in an isolated arm64 environment')
    sizes = []
    for item in args.size or DEFAULT_SIZES:
        try:
            width, height = map(int, item.split('x'))
        except ValueError:
            parser.error('Invalid size: ' + item)
        if min(width, height) < 1 or max(width, height) > 4096 or width * height > 2097152:
            parser.error('Size exceeds the GDI frame bounds: ' + item)
        if (width, height) not in sizes:
            sizes.append((width, height))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    models = output / 'coreml'
    models.mkdir()
    helper = output / 'winegdi-coreml-helper'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-O2', '-arch', 'arm64',
                    '-mmacosx-version-min=13.0', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                    '-ffile-prefix-map=' + str(ROOT) + '=/usr/src/wine-gdi-upscalers',
                    '-I', str(NATIVE / 'include'), str(NATIVE / 'src/coreml-helper.mm'),
                    '-framework', 'Foundation', '-framework', 'CoreML', '-framework', 'Accelerate', '-o', str(helper)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(helper)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(helper)], check=True)
    for width, height in sizes:
        package = models / ('realcugan-%dx%d.mlpackage' % (width, height))
        subprocess.run([sys.executable, str(ROOT / 'scripts/convert-realcugan-coreml.py'),
                        '--model-dir', str(args.model_dir.resolve()), '--width', str(width),
                        '--height', str(height), '--output', str(package)], check=True)
        subprocess.run(['xcrun', 'coremlcompiler', 'compile', str(package), str(models)], check=True)
        # Keep portable source packages alongside device-loadable compiled models
        # for reproducibility and future OS compiler compatibility investigation.
    source_paths = [Path(__file__), ROOT / 'scripts/convert-realcugan-coreml.py',
                    ROOT / 'scripts/requirements-coreml.txt', NATIVE / 'src/coreml-helper.mm',
                    NATIVE / 'include/wine_gdi_coreml_protocol.h', NATIVE / 'dependencies.json']
    manifest = {'schema': 1, 'helper_architecture': 'arm64', 'minimum_macos': '13.0',
                'compute_units': 'CPU_AND_NE', 'precision': 'FP16', 'source_sizes': sizes,
                'tools': versions, 'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
                'source_sha256': {str(p.relative_to(ROOT)): digest(p) for p in source_paths},
                'files': {str(p.relative_to(output)): digest(p) for p in sorted(output.rglob('*')) if p.is_file()},
                'verification': 'compiled; hardware placement and game acceptance require separate probes'}
    (models / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Core ML resource bundle:', output)


if __name__ == '__main__':
    main()
