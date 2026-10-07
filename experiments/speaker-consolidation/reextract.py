"""Re-extract existing spans through corrected production code without rerunning labeling."""

import argparse
import json
import os
from pathlib import Path
import subprocess

from score import private_output, sha


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--extractor", type=Path, required=True)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--production-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rollover", choices=["off", "on"], nargs="+", default=["off", "on"])
    args = parser.parse_args()
    root = args.manifest.resolve().parent
    out = private_output(args.output)
    out.mkdir(parents=True, exist_ok=False)
    manifest = json.loads(args.manifest.read_text())
    manifest["reextraction"] = dict(originalManifestSHA256=sha(args.manifest),
        extractorSHA256=sha(args.extractor), clusteringRunnerSHA256=sha(args.runner),
        productionExtractorSHA256=sha(args.production_source))
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for sample in manifest["samples"]:
        assert sha(sample["audioPath"]) == sample["audioSHA256"]
        for mode in args.rollover:
            name = sample["id"] + "-" + mode
            source = root / name
            source_run = json.loads((root / (name + ".run.json")).read_text())
            assert source_run["returncode"] == 0
            assert sha(source / "evidence.json") == source_run["artifacts"]["evidence.json"]
            target = out / name
            target.mkdir()
            run = subprocess.run([str(args.extractor.resolve()), sample["audioPath"],
                str(source / "evidence.json"), str(args.models.resolve()), str(target / "evidence.json")],
                check=True, capture_output=True, text=True)
            details = json.loads(run.stdout.strip().splitlines()[-1])
            original = json.loads((source / "evidence.json").read_text())
            corrected = json.loads((target / "evidence.json").read_text())
            assert original["activity"] == corrected["activity"]
            assert len(original["samples"]) == len(corrected["samples"])
            for old, new in zip(original["samples"], corrected["samples"]):
                assert {k:v for k,v in old.items() if k != "embedding"} == {
                    k:v for k,v in new.items() if k != "embedding"}
                assert old["embedding"]["type"] != new["embedding"]["type"], "Preprocessing must change compatibility"
            clustered = subprocess.run([str(args.runner.resolve()), str(target / "evidence.json"),
                str(target / "consolidated.json"), "0.72"], check=True, capture_output=True, text=True)
            receipt = json.loads((source / "receipt.json").read_text())
            receipt.update(details)
            receipt["reextracted"] = True
            receipt["originalEvidenceSHA256"] = sha(source / "evidence.json")
            receipt["correctedClusteringRuntime"] = clustered.stdout.strip()
            (target / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
            metadata = dict(source_run, reextraction=manifest["reextraction"],
                originalRunReceiptSHA256=sha(root / (name + ".run.json")),
                artifacts={p.name:sha(p) for p in target.glob("*.json")})
            (out / (name + ".run.json")).write_text(json.dumps(metadata, indent=2) + "\n")
            print(json.dumps(dict(sample=sample["id"], mode=mode, **details)), flush=True)


if __name__ == "__main__":
    main()
