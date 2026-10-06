"""Select quiet transcript gaps for listening, without claiming speech detection."""

import argparse
import json
import subprocess
from pathlib import Path

import numpy as np


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path)
    parser.add_argument("transcript", type=Path, help="Imported segment JSONL")
    parser.add_argument("output", type=Path)
    parser.add_argument("--after", type=int, default=360)
    parser.add_argument("--count", type=int, default=12)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Use a new output directory")
    samples = np.frombuffer(
        subprocess.check_output(
            [
                "ffmpeg",
                "-v",
                "error",
                "-i",
                str(args.audio),
                "-ac",
                "1",
                "-ar",
                "16000",
                "-f",
                "f32le",
                "-",
            ]
        ),
        dtype=np.float32,
    )
    seconds = len(samples) // 16000
    blocks = samples[: seconds * 16000].reshape(seconds, 16000)
    db = 20 * np.log10(np.maximum(np.sqrt(np.mean(blocks**2, axis=1)), 1e-9))
    coverage = np.zeros(seconds)
    for line in args.transcript.read_text().splitlines():
        segment = json.loads(line)
        for second in range(
            max(0, int(segment["start"])), min(seconds, int(segment["end"]) + 1)
        ):
            coverage[second] = max(
                coverage[second],
                max(0, min(second + 1, segment["end"]) - max(second, segment["start"])),
            )
    candidates = []
    for start in range(args.after, seconds - 40, 20):
        energy, covered = db[start : start + 40], coverage[start : start + 40]
        candidates.append(
            {
                "start": start,
                "duration": 40,
                "median_dbfs": float(np.median(energy)),
                "p90_dbfs": float(np.quantile(energy, 0.9)),
                "uncovered_seconds": float(np.sum(1 - covered)),
                "quiet_uncovered_seconds": int(
                    np.sum((covered < 0.2) & (energy > -65) & (energy < -32))
                ),
            }
        )
    candidates.sort(
        key=lambda row: (row["quiet_uncovered_seconds"], row["uncovered_seconds"]),
        reverse=True,
    )
    selected = []
    for candidate in candidates:
        if all(
            abs(candidate["start"] - previous["start"]) >= 100 for previous in selected
        ):
            selected.append(candidate)
        if len(selected) == args.count:
            break
    selected.sort(key=lambda row: row["start"])
    args.output.mkdir(parents=True)
    (args.output / "scan.private.json").write_text(
        json.dumps(
            {
                "duration": len(samples) / 16000,
                "selected": selected,
                "candidates": candidates,
                "coverage_method": "Maximum individual segment overlap per second; an approximate coverage proxy, not exact interval union.",
                "selection_method": "Rank 40-second windows at 20-second strides by seconds with under 0.2 transcript coverage and RMS between -65 and -32 dBFS, then uncovered duration. Separate starts by at least 100 seconds. Energy is not speech detection.",
            },
            indent=2,
        )
    )
    selection = [
        {
            "id": f"room{i + 1:02}",
            "language": "en",
            "setting": "room-quiet-gap",
            "start": row["start"],
            "duration": row["duration"],
            "sources": [{"id": "microphone", "path": str(args.audio.resolve())}],
        }
        for i, row in enumerate(selected)
    ]
    (args.output / "selection.private.json").write_text(json.dumps(selection, indent=2))
    np.savez(args.output / "scan.private.npz", db=db, coverage=coverage)
    print(f"Selected {len(selected)} windows")


if __name__ == "__main__":
    main()
