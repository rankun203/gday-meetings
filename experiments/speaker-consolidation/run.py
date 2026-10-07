"""Run the opt-in production replay test serially, without rebuilding or downloading."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import signal
import time

from score import sha, private_output


def source_snapshot(package, bundle, model_data):
    production = package / "Sources/GdayMeetings"
    model_root = model_data / "LocalModels"
    assets = {}
    # LocalModelManager rewrites its validation cache during model acquisition.
    # These operational receipts and Finder metadata are not model inputs.
    operational_files = {".gday-validation.json", ".gday-prepared", ".DS_Store"}
    for model in ("community1", "nemotronLow"):
        files = sorted(path for path in (model_root / model).rglob("*")
                       if path.is_file() and path.name not in operational_files)
        if not files:
            raise ValueError("Missing replay model assets: " + model)
        assets.update({str(path.relative_to(model_root)): sha(path) for path in files})
    return dict(
        productionSHA256={name: sha(production / name) for name in (
            "Services/LocalLiveDiarization.swift", "Core/CommunityVoiceEmbeddingExtractor.swift",
            "Core/SpeakerConsolidation.swift", "Core/SpeakerEvidence.swift", "Core/VoiceEmbeddingMath.swift",
            "Core/LocalModels/TypedVoiceEmbedding.swift", "Core/VoiceProfileSelection.swift", "Core/LiveSpeakerCapacity.swift")},
        replaySourceSHA256=sha(package / "Tests/GdayMeetingsTests/SpeakerConsolidationReplayTests.swift"),
        testBundleSHA256=sha(bundle), driverSourceSHA256=sha(__file__), modelAssetsSHA256=assets)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--package-path", type=Path, required=True)
    parser.add_argument("--sample", required=True)
    parser.add_argument("--rollover", choices=["on", "off"], required=True)
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    parser.add_argument("--test-bundle", type=Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    sample = next(s for s in manifest["samples"] if s["id"] == args.sample)
    assert sha(sample["audioPath"]) == sample["audioSHA256"]
    out = private_output(args.manifest.resolve().parent / (args.sample + "-" + args.rollover))
    assert not out.exists(), "Use a fresh output directory; existing attempts are retained."
    env = dict(os.environ, GDAY_CONSOLIDATION_REPLAY="1", GDAY_CONSOLIDATION_AUDIO=sample["audioPath"],
               GDAY_CONSOLIDATION_OUTPUT=str(out), GDAY_CONSOLIDATION_DATA=manifest["dataDirectory"],
               GDAY_CONSOLIDATION_ROLLOVER="1" if args.rollover == "on" else "0",
               CLANG_MODULE_CACHE_PATH=str(args.package_path / ".build/clang-cache"))
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    runtime_roots = [developer, Path("/Applications/Xcode.app/Contents/Developer")]
    frameworks = [p / relative for p in runtime_roots for relative in (
        "Library/Developer/Frameworks", "Platforms/MacOSX.platform/Developer/Library/Frameworks")]
    libraries = [p / relative for p in runtime_roots for relative in (
        "Library/Developer/usr/lib", "Platforms/MacOSX.platform/Developer/usr/lib")]
    env["DYLD_FRAMEWORK_PATH"] = ":".join(str(p) for p in frameworks if p.is_dir())
    env["DYLD_LIBRARY_PATH"] = ":".join(str(p) for p in libraries if p.is_dir())
    command = ["xcrun", "swift", "test", "--package-path", str(args.package_path),
               "--disable-sandbox", "--cache-path", str(args.package_path / ".build/cache"),
               "--config-path", str(args.package_path / ".build/config"),
               "--security-path", str(args.package_path / ".build/security"),
               "-c", args.configuration, "--skip-build",
               "--filter", "SpeakerConsolidationReplayTests"]
    if args.test_bundle:
        swift = Path(subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip())
        helper = swift.parent.parent / "libexec/swift/pm/swiftpm-testing-helper"
        executable = args.test_bundle.resolve() / "Contents/MacOS/GdayMeetingsTests"
        command = [str(helper), "--test-bundle-path", str(executable), "--testing-library", "swift-testing",
                   "--filter", "SpeakerConsolidationReplayTests"]
    bundle = (args.test_bundle / "Contents/MacOS/GdayMeetingsTests" if args.test_bundle else
              args.package_path / f".build/out/Products/{args.configuration.capitalize()}/GdayMeetingsTests.xctest/Contents/MacOS/GdayMeetingsTests")
    before = source_snapshot(args.package_path, bundle, Path(manifest["dataDirectory"]))
    log = out.with_suffix(".log")
    started = time.monotonic()
    interruption = None
    with log.open("x") as handle:
        process = subprocess.Popen(command, env=env, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            returncode = process.wait(timeout=args.timeout)
        except BaseException as error:
            interruption = error
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            returncode = process.returncode
    metadata = dict(command=command, rollover=args.rollover, sample=args.sample, buildConfiguration=args.configuration,
                    inputSHA256=sample["audioSHA256"], returncode=returncode,
                    wallSeconds=time.monotonic()-started, logSHA256=sha(log),
                    artifacts={p.name: sha(p) for p in out.glob("*.json")})
    metadata["status"] = "interrupted" if interruption else "completed" if returncode == 0 else "failed"
    if interruption:
        metadata["interruption"] = type(interruption).__name__
    metadata.update(before)
    metadata["provenanceStable"] = before == source_snapshot(
        args.package_path, bundle, Path(manifest["dataDirectory"]))
    if not metadata["provenanceStable"]:
        metadata["status"] = "invalid-provenance"
    out.with_suffix(".run.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(dict(sample=args.sample, rollover=args.rollover, returncode=returncode,
                         wallSeconds=metadata["wallSeconds"])))
    if interruption:
        raise interruption
    if returncode:
        raise SystemExit(returncode)
    if not metadata["provenanceStable"]:
        raise SystemExit("Replay source or binary changed during execution.")
    assert (out / "receipt.json").exists(), "Replay test did not run."


if __name__ == "__main__":
    main()
