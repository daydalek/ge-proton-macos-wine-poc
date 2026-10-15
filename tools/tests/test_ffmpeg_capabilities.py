#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ffmpeg', ROOT / 'scripts/ci/check-ffmpeg.py')
ffmpeg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ffmpeg)


class FFmpegTests(unittest.TestCase):
    def report(self):
        return {'decoders': sorted(ffmpeg.REQUIRED['decoders']),
                'demuxers': sorted(ffmpeg.REQUIRED['demuxers']),
                'parsers': 1, 'bitstream_filters': ['h264_mp4toannexb'],
                'licenses': {'avcodec': 'LGPL version 2.1 or later',
                             'avformat': 'LGPL version 2.1 or later'},
                '_configure_options': ['--enable-decoders', '--enable-demuxers',
                                       '--enable-parsers', '--enable-bsfs']}

    def test_broad_playback_profile(self):
        ffmpeg.validate(self.report())

    def test_demuxer_aliases(self):
        report = self.report()
        report['demuxers'].remove('mov')
        report['demuxers'].append('mov,mp4,m4a,3gp,3g2,mj2')
        ffmpeg.validate(report)

    def test_missing_codec_or_container_fails(self):
        for kind, name in (('decoders', 'wmalossless'), ('decoders', 'aac'),
                           ('demuxers', 'ogg')):
            with self.subTest(kind=kind, name=name):
                report = self.report()
                report[kind].remove(name)
                with self.assertRaisesRegex(ValueError, 'Missing FFmpeg'):
                    ffmpeg.validate(report)

    def test_missing_parser_or_bsf_fails(self):
        for kind in ('parsers', 'bitstream_filters'):
            report = self.report()
            report[kind] = 0 if kind == 'parsers' else []
            with self.assertRaises(ValueError):
                ffmpeg.validate(report)

    def test_restricted_or_non_lgpl_configuration_fails(self):
        report = self.report()
        report['_configure_options'].remove('--enable-decoders')
        with self.assertRaises(ValueError):
            ffmpeg.validate(report)
        for option in ('--enable-gpl', '--enable-nonfree', '--enable-version3'):
            report = self.report()
            report['_configure_options'].append(option)
            with self.assertRaises(ValueError):
                ffmpeg.validate(report)
        report = self.report()
        report['licenses']['avcodec'] = 'GPL version 2 or later'
        with self.assertRaises(ValueError):
            ffmpeg.validate(report)


if __name__ == '__main__':
    unittest.main()
