"""Export aggregate native measurements without meeting or passage identifiers."""
import argparse
import hashlib
import json
from pathlib import Path
from statistics import median

p = argparse.ArgumentParser()
p.add_argument("--fixture", required=True, type=Path)
p.add_argument("--reference", required=True, type=Path)
p.add_argument("--output", required=True, type=Path)
p.add_argument("--limits", type=int, nargs="+", default=[5, 100])
p.add_argument("--skip-mutations", action="store_true")
p.add_argument("--reference-prefix", default="truth")
p.add_argument("--search-source", type=Path)
a = p.parse_args()
fixture = json.loads((a.fixture / "fixture.json").read_text())
labels = json.loads((a.reference / "query-labels.json").read_text())
window_maps = []
start = 0
for artifact in sorted((a.fixture / "base-artifacts").glob("*.json")):
    rows = json.loads(artifact.read_text())["windows"]
    window_maps.append({row["id"]: start + i + 1 for i, row in enumerate(rows)})
    start += len(rows)
assert start == 39066


def vector_id(result_id):
    meeting, window = result_id.split(":", 1)
    suffix = int(meeting.split("-")[-1])
    block, index = divmod(suffix, 1000000)
    return (block - 1) * 39066 + window_maps[index][window]


def difference(before, after, name):
    return after[name] - before[name]


cases = []
mutations = []
for scale in range(1, fixture["scales"] + 1):
    truth = json.loads((a.reference / f"{a.reference_prefix}-{scale}.json").read_text())
    for limit in a.limits:
        r = json.loads((a.fixture / f"search-{scale}-top{limit}.json").read_text())
        queries = []
        for q in r["queries"]:
            ids = [vector_id(value) for value in q["ids"]]
            expected = truth[q["queryIndex"]]
            top = q["scores"][:5]
            errors = [abs(x-y) for x, y in zip(top, expected["plainScores"])]
            compared_count = min(limit, len(expected["plainScores"]))
            full_errors = [abs(x-y) for x, y in zip(q["scores"][:compared_count], expected["plainScores"][:compared_count])]
            queries.append({"queryIndex": q["queryIndex"], "lengthBucket": labels[q["queryIndex"]],
                "milliseconds": q["milliseconds"],
                "cpuSeconds": difference(q["before"], q["after"], "cpuSeconds"),
                "readBytes": difference(q["before"], q["after"], "readBytes"),
                "rssBefore": q["before"]["rss"], "rssAfter": q["after"]["rss"],
                "physicalFootprintAfter": q["after"]["physicalFootprint"],
                "peakRSSAfter": q["after"]["peakRSS"],
                "thermalState": q["after"]["thermalState"],
                "rssAfterIdle": q.get("afterIdle", q["after"])["rss"],
                "physicalFootprintAfterIdle": q.get("afterIdle", q["after"])["physicalFootprint"],
                "strictTopFiveRecall": len(set(ids[:5]) & set(expected["plain"][:5])) / 5,
                "maximumTopFiveScoreError": max(errors),
                "referenceComparedCount": compared_count,
                "strictTopKRecall": len(set(ids[:compared_count]) & set(expected["plain"][:compared_count])) / compared_count,
                "maximumTopKScoreError": max(full_errors),
                "topKScoresMatch": max(full_errors) < 2e-6,
                "topFiveScoresMatch": max(errors) < 2e-6})
        cases.append({"scale": scale, "windows": r["windows"], "meetings": scale * 366,
            "limit": limit, "sqliteVersion": r["sqliteVersion"], "modelsLoaded": False,
            "queryLifecycle": r.get("queryLifecycle", "continuous-task"),
            "idleMilliseconds": r.get("idleMilliseconds", 0),
            "catalogOpenMilliseconds": r["catalogOpenMilliseconds"],
            "indexOpenMilliseconds": r["indexOpenMilliseconds"],
            "baselineRSS": r["beforeOpen"]["rss"], "finalRSS": r["final"]["rss"],
            "peakRSS": r["final"]["peakRSS"], "physicalFootprint": r["final"]["physicalFootprint"],
            "firstMilliseconds": queries[0]["milliseconds"],
            "warmMedianMilliseconds": median(x["milliseconds"] for x in queries[1:]),
            "queries": queries})
    if a.skip_mutations:
        continue
    raw = json.loads((a.fixture / f"mutation-{scale}.json").read_text())
    result = {k: raw[k] for k in ["scale", "vectors", "meetings", "transactionScope",
                                 "speakerBoostBeforeTopKPassed", "deletedResultsAbsentAfterReopen"]}
    for operation in ("append", "delete"):
        event = raw[operation]
        result[operation] = {"milliseconds": event["milliseconds"],
            **{key: difference(event["before"], event["after"], key)
               for key in ("cpuSeconds", "readBytes", "writtenBytes")},
            "rssBefore": event["before"]["rss"], "rssAfter": event["after"]["rss"],
            "peakRSS": event["after"]["peakRSS"], "physicalFootprint": event["after"]["physicalFootprint"],
            "thermalState": event["after"]["thermalState"]}
    mutations.append(result)
metadata = json.loads((a.fixture / "prepare-1.json").read_text())["metadataBytesAdded"]
report = {"implementation": "Unchanged production SemanticSearchIndex in optimized Swift Testing harness",
    "dimensions": 384, "fixture": fixture, "nativeMetadataBytesPerBlock": metadata,
    "cacheCondition": "Fresh test process and SQLite connections; filesystem caches not cleared",
    "queryScope": "Precomputed query vector through production folder/fingerprint/metadata/FP32 search; no inference or UI",
    "referenceScoreTolerance": 2e-6, "search": cases, "mutations": mutations}
if a.search_source:
    report["productionSearchSHA256"] = hashlib.sha256(a.search_source.read_bytes()).hexdigest()
a.output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"searchCases": len(cases), "mutationCases": len(mutations),
    "allScoresMatch": all(q["topFiveScoresMatch"] for case in cases for q in case["queries"]),
    "maximumScoreError": max(q["maximumTopFiveScoreError"] for case in cases for q in case["queries"]),
    "allTopKScoresMatch": all(q["topKScoresMatch"] for case in cases for q in case["queries"]),
    "maximumTopKScoreError": max(q["maximumTopKScoreError"] for case in cases for q in case["queries"])}, indent=2))
