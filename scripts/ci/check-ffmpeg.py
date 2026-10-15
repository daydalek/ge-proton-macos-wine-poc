#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Check the actual x86_64 FFmpeg dylibs, without launching Wine or games."""
import argparse
import ctypes
import json
import platform
from pathlib import Path
import shlex
import subprocess
import sys

REQUIRED = {
    'decoders': {'wmv1', 'wmv2', 'wmv3', 'vc1', 'wmav1', 'wmav2', 'wmapro',
                 'wmalossless', 'aac', 'vorbis', 'opus', 'flac', 'ac3', 'dca',
                 'mpeg1video', 'mpeg2video', 'mpeg4', 'h264', 'hevc', 'vp8',
                 'vp9', 'theora', 'mjpeg', 'binkvideo', 'smackvid', 'adpcm_ms',
                 'adpcm_ima_wav', 'pcm_s16le', 'pcm_s24le', 'pcm_f32le'},
    'demuxers': {'asf', 'avi', 'mov', 'ogg', 'matroska', 'mpeg', 'mpegts',
                 'wav', 'mp3', 'aac', 'flac', 'bink', 'smk'},
}


def validate(report):
    for kind, required in REQUIRED.items():
        # Some demuxers advertise aliases as one comma-separated name.
        available = {alias for name in report[kind] for alias in name.split(',')}
        missing = required - available
        if missing:
            raise ValueError('Missing FFmpeg ' + kind + ': ' + ', '.join(sorted(missing)))
    if not report['parsers'] or not report['bitstream_filters']:
        raise ValueError('FFmpeg parsers or bitstream filters are missing')
    if any(license != 'LGPL version 2.1 or later' for license in report['licenses'].values()):
        raise ValueError('Expected LGPL-2.1-or-later FFmpeg libraries')
    options = set(report['_configure_options'])
    if not {'--enable-decoders', '--enable-demuxers', '--enable-parsers', '--enable-bsfs'} <= options:
        raise ValueError('Expected broad built-in FFmpeg playback configuration')
    if options & {'--enable-gpl', '--enable-nonfree', '--enable-version3'}:
        raise ValueError('Unexpected FFmpeg licensing configuration')


def inspect(directory):
    codec = ctypes.CDLL(str(directory / 'libavcodec.dylib'))
    format_lib = ctypes.CDLL(str(directory / 'libavformat.dylib'))

    def string(library, name):
        function = getattr(library, name)
        function.argtypes = []
        function.restype = ctypes.c_char_p
        return function().decode()

    # AVCodec, AVInputFormat and AVBitStreamFilter all have name as their
    # first public field in the locked FFmpeg ABI. No private layouts are used.
    class Named(ctypes.Structure):
        _fields_ = [('name', ctypes.c_char_p)]

    def enumerate_names(library, symbol, predicate=None):
        iterate = getattr(library, symbol)
        iterate.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        iterate.restype = ctypes.c_void_p
        state = ctypes.c_void_p()
        names = []
        while pointer := iterate(ctypes.byref(state)):
            if predicate is None or predicate(pointer):
                names.append(ctypes.cast(pointer, ctypes.POINTER(Named)).contents.name.decode())
        return sorted(names)

    codec.av_codec_is_decoder.argtypes = [ctypes.c_void_p]
    codec.av_codec_is_decoder.restype = ctypes.c_int
    parser_iterate = codec.av_parser_iterate
    parser_iterate.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    parser_iterate.restype = ctypes.c_void_p
    state = ctypes.c_void_p()
    parsers = 0
    while parser_iterate(ctypes.byref(state)):
        parsers += 1
    return {
        'profile': 'builtin-software-playback',
        'scope': 'Library registration and licensing only; Wine/game playback is not exercised',
        'decoders': enumerate_names(codec, 'av_codec_iterate', codec.av_codec_is_decoder),
        'demuxers': enumerate_names(format_lib, 'av_demuxer_iterate'),
        'parsers': parsers,
        'bitstream_filters': enumerate_names(codec, 'av_bsf_iterate'),
        'licenses': {'avcodec': string(codec, 'avcodec_license'),
                     'avformat': string(format_lib, 'avformat_license')},
        '_configure_options': shlex.split(string(codec, 'avcodec_configuration')),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('Requires macOS and the x86_64 runtime libraries')
    if platform.machine() not in ('x86_64', 'AMD64'):
        # Xcode Command Line Tools supply a universal Python; a Homebrew
        # interpreter may be arm64-only and cannot load the runtime dylibs.
        subprocess.run(['/usr/bin/arch', '-x86_64', '/usr/bin/python3',
                        str(Path(__file__).resolve()), *sys.argv[1:]], check=True)
        return
    report = inspect(args.library_dir.resolve())
    validate(report)
    # Build configuration contains private paths; publish capabilities only.
    del report['_configure_options']
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'FFmpeg: {len(report["decoders"])} decoders, {len(report["demuxers"])} demuxers, '
          f'{report["parsers"]} parsers, {len(report["bitstream_filters"])} bitstream filters; LGPL 2.1+')


if __name__ == '__main__':
    main()
