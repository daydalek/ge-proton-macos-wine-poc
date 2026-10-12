#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Fetch and verify the official CrossOver source archive without extracting it."""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from poc_common import CONFIGS, CROSSOVER_PORT, SETTINGS, download_verified  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--archive', type=Path, default=CROSSOVER_PORT / SETTINGS['POC_CROSSOVER_ARCHIVE'])
args = parser.parse_args()
lock = json.loads((CONFIGS / 'crossover-source-lock.json').read_text())
archive = download_verified(lock['source_url'], args.archive.resolve(), lock['source_sha256'])
print(f'Verified CrossOver source: {archive}')
