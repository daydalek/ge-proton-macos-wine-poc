#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Strict unittest discovery runner for CI.

Runs the repository source tests, writes a JSON report, and fails on any
condition a plain ``unittest discover`` would hide: a discovery error,
unexpected skip reasons, an empty suite, or a suite where no test method
actually executed.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import traceback
import unittest

REPO = Path(__file__).resolve().parents[2]


def _text(value):
    if value is None:
        return None
    if isinstance(value, bytes):
        return value.decode(errors='replace')
    return str(value)


def _subprocess_diagnostics(exc):
    lines = []
    timeout = getattr(exc, 'timeout', None)
    if timeout is not None:
        lines.append('Timed out after {!r} seconds.'.format(timeout))
    stdout = getattr(exc, 'stdout', None)
    if stdout is None:
        stdout = getattr(exc, 'output', None)
    stdout = _text(stdout)
    stderr = _text(getattr(exc, 'stderr', None))
    if stdout:
        lines.append('Captured stdout:\n' + stdout)
    if stderr:
        lines.append('Captured stderr:\n' + stderr)
    return '\n'.join(lines)


class DiagnosticsTestResult(unittest.TextTestResult):
    """Appends captured subprocess output to failure and error tracebacks.

    Tracks how many test methods actually started execution. A skip only
    discounts the method it interrupted: fixture-level skips (_ErrorHolder
    entries for setUpClass/setUpModule) and skipped subtests never started
    the method itself, so they must not drive the count negative.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.executed = 0
        self._active_test = None

    def startTest(self, test):
        super().startTest(test)
        self.executed += 1
        self._active_test = test

    def stopTest(self, test):
        super().stopTest(test)
        self._active_test = None

    def addSkip(self, test, reason):
        if test is self._active_test:
            self.executed -= 1
        super().addSkip(test, reason)

    def _exc_info_to_string(self, err, test):
        text = super()._exc_info_to_string(err, test)
        exc = err[1]
        if isinstance(exc, (subprocess.CalledProcessError, subprocess.TimeoutExpired)):
            extra = _subprocess_diagnostics(exc)
            if extra:
                text += '\n' + extra
        return text


def _test_id(test):
    if getattr(test, 'subtest', None) is not None:
        return str(test)
    identifier = getattr(test, 'id', None)
    if callable(identifier):
        try:
            return identifier()
        except Exception:
            pass
    return str(test)


def _outcome_entries(pairs):
    return [{'id': _test_id(test), 'traceback': output} for test, output in pairs]


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--start-directory', type=Path, default=REPO / 'tools/tests',
                        help='Directory scanned for tests (default: %(default)s)')
    parser.add_argument('--pattern', default='test_*.py',
                        help='Discovery glob (default: %(default)s)')
    parser.add_argument('--output', type=Path, default=REPO / 'outputs/checks/source-tests.json',
                        help='JSON report path (default: %(default)s)')
    parser.add_argument('--allow-skip', action='append', default=[], metavar='REASON',
                        help='Exact skip reason allowed without failing the run; repeatable')
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    start = args.start_directory.resolve()
    discovery_error = None
    try:
        suite = unittest.TestLoader().discover(str(start), pattern=args.pattern)
    except Exception:
        suite = None
        discovery_error = traceback.format_exc()
        print(discovery_error, file=sys.stderr)
    discovered = suite.countTestCases() if suite is not None else None
    result = None
    if suite is not None:
        runner = unittest.TextTestRunner(verbosity=2, resultclass=DiagnosticsTestResult)
        result = runner.run(suite)

    allowed_reasons = set(args.allow_skip)
    skips = [{'id': _test_id(test), 'reason': reason, 'allowed': reason in allowed_reasons}
             for test, reason in (result.skipped if result else [])]
    disallowed = [entry['id'] for entry in skips if not entry['allowed']]
    executed = result.executed if result else None

    failure_reasons = []
    if discovery_error is not None:
        failure_reasons.append('Test discovery failed under {}'.format(start))
    if result is not None:
        if result.failures:
            failure_reasons.append('{} test failure(s)'.format(len(result.failures)))
        if result.errors:
            failure_reasons.append('{} test error(s)'.format(len(result.errors)))
        if result.unexpectedSuccesses:
            failure_reasons.append('{} unexpected success(es)'.format(len(result.unexpectedSuccesses)))
        if disallowed:
            failure_reasons.append('{} skipped test(s) without an allowed reason: {}'.format(
                len(disallowed), ', '.join(disallowed)))
        if discovered == 0:
            failure_reasons.append('No tests discovered under {} matching {!r}'.format(start, args.pattern))
        elif executed == 0:
            failure_reasons.append('No test methods executed: all {} discovered test(s) were '
                                   'skipped or fixture errors prevented execution'.format(discovered))

    report = {
        'result': 'failed' if failure_reasons else 'passed',
        'start_directory': str(start),
        'pattern': args.pattern,
        'discovered': discovered,
        'tests_run': result.testsRun if result else None,
        'executed': executed,
        'failures': _outcome_entries(result.failures) if result else [],
        'errors': (_outcome_entries(result.errors) if result else []) +
                  ([{'id': 'discovery', 'traceback': discovery_error}] if discovery_error else []),
        'expected_failures': len(result.expectedFailures) if result else 0,
        'unexpected_successes': [_test_id(test) for test in result.unexpectedSuccesses] if result else [],
        'skipped': skips,
        'allowed_skip_reasons': sorted(allowed_reasons),
        'failure_reasons': failure_reasons,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    if failure_reasons:
        print('SOURCE TESTS FAILED: ' + '; '.join(failure_reasons), file=sys.stderr)
    else:
        print('Source tests passed: {} executed, {} skipped, report at {}'.format(
            executed, len(skips), args.output))
    return 1 if failure_reasons else 0


if __name__ == '__main__':
    sys.exit(main())
