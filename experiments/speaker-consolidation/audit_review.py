"""Verify frozen reviewed-clip coverage and exact source-audio alignment."""

import argparse
import json
from pathlib import Path
import wave

from score import private_output, sha, union_seconds


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evaluation-root", type=Path, required=True)
    parser.add_argument("--sample", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    receipt = json.loads((args.evaluation_root/"human-evaluation/snapshot-receipt.json").read_text())
    spec = next(s for s in receipt["samples"] if s["sample"] == args.sample)
    root = Path(spec["snapshotDirectory"])
    annotation_path, key_path = root/"blind/annotations.json", root/"private/key.json"
    assert sha(annotation_path) == spec["annotationSHA256"] and sha(key_path) == spec["keySHA256"]
    annotations, key = json.loads(annotation_path.read_text()), json.loads(key_path.read_text())
    assert sha(key["audio_path"]) == key["audio_sha256"]
    by_id = {c["id"]:c for c in annotations["clips"]}
    clips = []
    with wave.open(key["audio_path"], "rb") as source:
        assert (source.getframerate(),source.getnchannels(),source.getsampwidth()) == (16000,1,2)
        for selected in key["clips"]:
            clip = by_id[selected["id"]]
            assert clip["status"] == "reviewed"
            duration = selected["endSeconds"]-selected["startSeconds"]
            source.setpos(round(selected["startSeconds"]*16000))
            pcm = source.readframes(round(duration*16000))
            with wave.open(str(root/"blind"/(clip["id"]+".wav")), "rb") as stored:
                assert stored.getnframes()/stored.getframerate() == duration
                assert (stored.getframerate(),stored.getnchannels(),stored.getsampwidth()) == (16000,1,2)
                assert stored.readframes(stored.getnframes()) == pcm
            regions = clip["reviewedRegions"]
            assert all(0 <= r["start"] < r["end"] <= duration for r in regions+clip["intervals"])
            clips.append(dict(category=selected["category"], durationSeconds=duration,
                reviewedSeconds=union_seconds(regions), speechUnionSeconds=union_seconds(clip["intervals"]),
                uncertainSeconds=union_seconds(clip.get("uncertainRegions",[])), exactSourcePCM=True,
                instructions=clip["instructions"]))
    output = dict(sample=args.sample, annotationSHA256=sha(annotation_path), keySHA256=sha(key_path),
        audioSHA256=key["audio_sha256"], clips=clips,
        limitation="Metadata and alignment verification does not independently validate a reviewer's speech judgments.")
    with private_output(args.output).open("x") as handle:
        json.dump(output,handle,indent=2)
        handle.write("\n")
    random = [c for c in clips if c["category"]=="random"]
    print(json.dumps(dict(randomClips=len(random),reviewedSeconds=sum(c["reviewedSeconds"] for c in random),
        uncertainSeconds=sum(c["uncertainSeconds"] for c in random),allExactPCM=True)))


if __name__ == "__main__":
    main()
