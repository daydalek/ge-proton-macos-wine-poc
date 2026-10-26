#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Convert the SHA-locked ncnn SE graph into a fixed-size Core ML program.

Build dependency: coremltools==8.3.0, numpy==1.26.4 (arm64 Python).
No training framework or separately downloaded weights are required.
Input is padded RGB NCHW float32; output is unclamped RGB NCHW float32.
The native helper implements the same reflect101 padding and BGRA conversion
as the existing ncnn backend. Every source byte is checked before conversion.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]


def load_graph(model_dir):
    import numpy as np
    lock = json.loads((ROOT / 'native/gdi-upscalers/dependencies.json').read_text())
    for suffix in ('param', 'bin'):
        name = 'up2x-no-denoise.' + suffix
        path = model_dir / name
        expected = lock['model_sha256']['models/models-se/' + name]
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('Model digest mismatch: ' + name)
    lines = (model_dir / 'up2x-no-denoise.param').read_text().splitlines()
    if lines[:2] != ['7767517', '55 63']:
        raise ValueError('Unexpected ncnn graph header')
    data = (model_dir / 'up2x-no-denoise.bin').read_bytes()
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
                params[key] = int(value)
        layer = dict(kind=kind, name=name, inputs=inputs, outputs=outputs, params=params)
        if kind in ('Convolution', 'Deconvolution', 'InnerProduct'):
            count = params[2 if kind == 'InnerProduct' else 6]
            layer['weights'] = weights(count, True)
            if params.get(1 if kind == 'InnerProduct' else 5, 0) != 1:
                raise ValueError('Expected a bias on every learned layer')
            layer['bias'] = weights(params[0], False)
        graph.append(layer)
    if offset != len(data):
        raise ValueError('Unconsumed model bytes')
    return graph


def convert(model_dir, width, height, output):
    import numpy as np
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb
    graph = load_graph(model_dir)
    ph, pw = height + 36 + height % 2, width + 36 + width % 2

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, ph, pw))], opset_version=ct.target.macOS13)
    def program(input_rgb):
        blobs = {'in0': input_rgb}
        for layer in graph:
            kind, name, p = layer['kind'], layer['name'], layer['params']
            if kind == 'Input':
                continue
            args = [blobs[x] for x in layer['inputs']]
            x = args[0]
            if kind == 'Split':
                for target in layer['outputs']:
                    blobs[target] = x
                continue
            if kind in ('Convolution', 'Deconvolution'):
                k, channels = p[1], p[0]
                w = layer['weights'].reshape(channels, -1, k, k)
                options = dict(x=x, bias=layer['bias'], strides=[p.get(3, 1)] * 2, name=name)
                if kind == 'Convolution':
                    x = mb.conv(weight=w, pad_type='valid', **options)
                else:
                    # ncnn stores output,input,H,W; MIL uses input,output,H,W.
                    padding = p.get(4, 0)
                    x = mb.conv_transpose(weight=w.transpose(1, 0, 2, 3),
                                          pad_type='custom', pad=[padding] * 4, **options)
            elif kind == 'InnerProduct':
                w = layer['weights'].reshape(p[0], -1, 1, 1)
                x = mb.conv(x=x, weight=w, bias=layer['bias'], name=name)
            elif kind == 'Pooling' and p == {0: 1, 4: 1}:
                x = mb.reduce_mean(x=x, axes=[2, 3], keep_dims=True, name=name)
            elif kind == 'BinaryOp' and p.get(0, 0) in (0, 2):
                x = (mb.add if p.get(0, 0) == 0 else mb.mul)(x=x, y=args[1], name=name)
            elif kind == 'Crop':
                if p[11] != [-2, -1] or p[9] != [-v for v in p[10]]:
                    raise ValueError('Unsupported crop')
                top, left = [int(v) for v in p[9]]
                x = mb.crop(x=x, crop_height=[top, top], crop_width=[left, left], name=name)
            else:
                raise ValueError('Unsupported layer: ' + kind)
            activation = p.get(9, 0) if kind in ('Convolution', 'Deconvolution', 'InnerProduct') else 0
            if activation == 2:
                x = mb.leaky_relu(x=x, alpha=np.float32(p[10][0]), name=name + '_activation')
            elif activation == 1:
                x = mb.relu(x=x, name=name + '_activation')
            elif activation == 4:
                x = mb.sigmoid(x=x, name=name + '_activation')
            elif activation:
                raise ValueError('Unsupported activation')
            blobs[layer['outputs'][0]] = x
        return mb.identity(x=blobs['out0'], name='output_rgb')

    if program.functions['main'].outputs[0].shape != (1, 3, (ph-36)*2, (pw-36)*2):
        raise ValueError('Unexpected output dimensions')
    model = ct.convert(program, convert_to='mlprogram', minimum_deployment_target=ct.target.macOS13,
                       compute_precision=ct.precision.FLOAT16, skip_model_load=True)
    model.short_description = 'Real-CUGAN models-se 2x, official 20220728 ncnn weights'
    model.author = 'bilibili; ncnn conversion by nihui; Core ML adapter by Whisky contributors'
    model.license = 'MIT; see bundled RealCUGAN-bilibili-MIT.txt and RealCUGAN-ncnn-MIT.txt'
    model.user_defined_metadata['wgdi.width'] = str(width)
    model.user_defined_metadata['wgdi.height'] = str(height)
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
