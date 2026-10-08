"""Compare an observation candidate with frozen acoustic references, without model inference.

Runner contract: executable EVIDENCE OUTPUT_RESULT OUTPUT_AUDIT.
Results must use SpeakerConsolidationResult's JSON shape. No threshold tuning is
performed here. Existing recordings are regression diagnostics, not fresh holdout.
"""
import argparse
import json
import statistics
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "speaker-consolidation"))
from evaluate import human_view  # noqa: E402
from score import intervals, private_output, score, sha, union_seconds  # noqa: E402


def density(evidence):
    groups = {}
    for sample in evidence["samples"]:
        groups.setdefault((sample["source"], sample["localSpeakerID"]), []).append(sample)
    gaps = []
    for samples in groups.values():
        samples.sort(key=lambda item: item["start"])
        gaps.extend(max(0, right["start"] - left["end"]) for left, right in zip(samples, samples[1:]))
    gaps.sort()
    return dict(sampledLocalLabels=len(groups), withinLabelSampleGaps=len(gaps),
                medianGapSeconds=statistics.median(gaps) if gaps else None,
                gapsOver30Seconds=sum(gap > 30 for gap in gaps),
                note="Gaps include silence and other speakers; not missing-speech duration")


def run(manifest_path, runner, output):
    output = private_output(output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    manifest = json.loads(manifest_path.read_text())
    root = manifest_path.resolve().parent
    runner_hash = sha(runner)
    method_sources = [Path(__file__), Path(__file__).parents[1] / "speaker-consolidation/score.py",
                      Path(__file__).parents[1] / "speaker-consolidation/evaluate.py",
                      Path(__file__).parents[1] / "diarization-benchmark/compare_reference.py"]
    method_hashes = {str(path.relative_to(Path(__file__).parents[2])): sha(path) for path in method_sources}
    build_path = runner.with_suffix(".build.json")
    build_receipt = json.loads(build_path.read_text())
    if build_receipt["binarySHA256"] != runner_hash:
        raise ValueError("Binary does not match source build receipt")
    rows = []
    for sample in manifest["samples"]:
        name = sample["id"] + "-on"
        evidence_path = root / name / "evidence.json"
        receipt_path = root / (name + ".run.json")
        receipt = json.loads(receipt_path.read_text())
        if (receipt["returncode"] != 0 or receipt["inputSHA256"] != sample["audioSHA256"]
                or sha(evidence_path) != receipt["artifacts"]["evidence.json"]
                or sha(sample["referencesPath"]) != sample["referencesSHA256"]):
            raise ValueError("Frozen input provenance mismatch: " + sample["id"])
        evidence = json.loads(evidence_path.read_text())
        refs = json.loads(Path(sample["referencesPath"]).read_text())
        result_path = output / (sample["id"] + ".json")
        audit_path = output / (sample["id"] + ".audit.json")
        subprocess.run([str(runner.resolve()), str(evidence_path), str(result_path), str(audit_path)],
                       check=True, capture_output=True, text=True)
        result = json.loads(result_path.read_text())
        live, candidate = intervals(evidence, result)
        systems = dict(worker=refs["silver"]["intervals"], live=live, candidate=candidate)
        rows.append(dict(sample=sample["id"], evidenceSHA256=sha(evidence_path),
                         referenceSHA256=sha(sample["referencesPath"]), resultSHA256=sha(result_path),
                         auditSHA256=sha(audit_path), audit=json.loads(audit_path.read_text()),
                         retainedSampleCount=len(evidence["samples"]), sampleDensity=density(evidence),
                         sampledWallSeconds=union_seconds(evidence["samples"]),
                         activityWallSeconds=union_seconds(evidence["activity"]), clusterCount=len(result["clusters"]),
                         unresolvedWallSeconds=union_seconds([x for x in result["intervals"] if not x.get("clusterID")]),
                         silver={key: score(refs["silver"], value) for key, value in systems.items() if key != "worker"},
                         humanRandom=human_view(refs["human"], systems, "random"),
                         humanTargeted=human_view(refs["human"], systems, "speaker_coverage")))
    if sha(runner) != runner_hash:
        raise ValueError("Runner changed during evaluation")
    result = dict(schemaVersion=1, role="previously examined regression diagnostics; not fresh holdout",
                  manifestSHA256=sha(manifest_path), runnerSHA256=runner_hash, buildReceipt=build_receipt,
                  evaluationSources=method_hashes, samples=rows,
                  limitations=["Offline evidence grouping does not establish causal publication or live latency",
                               "Saved worker annotations are disagreement references, not ground truth",
                               "Unresolved activity retains local labels in scorer; not actual transcript publication"])
    (output / "evaluation.json").write_text(json.dumps(result, indent=2) + "\n")
    for row in rows:
        print(row["sample"], {key: round(value["views"][0]["disagreement_fraction"] * 100, 3)
                              for key, value in row["humanRandom"].items()}, flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    run(args.manifest, args.runner, args.output)
