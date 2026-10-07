"""Separate retained-sample grouping from temporal propagation errors."""

import argparse
import copy
import json
from pathlib import Path

from evaluate import human_view
from score import private_output, score, sha


def intersections(left, right):
    return [dict(start=max(a["start"], b["start"]), end=min(a["end"], b["end"]))
            for a in left for b in right if max(a["start"], b["start"]) < min(a["end"], b["end"])]


def diagnose(evidence, result, refs):
    assignments = {sample: cluster["id"] for cluster in result["clusters"] for sample in cluster["sampleIDs"]}
    systems = {"local": [], "clusters": []}
    for s in evidence["samples"]:
        systems["local"].append(dict(start=s["start"], end=s["end"], speaker=s["source"]+":"+s["localSpeakerID"]))
        systems["clusters"].append(dict(start=s["start"], end=s["end"], speaker=assignments.get(s["id"], "rejected:"+s["id"])))
    reference = copy.deepcopy(refs["silver"])
    # Saved worker gaps remain unknown, even inside a retained sample.
    reference["reviewedRegions"] = intersections(reference["intervals"], evidence["samples"])
    silver = {name: score(reference, rows) for name, rows in systems.items()}
    for value in silver.values():
        for variant in value["views"]:
            variant["reference_status"] = "saved_worker_annotations_not_ground_truth"
    clips = copy.deepcopy(refs["human"])
    for clip in clips:
        local_samples = [dict(start=max(clip["start"], s["start"])-clip["start"],
                              end=min(clip["end"], s["end"])-clip["start"])
                         for s in evidence["samples"] if s["start"] < clip["end"] and s["end"] > clip["start"]]
        clip["reviewedRegions"] = intersections(clip["reviewedRegions"], local_samples)
    return dict(sampleCount=len(evidence["samples"]), silver=silver,
                humanRandom=human_view(clips, systems, "random"),
                humanTargeted=human_view(clips, systems, "speaker_coverage"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--sample", required=True)
    parser.add_argument("--rollover", choices=["on", "off"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--consolidated", type=Path, help="Optional frozen calibrated result")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    sample = next(s for s in manifest["samples"] if s["id"] == args.sample)
    assert sha(sample["referencesPath"]) == sample["referencesSHA256"]
    root = args.manifest.resolve().parent / (args.sample+"-"+args.rollover)
    run = json.loads(root.with_suffix(".run.json").read_text())
    for name in ("evidence.json", "consolidated.json"):
        assert sha(root/name) == run["artifacts"][name]
    result_path = args.consolidated or root/"consolidated.json"
    result = diagnose(json.loads((root/"evidence.json").read_text()), json.loads(result_path.read_text()),
                      json.loads(Path(sample["referencesPath"]).read_text()))
    result["resultSHA256"] = sha(result_path)
    result["evidenceSHA256"] = sha(root/"evidence.json")
    with private_output(args.output).open("x") as handle:
        json.dump(result, handle, indent=2)
        handle.write("\n")
    for name in ("silver", "humanRandom", "humanTargeted"):
        print(name, {k: dict(error=v["views"][0]["disagreement_fraction"], precision=v["mergePrecision"],
                              recall=v["splitRecall"], seconds=v["pairedExclusiveSeconds"]) for k,v in result[name].items()})


if __name__ == "__main__":
    main()
