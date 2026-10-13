#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
import base64
import importlib.util
from pathlib import Path
import plistlib
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[2] / 'scripts/ci/publish-runtime-channel.py'
spec = importlib.util.spec_from_file_location('channel', path)
channel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(channel)


class ChannelTests(unittest.TestCase):
    def info(self, patch_version=1, digest='a' * 64):
        return {'version': {'major': 11, 'minor': 0, 'patch': patch_version}, 'sha256': digest}

    def release(self):
        prefix = 'https://github.com/example/wine/releases/download/v0.1.0/'
        return {'draft': False, 'prerelease': True, 'tag_name': 'v0.1.0', 'assets': [
            {'name': 'Libraries.tar.gz', 'state': 'uploaded', 'digest': 'sha256:' + 'a' * 64,
             'browser_download_url': prefix + 'Libraries.tar.gz'},
            {'name': 'WhiskyWineVersion.plist', 'state': 'uploaded',
             'browser_download_url': prefix + 'WhiskyWineVersion.plist'}]}

    def test_prerelease_preserves_exact_asset_url_and_filters_extra_fields(self):
        info = self.info()
        info['debugLog'] = 'local-only'
        with patch.object(channel, 'download', return_value=plistlib.dumps(info)):
            result = channel.manifest_for_release('example/wine', self.release())
        self.assertNotIn('debugLog', result)
        self.assertIn('/v0.1.0/', result['downloadURL'])
        self.assertEqual(channel.version(result), (11, 0, 1))

    def test_missing_and_partial_assets_are_skipped(self):
        release = self.release()
        release['assets'][0]['state'] = 'starter'
        self.assertIsNone(channel.manifest_for_release('example/wine', release))

    def test_wrong_archive_digest_blocks_publication(self):
        with patch.object(channel, 'download', return_value=plistlib.dumps(self.info(digest='b' * 64))):
            with self.assertRaisesRegex(ValueError, 'digest disagrees'):
                channel.manifest_for_release('example/wine', self.release())

    def test_older_runtime_keeps_current_channel(self):
        previous = {'content': base64.b64encode(plistlib.dumps(self.info(2))).decode()}
        with patch.object(channel, 'gh', side_effect=[{'object': {'sha': 'base'}}, previous]) as api:
            channel.publish('example/wine', self.info(1))
        self.assertEqual(api.call_count, 2)

    def test_changed_archive_requires_version_bump(self):
        previous = {'content': base64.b64encode(plistlib.dumps(self.info())).decode()}
        with patch.object(channel, 'gh', side_effect=[{'object': {'sha': 'base'}}, previous]):
            with self.assertRaisesRegex(ValueError, 'increased version'):
                channel.publish('example/wine', self.info(digest='b' * 64))


if __name__ == '__main__':
    unittest.main()
