#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Convert the SHA-locked ncnn AnimeVideo-v3 graph into a Core ML program.

Build dependency: coremltools==8.3.0, numpy==1.26.4 (arm64 Python).
No training framework or separately downloaded weights are required.
Input is padded RGB NCHW float32; output is unclamped RGB NCHW float32.
The graph is SRVGGNetCompact x4 (18 convolutions, PReLU, one PixelShuffle)
plus a nearest x4 skip and a bicubic x0.5 tail, which this file reproduces
exactly, including ncnn's A=-0.75 align_corners=0 cubic kernel. Only even
input dimensions are supported: the helper always feeds fixed-size tiles
with a reflect101 halo of 19, matching the native CPU backend's padding.
Every source byte is checked before conversion.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
PARAM = 'realesr-animevideov3-x2.param'
BIN = 'realesr-animevideov3-x2.bin'


def load_graph(model_dir):
    import numpy as np
    lock = json.loads((ROOT / 'native/gdi-upscalers/dependencies.json').read_text())
    for name in (PARAM, BIN):
        path = model_dir / name
        expected = lock['animevideov3_model_sha256']['models/' + name]
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('Model digest mismatch: ' + name)
    lines = (model_dir / PARAM).read_text().splitlines()
    if lines[:2] != ['7767517', '41 42']:
        raise ValueError('Unexpected ncnn graph header')
    data = (model_dir / BIN).read_bytes()
    offset = 0

    def weights(count, tagged):
        nonlocal offset
        dtype = '<f4'
        if tagged:
            tag, = struct.unpack_from('<I', data, offset)
            offset += 4
            if tag == 0x01306B47:
                dtype = '<f2'
            elif tag != 0:
                raise ValueError('Unsupported ncnn weight encoding')
        size = count * np.dtype(dtype).itemsize
        result = np.frombuffer(data, dtype=dtype, count=count, offset=offset).astype(np.float32)
        offset += (size + 3) & ~3
        if not np.isfinite(result).all():
            raise ValueError('Nonfinite model weights')
        return result

    graph = []
    for line in lines[2:]:
        fields = line.split()
        kind, name, nin, nout = fields[:4]
        nin, nout = int(nin), int(nout)
        inputs, outputs = fields[4:4+nin], fields[4+nin:4+nin+nout]
        params = {}
        for field in fields[4+nin+nout:]:
            key, value = field.split('=')
            key = int(key)
            if key < -23300:
                key = -key - 23300
                values = value.split(',')
                if int(values[0]) != len(values) - 1:
                    raise ValueError('Invalid ncnn array')
                params[key] = [float(x) for x in values[1:]]
            else:
                try:
                    params[key] = int(value)
                except ValueError:
                    params[key] = float(value)
        layer = dict(kind=kind, name=name, inputs=inputs, outputs=outputs, params=params)
        if kind == 'Convolution':
            layer['weights'] = weights(params[6], True)
            if params.get(5, 0) != 1:
                raise ValueError('Expected a bias on every convolution')
            layer['bias'] = weights(params[0], False)
        elif kind == 'PReLU':
            layer['slopes'] = weights(params[0], False)
        graph.append(layer)
    if offset != len(data):
        raise ValueError('Unconsumed model bytes')
    return graph


def validate(graph):
    kinds = [layer['kind'] for layer in graph]
    expected = (['Input', 'Split'] + ['Convolution', 'PReLU'] * 17 +
                ['Convolution', 'PixelShuffle', 'Interp', 'BinaryOp', 'Interp'])
    if kinds != expected:
        raise ValueError('Unexpected AnimeVideo-v3 layer sequence: ' + ','.join(kinds))
    split = graph[1]
    if graph[0]['outputs'] != ['data'] or split['inputs'] != ['data'] or len(split['outputs']) != 2:
        raise ValueError('Unexpected graph input/split wiring')
    convs = [layer for layer in graph if layer['kind'] == 'Convolution']
    for index, conv in enumerate(convs):
        p = conv['params']
        channels = 3 if index == 0 else 64
        out = 48 if index == len(convs) - 1 else 64
        if (p[0] != out or p[1] != 3 or p.get(4) != 1 or p.get(5) != 1 or p.get(3, 1) != 1 or
                conv['weights'].size != p[6] or conv['bias'].size != out or
                conv['weights'].size != channels * out * 9):
            raise ValueError('Unexpected convolution parameters: ' + conv['name'])
    for layer in graph:
        if layer['kind'] == 'PReLU' and layer['slopes'].size != layer['params'][0]:
            raise ValueError('Unexpected PReLU slope count: ' + layer['name'])
    shuffle, nearest, add, bicubic = graph[-4:]
    if convs[0]['inputs'][0] not in split['outputs'] or nearest['inputs'][0] not in split['outputs'] or \
            convs[0]['inputs'][0] == nearest['inputs'][0]:
        raise ValueError('Unexpected skip wiring')
    if (shuffle['params'][0] != 4 or nearest['params'].get(0) != 1 or
            nearest['params'].get(1) != 4.0 or nearest['params'].get(2) != 4.0 or
            add['inputs'] != [shuffle['outputs'][0], nearest['outputs'][0]] or
            add['params'].get(0, 0) != 0 or bicubic['params'].get(0) != 3 or
            bicubic['params'].get(1) != 0.5 or bicubic['params'].get(2) != 0.5 or
            bicubic['outputs'] != ['output']):
        raise ValueError('Unexpected AnimeVideo-v3 graph tail')


