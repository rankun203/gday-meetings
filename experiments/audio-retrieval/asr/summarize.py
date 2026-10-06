"""Summarize the controlled ASR pilot without treating scripts as verified gold."""

import argparse
import json
import statistics
from collections import Counter
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("evaluation", type=Path)
    ap.add_argument("--live", type=Path)
    a = ap.parse_args()
    metrics = json.loads((a.evaluation / "retrieval-metrics.json").read_text())
    quality = json.loads((a.evaluation / "transcript-quality.json").read_text())
    error_rates = []
    for source in ["apple", "whisperx"]:
        for condition in ["clean", "noise10db"]:
            for language in ["en", "zh"]:
                rs = [
                    r
                    for r in quality
                    if (r["source"], r["condition"], r["language"])
                    == (source, condition, language)
                ]
                if not rs:
                    continue
                edits = sum(r["edit_distance"] for r in rs)
                count = sum(r["script_tokens"] for r in rs)
                error_rates.append(
                    {
                        "source": source,
                        "condition": condition,
                        "language": language,
                        "script_tokens": count,
                        "edits": edits,
                        "script_mismatch_rate": edits / count,
                        "empty_windows": sum(r["empty"] for r in rs),
                        "windows_with_segment_fallback": sum(
                            r["fallback_segments_in_recording"] > 0 for r in rs
                        ),
                    }
                )
    index = {(r["dataset"], r["model"]): r for r in metrics}
    rescue = []
    for source in ["apple", "whisperx"]:
        for condition in ["clean", "noise10db"]:
            text = index.get((f"{source}-{condition}", "jina-text-only"))
            audio = index.get((f"audio-{condition}", "jina"))
            if not text or not audio:
                continue
            pairs = zip(text["per_query"], audio["per_query"])
            counts = Counter()
            for t, u in pairs:
                assert t["query_id"] == u["query_id"]
                if t["metrics"] is None:
                    continue
                counts[
                    "both_hit"
                    if t["metrics"]["hit@1"] and u["metrics"]["hit@1"]
                    else "text_only_hit"
                    if t["metrics"]["hit@1"]
                    else "audio_only_hit"
                    if u["metrics"]["hit@1"]
                    else "both_miss"
                ] += 1
            rescue.append(
                {"source": source, "condition": condition, "counts": dict(counts)}
            )
    live = []
    if a.live:
        for path in sorted(a.live.glob("s*.json")):
            r = json.loads(path.read_text())
            events = r["events"]
            final = [e for e in events if e["final"]]
            live.append(
                {
                    "recording_id": r["recording_id"],
                    "duration_seconds": r["duration_seconds"],
                    "events": len(events),
                    "partial_events": len(events) - len(final),
                    "final_events": len(final),
                    "first_event_seconds": events[0]["received_seconds"]
                    if events
                    else None,
                    "median_final_lag_seconds": statistics.median(
                        e["received_seconds"] - e["end"] for e in final
                    )
                    if final
                    else None,
                }
            )
    result = {
        "script_mismatch": error_rates,
        "audio_text_first_result_overlap": rescue,
        "live": live,
        "limits": "Templated synthetic pilot; intended scripts are not listening-verified gold. Live event lag is not live search latency.",
    }
    (a.evaluation / "pilot-summary.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
