"""Verify frozen selection, source placement, hashes, and every rendered PCM sample."""

import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile

import numpy as np
import soundfile as sf

from prepare import ARCHIVE, RATE, digest


def validate(manifest_path):
    manifest = json.loads(manifest_path.read_text())
    root = manifest_path.parent
    selection_path = root / "selection.json"
    selection = json.loads(selection_path.read_text())
    if digest(selection_path) != manifest["selectionSHA256"]:
        raise ValueError("Selection hash differs")
    cohorts = selection["cohorts"]
    if any(len(v) != 12 or len(set(v)) != 12 for v in cohorts.values()):
        raise ValueError("Each cohort must have twelve distinct speakers")
    if set(cohorts["development"]) & set(cohorts["validation"]):
        raise ValueError("Cohorts share speakers")
    archive = root / ARCHIVE
    if digest(archive) != manifest["sourceArchiveSHA256"]:
        raise ValueError("Archive hash differs")
    results = []
    with tarfile.open(archive, "r:gz") as tar:
        for item in manifest["samples"]:
            wav, reference = Path(item["audioPath"]), Path(item["ownershipPath"])
            if digest(wav) != item["audioSHA256"] or digest(reference) != item["ownershipSHA256"]:
                raise ValueError("Recording or ownership hash differs")
            ref = json.loads(reference.read_text())
            actual, rate = sf.read(wav, dtype="float64")
            if rate != RATE or actual.ndim != 1 or len(actual) != round(item["durationSeconds"] * RATE):
                raise ValueError("Recording format or duration differs")
            expected = np.zeros_like(actual)
            intervals, seen, owner_frames = [], set(), np.zeros(len(actual), dtype=np.int16)
            for placement in ref["placements"]:
                if placement["speaker"] not in cohorts[item["cohort"]] or placement["member"] in seen:
                    raise ValueError("Invalid or repeated source utterance")
                seen.add(placement["member"])
                parts = PurePosixPath(placement["member"]).parts
                if len(parts) != 5 or parts[:2] != ("LibriSpeech", "test-clean") or parts[2] != placement["speaker"]:
                    raise ValueError("Source member does not match its owner")
                member = tar.getmember(placement["member"])
                if not member.isfile():
                    raise ValueError("Source member is not a regular file")
                raw = tar.extractfile(member).read()
                if hashlib.sha256(raw).hexdigest() != placement["sourceSHA256"]:
                    raise ValueError("Source audio hash differs")
                source, source_rate = sf.read(io.BytesIO(raw), dtype="float64")
                source_start, frames, start = (placement[k] for k in ("sourceStartFrame", "frames", "outputStartFrame"))
                if source_rate != RATE or not 0 <= source_start < source_start + frames <= len(source):
                    raise ValueError("Invalid source crop")
                if not 0 <= start < start + frames <= len(actual):
                    raise ValueError("Invalid output placement")
                expected[start:start + frames] += source[source_start:source_start + frames] * placement["gain"]
                owner_frames[start:start + frames] += 1
                intervals.append(dict(start=start / RATE, end=(start + frames) / RATE, speaker=placement["speaker"]))
            if intervals != ref["intervals"]:
                raise ValueError("Ownership intervals differ from source placements")
            delta = float(np.max(np.abs(actual - expected)))
            if delta > 1 / 32768 + 1e-12 or np.any(actual[owner_frames == 0] != 0):
                raise ValueError("Rendered audio differs from placements or injected silence")
            results.append(dict(id=item["id"], durationSeconds=len(actual) / RATE,
                sourcePlacements=len(intervals), speakers=len({r["speaker"] for r in intervals}),
                injectedSilenceSeconds=float(np.count_nonzero(owner_frames == 0)) / RATE,
                overlapPlacementSeconds=float(np.count_nonzero(owner_frames > 1)) / RATE,
                maximumPCMQuantizationError=delta))
    return dict(manifestSHA256=digest(manifest_path), selectionSHA256=digest(selection_path), validatorSHA256=digest(__file__),
        dependencies=dict(numpy=np.__version__, soundfile=sf.__version__, libsndfile=sf.__libsndfile_version__),
        recordings=results)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(validate(args.manifest), indent=2))
