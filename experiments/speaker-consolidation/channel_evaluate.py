"""Calibrate and evaluate channel-unit clustering with frozen rollover provenance."""

import argparse
import json
from pathlib import Path
import subprocess

from evaluate import human_view
from score import intervals, private_output, score, sha

GRID = [0.10, 0.20, 0.30, 0.40, 0.50, 0.55, 0.60, 0.65, 0.70, 0.72, 0.75, 0.80, 0.85, 0.90]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--original-root", type=Path, required=True)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--method", default="normalized-channel-mean-complete-link-v1")
    parser.add_argument("--samples", nargs="+", help="Optional declared subset of manifest sample IDs")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--calibrate", metavar="SAMPLE_ID")
    group.add_argument("--calibration", type=Path)
    args = parser.parse_args()
    out = private_output(args.output)
    out.mkdir(parents=True, exist_ok=False)
    root = args.manifest.resolve().parent
    manifest = json.loads(args.manifest.read_text())
    runner_hash = sha(args.runner)
    calibration = json.loads(args.calibration.read_text()) if args.calibration else None
    if calibration:
        assert runner_hash == calibration["runnerSHA256"]
        assert args.method == calibration["method"]
    results = []
    for sample in manifest["samples"]:
        if args.samples and sample["id"] not in args.samples:
            continue
        if args.calibrate and sample["id"] != args.calibrate:
            continue
        name = sample["id"] + "-on"
        folder = root / name
        evidence_path = folder / "evidence.json"
        receipt = json.loads((root / (name + ".run.json")).read_text())
        assert receipt["returncode"] == 0 and receipt["inputSHA256"] == sample["audioSHA256"]
        assert sha(evidence_path) == receipt["artifacts"]["evidence.json"]
        assert sha(sample["referencesPath"]) == sample["referencesSHA256"]
        evidence = json.loads(evidence_path.read_text())
        refs = json.loads(Path(sample["referencesPath"]).read_text())
        trials = []
        systems = {"worker": refs["silver"]["intervals"]}
        thresholds = GRID if args.calibrate else sorted(set([0.72, calibration["selectedThreshold"]]))
        for threshold in thresholds:
            result_path = out / f"{sample['id']}-{threshold:.2f}.json"
            audit_path = result_path.with_suffix(".audit.json")
            subprocess.run([str(args.runner.resolve()), str(evidence_path),
                str(args.original_root / name / "evidence.json"),
                str(args.original_root / (name + ".run.json")),
                str(result_path), str(audit_path), str(threshold)], check=True, capture_output=True, text=True)
            result = json.loads(result_path.read_text())
            baseline, combined = intervals(evidence, result)
            systems["live"] = baseline
            systems[f"channels-{threshold:.2f}"] = combined
            measured = score(refs["silver"], combined)
            trials.append(dict(threshold=threshold, metrics=measured, clusterCount=len(result["clusters"]),
                resultSHA256=sha(result_path), audit=json.loads(audit_path.read_text())))
        if args.calibrate:
            best = min(trials, key=lambda t:(t["metrics"]["views"][0]["disagreement_fraction"],abs(t["threshold"]-.72)))
            frozen = dict(method=args.method, calibrationSample=sample["id"],
                runnerSHA256=runner_hash, manifestSHA256=sha(args.manifest), evidenceSHA256=sha(evidence_path),
                referenceSHA256=sample["referencesSHA256"], thresholdGrid=GRID, trials=trials,
                selectedThreshold=best["threshold"], selection="minimum B silver disagreement; tie nearest 0.72")
            (out / "calibration.json").write_text(json.dumps(frozen, indent=2)+"\n")
            print(json.dumps(dict(selectedThreshold=best["threshold"],scores={str(t["threshold"]):
                t["metrics"]["views"][0]["disagreement_fraction"] for t in trials})),flush=True)
        else:
            results.append(dict(sample=sample["id"], trials=trials,
                silver={name:score(refs["silver"],rows) for name,rows in systems.items() if name!="worker"},
                humanRandom=human_view(refs["human"], systems, "random"),
                humanTargeted=human_view(refs["human"], systems, "speaker_coverage")))
    if args.calibrate:
        assert (out/"calibration.json").exists(), "Calibration sample absent"
    else:
        (out/"evaluation.json").write_text(json.dumps(dict(method=args.method, runnerSHA256=runner_hash,
            manifestSHA256=sha(args.manifest), calibrationSHA256=sha(args.calibration),
            selectedThreshold=calibration["selectedThreshold"], samples=results), indent=2)+"\n")
        for sample in results:
            print(sample["sample"],{name:round(s["views"][0]["disagreement_fraction"]*100,2)
                for name,s in sample["humanRandom"].items()},flush=True)


if __name__ == "__main__":
    main()
