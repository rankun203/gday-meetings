"""Summarize event-only startup receipts without including library content."""
import argparse
import json
from collections import defaultdict
from pathlib import Path
from statistics import median

parser = argparse.ArgumentParser()
parser.add_argument("receipt", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--background-tasks-disabled", action="store_true")
args = parser.parse_args()
by_process = defaultdict(list)
for line in args.receipt.read_text().splitlines():
    row = json.loads(line)
    by_process[row["process"]].append(row)
runs = []
for rows in by_process.values():
    first = {}
    for row in rows:
        first.setdefault(row["event"], row)
    if "search-ready" not in first:
        continue
    def duration(start, end):
        return first[end]["milliseconds"] - first[start]["milliseconds"]
    queries = []
    submitted = None
    for row in rows:
        if row["event"] == "query-submit":
            submitted = row["milliseconds"]
        elif row["event"] == "results-layout-complete" and submitted is not None:
            queries.append(row["milliseconds"] - submitted)
            submitted = None
    runs.append({
        "windowReadyMilliseconds": first["window-visible-layout-complete"]["milliseconds"],
        "searchReadyMilliseconds": first["search-ready"]["milliseconds"],
        "indexOpenMilliseconds": duration("index-open-start", "index-open-end"),
        "modelPrepareMilliseconds": duration("model-prepare-start", "model-prepare-end"),
        "modelAcquireMilliseconds": duration("model-acquire-start", "model-acquire-end"),
        "tokenizerMilliseconds": duration("model-acquire-end", "tokenizer-ready"),
        "warmupMilliseconds": duration("tokenizer-ready", "warmup-complete"),
        "queryMilliseconds": queries,
        "firstQueryMilliseconds": queries[0] if queries else None,
        "subsequentMedianMilliseconds": median(queries[1:]) if len(queries)>1 else None,
        "peakRSSBytesAtSearchReady": first["search-ready"]["peakRSSBytes"],
        "peakRSSBytes": max(row["peakRSSBytes"] for row in rows),
        "thermalStates": sorted({row["thermalState"] for row in rows}),
    })
report = {"cacheCondition": "Fresh app processes; filesystem and Core ML caches not cleared",
          "windowBoundary": "Visible titled window with content layout complete; not display scan-out",
          "queryBoundary": "Submission handler to completed native result layout",
          "model": "granite97M mixed-fp16-v1", "backgroundTasksDisabled": args.background_tasks_disabled,
          "queryLimit": 100, "runs": runs}
args.output.write_text(json.dumps(report, indent=2)+"\n")
print(json.dumps(report, indent=2))
