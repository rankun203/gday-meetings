"""Create a private, one-sided transcript discrepancy queue with audio links."""

import argparse
import json
import re
import subprocess
import unicodedata
from difflib import SequenceMatcher
from functools import lru_cache
from pathlib import Path


@lru_cache(maxsize=1)
def converter():
    from opencc import OpenCC

    return OpenCC("t2s")


@lru_cache(maxsize=8192)
def tokens(text):
    normalized = converter().convert(unicodedata.normalize("NFKC", text).lower())
    return re.findall(r"[\u3400-\u9fff]|[a-z0-9]+", normalized)


def additions(apple, gpt):
    """Only flag GPT spans absent from nearby Apple text; never claim correctness."""
    a, b = tokens(apple), tokens(gpt)
    extra = []
    for tag, _, _, start, end in SequenceMatcher(
        None, a, b, autojunk=False
    ).get_opcodes():
        if tag not in ("insert", "replace"):
            continue
        part = b[start:end]
        if not part:
            continue
        # Reordered words already present in Apple aren't omissions.
        if any(a[i : i + len(part)] == part for i in range(len(a) - len(part) + 1)):
            continue
        if len(part) == 1 and part[0] in {"uh", "um", "hmm", "啊", "嗯", "呃", "哦"}:
            continue
        extra.append(" ".join(part))
    return extra


def meeting_additions(apple_texts, gpt):
    """Avoid reviewing speech already captured on another Apple source track."""
    b = tokens(gpt)
    closest = max(
        apple_texts,
        key=lambda text: SequenceMatcher(None, tokens(text), b, autojunk=False).ratio(),
    )
    extra = additions(closest, gpt)
    candidates = [tokens(text) for text in apple_texts]
    return [
        span
        for span in extra
        if not any(
            candidate[i : i + len(tokens(span))] == tokens(span)
            for candidate in candidates
            for i in range(len(candidate) - len(tokens(span)) + 1)
        )
    ]


