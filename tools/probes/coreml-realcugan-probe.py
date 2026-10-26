#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Headless arm64-helper versus x86_64 ncnn image/IPC/latency probe.

Use arm64 Python with numpy/coremltools; --reference is a dependency-free
x86_64 subprocess using the previously built CPU-only dylib as the oracle.
The compute plan describes anticipated placement, not hardware counters.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import time


class Image(ctypes.Structure):
    _fields_ = [('pixels', ctypes.c_void_p), ('buffer_bytes', ctypes.c_size_t),
                ('stride', ctypes.c_size_t), ('width', ctypes.c_uint32), ('height', ctypes.c_uint32)]


def reference(args):
    class Options(ctypes.Structure):
        _fields_ = [('size', ctypes.c_uint32), ('algorithm', ctypes.c_uint32),
                    ('resources', ctypes.c_char_p), ('threads', ctypes.c_uint32)]
    create = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.POINTER(Options), ctypes.c_char_p, ctypes.c_size_t)
    process = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(Image), ctypes.POINTER(Image),
                              ctypes.c_char_p, ctypes.c_size_t)
    destroy = ctypes.CFUNCTYPE(None, ctypes.c_void_p)
    class API(ctypes.Structure):
        _fields_ = [('version', ctypes.c_uint32), ('size', ctypes.c_uint32),
                    ('create', create), ('process', process), ('destroy', destroy)]
    library = ctypes.CDLL(str(args.library.resolve()))
    library.wgdi_upscaler_get_api.restype = ctypes.POINTER(API)
    api = library.wgdi_upscaler_get_api(1).contents
    options = Options(ctypes.sizeof(Options), 2,
                      os.fsencode(args.resources.resolve()), 2)
    error = ctypes.create_string_buffer(1024)
    context = api.create(ctypes.byref(options), error, len(error))
    if not context:
        raise RuntimeError(error.value)
    source = ctypes.create_string_buffer(args.input.read_bytes())
    result = ctypes.create_string_buffer(args.width * args.height * 16)
    inp = Image(ctypes.addressof(source), len(source), args.width * 4, args.width, args.height)
    out = Image(ctypes.addressof(result), len(result), args.width * 8, args.width * 2, args.height * 2)
    begin = time.perf_counter()
    try:
        # First call warms model loading and allocations, separately from FPS.
        if api.process(context, ctypes.byref(inp), ctypes.byref(out), error, len(error)):
            raise RuntimeError(error.value)
        first_ms = (time.perf_counter() - begin) * 1000
        samples = []
        measured_begin = time.perf_counter()
        for index in range(args.repeat):
            if args.fps:
                delay = measured_begin + index / args.fps - time.perf_counter()
                if delay > 0:
                    time.sleep(delay)
            source[0] = bytes([index % 256])
            call_begin = time.perf_counter()
            if api.process(context, ctypes.byref(inp), ctypes.byref(out), error, len(error)):
                raise RuntimeError(error.value)
            samples.append((time.perf_counter() - call_begin) * 1000)
        elapsed = time.perf_counter() - measured_begin
    finally:
        api.destroy(context)
    args.output.write_bytes(result.raw)
    report = {'ncnn_ms': first_ms}
    if samples:
        ordered = sorted(samples)
        report.update({'frames': len(samples), 'median_ms': ordered[len(samples)//2],
                       'p95_ms': ordered[min(len(samples)-1, int(len(samples)*0.95))],
                       'max_ms': max(samples), 'measured_fps': len(samples)/elapsed,
                       'deadline_misses': sum(x > 1000/args.fps for x in samples) if args.fps else None})
    print(json.dumps(report))


def main(args):
    import fcntl
    import mmap
    import socket
    import struct
    import tempfile
    import numpy as np
    size = 288 + 2097152 * 20
    width, height = args.width, args.height
    with tempfile.TemporaryDirectory() as temp, tempfile.TemporaryFile() as file:
        work = Path(temp)
        file.truncate(size)
        shared = fcntl.fcntl(file.fileno(), fcntl.F_DUPFD_CLOEXEC, 10)
        left, right = socket.socketpair()
        remote = fcntl.fcntl(right.fileno(), fcntl.F_DUPFD_CLOEXEC, 10)
        right.close()
        left.settimeout(60)
        actions = [(os.POSIX_SPAWN_DUP2, shared, 3), (os.POSIX_SPAWN_DUP2, remote, 4),
                   (os.POSIX_SPAWN_CLOSE, shared), (os.POSIX_SPAWN_CLOSE, remote)]
        child = os.posix_spawn(str(args.helper.resolve()),
                              [str(args.helper.resolve()), '--serve', str(args.bundle.resolve())],
                              os.environ.copy(), file_actions=actions)
        os.close(remote)
        os.close(shared)
        mapping = mmap.mmap(file.fileno(), size)
        report = {'shape': [width, height], 'policy': 'CPU_AND_NE', 'cases': []}
        rng = np.random.default_rng(1234)
        yy, xx = np.indices((height, width))
        gradient = np.stack([(xx * 255 // max(width-1, 1)), (yy * 255 // max(height-1, 1)),
                             (xx + yy) % 256, np.full_like(xx, 255)], axis=-1).astype(np.uint8)
        cases = [('gradient', gradient), ('noise', rng.integers(0, 256, (height, width, 4), dtype=np.uint8)),
                 ('black', np.zeros((height, width, 4), dtype=np.uint8))]
        try:
            for seq, (name, image) in enumerate(cases, 1):
                image[:, :, 3] = 255
                raw = image.tobytes()
                (work / 'input.bgra').write_bytes(raw)
                reference_cmd = ['/usr/bin/arch', '-x86_64', '/usr/bin/python3', str(Path(__file__).resolve()),
                    '--reference', '--library', str(args.library.resolve()), '--resources', str(args.resources.resolve()),
                    '--input', str(work / 'input.bgra'), '--output', str(work / 'output.bgra'),
                    '--width', str(width), '--height', str(height)]
                cpu = subprocess.run(reference_cmd, check=True, capture_output=True, text=True, timeout=120,
                                     env=dict(os.environ, WINE_GDI_REALCUGAN_BACKEND='cpu'))
                struct.pack_into('<6IQ', mapping, 0, 0x5747434d, 1, seq, width, height, 1, 0)
                mapping[288:288+len(raw)] = raw
                begin = time.perf_counter()
                left.sendall(b'R')
                if left.recv(1) != b'D':
                    raise RuntimeError('helper disconnected')
                total_ms = (time.perf_counter() - begin) * 1000
                status, = struct.unpack_from('<I', mapping, 20)
                if status:
                    raise RuntimeError(mapping[32:288].split(b'\0')[0].decode())
                inference_ns, = struct.unpack_from('<Q', mapping, 24)
                offset = 288 + len(raw)
                actual = np.frombuffer(mapping[offset:offset+width*height*16], dtype=np.uint8).astype(np.int16)
                expected = np.frombuffer((work / 'output.bgra').read_bytes(), dtype=np.uint8).astype(np.int16)
                diff = np.abs(actual - expected).reshape(-1, 4)[:, :3]
                mse = float(np.mean(diff.astype(np.float64) ** 2))
                psnr = float(10 * np.log10(255**2 / mse)) if mse else 100.0
                entry = {'case': name, 'helper_total_ms': total_ms, 'prediction_ms': inference_ns/1e6,
                         'max_error_255': int(diff.max()), 'mean_error_255': float(diff.mean()),
                         'psnr_db': psnr,
                         **json.loads(cpu.stdout)}
                report['cases'].append(entry)
                if args.client_library:
                    command = list(reference_cmd)
                    command[command.index('--library') + 1] = str(args.client_library.resolve())
                    command[command.index('--resources') + 1] = str(args.client_resources.resolve())
                    command[command.index('--output') + 1] = str(work / 'client.bgra')
                    environment = dict(os.environ, WINE_GDI_REALCUGAN_BACKEND='auto')
                    client = subprocess.run(command, check=True, capture_output=True, text=True,
                                            timeout=120, env=environment)
                    if 'Core ML arm64' not in client.stderr:
                        raise AssertionError('x86_64 client did not report helper inference: ' + client.stderr)
                    integrated = np.frombuffer((work / 'client.bgra').read_bytes(), dtype=np.uint8).astype(np.int16)
                    error = int(np.abs(actual - integrated).max())
                    if error > 1:
                        raise AssertionError('Integrated client differs from direct helper')
                    entry['integrated_client_ms'] = json.loads(client.stdout)['ncnn_ms']
                    entry['integrated_client_max_error_255'] = error
                # FP16 ANE accumulation differs from CPU FP32, particularly on
                # high-frequency noise. Keep an explicit perceptual/error gate.
                if diff.max() > 16 or psnr < 40:
                    raise AssertionError('Core ML image error exceeds prototype threshold: ' + str(entry))
            # Exercise validation and recovery on the same connection.
            struct.pack_into('<I', mapping, 12, 0)
            left.sendall(b'R')
            assert left.recv(1) == b'D' and struct.unpack_from('<I', mapping, 20)[0] == 1
            report['invalid_frame_rejected'] = True
        finally:
            left.close()
            os.kill(child, 9)
            os.waitpid(child, 0)
            mapping.close()
        if args.plan:
            import coremltools as ct
            from coremltools.models.compute_plan import MLComputePlan
            plan = MLComputePlan.load_from_path(str(args.bundle.resolve() / 'coreml' /
                ('realcugan-' +
                 '%dx%d.mlmodelc' % (width, height))), compute_units=ct.ComputeUnit.CPU_AND_NE)
            counts, costs = {}, {}
            for operation in plan.model_structure.program.functions['main'].block.operations:
                usage = plan.get_compute_device_usage_for_mlprogram_operation(operation)
                device = type(usage.preferred_compute_device).__name__ if usage else 'unknown'
                counts[device] = counts.get(device, 0) + 1
                cost = plan.get_estimated_cost_for_mlprogram_operation(operation)
                costs[device] = costs.get(device, 0.0) + (cost.weight if cost else 0.0)
            report['anticipated_placement_operations'] = counts
            report['anticipated_placement_cost'] = costs
        text = json.dumps(report, indent=2)
        print(text)
        if args.report:
            args.report.write_text(text + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', action='store_true')
    parser.add_argument('--library', required=True, type=Path)
    parser.add_argument('--resources', required=True, type=Path)
    parser.add_argument('--input', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--helper', type=Path)
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--width', type=int, default=64)
    parser.add_argument('--height', type=int, default=48)
    parser.add_argument('--plan', action='store_true')
    parser.add_argument('--report', type=Path)
    parser.add_argument('--client-library', type=Path, help='New x86_64 client dylib for full ABI/IPC comparison')
    parser.add_argument('--client-resources', type=Path)
    parser.add_argument('--repeat', type=int, default=0, help='Warm frames in --reference worker')
    parser.add_argument('--fps', type=float, default=0, help='Frame submission rate in --reference worker')
    options = parser.parse_args()
    (reference if options.reference else main)(options)
