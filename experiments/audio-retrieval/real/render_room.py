"""Render private room excerpts with legacy and fresh transcripts for listening."""

import argparse
import json
import subprocess
import wave
from pathlib import Path

import numpy as np


def clock(seconds):
    return f"{int(seconds) // 60:02d}:{int(seconds) % 60:02d}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("legacy", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Use a new output directory to preserve annotations")
    rows = [
        json.loads(line)
        for line in (args.run / "audio/recordings.jsonl").read_text().splitlines()
    ]
    legacy = [json.loads(line) for line in args.legacy.read_text().splitlines()]
    args.output.mkdir(parents=True)
    lines = [
        "---",
        "title: Quiet room listening review",
        "date: 2026-10-06",
        "status: awaiting-listening-review",
        "---",
        "",
        "Times refer to the original room recording. Imported text is the historical transcript; Apple and GPT are fresh drafts, not verified references. GPT is used only to help prepare ground truth. Missing text does not prove that speech occurred. Both recognizers received audio at its original level.",
        "",
        "The louder copies apply constant gain, capped at +24 dB and a peak of −1 dBFS. They also amplify room noise. They are listening aids only; recognition used the original audio. Full clips preserve context; GPT turn times below are coarse and can split sentences. Annotate only words you can hear. Leave uncertainty unresolved.",
        "",
    ]
    gains = []
    for row in rows:
        ident = row["id"]
        apple = json.loads((args.run / "apple" / (ident + ".json")).read_text())
        gpt = json.loads((args.run / "gpt" / (ident + ".json")).read_text())
        if not apple["complete"] or not gpt["complete"]:
            raise ValueError("Incomplete transcription receipt")
        with wave.open(row["audio"]) as wav:
            pcm = (
                np.frombuffer(wav.readframes(wav.getnframes()), dtype=np.int16).astype(
                    float
                )
                / 32768
            )
        peak = float(np.max(np.abs(pcm)))
        gain = min(24.0, max(0.0, -1 - 20 * np.log10(max(peak, 1e-9))))
        gains.append({"id": ident, "gain_db": gain})
        for suffix, filters in [
            ("original", []),
            ("louder", ["-af", f"volume={gain}dB"]),
        ]:
            subprocess.run(
                [
                    "ffmpeg",
                    "-v",
                    "error",
                    "-nostdin",
                    "-i",
                    row["audio"],
                    *filters,
                    "-c:a",
                    "aac",
                    "-b:a",
                    "128k",
                    str(args.output / f"{ident}-{suffix}.m4a"),
                ],
                check=True,
            )
        start, end = row["source_start"], row["source_start"] + row["duration"]
        lines += [
            f"## {ident} · {clock(start)}–{clock(end)}",
            "",
            f"[Original level]({ident}-original.m4a) · [Louder copy (+{gain:.1f} dB)]({ident}-louder.m4a)",
            "",
        ]
        historical = [
            segment
            for segment in legacy
            if segment["end"] > start and segment["start"] < end
        ]
        lines += [
            "**Imported transcript:** "
            + (
                " ".join(segment["text"].strip() for segment in historical)
                or "No segment overlaps this interval."
            ),
            "",
            "**Apple draft:** "
            + (
                " ".join(segment["text"].strip() for segment in apple["segments"])
                or "No text."
            ),
            "",
            "**GPT draft by submitted turn:**",
            "",
        ]
        for segment in gpt["segments"]:
            lines += [
                f"- {clock(start + segment['start'])}–{clock(start + segment['end'])}: {segment['text'].strip() or '[No text]'}"
            ]
        lines += ["", "**Optional reference correction:**", "", ""]
    (args.output / "ROOM-REVIEW.md").write_text("\n".join(lines))
    (args.output / "listening-gains.json").write_text(json.dumps(gains, indent=2))
    print(f"Rendered {len(rows)} excerpts")


if __name__ == "__main__":
    main()
