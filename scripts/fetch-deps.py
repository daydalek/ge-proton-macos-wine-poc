#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Download and verify the locked build dependencies and Vulkan registry files."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
from poc_common import CONFIGS, POC_ROOT, WORK, download_verified  # noqa: E402

for item in json.loads((CONFIGS / 'dependency-lock.json').read_text()):
    download_verified(item['url'], WORK / item['archive'], item['sha256'])
    print('Verified', item['archive'])
vulkan_cache = POC_ROOT / 'cache/wine'
for item in json.loads((CONFIGS / 'vulkan-generation-lock.json').read_text()):
    download_verified(item['url'], vulkan_cache / item['file'], item['sha256'])
    print('Verified', item['file'])