def apple_nearby(receipt, start, end):
    words = [w for segment in receipt["segments"] for w in segment.get("words", [])]
    if words:
        return " ".join(
            w["text"]
            for w in words
            if start - 2 <= (w["start"] + w["end"]) / 2 < end + 2
        )
    return " ".join(
        segment["text"]
        for segment in receipt["segments"]
        if segment["end"] > start - 2 and segment["start"] < end + 2
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("apple", type=Path)
    parser.add_argument("gpt", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "clips").mkdir(exist_ok=True)
    rows = [json.loads(line) for line in args.manifest.read_text().splitlines()]
    queue, totals = (
        [],
        {
            "tracks": 0,
            "turns": 0,
            "normalized_agreement": 0,
            "no_gpt_only_content": 0,
            "gpt_empty": 0,
            "review_turns": 0,
        },
    )
    transcripts = [
        "---",
        "title: Private paired transcripts",
        "date: 2026-10-06",
        "status: unverified",
        "---",
        "",
        "These are recognizer outputs, not verified ground truth. Times are relative to the original recording.",
        "",
    ]
    apples = {
        row["id"]: json.loads((args.apple / (row["id"] + ".json")).read_text())
        for row in rows
    }
    for row in rows:
        apple = apples[row["id"]]
        gpt = json.loads((args.gpt / (row["id"] + ".json")).read_text())
        assert (
            apple["recording"]["sha256"] == gpt["recording"]["sha256"] == row["sha256"]
        )
        assert apple["complete"] and gpt["complete"]
        totals["tracks"] += 1
        transcripts += [f"# {row['id']}", ""]
        for n, segment in enumerate(gpt["segments"]):
            start, end = segment["start"], segment["end"]
            # Compare both saved sources at the same original recording interval.
            contexts = {
                other["source"]: apple_nearby(
                    apples[other["id"]],
                    start + row["source_start"] - other["source_start"],
                    end + row["source_start"] - other["source_start"],
                )
                for other in rows
                if other["meeting"] == row["meeting"]
            }
            nearby = "\n\n".join(
                f"{source}: {text}" for source, text in contexts.items()
            )
            text = segment["text"]
            totals["turns"] += 1
            label = f"{row['id']}-{n + 1:02d}"
            t0, t1 = row["source_start"] + start, row["source_start"] + end
            transcripts += [
                f"## {label}: {t0:.1f}–{t1:.1f} seconds",
                "",
                "**Apple:** " + nearby,
                "",
                "**GPT:** " + text,
                "",
            ]
            if not tokens(text):
                totals["gpt_empty"] += 1
                continue
            if any(tokens(context) == tokens(text) for context in contexts.values()):
                totals["normalized_agreement"] += 1
                continue
            extra = meeting_additions(list(contexts.values()), text)
            if not extra:
                totals["no_gpt_only_content"] += 1
                continue
            totals["review_turns"] += 1
            clip = args.output / "clips" / (label + ".m4a")
            clip_start = max(0, start - 2)
            subprocess.run(
                [
                    "ffmpeg",
                    "-v",
                    "error",
                    "-nostdin",
                    "-y",
                    "-ss",
                    str(clip_start),
                    "-i",
                    row["audio"],
                    "-t",
                    str(min(row["duration"], end + 2) - clip_start),
                    "-c:a",
                    "aac",
                    "-b:a",
                    "96k",
                    str(clip),
                ],
                check=True,
            )
            queue.append(
                {
                    "id": label,
                    "meeting": row["meeting"],
                    "source": row["source"],
                    "start": t0,
                    "end": t1,
                    "apple": nearby,
                    "gpt": text,
                    "gpt_only_spans": extra,
                    "audio": "clips/" + clip.name,
                    "status": "needs_listening",
                    "corrected_text": None,
                }
            )
    (args.output / "paired-transcripts.md").write_text("\n".join(transcripts))
    (args.output / "review.json").write_text(
        json.dumps(queue, ensure_ascii=False, indent=2)
    )
    (args.output / "summary.json").write_text(json.dumps(totals, indent=2))
    report = [
        "---",
        "title: Review GPT-only transcript content",
        "date: 2026-10-06",
        "status: awaiting-listening-review",
        "---",
        "",
        "Review only the content listed as missing from Apple. It may be recovered speech, a recognition substitution, or a GPT hallucination. Listen before accepting it. Agreement is excluded from this queue, but is not verified ground truth.",
        "",
        "Audio clips include up to two seconds of context on either side. Times below refer to the original recording. GPT times identify a 20-second submitted audio turn, not word timestamps. Apple text includes boundary context from both source tracks where available.",
        "",
        f"{totals['tracks']} source tracks; {totals['turns']} turns; {totals['review_turns']} turns contain potential GPT-only content.",
        "",
    ]

    def card(item):
        return [
            f"## {item['id']} · {item['start']:.0f}–{item['end']:.0f} seconds",
            "",
            f"[Listen]({item['audio']})",
            "",
            "**Potential GPT-only content:** " + " / ".join(item["gpt_only_spans"]),
            "",
            "**Apple:** " + item["apple"],
            "",
            "**GPT:** " + item["gpt"],
            "",
            "**Review:** Unreviewed. Mark recovered speech, GPT error, equivalent wording, or unclear; provide corrected text if needed.",
            "",
        ]

    for item in queue:
        report += card(item)
    first_pass = (
        report[: report.index(next(line for line in report if line.startswith("## ")))]
        if queue
        else list(report)
    )
    first_pass[1] = "title: First-pass real transcript review"
    first_pass += [
        "# First pass",
        "",
        "One candidate per meeting, selected by the largest unmatched token span. These are candidates for listening, not confirmed improvements. This prioritization is not a representative accuracy sample. The complete queue is in [REVIEW.md](REVIEW.md).",
        "",
    ]
    for meeting in sorted({item["meeting"] for item in queue}):
        candidates = [item for item in queue if item["meeting"] == meeting]
        chosen = max(
            candidates,
            key=lambda item: max(len(tokens(span)) for span in item["gpt_only_spans"]),
        )
        first_pass += card(chosen)
    (args.output / "START-HERE.md").write_text("\n".join(first_pass))
    (args.output / "REVIEW.md").write_text("\n".join(report))
    print(json.dumps(totals))


if __name__ == "__main__":
    main()
