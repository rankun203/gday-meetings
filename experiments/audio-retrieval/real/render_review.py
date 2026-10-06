"""Render a private listening queue after text-only semantic triage."""

import argparse
import json
import re
from pathlib import Path

from review import tokens
from triage import validate


def display_text(text):
    text = re.sub(r"[ \t]+", " ", text)
    return re.sub(r"(?<=[\u3400-\u9fff]) +(?=[\u3400-\u9fff])", "", text)


def clock(seconds):
    return f"{int(seconds) // 60:02d}:{int(seconds) % 60:02d}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("review_directory", type=Path)
    parser.add_argument("judgments", type=Path)
    parser.add_argument(
        "--priority-meeting", help="Anonymous meeting ID to review first"
    )
    args = parser.parse_args()
    root = args.review_directory
    # Human annotations can live in any generated review document.
    outputs = [
        "focused-summary.json",
        "focused-review.json",
        "FOCUSED-REVIEW.md",
        "START-HERE.md",
        "PRIORITY-REVIEW.md",
        "first-pass-ids.json",
    ]
    if any((root / name).exists() for name in outputs):
        parser.error(
            "Review outputs already exist. Use a fresh review directory to preserve annotations."
        )
    items = json.loads((root / "review.json").read_text())
    judgments = json.loads(args.judgments.read_text())
    validate(items, judgments)
    decisions = {j["id"]: j for j in judgments}
    grouped = {}
    for item in items:
        judgment = decisions[item["id"]]
        if judgment["decision"] != "review":
            continue
        entry = dict(item, triage=judgment)
        key = (item["meeting"], item["start"], tuple(tokens(judgment["focus_quote"])))
        if key in grouped:
            grouped[key]["also_on"].append({"id": item["id"], "audio": item["audio"]})
        else:
            entry["also_on"] = []
            grouped[key] = entry
    queue = list(grouped.values())
    summary = json.loads((root / "summary.json").read_text())
    summary.update(
        semantic_candidates=len(items),
        semantic_equivalent=sum(j["decision"] == "equivalent" for j in judgments),
        semantic_review=sum(j["decision"] == "review" for j in judgments),
        unique_review_items=len(queue),
        semantic_model="gpt-5.6-luna",
        listening_verified=0,
    )
    (root / "focused-summary.json").write_text(json.dumps(summary, indent=2))
    (root / "focused-review.json").write_text(
        json.dumps(queue, ensure_ascii=False, indent=2)
    )
    header = [
        "---",
        "title: Improve the reference transcript",
        "date: 2026-10-06",
        "status: awaiting-listening-review",
        "---",
        "",
        "GPT is a reference-drafting tool, not an app candidate. Review these possible gaps to improve the transcript used to label retrieval evidence. Only potential meaningful GPT content absent from Apple is listed. A text-only comparison removed apparent equivalent wording, formatting and fillers. It can make mistakes; the complete paired transcripts and raw discrepancy records remain available. No item is verified ground truth.",
        "",
        f"Ten five-minute real meeting excerpts; {len(queue)} listening items after filtering and duplicate removal. Review focus quotes, not every wording difference in the full context.",
        "",
        "Times refer to the original recording. Clips contain the 20-second submitted turn plus up to two seconds of context. Apple context includes both sources where available. A GPT-only statement may be a hallucination.",
        "",
    ]

    def card(item):
        return [
            f"## {item['id']} · {clock(item['start'])}–{clock(item['end'])}",
            "",
            f"[Listen]({item['audio']})",
            "",
            "**Check this GPT content:** " + item["triage"]["focus_quote"],
            "",
            "**Why flagged:** " + item["triage"]["reason"],
            "",
            "**Apple context:** " + display_text(item["apple"]),
            "",
            "**GPT context:** " + display_text(item["gpt"]),
            "",
            "**Reference correction:** Give the words actually spoken, or mark same meaning / not audible / unclear. Do not accept a GPT-only claim unless the audio supports it.",
            "",
            *[f"Also captured on [{x['id']}]({x['audio']})." for x in item["also_on"]],
            "",
        ]

    full = list(header)
    for item in queue:
        full += card(item)
    (root / "FOCUSED-REVIEW.md").write_text("\n".join(full))
    first = header + [
        "# First pass",
        "",
        "One flagged item per meeting, prioritizing factual differences, then the length of the quoted difference. These selected examples do not estimate overall accuracy. Continue with the [complete listening queue](FOCUSED-REVIEW.md).",
        "",
    ]
    chosen = []
    for meeting in sorted(
        {x["meeting"] for x in queue},
        key=lambda meeting: (meeting != args.priority_meeting, meeting),
    ):
        item = max(
            (x for x in queue if x["meeting"] == meeting),
            key=lambda x: (
                x["triage"]["priority"],
                len(tokens(x["triage"]["focus_quote"])),
            ),
        )
        chosen.append(item["id"])
        first += card(item)
    if args.priority_meeting:
        priority = [item for item in queue if item["meeting"] == args.priority_meeting]
        priority_report = header + [
            "# Priority recording",
            "",
            f"{len(priority)} reference questions from {args.priority_meeting}. This is the selected five-minute excerpt; the rest of the recording has not been transcribed in this pass.",
            "",
        ]
        for item in priority:
            priority_report += card(item)
        (root / "PRIORITY-REVIEW.md").write_text("\n".join(priority_report))
    (root / "START-HERE.md").write_text("\n".join(first))
    (root / "first-pass-ids.json").write_text(json.dumps(chosen, indent=2))
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
