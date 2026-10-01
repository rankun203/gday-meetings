"""Synthetic runner regressions; no models, recordings, or inference required."""
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
sys.dont_write_bytecode = True

SOURCE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE))
import run_private as runner
import run_suite as suite


@unittest.skipUnless(os.name == "posix", "Process-group tests require POSIX signals")
class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fake-diarization-tests-')
        self.base = Path(self.temp.name)
        self.root = self.base / 'checkout' / 'experiments' / 'benchmark'
        self.root.mkdir(parents=True)
        self.previous_root = runner.ROOT
        runner.ROOT = self.root
        (self.root / 'run_suite.py').write_text('synthetic runner revision\n')
        model = self.root / '.models' / 'low'
        model.mkdir(parents=True)
        (model / 'manifest.json').write_text(json.dumps({'revision': 'synthetic-revision'}))
        (model / 'weights.bin').write_bytes(b'synthetic weights')
        binary = self.root / '.build' / 'release' / 'NemotronBenchmark'
        binary.parent.mkdir(parents=True)
        binary.write_text('#!' + sys.executable + '\n' + '''import json, os, sys
from pathlib import Path
args=sys.argv
Path(os.environ['TMPDIR'], 'synthetic.raw').write_bytes(b'fake audio')
Path(args[args.index('--segments-output')+1]).write_text('')
offset=float(args[args.index('--offset-seconds')+1])
seconds=min(10-offset,float(args[args.index('--max-seconds')+1])) if '--max-seconds' in args else 10-offset
print(json.dumps({'phase':'file','audio_seconds':seconds}))
''')
        binary.chmod(0o700)
        audio = self.base / 'synthetic.wav'
        audio.write_bytes(b'not real audio')
        self.manifest = self.base / 'manifest.json'
        self.manifest.write_text(json.dumps({'preparationComplete':True,'samples':[
            {'id':'A','durationSeconds':10,'audioPath':str(audio),'sha256':runner.sha256(audio)}]}))
        self.output = self.base / 'results'

    def tearDown(self):
        runner.ROOT = self.previous_root
        self.temp.cleanup()

    def args(self, extra=()):
        return runner.parser().parse_args(['--manifest', str(self.manifest), '--output-directory',
            str(self.output), '--sample','A','--model','nemotron','--mode','offline',*extra])

    def test_manifest_reference_path_selects_paced_excerpt(self):
        manifest = json.loads(self.manifest.read_text())
        manifest['samples'][0]['durationSeconds'] = 30
        reference = self.base / 'explicit-reference.json'
        reference.write_text(json.dumps({
            'preparedAudioSHA256': manifest['samples'][0]['sha256'],
            'intervals': [dict(start=10, end=15, speaker='a'),
                          dict(start=15, end=20, speaker='b')]}))
        manifest['samples'][0]['referencePath'] = str(reference)
        self.manifest.write_text(json.dumps(manifest))
        args = self.args(['--mode', 'replay', '--paced', '--max-seconds', '10'])
        plan = runner.prepare(args)
        self.assertEqual(plan['config']['offset_seconds'], 10)
        reference.write_text(json.dumps({'preparedAudioSHA256': 'wrong', 'intervals': []}))
        with self.assertRaises(ValueError):
            runner.prepare(self.args(['--mode', 'replay', '--paced', '--max-seconds', '10']))

    def test_numeric_validation(self):
        for flag in ['--max-seconds','--offset-seconds','--wall-limit-seconds']:
            for value in ['nan','inf','-inf','garbage','-1','1e300']:
                with self.subTest(flag=flag,value=value), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit): self.args([flag,value])
        for flag in ['--max-seconds','--wall-limit-seconds']:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit): self.args([flag,'0'])
        self.assertEqual(self.args(['--offset-seconds','0']).offset_seconds,0)
        with self.assertRaises(ValueError): runner.prepare(self.args(['--offset-seconds','10']))
        with self.assertRaises(ValueError): runner.prepare(self.args(['--paced']))

    def test_fingerprint_inputs_options_models_binary(self):
        original=runner.prepare(self.args())['fingerprint']
        for options in [['--offset-seconds','1'],['--max-seconds','2'],['--wall-limit-seconds','3'],
                        ['--mode','replay'],['--mode','replay','--paced']]:
            self.assertNotEqual(original,runner.prepare(self.args(options))['fingerprint'])
        for path in [self.root/'.models/low/weights.bin',self.root/'.models/low/manifest.json',
                     self.root/'.build/release/NemotronBenchmark',self.root/'run_suite.py']:
            content=path.read_bytes()
            path.write_bytes(content+b' ')
            self.assertNotEqual(original,runner.prepare(self.args())['fingerprint'])
            path.write_bytes(content)
        data=json.loads(self.manifest.read_text())
        audio=Path(data['samples'][0]['audioPath'])
        audio.write_bytes(b'different synthetic audio')
        with self.assertRaises(ValueError): runner.prepare(self.args())
        data['samples'][0]['sha256']=runner.sha256(audio)
        self.manifest.write_text(json.dumps(data))
        self.assertNotEqual(original,runner.prepare(self.args())['fingerprint'])

    def test_success_reuse_tamper_and_immutable_attempts(self):
        run_owned = runner.run_owned

        def run_fake(command, stdout, stderr, timeout):
            self.assertEqual(command[:5], ["/usr/bin/nice", "-n", "10", "/usr/bin/time", "-l"])
            return run_owned(command[5:], stdout, stderr, timeout)

        with mock.patch.object(runner, "run_owned", side_effect=run_fake):
            self.check_success_reuse_tamper_and_immutable_attempts()

    def check_success_reuse_tamper_and_immutable_attempts(self):
        args=self.args(); plan=runner.prepare(args)
        with contextlib.redirect_stdout(io.StringIO()): self.assertEqual(runner.execute(plan,args),0)
        match=runner.successful_match(plan)
        self.assertIsNotNone(match)
        before={p:p.read_bytes() for p in match.parent.iterdir()}
        with contextlib.redirect_stdout(io.StringIO()): self.assertEqual(runner.execute(plan,args),0)
        self.assertEqual(len(list(self.output.iterdir())),1)
        for p,content in before.items(): self.assertEqual(p.read_bytes(),content)
        (match.parent/'segments.jsonl').write_text('tampered')
        self.assertIsNone(runner.successful_match(plan))
        with contextlib.redirect_stdout(io.StringIO()): self.assertEqual(runner.execute(plan,args),0)
        self.assertEqual(len(list(self.output.iterdir())),2)
        self.assertEqual((match.parent/'segments.jsonl').read_text(),'tampered')
        args2=self.args(['--offset-seconds','1']); plan2=runner.prepare(args2)
        self.assertIn('offset-1s',plan2['name'])
        with contextlib.redirect_stdout(io.StringIO()): self.assertEqual(runner.execute(plan2,args2),0)
        self.assertEqual(len(list(self.output.iterdir())),3)

    def test_legacy_records_remain_historical(self):
        self.output.mkdir()
        legacy=self.output/'A-nemotron-offline-accelerated.run.json'
        legacy.write_text(json.dumps({'sample':'A','model':'nemotron','mode':'offline','paced':False,'returncode':0}))
        content=legacy.read_bytes()
        plan=runner.prepare(self.args())
        self.assertIsNone(runner.successful_match(plan))
        self.assertEqual(suite.historical_successes(plan),[str(legacy.resolve())])
        self.assertEqual(legacy.read_bytes(),content)

    def test_suite_plan_and_historical_execution_gate(self):
        self.output.mkdir()
        legacy=self.output/'legacy.run.json'
        legacy.write_text(json.dumps({'sample':'A','model':'nemotron','mode':'offline','paced':False,'returncode':0}))
        plan=runner.prepare(self.args())
        argv=['run_suite.py','--manifest',str(self.manifest),'--output-directory',str(self.output)]
        with mock.patch.object(runner,'prepare',return_value=plan), mock.patch.object(runner,'execute',return_value=0) as execute:
            with mock.patch.object(sys,'argv',argv), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(suite.main(),0)
            execute.assert_not_called()
            with mock.patch.object(sys,'argv',argv+['--execute']), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(suite.main(),1)
            execute.assert_not_called()
            with mock.patch.object(sys,'argv',argv+['--execute','--rerun-historical']), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(suite.main(),0)
            self.assertEqual(execute.call_count,16)
            execute.reset_mock(); execute.return_value=143
            with mock.patch.object(sys,'argv',argv+['--execute','--rerun-historical']), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(suite.main(),1)
            self.assertEqual(execute.call_count,1)

    def test_spawn_failure_cleanup(self):
        prior=set(Path(tempfile.gettempdir()).glob('gday-diarization-run-*'))
        with open(os.devnull,'w') as sink, self.assertRaises(FileNotFoundError):
            runner.run_owned(['/nonexistent-synthetic-executable'],sink,sink,1)
        self.assertEqual(prior,set(Path(tempfile.gettempdir()).glob('gday-diarization-run-*')))

    def process_case(self, cancel=None):
        marker=self.base/'child.json'
        child=self.base/'child.py'
        child.write_text('''import json, os, signal, time, sys
from pathlib import Path
signal.signal(signal.SIGTERM,signal.SIG_IGN)
raw=Path(os.environ['TMPDIR'])/'synthetic.raw'
raw.write_bytes(b'fake audio')
pid=os.fork()
if pid==0:
    while True: time.sleep(1)
Path(sys.argv[1]).write_text(json.dumps({'parent':os.getpid(),'child':pid,'tmp':str(raw.parent)}))
while True: time.sleep(1)
''')
        wrapper=self.base/'wrapper.py'
        wrapper.write_text('''import sys, subprocess, os
sys.dont_write_bytecode=True
sys.path.insert(0,sys.argv[1])
import run_private as runner
try:
    with open(os.devnull,'w') as sink:
        runner.run_owned([sys.executable,sys.argv[2],sys.argv[3]],sink,sink,float(sys.argv[4]))
except runner.Cancelled as error: sys.exit(128+error.signum)
except subprocess.TimeoutExpired: sys.exit(124)
''')
        # Unrelated process must survive group cleanup.
        unrelated=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'])
        info=None
        start=time.monotonic()
        process=subprocess.Popen([sys.executable,str(wrapper),str(SOURCE),str(child),str(marker),
                                  '30' if cancel else '0.3'])
        try:
            deadline=time.monotonic()+5
            while not marker.exists() and time.monotonic()<deadline: time.sleep(.01)
            self.assertTrue(marker.exists())
            info=json.loads(marker.read_text())
            if cancel: process.send_signal(cancel)
            self.assertEqual(process.wait(timeout=8),128+cancel if cancel else 124)
            self.assertLess(time.monotonic()-start,7)
            self.assertFalse(Path(info['tmp']).exists())
            for key in ['parent','child']:
                state=subprocess.run(['ps','-o','stat=','-p',str(info[key])],capture_output=True,text=True).stdout.strip()
                self.assertTrue(not state or state.startswith('Z'),(key,state))
            self.assertIsNone(unrelated.poll())
        finally:
            # Clean up only this test's child group even if a regression fails an assertion.
            if info is not None:
                try: os.killpg(info['parent'], signal.SIGKILL)
                except ProcessLookupError: pass
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            unrelated.terminate()
            unrelated.wait(timeout=5)

    def test_timeout_owned_group_and_pcm_cleanup(self): self.process_case()
    def test_sigterm_owned_group_and_pcm_cleanup(self): self.process_case(signal.SIGTERM)
    def test_sigint_owned_group_and_pcm_cleanup(self): self.process_case(signal.SIGINT)
    def test_sighup_owned_group_and_pcm_cleanup(self): self.process_case(signal.SIGHUP)


if __name__=='__main__': unittest.main(verbosity=2)
