"""Prepare frozen, public-speaker capacity stress inputs. No model inference."""

import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import sys
import tarfile
import urllib.request

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "diarization-benchmark"))
from private_paths import private_output

BASE = "https://openslr.trmal.net/resources/12/"
ARCHIVE = "test-clean.tar.gz"
EXPECTED_MD5 = "32fa31d27d2e1cad72775fee3f4849a9"
SEED = "gday-public-capacity-v1"
RATE = 16000


def digest(path, algorithm="sha256"):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, algorithm).hexdigest()


def write_json(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


def rank(value):
    return hashlib.sha256((SEED + ":" + value).encode()).hexdigest()


def schedules():
    """Owner index, crop length, gap after crop; optional simultaneous owner."""
    return {
        "arrivals-returns": [(i, 8., .5, None) for i in range(12)]
        + [(i, 8., .5, None) for i in (0, 7, 3, 11, 1, 8, 2, 9)],
        "short-turns": [(i, 1.5, .2, None) for _ in range(3) for i in range(8)]
        + [(i, 1.5, .2, None) for i in range(8, 12)]
        + [(i, 6., .5, None) for i in (0, 8, 1, 9, 2, 10, 3, 11)],
        "saturated-rearm": [(i, 4., .2, None) for _ in range(2) for i in range(8)]
        + [(i, 6., .5, None) for i in (1, 2, 3, 4, 5, 6, 7, 1, 2)]
        + [(i, 6., .5, None) for i in (8, 9, 10, 11, 0)],
        "six-speaker-overlap": [(i, 8., .5, None) for _ in range(2) for i in range(6)]
        + [(i, 6., .5, (i + 1) % 6) for i in range(6)],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = private_output(args.output)
    out.mkdir(parents=True, exist_ok=True)
    archive = out / ARCHIVE
    checksums = out / "md5sum.txt"
    for name, path in (("md5sum.txt", checksums), (ARCHIVE, archive)):
        if not path.exists():
            partial = path.with_suffix(path.suffix + ".partial")
            urllib.request.urlretrieve(BASE + name, partial)
            partial.replace(path)
    official = {line.split()[1]: line.split()[0] for line in checksums.read_text().splitlines()}
    if official.get(ARCHIVE) != EXPECTED_MD5 or digest(archive, "md5") != EXPECTED_MD5:
        raise ValueError("Archive differs from the pinned official checksum")
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        audio = []
        for member in members:
            path = PurePosixPath(member.name)
            if member.isfile() and len(path.parts) == 5 and path.parts[:2] == ("LibriSpeech", "test-clean"):
                if path.suffix == ".flac" and path.parts[2].isdigit() and path.parts[3].isdigit():
                    audio.append(member)
        speakers = sorted({PurePosixPath(m.name).parts[2] for m in audio}, key=rank)
        if len(speakers) < 24:
            raise ValueError("The source must contain 24 distinct speaker IDs")
        cohorts = {"development": speakers[:12], "validation": speakers[12:24]}
        # This immutable metadata selection precedes decoding, rendering, and all model scores.
        selection = {
            "schemaVersion": 1, "seed": SEED, "sourceURL": BASE + ARCHIVE,
            "archiveMD5": EXPECTED_MD5, "archiveSHA256": digest(archive),
            "officialChecksumSHA256": digest(checksums), "license": "CC-BY-4.0",
            "cohorts": cohorts, "schedules": schedules(),
            "selection": "SHA256(seed:speaker_id), first 12 development, next 12 validation",
        }
        selection_path = out / "selection.json"
        if selection_path.exists():
            if json.loads(selection_path.read_text()) != json.loads(json.dumps(selection)):
                raise ValueError("Existing frozen selection differs")
        else:
            write_json(selection_path, selection)
        chosen = set(speakers[:24])
        candidates = {speaker: [] for speaker in chosen}
        for member in audio:
            speaker = PurePosixPath(member.name).parts[2]
            if speaker not in chosen:
                continue
            raw = tar.extractfile(member).read()
            info = sf.info(io.BytesIO(raw))
            if info.samplerate == RATE and info.channels == 1 and info.frames >= 8 * RATE:
                candidates[speaker].append((member.name, raw, info.frames))
        if any(not rows for rows in candidates.values()):
            raise ValueError("A selected speaker has no eight-second utterance")
        for rows in candidates.values():
            rows.sort(key=lambda row: rank(row[0]))
        # Read named regular members only; never extract archive-supplied paths.
        for name in ("LICENSE.TXT", "README.TXT"):
            found = [m for m in members if m.isfile() and m.name == "LibriSpeech/" + name]
            if len(found) != 1:
                raise ValueError("Missing source license or README")
            target = out / name
            raw = tar.extractfile(found[0]).read()
            if target.exists() and target.read_bytes() != raw:
                raise ValueError("Source attribution changed")
            if not target.exists():
                target.write_bytes(raw)
    generated = []
    for cohort, identifiers in cohorts.items():
        for scenario, turns in schedules().items():
            target = out / f"{cohort}-{scenario}"
            target.mkdir(exist_ok=False)
            used = {speaker: 0 for speaker in identifiers}
            chunks, ownership, placements = [], [], []
            cursor = 0
            for owner, seconds, gap, simultaneous in turns:
                length = round(seconds * RATE)
                mixed = np.zeros(length, dtype=np.float64)
                owners = [owner] if simultaneous is None else [owner, simultaneous]
                for index in owners:
                    speaker = identifiers[index]
                    choices = candidates[speaker]
                    if used[speaker] >= len(choices):
                        raise ValueError("Insufficient distinct utterances for this schedule")
                    member, raw, total = choices[used[speaker]]
                    used[speaker] += 1
                    # Center cropping is deterministic and does not inspect model predictions.
                    offset = (total - length) // 2
                    signal, _ = sf.read(io.BytesIO(raw), dtype="float64")
                    gain = .45 if simultaneous is not None else .9
                    mixed += signal[offset:offset + length] * gain
                    ownership.append(dict(start=cursor / RATE, end=(cursor + length) / RATE, speaker=speaker))
                    placements.append(dict(member=member, sourceSHA256=hashlib.sha256(raw).hexdigest(),
                        sourceStartFrame=offset, frames=length, outputStartFrame=cursor, gain=gain, speaker=speaker))
                if np.max(np.abs(mixed)) > 1:
                    raise ValueError("Generated mixture clips")
                chunks.extend((mixed, np.zeros(round(gap * RATE), dtype=np.float64)))
                cursor += length + round(gap * RATE)
            if cursor > 240 * RATE:
                raise ValueError("Schedule exceeds four minutes")
            wav = target / "audio.wav"
            sf.write(wav, np.concatenate(chunks), RATE, subtype="PCM_16")
            reference = dict(schemaVersion=1, annotationKind="source-placement-ownership-not-speech-activity",
                audioDurationSeconds=cursor / RATE, sampleRate=RATE, intervals=ownership,
                placements=placements, selectionSHA256=digest(selection_path), audioSHA256=digest(wav))
            reference_path = target / "ownership.json"
            write_json(reference_path, reference)
            generated.append(dict(id=target.name, cohort=cohort, scenario=scenario, audioPath=str(wav.resolve()),
                audioSHA256=digest(wav), ownershipPath=str(reference_path.resolve()),
                ownershipSHA256=digest(reference_path), durationSeconds=cursor / RATE))
    write_json(out / "manifest.json", dict(schemaVersion=1, selectionSHA256=digest(selection_path),
        prepareSHA256=digest(__file__), sourceArchiveSHA256=digest(archive), samples=generated))
    print(json.dumps({"recordings": len(generated), "seconds": sum(row["durationSeconds"] for row in generated),
        "selectionSHA256": digest(selection_path)}, indent=2))


if __name__ == "__main__":
    main()
