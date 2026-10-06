"""Prepare private real-audio excerpts from an explicit selection manifest."""

import argparse
import hashlib
import json
import subprocess
import wave
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("selection", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    rows = []
    for meeting in json.loads(args.selection.read_text()):
        for source in meeting["sources"]:
            ident = meeting["id"] + "-" + source["id"]
            audio = args.output / (ident + ".wav")
            subprocess.run(
                [
                    "ffmpeg",
                    "-v",
                    "error",
                    "-nostdin",
                    "-y",
                    "-ss",
                    str(meeting["start"]),
                    "-i",
                    source["path"],
                    "-t",
                    str(meeting["duration"]),
                    "-ac",
                    "1",
                    "-ar",
                    "24000",
                    "-c:a",
                    "pcm_s16le",
                    str(audio),
                ],
                check=True,
            )
            with wave.open(str(audio)) as wav:
                duration = wav.getnframes() / wav.getframerate()
            if abs(duration - meeting["duration"]) > 0.1:
                raise ValueError(f"Incomplete excerpt: {ident}")
            rows.append(
                {
                    "id": ident,
                    "meeting": meeting["id"],
                    "source": source["id"],
                    "setting": meeting["setting"],
                    "language": meeting["language"],
                    "source_start": meeting["start"],
                    "duration": duration,
                    "audio": str(audio.resolve()),
                    "sha256": hashlib.sha256(audio.read_bytes()).hexdigest(),
                }
            )
    (args.output / "recordings.jsonl").write_text(
        "".join(json.dumps(x) + "\n" for x in rows)
    )
    print(f"Prepared {len(rows)} source tracks")


if __name__ == "__main__":
    main()
