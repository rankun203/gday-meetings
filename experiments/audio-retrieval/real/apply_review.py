"""Save curated listening corrections without changing annotated review files."""

import argparse
import hashlib
import json
from pathlib import Path


def assemble(queue, decisions, annotated):
    """Validate a human-curated interpretation; do not infer prose corrections."""
    if hashlib.sha256(annotated).hexdigest() != decisions["annotation_sha256"]:
        raise ValueError("Annotation hash mismatch")
    by_id = {item["id"]: item for item in queue}
    seen = set()
    references = []
    for decision in decisions["items"]:
        item_id = decision["id"]
        if item_id not in by_id or item_id in seen:
            raise ValueError("Unknown or duplicate review ID")
        if f"## {item_id} ·" not in annotated.decode():
            raise ValueError("Review ID absent from annotation source")
        seen.add(item_id)
        item = by_id[item_id]
        for span in decision["spans"]:
            if span["evidence"] not in {"audio_review", "context_only"}:
                raise ValueError("Unknown evidence type")
            if not span["text"].strip():
                raise ValueError("Empty correction")
            if span["evidence"] == "audio_review":
                references.append(
                    {
                        "id": item_id,
                        "meeting": item["meeting"],
                        "source": item["source"],
                        "text": span["text"],
                        "evidence": "audio_review",
                        "review_interval": [item["start"], item["end"]],
                        "alignment": "turn interval with boundary context; not word aligned",
                        "scope": "selected span; not a complete turn or excerpt",
                        "annotation_sha256": decisions["annotation_sha256"],
                    }
                )
    return references, [item for item in queue if item["id"] not in seen]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("queue", type=Path)
    parser.add_argument("annotations", type=Path)
    parser.add_argument("decisions", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    annotated = args.annotations.read_bytes()
    decisions = json.loads(args.decisions.read_text())
    refs, remaining = assemble(json.loads(args.queue.read_text()), decisions, annotated)
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "START-HERE.annotated.md").write_bytes(annotated)
    (args.output / "decisions.json").write_text(
        json.dumps(decisions, ensure_ascii=False, indent=2)
    )
    (args.output / "reference-spans.jsonl").write_text(
        "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in refs)
    )
    (args.output / "unannotated.json").write_text(
        json.dumps(remaining, ensure_ascii=False, indent=2)
    )
    summary = {
        "annotated_items": len(decisions["items"]),
        "reviewed_spans": len(refs),
        "unannotated_items": len(remaining),
        "complete_verified_excerpts": 0,
        "annotation_sha256": decisions["annotation_sha256"],
    }
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
