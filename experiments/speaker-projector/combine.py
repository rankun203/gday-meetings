"""Combine verified independent source replays and run production consolidation."""

import argparse
import copy
import hashlib
import json
import subprocess
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_sources(sources):
    require(bool(sources), "No replay sources")
    names = [s["actualSource"] for s in sources]
    identifiers = [s["id"] for s in sources]
    require(len(set(names)) == len(names), "Repeated actual source")
    require(len(set(identifiers)) == len(identifiers), "Repeated replay identifier")
    require(
        all(
            Path(identifier).name == identifier and identifier not in (".", "..")
            for identifier in identifiers
        ),
        "Unsafe replay identifier",
    )


def validate_artifacts(folder, artifacts):
    require(
        {"evidence.json", "receipt.json"} <= set(artifacts),
        "Missing required replay artifact hashes",
    )
    for name, digest in artifacts.items():
        require(
            Path(name).name == name and name not in (".", ".."), "Unsafe artifact path"
        )
        require(sha(folder / name) == digest, "Replay artifact hash differs")


def validate_ids(evidence, all_samples, all_locals):
    sample_ids = {item["id"] for item in evidence["samples"]}
    require(len(sample_ids) == len(evidence["samples"]), "Repeated sample ID")
    locals_ = {
        item["localSpeakerID"] for item in evidence["activity"] + evidence["samples"]
    }
    locals_.update(
        local for window in evidence["windows"] for local in window["localSpeakerIDs"]
    )
    require(
        not all_samples & sample_ids and not all_locals & locals_,
        "Replay identity collision",
    )
    return sample_ids, locals_


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--runner", type=Path, required=True)
    args = parser.parse_args()
    root = args.manifest.resolve().parent
    subprocess.run(
        ["git", "check-ignore", str(root)], check=True, stdout=subprocess.DEVNULL
    )
    manifest = json.loads(args.manifest.read_text())
    validate_sources(manifest["samples"])
    input_hashes = {args.manifest: sha(args.manifest), args.runner: sha(args.runner)}
    combined = None
    provenance = {
        "manifestSHA256": sha(args.manifest),
        "runnerSHA256": sha(args.runner),
        "sources": [],
    }
    all_samples, all_locals = set(), set()
    for source in manifest["samples"]:
        name = source["actualSource"]
        require(
            name in ("microphone", "system") and source["timeOffsetSeconds"] == 0,
            "Replay provenance or source integrity check failed",
        )
        require(
            sha(source["audioPath"]) == source["audioSHA256"],
            "Replay provenance or source integrity check failed",
        )
        folder = root / (source["id"] + "-on")
        run_path = folder.with_suffix(".run.json")
        run = json.loads(run_path.read_text())
        require(
            run["returncode"] == 0
            and run["status"] == "completed"
            and run["provenanceStable"] is True,
            "Replay provenance or source integrity check failed",
        )
        require(
            run["inputSHA256"] == source["audioSHA256"] and run["rollover"] == "on",
            "Replay provenance or source integrity check failed",
        )
        validate_artifacts(folder, run["artifacts"])
        input_hashes[run_path] = sha(run_path)
        input_hashes[Path(source["audioPath"])] = source["audioSHA256"]
        input_hashes.update(
            {folder / name: digest for name, digest in run["artifacts"].items()}
        )
        receipt = json.loads((folder / "receipt.json").read_text())
        require(
            receipt["complete"]
            and all(
                receipt[key] == 0
                for key in ("gapCount", "failureCount", "extractionFailures")
            ),
            "Replay provenance or source integrity check failed",
        )
        evidence = json.loads((folder / "evidence.json").read_text())
        if combined is None:
            combined = copy.deepcopy(evidence)
            for key in ("samples", "activity", "windows"):
                combined[key] = []
        sample_ids, locals_ = validate_ids(evidence, all_samples, all_locals)
        all_samples |= sample_ids
        all_locals |= locals_
        for key in ("samples", "activity", "windows"):
            for item in evidence[key]:
                require(
                    item["source"] == source["replayInternalSource"],
                    "Replay provenance or source integrity check failed",
                )
                value = dict(item, source=name)
                combined[key].append(value)
        provenance["sources"].append(
            {
                "source": name,
                "internalSource": source["replayInternalSource"],
                "runReceiptSHA256": sha(run_path),
                "audioSHA256": source["audioSHA256"],
            }
        )
    evidence_path = root / "combined-evidence.json"
    with evidence_path.open("x") as handle:
        json.dump(combined, handle, sort_keys=True)
    output = root / "combined-analysis.json"
    subprocess.run(
        [str(args.runner.resolve()), str(evidence_path), str(output)], check=True
    )
    require(
        sha(args.runner) == provenance["runnerSHA256"],
        "Replay provenance or source integrity check failed",
    )
    for path, expected in input_hashes.items():
        require(sha(path) == expected, "Input changed during consolidation")
    analysis = json.loads(output.read_text())
    provenance["evidenceSHA256"] = sha(evidence_path)
    provenance["analysisSHA256"] = sha(output)
    for name, value in (
        ("combined-result.json", analysis["result"]),
        (
            "combined-audit.json",
            dict(analysis["audit"], evidenceSHA256=sha(evidence_path)),
        ),
        ("combined-receipt.json", provenance),
    ):
        with (root / name).open("x") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)


if __name__ == "__main__":
    main()
