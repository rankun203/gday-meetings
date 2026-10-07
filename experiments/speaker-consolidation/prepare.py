"""Stage frozen evaluation references and copy installed models into private storage."""

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import shutil
import sys
import wave

from score import sha

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "diarization-benchmark"))
from private_paths import private_output


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evaluation-root", type=Path, required=True)
    parser.add_argument("--installed-models", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--samples", nargs="+", default=["sample-J", "sample-B-coverage", "sample-G"])
    args = parser.parse_args()
    out = private_output(args.output)
    out.mkdir(parents=True, exist_ok=False)
    base = args.evaluation_root.resolve()
    manifests = [base / "manifest.json", base / "busy-tracks-20261001/manifest.json",
                 base / "research-expansion-20261001/manifest.json"]
    specs = {s["id"]: s for p in manifests for s in json.loads(p.read_text())["samples"]}
    frozen = base / "human-evaluation"
    snapshots = json.loads((frozen / "snapshot-receipt.json").read_text())
    snapshot = {s["sample"]: s for s in snapshots["samples"]}
    overlay = json.loads((frozen / "adjudication.json").read_text())
    samples = []
    for name in args.samples:
        spec, snap = specs[name], snapshot[name]
        audio = Path(spec["audioPath"])
        assert sha(audio) == spec["sha256"]
        with wave.open(str(audio), "rb") as wav:
            assert (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) == (16000, 1, 2)
            assert abs(wav.getnframes() / 16000 - spec["durationSeconds"]) < 1e-6
        source = Path(spec["sourceDirectory"])
        raw_path = source / "extraction_raw.json"
        raw = json.loads(raw_path.read_text())["tracks"][spec["sourceTrack"]]
        saved = json.loads(Path(spec["referencePath"]).read_text())
        assert saved["preparedAudioSHA256"] == spec["sha256"]
        assert Counter((s["start"], s["end"]) for s in raw["segments"]) == Counter(
            (s["start"], s["end"]) for s in saved["intervals"])
        aliases = {}
        reference = dict(audioDurationSeconds=spec["durationSeconds"], intervals=[])
        for s in raw["segments"]:
            if not s.get("speaker"):
                continue
            assert 0 <= s["start"] < s["end"] <= spec["durationSeconds"]
            alias = aliases.setdefault(s["speaker"], f"worker-{len(aliases):03d}")
            reference["intervals"].append(dict(start=s["start"], end=s["end"], speaker=alias))
        directory = Path(snap["snapshotDirectory"])
        annotation_path, key_path = directory / "blind/annotations.json", directory / "private/key.json"
        assert sha(annotation_path) == snap["annotationSHA256"]
        assert sha(key_path) == snap["keySHA256"]
        annotations, key = json.loads(annotation_path.read_text()), json.loads(key_path.read_text())
        assert key["audio_sha256"] == spec["sha256"]
        if name == overlay["sample"]:
            assert overlay["sourceAnnotationSHA256"] == snap["annotationSHA256"]
            for clip in annotations["clips"]:
                for row in clip["intervals"]:
                    row["speaker"] = overlay["speakerMapping"].get(row["speaker"], row["speaker"])
        human = []
        by_id = {c["id"]: c for c in annotations["clips"]}
        for selection in key["clips"]:
            clip = by_id[selection["id"]]
            assert clip["status"] == "reviewed"
            human.append(dict(start=selection["startSeconds"], end=selection["endSeconds"],
                              category=selection["category"], intervals=clip["intervals"],
                              reviewedRegions=clip["reviewedRegions"]))
        ref_path = out / (name + "-references.json")
        ref_path.write_text(json.dumps(dict(silver=reference, human=human), indent=2) + "\n")
        samples.append(dict(id=name, audioPath=str(audio), audioSHA256=spec["sha256"],
                            referencesPath=str(ref_path), referencesSHA256=sha(ref_path),
                            rawWorkerOutputSHA256=sha(raw_path), annotationSHA256=snap["annotationSHA256"],
                            keySHA256=snap["keySHA256"], durationSeconds=spec["durationSeconds"],
                            workerSpeakerCount=len(aliases)))
    model_data = out / "data/LocalModels"
    for model in ("community1", "nemotronLow"):
        shutil.copytree(args.installed_models / model, model_data / model)
    manifest = dict(schemaVersion=1, samples=samples, dataDirectory=str(model_data.parent),
                    referenceProvenance="raw extraction output retained by RunPod client; historical worker revision absent",
                    adjudicationSHA256=sha(frozen / "adjudication.json"),
                    evaluationSnapshotSHA256=sha(frozen / "snapshot-receipt.json"))
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps([dict(sample=s["id"], seconds=s["durationSeconds"], workerSpeakers=s["workerSpeakerCount"]) for s in samples]))


if __name__ == "__main__":
    main()
