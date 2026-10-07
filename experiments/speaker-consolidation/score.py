"""Score production consolidation against saved worker or reviewed intervals."""

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "diarization-benchmark"))
from compare_reference import compare
from private_paths import private_output


def sha(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def intervals(evidence, result):
    """Retain anonymous activity when consolidation cannot assign a voice group."""
    baseline = [dict(start=r["start"], end=r["end"], speaker=r["source"] + ":" + r["localSpeakerID"])
                for r in evidence["activity"]]
    consolidated = [dict(start=r["start"], end=r["end"], speaker=r.get("clusterID") or
                         "unresolved:" + r["source"] + ":" + r["localSpeakerID"])
                    for r in result["intervals"]]
    return baseline, consolidated


def union_seconds(rows):
    merged = []
    for row in sorted(rows, key=lambda x: x["start"]):
        a, b = row["start"], row["end"]
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return sum(b - a for a, b in merged)


def purity(reference, hypothesis, coverage=None):
    """Duration-weighted B-cubed precision/recall on exclusive paired speech.

    Precision falls for incorrect merges, recall for splits. Read these
    conditional scores alongside pairedExclusiveSeconds and DER: dropping
    difficult unpaired or overlapping regions can raise precision and recall.
    """
    events = defaultdict(list)
    for kind, rows in enumerate((reference, hypothesis, coverage or [])):
        for r in rows:
            label = r.get("speaker", "reviewed")
            events[r["start"]].append((kind, label, 1))
            events[r["end"]].append((kind, label, -1))
    edges = sorted(events)
    states = [Counter(), Counter(), Counter()]
    contingency = defaultdict(float)
    for a, b in zip(edges, edges[1:]):
        for kind, label, delta in events[a]:
            states[kind][label] += delta
        if coverage is not None and states[2]["reviewed"] <= 0:
            continue
        rs, hs = ({k for k, v in state.items() if v > 0} for state in states[:2])
        if len(rs) == len(hs) == 1:
            contingency[(next(iter(rs)), next(iter(hs)))] += b - a
    rt, ht = defaultdict(float), defaultdict(float)
    for (r, h), value in contingency.items():
        rt[r] += value
        ht[h] += value
    total = sum(contingency.values())
    precision = sum(v*v / ht[h] for (r, h), v in contingency.items()) / total if total else None
    recall = sum(v*v / rt[r] for (r, h), v in contingency.items()) / total if total else None
    return dict(pairedExclusiveSeconds=total, mergePrecision=precision, splitRecall=recall,
                referenceSpeakers=len(rt), hypothesisSpeakers=len(ht))


def score(reference, hypothesis):
    views = []
    for collar in (0, 0.25):
        for overlap in (False, True):
            value = compare(reference["intervals"], hypothesis, reference["audioDurationSeconds"], collar, overlap,
                            coverage=reference.get("reviewedRegions"))
            value["reference_status"] = ("single_reviewer_audio_annotations" if "reviewedRegions" in reference
                                         else "saved_worker_annotations_not_ground_truth")
            value.pop("review_intervals")
            value.pop("mapping")
            views.append(value)
    return dict(views=views, **purity(reference["intervals"], hypothesis, reference.get("reviewedRegions")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--consolidated", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    ref, evidence, result = (json.loads(p.read_text()) for p in (args.reference, args.evidence, args.consolidated))
    baseline, consolidated = intervals(evidence, result)
    output = dict(schemaVersion=1, inputSHA256={k: sha(getattr(args, k)) for k in ("reference", "evidence", "consolidated")},
                  baseline=score(ref, baseline), consolidated=score(ref, consolidated),
                  sampleCount=len(evidence["samples"]), sampleCoverageSeconds=union_seconds(evidence["samples"]),
                  activityCoverageSeconds=union_seconds(evidence["activity"]), clusterCount=len(result["clusters"]),
                  unresolvedSeconds=union_seconds([r for r in result["intervals"] if not r.get("clusterID")]))
    with private_output(args.output).open("x") as handle:
        json.dump(output, handle, indent=2)
        handle.write("\n")


if __name__ == "__main__":
    main()
