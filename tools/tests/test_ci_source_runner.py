# SPDX-License-Identifier: LGPL-2.1-or-later
"""Regression tests for scripts/ci/run-source-tests.py.

Each case drives the runner in a subprocess against synthetic unittest
fixtures in a temporary directory; the repository suite itself is never
discovered here.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / 'scripts/ci/run-source-tests.py'

PASSING = '''\
import unittest
class PassingTests(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(1 + 1, 2)
'''

FAILING = '''\
import unittest
class FailingTests(unittest.TestCase):
    def test_broken(self):
        self.assertEqual(1 + 1, 3)
'''

IMPORT_ERROR = '''\
import unittest
import totally_missing_ci_fixture_module
class NeverRuns(unittest.TestCase):
    def test_nothing(self):
        pass
'''

SETUP_CLASS_ERROR = '''\
import unittest
class SetupErrorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raise RuntimeError('synthetic setUpClass failure')
    def test_never(self):
        pass
'''

UNEXPECTED_SKIP = '''\
import unittest
class SkipTests(unittest.TestCase):
    @unittest.skip('uncovered environment gap')
    def test_skipped(self):
        pass
'''

SKIPPED_AND_PASSING = '''\
import unittest
class MixedTests(unittest.TestCase):
    @unittest.skip('documented limitation')
    def test_skipped(self):
        pass
    def test_ok(self):
        self.assertTrue(True)
'''

SETUP_CLASS_SKIP = '''\
import unittest
class FixtureSkipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raise unittest.SkipTest('fixture unavailable')
    def test_one(self):
        pass
    def test_two(self):
        pass
'''

SKIPPED_CLASS_AND_PASSING = '''\
import unittest
@unittest.skip('class gap')
class SkippedTests(unittest.TestCase):
    def test_skip_a(self):
        pass
    def test_skip_b(self):
        pass
class PassingTests(unittest.TestCase):
    def test_ok(self):
        self.assertTrue(True)
'''

SUBTEST_SKIPS = '''\
import unittest
class SubtestSkipTests(unittest.TestCase):
    def test_values(self):
        for index in range(3):
            with self.subTest(index=index):
                if index < 2:
                    self.skipTest('subtest gap')
                self.assertTrue(True)
'''

MODULE_SKIP = '''\
import unittest
raise unittest.SkipTest('module unavailable')
class NeverRuns(unittest.TestCase):
    def test_nothing(self):
        pass
'''

UNEXPECTED_SUCCESS = '''\
import unittest
class UnexpectedSuccessTests(unittest.TestCase):
    @unittest.expectedFailure
    def test_now_passes(self):
        self.assertTrue(True)
'''

SUBTEST_FAILURE = '''\
import unittest
class SubtestTests(unittest.TestCase):
    def test_values(self):
        for index in range(4):
            with self.subTest(index=index):
                self.assertLess(index, 2)
'''

CALLED_PROCESS_ERROR = '''\
import subprocess
import unittest
class CommandTests(unittest.TestCase):
    def test_probe(self):
        raise subprocess.CalledProcessError(7, 'probe', output=b'magic-stdout',
                                            stderr=b'magic-stderr')
'''

TIMEOUT_EXPIRED = '''\
import subprocess
import unittest
class TimeoutTests(unittest.TestCase):
    def test_probe(self):
        raise subprocess.TimeoutExpired('probe', 5, output=b'timeout-stdout',
                                        stderr=b'timeout-stderr')
'''


class SourceTestRunnerTests(unittest.TestCase):
    def run_suite(self, files, extra_args=()):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        for name, content in files.items():
            (root / name).write_text(content)
        output = root / 'report.json'
        completed = subprocess.run([sys.executable, str(RUNNER), '--start-directory', str(root),
                                    '--output', str(output), *extra_args],
                                   capture_output=True, text=True, timeout=60)
        report = json.loads(output.read_text()) if output.is_file() else None
        return completed, report

    def test_passing_suite(self):
        completed, report = self.run_suite({'test_ok.py': PASSING})
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(report['result'], 'passed')
        self.assertEqual(report['executed'], 1)
        self.assertEqual(report['failures'], [])
        self.assertEqual(report['errors'], [])

    def test_assertion_failure_fails_with_id(self):
        completed, report = self.run_suite({'test_bad.py': FAILING})
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(report['result'], 'failed')
        self.assertEqual(len(report['failures']), 1)
        self.assertIn('test_broken', report['failures'][0]['id'])
        self.assertTrue(any('failure' in reason for reason in report['failure_reasons']))

    def test_import_error_reported(self):
        completed, report = self.run_suite({'test_broken_import.py': IMPORT_ERROR})
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(len(report['errors']), 1)
        self.assertIn('totally_missing_ci_fixture_module', report['errors'][0]['traceback'])

    def test_setup_class_error_reported_without_tests_run(self):
        completed, report = self.run_suite({'test_setup.py': SETUP_CLASS_ERROR})
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(len(report['errors']), 1)
        self.assertIn('synthetic setUpClass failure', report['errors'][0]['traceback'])
        self.assertEqual(report['tests_run'], 0)

    def test_empty_discovery_fails_with_explanation(self):
        completed, report = self.run_suite({'helper.py': PASSING})
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(report['discovered'], 0)
        self.assertTrue(any('No tests discovered' in reason for reason in report['failure_reasons']))
        self.assertIn('No tests discovered', completed.stderr)

    def test_unexpected_skip_reason_fails(self):
        completed, report = self.run_suite({'test_skip.py': UNEXPECTED_SKIP})
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(report['skipped'][0]['reason'], 'uncovered environment gap')
        self.assertFalse(report['skipped'][0]['allowed'])
        self.assertTrue(any('without an allowed reason' in reason for reason in report['failure_reasons']))

    def test_allowed_skip_with_real_pass_succeeds(self):
        completed, report = self.run_suite({'test_mixed.py': SKIPPED_AND_PASSING},
                                           ['--allow-skip', 'documented limitation'])
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(report['result'], 'passed')
        self.assertEqual(report['executed'], 1)
        self.assertTrue(report['skipped'][0]['allowed'])

    def test_allowed_skip_does_not_cover_other_reasons(self):
        completed, report = self.run_suite(
            {'test_mixed.py': SKIPPED_AND_PASSING},
            ['--allow-skip', 'a different documented limitation'])
        self.assertNotEqual(completed.returncode, 0)

    def test_all_skipped_suite_fails_even_when_allowed(self):
        completed, report = self.run_suite({'test_skip.py': UNEXPECTED_SKIP},
                                           ['--allow-skip', 'uncovered environment gap'])
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(report['executed'], 0)
        self.assertTrue(any('No test methods executed' in reason
                            for reason in report['failure_reasons']))

    def test_allowed_setup_class_skip_fails_without_execution(self):
        completed, report = self.run_suite({'test_setup_skip.py': SETUP_CLASS_SKIP},
                                           ['--allow-skip', 'fixture unavailable'])
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(report['executed'], 0)
        self.assertTrue(any('No test methods executed' in reason
                            for reason in report['failure_reasons']))

    def test_allowed_skipped_class_with_passing_class_succeeds(self):
        completed, report = self.run_suite({'test_classes.py': SKIPPED_CLASS_AND_PASSING},
                                           ['--allow-skip', 'class gap'])
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(report['result'], 'passed')
        self.assertEqual(report['executed'], 1)

    def test_allowed_skipped_subtests_with_passing_subtest_succeeds(self):
        completed, report = self.run_suite({'test_subtest_skips.py': SUBTEST_SKIPS},
                                           ['--allow-skip', 'subtest gap'])
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(report['result'], 'passed')
        self.assertEqual(report['executed'], 1)

    def test_module_level_skip_alone_fails_without_execution(self):
        completed, report = self.run_suite({'test_module_skip.py': MODULE_SKIP})
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(report['executed'], 0)

    def test_missing_start_directory_reports_discovery_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            missing = Path(temp) / 'no-such-dir'
            output = Path(temp) / 'report.json'
            completed = subprocess.run([sys.executable, str(RUNNER), '--start-directory',
                                        str(missing), '--output', str(output)],
                                       capture_output=True, text=True, timeout=60)
            self.assertNotEqual(completed.returncode, 0)
            report = json.loads(output.read_text())
            self.assertEqual(report['result'], 'failed')
            self.assertEqual(report['errors'][0]['id'], 'discovery')
            self.assertIn('Traceback', report['errors'][0]['traceback'])
            self.assertTrue(any('discovery failed' in reason for reason in report['failure_reasons']))
            self.assertIn('Traceback', completed.stderr)

    def test_unexpected_success_fails(self):
        completed, report = self.run_suite({'test_unexpected.py': UNEXPECTED_SUCCESS})
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(len(report['unexpected_successes']), 1)
        self.assertTrue(any('unexpected success' in reason for reason in report['failure_reasons']))

    def test_failing_subtest_fails(self):
        completed, report = self.run_suite({'test_subtests.py': SUBTEST_FAILURE})
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(len(report['failures']), 2)
        self.assertIn('index=2', report['failures'][0]['id'])

    def test_called_process_error_carries_output(self):
        completed, report = self.run_suite({'test_command.py': CALLED_PROCESS_ERROR})
        self.assertNotEqual(completed.returncode, 0)
        traceback = report['errors'][0]['traceback']
        self.assertIn('magic-stdout', traceback)
        self.assertIn('magic-stderr', traceback)
        self.assertIn('magic-stderr', completed.stderr)

    def test_timeout_expired_carries_output(self):
        completed, report = self.run_suite({'test_timeout.py': TIMEOUT_EXPIRED})
        self.assertNotEqual(completed.returncode, 0)
        traceback = report['errors'][0]['traceback']
        self.assertIn('timeout-stdout', traceback)
        self.assertIn('timeout-stderr', traceback)
        self.assertIn('Timed out after', traceback)
        self.assertIn('timeout-stderr', completed.stderr)


if __name__ == '__main__':
    unittest.main()
