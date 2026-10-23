#!/usr/bin/env python3
"""Prepare independent local audio fixtures, run native providers, and build a blind review page."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import signal
import subprocess
import time
import wave

PROVIDERS = ("apple", "nemotron", "whisper")
ID = re.compile(r"^[a-z][a-z0-9_-]{0,39}$")


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def write_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def safe_id(value: str) -> str:
    if not ID.fullmatch(value):
        raise ValueError("Fixture and track IDs must be short generic identifiers")
    return value


def private_output(path: Path) -> Path:
    path = path.resolve()
    repository = Path(__file__).resolve().parents[2]
    if path.is_relative_to(repository / "tmp"):
        return path
    raise ValueError("Private artifacts must stay under this repository's ignored tmp/ directory")


def prepare(config: dict, root: Path) -> dict:
    """Copy independent audio first; normalize once so all providers receive identical PCM."""
    if root.exists():
        raise ValueError("Preserve the existing fixture: choose a new output directory")
    sources = []
    seen = set()
    for fixture in config["fixtures"]:
        fixture_id = safe_id(fixture["id"])
        if fixture_id in seen:
            raise ValueError("Duplicate fixture ID")
        seen.add(fixture_id)
        track_ids = set()
        for track in fixture["tracks"]:
            track_id = safe_id(track["id"])
            if track_id in track_ids:
                raise ValueError("Duplicate track ID")
            track_ids.add(track_id)
            source = Path(track["source"])
            if not source.is_file() or source.is_symlink():
                raise ValueError("Source must be an independent regular audio file")
            sources.append((fixture, track, source, source.stat(), digest(source)))
    root.mkdir(parents=True, mode=0o700)
    tracks = []
    for fixture, track, source, prior, original_hash in sources:
        folder = root / "audio" / fixture["id"]
        folder.mkdir(parents=True, exist_ok=True)
        original = folder / (track["id"] + "-original" + source.suffix.lower())
        shutil.copyfile(source, original)
        original.chmod(0o600)
        if original.stat().st_ino == source.stat().st_ino or digest(original) != original_hash:
            raise ValueError("Independent copy verification failed")
        pcm = folder / (track["id"] + ".wav")
        tick = time.perf_counter()
        completed = subprocess.run([config.get("ffmpeg", "ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error",
                                    "-i", str(original), "-map", "0:a:0", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(pcm)],
                                   capture_output=True, text=True)
        if completed.returncode:
            raise RuntimeError("Audio normalization failed: " + completed.stderr)
        with wave.open(str(pcm), "rb") as audio:
            if (audio.getnchannels(), audio.getframerate(), audio.getsampwidth()) != (1, 16000, 2):
                raise ValueError("Unexpected normalized PCM format")
            duration = audio.getnframes() / audio.getframerate()
        tracks.append({"fixture": fixture["id"], "label": fixture.get("label", fixture["id"]),
                       "track": track["id"], "language": fixture["language"],
                       "original": str(original.relative_to(root)), "audio": str(pcm.relative_to(root)),
                       "sourceSHA256": original_hash, "pcmSHA256": digest(pcm), "durationSeconds": duration,
                       "preparationSeconds": time.perf_counter() - tick})
    for _, _, source, prior, expected in sources:
        current = source.stat()
        if (current.st_size, current.st_mtime_ns) != (prior.st_size, prior.st_mtime_ns) or digest(source) != expected:
            raise ValueError("Source audio changed during snapshot; discard this fixture and retry")
    manifest = {"schemaVersion": 1, "tracks": tracks,
                "preparation": "Independent originals, verified source hashes; shared mono16kHz PCM for all providers"}
    write_json(root / "manifest.json", manifest)
    return manifest


def validate_result(value: dict, provider: str, duration: float) -> None:
    if value.get("schemaVersion") != 1 or value.get("provider") != provider or value.get("status") != "completed":
        raise ValueError("Native result identity/status mismatch")
    previous = -1.
    for segment in value["segments"]:
        start, end = segment["start"], segment["end"]
        if not (isinstance(segment["text"], str) and 0 <= start <= end <= duration + 1 and start >= previous):
            raise ValueError("Invalid or unordered native transcript segments")
        previous = start


def run_process(command: list[str], log, timeout: float) -> int:
    """Cancel the entire native process group when a provider hangs."""
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        raise


def run(config: dict, root: Path, selected: list[str], repetitions: int,
        fixtures: list[str] | None = None, tracks: list[str] | None = None, iteration_start: int = 0) -> None:
    manifest = json.loads((root / "manifest.json").read_text())
    runner_hash = digest(Path(__file__))
    for track in manifest["tracks"]:
        if (fixtures and track["fixture"] not in fixtures) or (tracks and track["track"] not in tracks):
            continue
        audio = root / track["audio"]
        if digest(audio) != track["pcmSHA256"]:
            raise ValueError("Prepared audio changed")
        for provider in selected:
            settings = config["providers"][provider]
            folder = root / "results" / track["fixture"] / track["track"]
            folder.mkdir(parents=True, exist_ok=True)
            for iteration in range(iteration_start, iteration_start + repetitions):
                output = folder / f"{provider}-{iteration}.json"
                if output.exists():
                    raise ValueError("Result exists; preserve it and choose a separate experiment root")
                command = [settings["executable"], "--provider", provider, "--audio", str(audio),
                           "--language", track["language"], "--output", str(output), "--model-root", settings["modelRoot"]]
                if settings.get("modelRevision"):
                    command += ["--model-revision", settings["modelRevision"]]
                command += settings.get("arguments", [])
                pcm_before = digest(audio)
                executable_before = digest(Path(settings["executable"]))
                if pcm_before != track["pcmSHA256"]:
                    raise ValueError("Prepared audio changed before invocation")
                tick = time.perf_counter()
                load_before = os.getloadavg()
                timeout = float(settings.get("timeoutSeconds", config.get("timeoutSeconds", 3600)))
                if not 1 <= timeout <= 86400:
                    raise ValueError("Run timeout must be 1–86400 seconds")
                status, failure, exit_code = "failed", None, None
                with output.with_suffix(".log").open("w") as log:
                    try:
                        exit_code = run_process(["/usr/bin/time", "-l", *command], log, timeout)
                        if exit_code == 0 and output.exists():
                            try:
                                value = json.loads(output.read_text())
                                validate_result(value, provider, track["durationSeconds"])
                                status = "completed"
                            except (ValueError, KeyError, TypeError) as error:
                                failure = "Invalid native result: " + str(error)
                        else:
                            failure = "Provider failed; inspect the private run log"
                    except subprocess.TimeoutExpired:
                        status, failure = "timeout", "Provider exceeded its configured timeout"
                elapsed = time.perf_counter() - tick
                pcm_after = digest(audio)
                executable_after = digest(Path(settings["executable"]))
                invalidated = pcm_before != pcm_after or executable_before != executable_after
                if invalidated:
                    status, failure = "invalidated", "Audio or executable changed during invocation"
                receipt = {"provider": provider, "iteration": iteration, "status": status,
                           "elapsedSeconds": elapsed, "exitCode": exit_code,
                           "timeoutSeconds": timeout, "loadAverageBefore": load_before,
                           "loadAverageAfter": os.getloadavg(), "pcmSHA256": track["pcmSHA256"],
                           "executableSHA256": executable_before, "executableAfterSHA256": executable_after,
                           "pcmAfterSHA256": pcm_after, "runnerSHA256": runner_hash,
                           "modelRevision": settings.get("modelRevision"),
                           "configurationSHA256": hashlib.sha256(json.dumps(settings,sort_keys=True).encode()).hexdigest(),
                           "measurementScope": "Serial isolated process including native startup/model load; shared audio conversion excluded"}
                log_text = output.with_suffix(".log").read_text()
                rss = re.search(r"(\d+)\s+maximum resident set size", log_text)
                if rss:
                    receipt["clientProcessPeakRSSBytes"] = int(rss[1])
                if failure:
                    receipt["error"] = failure
                    if output.exists():
                        receipt["rawResultSHA256"] = digest(output)
                        output.replace(output.with_suffix(".raw.json"))
                    write_json(output, {"schemaVersion": 1, "provider": provider, "status": status,
                                        "segments": [], "error": failure})
                receipt["resultSHA256"] = digest(output)
                write_json(output.with_suffix(".receipt.json"), receipt)
                print(f"Completed {track['fixture']}/{track['track']} {provider} {iteration}: {status}", flush=True)
                if invalidated:
                    raise RuntimeError(failure)



def page(root: Path, seed: int) -> Path:
    manifest = json.loads((root / "manifest.json").read_text())
    rng = random.Random(seed)
    items = []
    for track in manifest["tracks"]:
        providers = list(PROVIDERS)
        rng.shuffle(providers)
        columns = []
        for provider in providers:
            folder = root / "results" / track["fixture"] / track["track"]
            candidates = []
            for path in folder.glob(f"{provider}-*.json"):
                match = re.fullmatch(provider + r"-(\d+)\.json", path.name)
                if match:
                    candidates.append((int(match[1]), path, json.loads(path.read_text())))
            completed = [candidate for candidate in candidates if candidate[2].get("status") == "completed"]
            selected = max(completed, default=None) or max(candidates, default=None)
            if selected:
                iteration, result, value = selected
                value["resultSHA256"] = digest(result)
                value["selectedIteration"] = iteration
                value["resultFile"] = str(result.relative_to(root))
            else:
                value = {"provider": provider, "status": "pending", "segments": [], "resultSHA256": "unavailable"}
            columns.append(value)
        items.append({**track, "columns": columns})
    data = json.dumps({"schemaVersion": 1, "items": items}, ensure_ascii=False).replace("<", "\\u003c").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    template = Path(__file__).with_name("review.html").read_text()
    output = root / "review.html"
    output.write_text(template.replace("/*EXPERIMENT_DATA*/null", data))
    output.chmod(0o600)
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "run", "page"])
    parser.add_argument("--config", type=Path)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--providers", nargs="+", choices=PROVIDERS, default=list(PROVIDERS))
    parser.add_argument("--repetitions", type=int, default=1)
    parser.add_argument("--fixtures", nargs="+")
    parser.add_argument("--tracks", nargs="+")
    parser.add_argument("--seed", type=int, default=20261023)
    parser.add_argument("--iteration-start", type=int, default=0)
    args = parser.parse_args()
    root = private_output(args.root)
    config = json.loads(args.config.read_text()) if args.config else {}
    if not 0 <= args.iteration_start <= 99:
        parser.error("Use an iteration start between 0 and 99")
    if not 1 <= args.repetitions <= 10:
        parser.error("Use 1–10 repetitions")
    if args.action == "prepare":
        prepare(config, root)
    elif args.action == "run":
        manifest = json.loads((root / "manifest.json").read_text())
        for requested, key in [(args.fixtures,"fixture"),(args.tracks,"track")]:
            if requested and not set(requested).issubset({t[key] for t in manifest["tracks"]}):
                parser.error("Requested fixture or track is unavailable")
        run(config, root, args.providers, args.repetitions, args.fixtures, args.tracks, args.iteration_start)
    else:
        print(page(root, args.seed))


if __name__ == "__main__":
    main()
