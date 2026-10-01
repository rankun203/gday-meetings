"""Run one local input with immutable, fingerprinted results outside the worktree."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid

from private_paths import private_output

ROOT = Path(__file__).resolve().parent
MAX_SECONDS = 7 * 24 * 60 * 60


def seconds(value, *, allow_zero=False):
    number = float(value)
    if not math.isfinite(number) or number > MAX_SECONDS or number < 0 or (number == 0 and not allow_zero):
        raise argparse.ArgumentTypeError("Seconds must be finite and within seven days" +
                                         (" (zero is allowed)" if allow_zero else " and greater than zero"))
    return number


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--manifest", type=Path, required=True)
    result.add_argument("--output-directory", type=Path, required=True)
    result.add_argument("--sample", choices=list("ABCD"), required=True)
    result.add_argument("--model", choices=["nemotron", "community1"], required=True)
    result.add_argument("--mode", choices=["offline", "replay"], required=True)
    result.add_argument("--paced", action="store_true")
    result.add_argument("--max-seconds", type=seconds)
    result.add_argument("--offset-seconds", type=lambda value: seconds(value, allow_zero=True))
    result.add_argument("--wall-limit-seconds", type=seconds, default=900.0)
    result.add_argument("--describe", action="store_true", help="Print the configuration without running inference")
    return result


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def prepare(args):
    if args.paced and args.mode != "replay":
        raise ValueError("Paced input requires replay mode")
    # Validate programmatic callers as well as argparse input.
    args.wall_limit_seconds = seconds(args.wall_limit_seconds)
    if args.max_seconds is not None:
        args.max_seconds = seconds(args.max_seconds)
    if args.offset_seconds is not None:
        args.offset_seconds = seconds(args.offset_seconds, allow_zero=True)
    output = private_output(args.output_directory)
    manifest = json.loads(args.manifest.read_text())
    if not manifest.get("preparationComplete"):
        raise ValueError("Input preparation is incomplete")
    sample = next(item for item in manifest["samples"] if item["id"] in [args.sample, "sample-" + args.sample])
    duration = seconds(sample["durationSeconds"])
    excerpt_policy = "explicit_offset" if args.offset_seconds is not None else "prefix"
    if args.offset_seconds is None:
        args.offset_seconds = 0.0
        references = Path(sample["referencePath"]) if sample.get("referencePath") else args.manifest.parent / "reference-intervals" / f"sample-{args.sample}.json"
        if args.paced and args.max_seconds is not None and references.exists():
            reference = json.loads(references.read_text())
            if reference["preparedAudioSHA256"] != sample["sha256"]:
                raise ValueError("Reference intervals belong to a different prepared input")
            width = args.max_seconds
            best = None
            for begin in range(0, max(1, int(sample["durationSeconds"] - width) + 1), 10):
                by_speaker = {}
                spans = []
                for item in reference["intervals"]:
                    left, right = max(begin, item["start"]), min(begin + width, item["end"])
                    if right > left:
                        by_speaker.setdefault(item["speaker"], []).append((left, right))
                        spans.append((left, right))
                covered = 0.0
                edge = float(begin)
                for left, right in sorted(spans):
                    covered += max(0, right - max(left, edge))
                    edge = max(edge, right)
                eligible = 0
                for speaker_spans in by_speaker.values():
                    speaker_covered, speaker_edge = 0.0, float(begin)
                    for left, right in sorted(speaker_spans):
                        speaker_covered += max(0, right - max(left, speaker_edge))
                        speaker_edge = max(speaker_edge, right)
                    eligible += speaker_covered >= 2
                score = (eligible, covered, -begin)
                if best is None or score > best[0]:
                    best = (score, begin)
            args.offset_seconds = float(best[1])
            excerpt_policy = "existing_label_diversity_then_annotated_coverage_not_ground_truth"

    if args.offset_seconds >= duration:
        raise ValueError("Offset must be before the end of the input")
    audio = Path(sample["audioPath"]).resolve()
    input_hash = sha256(audio)
    if input_hash != sample["sha256"]:
        raise ValueError("Prepared input hash does not match its manifest")
    product, model_name = (("NemotronBenchmark", "low") if args.model == "nemotron"
                           else ("Community1Benchmark", "community1"))
    binary = ROOT / ".build" / "release" / product
    model_dir = ROOT / ".models" / model_name
    model_manifest = json.loads((model_dir / "manifest.json").read_text())
    model_files = [{"path": path.relative_to(model_dir).as_posix(), "sha256": sha256(path)}
                   for path in sorted(model_dir.rglob("*")) if path.is_file()]
    config = {
        "schema": 2, "sample": args.sample, "model": args.model,
        "binary_sha256": sha256(binary), "input_sha256": input_hash,
        "model_revision": model_manifest["revision"], "model_files": model_files,
        "runner_sha256": sha256(Path(__file__)),
        "suite_sha256": sha256(ROOT / "run_suite.py"),
        "mode": args.mode, "paced": args.paced, "max_seconds": args.max_seconds,
        "offset_seconds": args.offset_seconds, "wall_limit_seconds": args.wall_limit_seconds,
        "outer_timeout_seconds": args.wall_limit_seconds + 180,
        "nice": 10, "full_input_seconds": duration, "excerpt_selection": excerpt_policy,
    }
    fingerprint = hashlib.sha256(canonical(config).encode()).hexdigest()
    name = (f"{args.sample}-{args.model}-{args.mode}-"
            f"{'paced' if args.paced else 'accelerated'}-offset-{args.offset_seconds:g}s-"
            f"{fingerprint}")
    return {"config": config, "fingerprint": fingerprint, "name": name,
            "output": output, "audio": audio, "binary": binary, "model_dir": model_dir}


def successful_match(plan):
    """Reuse only exact configurations whose immutable artifacts still match."""
    for record in sorted(plan["output"].glob(plan["name"] + "-*/run.json")):
        try:
            value = json.loads(record.read_text())
            if (value.get("fingerprint") != plan["fingerprint"] or
                    value.get("config") != plan["config"] or value.get("returncode") != 0 or
                    value.get("status") != "completed" or not value.get("duration_validated")):
                continue
            artifacts = value["artifacts"]
            names = ("stdout.jsonl", "stderr.log", "segments.jsonl")
            if all(sha256(record.parent / name) == artifacts[name] for name in names):
                return record
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return None


class Cancelled(Exception):
    def __init__(self, signum):
        self.signum = signum
        super().__init__(f"Cancelled by signal {signum}")


@contextmanager
def cancellation_signals():
    def cancel(signum, frame):
        raise Cancelled(signum)
    previous = {sig: signal.signal(sig, cancel) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        yield
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def terminate_group(process, grace=2.0):
    """Only signal the new session created for this child, including descendants."""
    previous = {sig: signal.signal(sig, signal.SIG_IGN)
                for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            process.wait(timeout=grace)
            return
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            process.poll()  # Reap the leader; descendants may still own the group.
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.025)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=grace)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def run_owned(command, stdout, stderr, timeout):
    process = None
    # The parent removes raw PCM even when Swift cannot run its defer blocks.
    with tempfile.TemporaryDirectory(prefix="gday-diarization-run-") as temporary:
        environment = dict(os.environ, TMPDIR=temporary, TMP=temporary, TEMP=temporary)
        with cancellation_signals():
            try:
                # Defer cancellation until the new group has an owner to clean it up.
                pending = []
                handlers = {sig: signal.signal(sig, lambda signum, frame: pending.append(signum))
                            for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
                try:
                    process = subprocess.Popen(command, stdout=stdout, stderr=stderr,
                                               env=environment, start_new_session=True)
                finally:
                    for sig, handler in handlers.items():
                        signal.signal(sig, handler)
                if pending:
                    raise Cancelled(pending[0])
                return process.wait(timeout=timeout)
            finally:
                if process is not None:
                    terminate_group(process)


def execute(plan, args):
    previous = successful_match(plan)
    if previous:
        print(json.dumps({"status": "reused_exact_match", "record": str(previous),
                          "fingerprint": plan["fingerprint"]}), flush=True)
        return 0
    plan["output"].mkdir(parents=True, exist_ok=True)
    attempt = plan["output"] / (plan["name"] + "-" + uuid.uuid4().hex)
    attempt.mkdir(mode=0o700)  # Never overwrite an earlier attempt or legacy record.
    command = ["/usr/bin/nice", "-n", "10", "/usr/bin/time", "-l",
               str(plan["binary"]), str(plan["model_dir"]),
               "--audio", str(plan["audio"]), "--mode", args.mode,
               "--offset-seconds", str(args.offset_seconds),
               "--wall-limit-seconds", str(args.wall_limit_seconds),
               "--segments-output", str(attempt / "segments.jsonl")]
    if args.paced:
        command.append("--paced")
    if args.max_seconds is not None:
        command += ["--max-seconds", str(args.max_seconds)]
    start = time.monotonic()
    status, returncode, duration_validated = "failed", 1, False
    try:
        with (attempt / "stdout.jsonl").open("x") as stdout, (attempt / "stderr.log").open("x") as stderr:
            returncode = run_owned(command, stdout, stderr, args.wall_limit_seconds + 180)
        if returncode == 0:
            records = [json.loads(line) for line in (attempt / "stdout.jsonl").read_text().splitlines()]
            final = next((record for record in reversed(records)
                          if record.get("phase") in ["file", "file_offline", "replay_summary"]), None)
            expected = plan["config"]["full_input_seconds"] - args.offset_seconds
            if args.max_seconds is not None:
                expected = min(expected, args.max_seconds)
            duration_validated = (final is not None and
                                  abs(final["audio_seconds"] - expected) <= 1 / 16000)
            status = "completed" if duration_validated else "duration_validation_failed"
            if not duration_validated:
                returncode = 1
    except subprocess.TimeoutExpired:
        status, returncode = "timeout", 124
    except Cancelled as error:
        status, returncode = "cancelled", 128 + error.signum
    except (Exception, KeyboardInterrupt) as error:
        # Avoid serializing exception messages that may contain source paths.
        status, returncode = "runner_error_" + type(error).__name__, 1
    finally:
        artifacts = {name: sha256(attempt / name)
                     for name in ("stdout.jsonl", "stderr.log", "segments.jsonl")
                     if (attempt / name).is_file()}
        metadata = {"fingerprint": plan["fingerprint"], "config": plan["config"],
                    "duration_validated": duration_validated, "artifacts": artifacts,
                    "wall_seconds_including_load": time.monotonic() - start,
                    "returncode": returncode, "status": status,
                    "existing_labels_are_ground_truth": False}
        (attempt / "run.json").write_text(json.dumps(metadata, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"status": status, "returncode": returncode,
                      "fingerprint": plan["fingerprint"], "record": str(attempt / "run.json")}), flush=True)
    return returncode if returncode > 0 else (1 if returncode else 0)


def main():
    arguments = parser()
    args = arguments.parse_args()
    try:
        plan = prepare(args)
    except (ValueError, OSError, KeyError, StopIteration, argparse.ArgumentTypeError) as error:
        arguments.error(f"Cannot prepare the run ({type(error).__name__}). Check options and local input/model files.")
    if args.describe:
        print(canonical({"fingerprint": plan["fingerprint"], "config": plan["config"], "name": plan["name"]}))
        return 0
    return execute(plan, args)


if __name__ == "__main__":
    raise SystemExit(main())
