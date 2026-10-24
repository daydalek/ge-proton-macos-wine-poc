# SPDX-License-Identifier: LGPL-2.1-or-later
"""Exercise GitHub draft visibility and exact asset-digest publication checks."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('linux_publish', ROOT / 'scripts/linux/publish.py')
publish = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publish)


class LinuxPublishTests(unittest.TestCase):
    def test_draft_hidden_by_tag_resolves_numeric_id(self):
        draft = {'id': 123, 'tag_name': 'v1.0.0-linux-amd64', 'draft': True}
        with patch.object(publish, 'api', side_effect=[None, [draft], draft]) as api:
            self.assertEqual(publish.find_release('repos/example/wine', draft['tag_name']), draft)
        self.assertEqual(api.call_args_list[-1].args, ('repos/example/wine/releases/123',))

    def test_published_release_uses_tag_lookup(self):
        release = {'id': 124, 'tag_name': 'v1.0.1-linux-amd64', 'draft': False}
        with patch.object(publish, 'api', return_value=release) as api:
            self.assertEqual(publish.find_release('repos/example/wine', release['tag_name']), release)
            self.assertEqual(api.call_count, 1)

    def test_missing_release_returns_none(self):
        with patch.object(publish, 'api', side_effect=[None, []]):
            self.assertIsNone(publish.find_release('repos/example/wine', 'v1.0.0-linux-amd64'))

    def test_mismatched_uploaded_digest_blocks_publication(self):
        info = {'assets': [{'name': 'runtime.tar.gz', 'state': 'uploaded', 'digest': 'sha256:' + 'a' * 64}]}
        publish.verify_uploaded(info, {'runtime.tar.gz': 'a' * 64})
        with self.assertRaises(ValueError):
            publish.verify_uploaded(info, {'runtime.tar.gz': 'b' * 64})


if __name__ == '__main__':
    unittest.main()
