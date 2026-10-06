"""Summarize the opt-in native table layout test's synthetic receipts."""
import argparse
import json
from pathlib import Path
from statistics import median

p = argparse.ArgumentParser()
p.add_argument("input", type=Path)
p.add_argument("output", type=Path)
a = p.parse_args()
d = json.loads(a.input.read_text())
d["limitations"] = "Offscreen table only. Excludes the SwiftUI header, asynchronous summary lookup, actual on-screen presentation, display scanout, and scrolling to later rows."
d["warmSummary"] = []
for count in [10, 20, 50, 100]:
    rows = [x for x in d["samples"] if x["count"] == count and x["repetition"] > 0]
    d["warmSummary"].append({
        "count": count, "samples": len(rows),
        "constructionMedianMilliseconds": median(x["milliseconds"] for x in rows),
        "reloadMedianMilliseconds": median(x["tableReloadMilliseconds"] for x in rows),
        "materializedCells": sorted({x["materializedCells"] for x in rows}),
    })
a.output.write_text(json.dumps(d, indent=2) + "\n")