def convert(model_dir, width, height, output):
    import numpy as np
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb
    graph = load_graph(model_dir)
    validate(graph)
    if (width | height) & 1:
        raise ValueError('AnimeVideo-v3 tiles require even dimensions')
    ph, pw = height + 38, width + 38

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, ph, pw))], opset_version=ct.target.macOS13)
    def program(input_rgb):
        blobs = {'data': input_rgb}
        x = None
        for layer in graph:
            kind, name, p = layer['kind'], layer['name'], layer['params']
            if kind == 'Input':
                continue
            if kind == 'Split':
                for target in layer['outputs']:
                    blobs[target] = blobs[layer['inputs'][0]]
                continue
            args = [blobs[source] for source in layer['inputs']]
            if kind == 'Convolution':
                k, channels = p[1], p[0]
                w = layer['weights'].reshape(channels, -1, k, k)
                x = mb.conv(x=args[0], weight=w, bias=layer['bias'], strides=[p.get(3, 1)] * 2,
                            pad_type='custom', pad=[p[4]] * 4, name=name)
            elif kind == 'PReLU':
                x = mb.prelu(x=args[0], alpha=layer['slopes'], name=name)
            elif kind == 'PixelShuffle':
                x = mb.pixel_shuffle(x=args[0], upscale_factor=p[0], name=name)
            elif kind == 'Interp' and p[0] == 1:
                x = mb.upsample_nearest_neighbor(x=args[0], scale_factor_height=int(p[1]),
                                                 scale_factor_width=int(p[2]), name=name)
            elif kind == 'BinaryOp' and p.get(0, 0) == 0:
                x = mb.add(x=args[0], y=args[1], name=name)
            elif kind == 'Interp' and p[0] == 3:
                # ncnn bicubic (A=-0.75, align_corners=0) at scale 0.5 samples
                # output o at input 2o+0.5 with taps k, expressed as a stride-2
                # depthwise separable convolution; its zero border lies in the
                # halo and is cropped below.
                k = np.array([-0.09375, 0.59375, 0.59375, -0.09375], dtype=np.float32)
                w = np.repeat(np.outer(k, k)[None, None], 3, axis=0)
                x = mb.conv(x=args[0], weight=w, strides=[2, 2], pad_type='custom',
                            pad=[1, 1, 1, 1], groups=3, name=name)
            else:
                raise ValueError('Unsupported layer: ' + kind)
            blobs[layer['outputs'][0]] = x
        # The input halo of 19 reappears at x2 scale around the 2*pw output.
        x = mb.crop(x=blobs['output'], crop_height=[38, 38], crop_width=[38, 38], name='crop_halo')
        return mb.identity(x=x, name='output_rgb')

    if program.functions['main'].outputs[0].shape != (1, 3, height * 2, width * 2):
        raise ValueError('Unexpected output dimensions')
    model = ct.convert(program, convert_to='mlprogram', minimum_deployment_target=ct.target.macOS13,
                       compute_precision=ct.precision.FLOAT16, skip_model_load=True)
    model.short_description = 'Real-ESRGAN AnimeVideo-v3 x2, official 20220424 ncnn weights'
    model.author = 'Xintao Wang (Real-ESRGAN ncnn release); Core ML adapter by Whisky contributors'
    model.license = 'BSD-3-Clause; see bundled Real-ESRGAN-BSD-3-Clause.txt'
    model.user_defined_metadata['wgdi.width'] = str(width)
    model.user_defined_metadata['wgdi.height'] = str(height)
    model.user_defined_metadata['wgdi.model'] = 'animevideov3'
    model.user_defined_metadata['wgdi.input_halo'] = '19'
    model.user_defined_metadata['wgdi.dependency_halo'] = '19'
    model.user_defined_metadata['wgdi.integer_translation'] = 'true'
    model.save(str(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-dir', required=True, type=Path)
    parser.add_argument('--width', required=True, type=int)
    parser.add_argument('--height', required=True, type=int)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if min(args.width, args.height) < 1 or max(args.width, args.height) > 4096 or args.width * args.height > 2097152:
        parser.error('Dimensions exceed the GDI inference bounds')
    convert(args.model_dir, args.width, args.height, args.output)


if __name__ == '__main__':
    main()
