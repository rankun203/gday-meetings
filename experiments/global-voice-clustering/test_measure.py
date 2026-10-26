"""Synthetic resource-monitor checks; no meeting-library inputs."""
import importlib.util
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from types import SimpleNamespace

SCRIPT = Path(__file__).with_name('measure.py')
spec = importlib.util.spec_from_file_location('measure', SCRIPT)
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


class MeasurementTests(unittest.TestCase):
    def command(self, root, code, name='receipt'):
        return [sys.executable, str(SCRIPT), '--output', str(root / f'{name}.json'),
                '--stage', 'synthetic', '--interval', '0.02', '--stdout-log', str(root / f'{name}.log'),
                '--directory', str(root / 'outputs'), '--', sys.executable, '-c', code]

    def test_child_work_disk_growth_and_log(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'outputs').mkdir()
            child = ('import time; data=bytearray(16*1024*1024); '
                     'end=time.monotonic()+0.2\nwhile time.monotonic()<end: pass\ntime.sleep(0.15)')
            code = (f'import subprocess, sys; from pathlib import Path; '
                    f'subprocess.run([sys.executable,"-c",{child!r}],check=True); '
                    f'Path({str(root / "outputs" / "generated")!r}).write_bytes(b"x"*4096); print("complete")')
            completed = subprocess.run(self.command(root, code), capture_output=True, text=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            receipt = json.loads((root / 'receipt.json').read_text())
            self.assertEqual(receipt['status'], 'completed')
            self.assertEqual(receipt['exit_status'], 0)
            self.assertGreater(receipt['wall_seconds'], .3)
            self.assertEqual(receipt['directory_growth_bytes'], 4096)
            self.assertIn('complete', (root / 'receipt.log').read_text())
            self.assertGreater(receipt['cpu_and_process_peak']['user_seconds'], .05)
            self.assertGreater(receipt['cpu_and_process_peak']['peak_rss_bytes'], 16 * 1024 * 1024)
            sampled = receipt['sampled_process_tree']
            if sampled['complete_memory_samples']:
                self.assertGreater(sampled['peak_rss_bytes'], 0)
            else:
                self.assertIsNone(sampled['peak_rss_bytes'])
                self.assertTrue(sampled['errors'] or sampled['source'] is None)

    def test_failure_and_retry_preserve_attempt(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'outputs').mkdir()
            command = self.command(root, 'raise SystemExit(7)')
            first = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(first.returncode, 7)
            original = (root / 'receipt.json').read_bytes()
            self.assertEqual(json.loads(original)['status'], 'failed')
            repeated = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(repeated.returncode, 0)
            self.assertEqual((root / 'receipt.json').read_bytes(), original)
            retry = subprocess.run(self.command(root, 'print("retry")', name='retry'), capture_output=True)
            self.assertEqual(retry.returncode, 0)

    def test_interruption_records_signal(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'outputs').mkdir()
            process = subprocess.Popen(self.command(root, 'import time; print("ready",flush=True); time.sleep(30)'),
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                log = root / 'receipt.log'
                if log.exists() and 'ready' in log.read_text():
                    break
                time.sleep(.02)
            else:
                process.kill()
                process.communicate()
                self.fail('Synthetic command did not become ready.')
            process.send_signal(signal.SIGTERM)
            _, error = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM, error)
            receipt = json.loads((root / 'receipt.json').read_text())
            self.assertEqual(receipt['status'], 'interrupted')
            self.assertEqual(receipt['interrupt_signals'], [signal.SIGTERM])


    def test_memory_permission_failure_still_waits_for_command(self):
        if measure.psutil is None:
            self.skipTest('psutil is unavailable')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            args = SimpleNamespace(output=str(root / 'receipt.json'), stage='denied',
                command=[sys.executable, '-c', 'import time; time.sleep(.1); print("complete")'],
                directory=None, stdout_log=str(root / 'receipt.log'), interval=.01)
            with mock.patch.object(measure.psutil, 'Process', side_effect=PermissionError('synthetic denial')):
                self.assertEqual(measure.run(args), 0)
            receipt = json.loads((root / 'receipt.json').read_text())
            self.assertEqual(receipt['status'], 'completed')
            self.assertIsNone(receipt['sampled_process_tree']['peak_rss_bytes'])
            self.assertTrue(receipt['sampled_process_tree']['errors'])
            self.assertIsNotNone(receipt['cpu_and_process_peak']['user_seconds'])
            self.assertIn('complete', (root / 'receipt.log').read_text())

    def test_launch_failure_has_no_invented_metrics(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            args = SimpleNamespace(output=str(root / 'receipt.json'), stage='launch',
                command=[str(root / 'missing-command')], directory=None, stdout_log=None, interval=.01)
            self.assertEqual(measure.run(args), 1)
            receipt = json.loads((root / 'receipt.json').read_text())
            self.assertEqual(receipt['status'], 'failed')
            self.assertIn('launch_error', receipt)
            self.assertIsNone(receipt['exit_status'])
            for field in ['user_seconds', 'system_seconds', 'peak_rss_bytes']:
                self.assertIsNone(receipt['cpu_and_process_peak'][field])


if __name__ == '__main__':
    unittest.main()
