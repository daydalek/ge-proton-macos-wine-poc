#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Own a private PulseAudio server and null sink for native Wine probes."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


class PulseAudioFixture:
    def __init__(self, environment, output, timeout=20):
        self.environment = environment
        self.output = output
        self.timeout = timeout
        self.process = None
        self.stream = None
        self.runtime = None

    def start(self):
        started = time.monotonic()
        self.runtime = tempfile.TemporaryDirectory(prefix='ge-wine-pulse-')
        directory = Path(self.runtime.name)
        self.server = 'unix:' + str(directory / 'native')
        self.sink = 'ge_wine_test_' + str(os.getpid())
        client = directory / 'client.conf'
        client.write_text('autospawn = no\n')
        self.environment.update(PULSE_SERVER=self.server, PULSE_SINK=self.sink,
                                PULSE_CLIENTCONFIG=str(client))
        server_env = dict(os.environ)
        for key in ('LD_LIBRARY_PATH', 'LD_PRELOAD', 'LD_AUDIT', 'PULSE_SERVER',
                    'PULSE_SINK', 'PULSE_SOURCE', 'PULSE_COOKIE', 'PULSE_CLIENTCONFIG',
                    'PULSE_RUNTIME_PATH', 'PULSE_STATE_PATH', 'DBUS_SESSION_BUS_ADDRESS',
                    'DBUS_STARTER_ADDRESS', 'DBUS_STARTER_BUS_TYPE'):
            server_env.pop(key, None)
        server_env.update(PULSE_RUNTIME_PATH=str(directory),
                          PULSE_STATE_PATH=str(directory / 'state'),
                          PULSE_CLIENTCONFIG=str(client), PULSE_SERVER=self.server)
        self.stream = (self.output / 'pulseaudio.log').open('wb')
        status, code = 'timed_out', None
        try:
            self.process = subprocess.Popen([
                'dbus-run-session', '--', 'pulseaudio', '-n', '--daemonize=no',
                '--use-pid-file=no', '--realtime=no', '--high-priority=no',
                '--exit-idle-time=-1', '--log-level=info',
                '--load=module-native-protocol-unix socket=' + str(directory / 'native') + ' auth-anonymous=1',
                '--load=module-null-sink sink_name=' + self.sink,
            ], env=server_env, stdout=self.stream, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = started + self.timeout
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    status, code = 'failed', self.process.returncode
                    break
                try:
                    result = subprocess.run(['pactl', '--server=' + self.server, 'list', 'short', 'sinks'],
                        env=server_env, capture_output=True, text=True,
                        timeout=min(5, max(0.1, deadline - time.monotonic())))
                    names = [line.split()[1] for line in result.stdout.splitlines() if len(line.split()) > 1]
                    if result.returncode == 0 and self.sink in names:
                        status, code = 'passed', 0
                        break
                except subprocess.TimeoutExpired:
                    pass
                time.sleep(0.1)
        except OSError as error:
            self.stream.write((str(error) + '\n').encode())
            status = 'failed'
        self.stream.flush()
        return {'name': 'pulse-audio', 'status': status, 'exit_code': code,
                'seconds': round(time.monotonic() - started, 2), 'log': 'pulseaudio.log'}

    def close(self):
        if self.process:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=self.timeout)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.process.wait()
            self.process = None
        if self.stream:
            self.stream.close()
            self.stream = None
        if self.runtime:
            self.runtime.cleanup()
            self.runtime = None
