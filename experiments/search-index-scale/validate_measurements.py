"""Validate completeness and lifecycle outcomes in the published benchmark grid."""

import json
import math
from pathlib import Path

ROOT = Path(__file__).parent
BUCKETS = {"perturbed-corpus", "8", "32", "64", "96", "128", "256", "512"}
CANDIDATES = {10, 20, 50, 100, 200, 800, 1000}
OPERATIONS = {"append1000", "delete1000", "replace10DeleteInsert", "deleteEntryNode"}


def read(name):
    text = (ROOT / name).read_text()
    assert "/Users/" not in text, f"Private filesystem path in {name}"
    value = json.loads(text)

    def finite(item):
        if isinstance(item, dict):
            for child in item.values():
                finite(child)
        elif isinstance(item, list):
            for child in item:
                finite(child)
        elif isinstance(item, float):
            assert math.isfinite(item), f"Nonfinite number in {name}"

    finite(value)
    return value


def search_case(case):
    assert case["p50Ms"] >= 0 and case["p95Ms"] >= case["p50Ms"]
    assert set(case["byLength"]) == BUCKETS
    assert sum(row["samples"] for row in case["byLength"].values()) == 180
    assert case["byLength"]["perturbed-corpus"]["samples"] == 96
    expected = {str(k) for k in [10, 20, 50, 100] if k <= case["candidates"]}
    assert set(case["rankingByLimit"]) == expected
    for row in case["rankingByLimit"].values():
        assert all(0 <= value <= 1.0000001 for value in row.values())


def mutation(cell):
    assert {row["operation"] for row in cell["operations"]} == OPERATIONS
    assert cell["appendedProbeHits"] == 8
    assert cell["deletedAbsentAfterReopen"]
    assert cell["deletedCandidatesReturned"] == 0
    assert cell["entryNodeDeletionSearchable"]
    for row in cell["operations"]:
        assert row["totalSeconds"] >= 0


hnsw = read("hnsw_measurements.json")
assert {row["dtype"] for row in hnsw["precisions"]} == {"f32", "f16", "i8"}
for precision in hnsw["precisions"]:
    assert {row["scale"] for row in precision["stages"]} == set(range(1, 11))
    for stage in precision["stages"]:
        assert stage["windows"] == stage["scale"] * 39066
        assert stage["search"]["hardware"] != "serial"
        cases = stage["search"]["cases"]
        assert len(cases) == 14
        assert {(c["candidates"], c["fp32Rerank"]) for c in cases} == {
            (count, rerank) for count in CANDIDATES for rerank in [False, True]
        }
        for case in cases:
            search_case(case)
        assert sum(r["samples"] for r in stage["hybrid"]["byLength"].values()) == 60
        mutation(stage["mutations"])

sqlite = read("diskann_measurements.json")
assert {row["scale"] for row in sqlite["scales"]} == set(range(1, 11))
for stage in sqlite["scales"]:
    for engine, counts in [("diskann", CANDIDATES), ("exact", {10, 20, 50, 100})]:
        cases = stage[engine]["cases"]
        assert len(cases) == len(counts) and {c["candidates"] for c in cases} == counts
        for case in cases:
            search_case(case)
        changes = stage[engine + "Mutations"]
        mutation(changes)
        assert (
            changes["replacementValuesVerified"] and changes["sqliteIntegrity"] == "ok"
        )
    assert sum(r["samples"] for r in stage["hybrid"]["byLength"].values()) == 60
    # This known prerelease failure remains an adoption gate, not a passing API claim.
    assert "deletedPointLookupError" in stage["diskannMutations"]
    assert stage["exactMutations"]["deletedPointLookup"] == 0

native = read("native_limit_measurements.json")
assert len(native["search"]) == 40
assert {(r["scale"], r["limit"]) for r in native["search"]} == {
    (scale, limit) for scale in range(1, 11) for limit in [10, 20, 50, 100]
}
for case in native["search"]:
    assert len(case["queries"]) == 11
    assert all(
        q["strictTopKRecall"] == 1 and q["topKScoresMatch"] for q in case["queries"]
    )
quality = read("quantization_measurements.json")
assert quality["queries"] == 102 and quality["passages"] == 1677
assert len(quality["cases"]) == 45
assert len(read("query_length_measurements.json")) == 7
summary = {
    "status": "passed",
    "dimensions": 384,
    "hnswPrecisionScaleCells": 30,
    "hnswQueryObservations": 30 * 14 * 180,
    "sqliteScaleCellsPerEngine": 10,
    "sqliteQueryObservations": 10 * (7 + 4) * 180,
    "speakerUnionQueries": 40 * 60,
    "nativeCountScaleCells": 40,
    "nativeQueries": 440,
    "lifecycleCells": 50,
    "labeledQueries": 102,
    "knownDiskANNDeletedPointLookupFailure": True,
}
(ROOT / "validation_summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
