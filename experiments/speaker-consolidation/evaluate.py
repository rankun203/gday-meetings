"""Produce aggregate metrics from replay artifacts and frozen private references."""

import argparse
import json
from pathlib import Path
import subprocess

from score import intervals, score, sha, union_seconds, private_output


def human_view(clips, hypotheses, category):
    reference = dict(intervals=[], reviewedRegions=[])
    outputs = {name: [] for name in hypotheses}
    cursor = 0.0
    for clip in clips:
        if clip["category"] != category:
            continue
        a, b = clip["start"], clip["end"]
        for key in ("intervals", "reviewedRegions"):
            reference[key].extend(dict(row, start=row["start"]+cursor, end=row["end"]+cursor) for row in clip[key])
        for name, rows in hypotheses.items():
            outputs[name].extend(dict(row, start=max(a, row["start"])-a+cursor, end=min(b, row["end"])-a+cursor)
                                 for row in rows if row["start"] < b and row["end"] > a)
        cursor += b-a+1
    reference["audioDurationSeconds"] = cursor-1
    return {name: score(reference, rows) for name, rows in outputs.items()} if cursor else {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--calibration", type=Path)
    parser.add_argument("--runner", type=Path)
    args = parser.parse_args()
    root = args.manifest.resolve().parent
    manifest = json.loads(args.manifest.read_text())
    calibration = json.loads(args.calibration.read_text()) if args.calibration else None
    if calibration:
        assert args.runner and sha(args.runner) == calibration["runnerSHA256"]
        calibration_evidence = root / (calibration["calibrationSample"] + "-" + calibration["rollover"]) / "evidence.json"
        assert sha(calibration_evidence) == calibration["evidenceSHA256"]
        calibrated_root = private_output(args.output.with_suffix(".clusters"))
        calibrated_root.mkdir(parents=True, exist_ok=False)
    results = []
    for sample in manifest["samples"]:
        refs = json.loads(Path(sample["referencesPath"]).read_text())
        assert sha(sample["referencesPath"]) == sample["referencesSHA256"]
        systems = {"worker": refs["silver"]["intervals"]}
        measurements = {}
        for mode in ("off", "on"):
            folder = root / (sample["id"] + "-" + mode)
            if not (folder / "receipt.json").exists():
                continue
            run = json.loads(folder.with_suffix(".run.json").read_text())
            assert run["returncode"] == 0 and run["inputSHA256"] == sample["audioSHA256"]
            for filename, digest in run["artifacts"].items():
                assert sha(folder / filename) == digest
            receipt = json.loads((folder / "receipt.json").read_text())
            assert receipt["complete"] and receipt["gapCount"] == 0 and receipt["failureCount"] == 0
            evidence = json.loads((folder / "evidence.json").read_text())
            consolidated = json.loads((folder / "consolidated.json").read_text())
            base, combined = intervals(evidence, consolidated)
            systems[mode + "-live"], systems[mode + "-consolidated"] = base, combined
            systems[mode + "-resolved-only"] = [dict(start=r["start"], end=r["end"], speaker=r["clusterID"])
                                                for r in consolidated["intervals"] if r.get("clusterID")]
            measurements[mode] = dict(receipt, clusterCount=len(consolidated["clusters"]),
                                      sampleCoverageSeconds=union_seconds(evidence["samples"]),
                                      activityCoverageSeconds=union_seconds(evidence["activity"]),
                                      unresolvedSeconds=union_seconds([r for r in consolidated["intervals"] if not r.get("clusterID")]))
            if calibration:
                target = calibrated_root / (sample["id"] + "-" + mode + ".json")
                run = subprocess.run([str(args.runner.resolve()), str(folder / "evidence.json"), str(target),
                                      str(calibration["selectedThreshold"])], check=True, capture_output=True, text=True)
                tuned = json.loads(target.read_text())
                _, systems[mode + "-calibrated"] = intervals(evidence, tuned)
                measurements[mode]["calibrated"] = dict(threshold=calibration["selectedThreshold"],
                    resultSHA256=sha(target), evidenceSHA256=sha(folder / "evidence.json"),
                    clusterCount=len(tuned["clusters"]), runtime=run.stdout.strip(),
                    unresolvedSeconds=union_seconds([r for r in tuned["intervals"] if not r.get("clusterID")]))
        if not measurements:
            continue
        results.append(dict(sample=sample["id"], measurements=measurements,
                            silver={name: score(refs["silver"], rows) for name, rows in systems.items() if name != "worker"},
                            humanRandom=human_view(refs["human"], systems, "random"),
                            humanTargeted=human_view(refs["human"], systems, "speaker_coverage")))
    output = dict(schemaVersion=1, manifestSHA256=sha(args.manifest), samples=results)
    if calibration:
        output["calibration"] = dict(path=str(args.calibration), sha256=sha(args.calibration),
                                     sample=calibration["calibrationSample"], threshold=calibration["selectedThreshold"])
    with private_output(args.output).open("x") as handle:
        json.dump(output, handle, indent=2)
        handle.write("\n")
    for sample in results:
        print(sample["sample"], {name: round(s["views"][0]["disagreement_fraction"]*100, 2)
                                for name, s in sample["humanRandom"].items()})


if __name__ == "__main__":
    main()
