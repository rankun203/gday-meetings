"""Export private speaker evidence to Embedding Atlas without modifying meetings."""

import argparse
import base64
import hashlib
import importlib.metadata
import io
import json
import math
import os
import shutil
import tempfile
from pathlib import Path

VERSION = "gday-span-feature-center-v2"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def overlap(a, b):
    return (
        max(0, min(a["end"], b["end"]) - max(a["start"], b["start"]))
        if a["source"] == b["source"]
        else 0
    )


def vector(sample):
    embedding = sample["embedding"]
    values = embedding["values"]
    if embedding["type"].get("compatibilityVersion") != VERSION:
        raise ValueError("Only corrected v2 embeddings can enter this projection")
    if len(values) != 256 or not all(math.isfinite(x) for x in values):
        raise ValueError("Expected 256 finite embedding dimensions")
    norm = math.sqrt(sum(x * x for x in values))
    if norm <= 0:
        raise ValueError("Zero embedding")
    return [x / norm for x in values]


def membership(result, sample_ids, untrusted_ids):
    assigned, ranks = {}, {}
    for cluster in result["clusters"]:
        for identifier in cluster["sampleIDs"]:
            if identifier not in sample_ids or identifier in assigned:
                raise ValueError("Cluster membership is unknown or duplicated")
            assigned[identifier] = cluster["id"]
        for rank, identifier in enumerate(cluster["representativeSampleIDs"], 1):
            if identifier not in cluster["sampleIDs"] or identifier in ranks:
                raise ValueError("Invalid representative membership")
            ranks[identifier] = rank
    rejected = set(result["rejectedSampleIDs"])
    untrusted = set(untrusted_ids)
    if len(untrusted) != len(untrusted_ids) or len(rejected) != len(
        result["rejectedSampleIDs"]
    ):
        raise ValueError("Repeated excluded sample ID")
    if (
        rejected & set(assigned)
        or untrusted & (rejected | set(assigned))
        or set(assigned) | rejected | untrusted != sample_ids
    ):
        raise ValueError(
            "Result does not account for every evidence sample exactly once"
        )
    return assigned, ranks


def trust(sample, windows):
    matching = [
        w
        for w in windows
        if w["source"] == sample["source"]
        and sample["localSpeakerID"] in w["localSpeakerIDs"]
    ]
    if len(matching) != 1:
        return None, "missing_or_ambiguous_window"
    window = matching[0]
    if sample["start"] < window["publicationStart"]:
        return window["generation"], "before_publication"
    cap = window.get("capacityReachedAt")
    if not all(
        math.isfinite(window[k]) for k in ("publicationStart", "observedEnd")
    ) or (cap is not None and not math.isfinite(cap)):
        raise ValueError("Nonfinite window bounds")
    if cap is not None and sample["end"] > cap:
        return window["generation"], "after_capacity"
    if sample["end"] > window["observedEnd"]:
        return window["generation"], "after_observed_end"
    return window["generation"], "trusted_window"


def build_rows(
    evidence, result, historical, references, historical_intervals, untrusted_ids=()
):
    samples = evidence["samples"]
    ids = {s["id"] for s in samples}
    if len(ids) != len(samples):
        raise ValueError("Repeated evidence sample ID")
    assigned, ranks = membership(result, ids, untrusted_ids)
    examples = {e["id"]: e for e in historical["examples"]}
    speakers = {s["id"]: s for s in historical["speakers"]}
    people = historical.get("people", {})
    rows = []
    contracts = set()
    for role, collection in (
        ("replay_sample", samples),
        ("historical_reference", references.get("samples", [])),
    ):
        for sample in collection:
            values = vector(sample)
            contracts.add(json.dumps(sample["embedding"]["type"], sort_keys=True))
            if (
                not all(math.isfinite(sample[k]) for k in ("start", "end"))
                or not sample["start"] < sample["end"]
                or sample["start"] < 0
            ):
                raise ValueError("Invalid timed sample")
            generation, reason = (
                trust(sample, evidence.get("windows", []))
                if role == "replay_sample"
                else (None, "historical_reference_not_replay_evidence")
            )
            example = (
                examples.get(sample["id"]) if role == "historical_reference" else None
            )
            if role == "historical_reference" and (
                example is None
                or any(sample[k] != example[k] for k in ("source", "start", "end"))
            ):
                raise ValueError("Reference does not match its historical excerpt")
            confirmed = bool(
                example
                and example.get("review") == "confirmed"
                and not example.get("excluded")
                and not example.get("manuallyCleared")
                and example.get("personID")
            )
            person_id = example.get("personID") if confirmed else None
            contexts = []
            for interval in historical_intervals:
                seconds = overlap(sample, interval)
                if seconds <= 0:
                    continue
                speaker = speakers.get(interval.get("speakerID"), {})
                context_person = interval.get("personID") or speaker.get("personID")
                contexts.append(
                    {
                        "speakerLabel": speaker.get("label", interval.get("speakerID")),
                        "personName": people.get(context_person, {}).get("name"),
                        "overlapSeconds": seconds,
                    }
                )
            rows.append(
                {
                    "id": role + ":" + sample["id"],
                    "sampleID": sample["id"],
                    "role": role,
                    "source": sample["source"],
                    "start": sample["start"],
                    "end": sample["end"],
                    "duration": sample["end"] - sample["start"],
                    "localLabel": sample["localSpeakerID"],
                    "window": generation,
                    "trustReason": reason,
                    "trusted": reason == "trusted_window"
                    and sample["id"] not in untrusted_ids,
                    "productionSampleStatus": (
                        "historical_reference"
                        if role != "replay_sample"
                        else "untrusted"
                        if sample["id"] in untrusted_ids
                        else "invalid"
                        if sample["id"] in result["rejectedSampleIDs"]
                        else "clustered"
                    ),
                    "cluster": assigned.get(sample["id"])
                    if role == "replay_sample"
                    else None,
                    "representativeRank": ranks.get(sample["id"])
                    if role == "replay_sample"
                    else None,
                    "reviewConfirmedPerson": people.get(person_id, {}).get("name")
                    if person_id
                    else None,
                    "reviewConfirmedPersonID": person_id,
                    "historicalContext": json.dumps(contexts, ensure_ascii=False),
                    "historicalContextMeaning": "Historical context, not ground truth",
                    "embedding": values,
                }
            )
    if len({r["id"] for r in rows}) != len(rows):
        raise ValueError("Repeated role/sample identity")
    if len(contracts) > 1:
        raise ValueError("Mixed typed embedding contracts")
    return rows


def neighbors_and_diagnostics(rows, k=15):
    import numpy as np

    values = np.asarray([r["embedding"] for r in rows], dtype=np.float64)
    references = [
        i
        for i, row in enumerate(rows)
        if row["role"] == "historical_reference" and row["reviewConfirmedPersonID"]
    ]
    # One query at a time bounds temporary memory; neighbors use original 256D space.
    for i, row in enumerate(rows):
        scores = np.clip(values @ values[i], -1, 1)
        order = sorted(
            (j for j in range(len(rows)) if j != i), key=lambda j: (-scores[j], j)
        )[:k]
        row["neighbors"] = {
            "ids": order,
            "distances": [float(1 - scores[j]) for j in order],
        }
        by_person = {}
        excluded = 0
        for j in references:
            if i == j or overlap(row, rows[j]) > 0:
                excluded += 1
                continue
            person = rows[j]["reviewConfirmedPersonID"]
            if person not in by_person or scores[j] > by_person[person][0]:
                by_person[person] = (
                    float(scores[j]),
                    rows[j]["reviewConfirmedPerson"],
                    rows[j]["id"],
                )
        ranked = sorted(by_person.items(), key=lambda item: (-item[1][0], item[0]))
        row["diagnosticReferenceName"] = ranked[0][1][1] if ranked else None
        row["diagnosticReferenceCosine"] = ranked[0][1][0] if ranked else None
        row["diagnosticReferenceMargin"] = (
            ranked[0][1][0] - ranked[1][1][0] if len(ranked) > 1 else None
        )
        row["diagnosticReferenceSampleID"] = ranked[0][1][2] if ranked else None
        row["overlappingReferencesExcluded"] = excluded
        row["referenceDiagnosisMeaning"] = (
            "Nearest independent confirmed excerpt; not calibrated or applied"
        )


def audio_data_url(row, sources):
    import soundfile as sf

    source = sources[row["source"]]
    path = source["audioPath"]
    offset = source.get("timeOffsetSeconds", 0)
    with sf.SoundFile(path) as stream:
        start = round((row["start"] - offset) * stream.samplerate)
        end = round((row["end"] - offset) * stream.samplerate)
        if start < 0 or end > len(stream) or start >= end:
            raise ValueError("Excerpt exceeds supplied audio")
        stream.seek(start)
        pcm = stream.read(end - start, dtype="float32", always_2d=True)
        buffer = io.BytesIO()
        sf.write(buffer, pcm, stream.samplerate, format="WAV", subtype="PCM_16")
    return "data:audio/wav;base64," + base64.b64encode(buffer.getvalue()).decode()


def covered_seconds(intervals):
    total = 0
    for source in {r["source"] for r in intervals}:
        end = -1
        for row in sorted(
            (r for r in intervals if r["source"] == source), key=lambda r: r["start"]
        ):
            total += max(0, row["end"] - max(end, row["start"]))
            end = max(end, row["end"])
    return total


def atomic_directory(destination, writer):
    """Publish a complete export directory; remove staging after any failure."""
    if destination.exists():
        raise ValueError("Export destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".projector-stage-", dir=destination.parent))
    try:
        writer(staging)
        if destination.exists():
            raise ValueError("Export destination appeared during export")
        os.rename(staging, destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in (
        "manifest",
        "evidence",
        "result",
        "audit",
        "historical-examples",
        "output",
    ):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--references-v2", type=Path)
    parser.add_argument("--historical-intervals", type=Path)
    args = parser.parse_args()
    destination = args.output.resolve()
    root = Path(__file__).resolve().parents[2] / "tmp"
    if not destination.is_relative_to(root) or destination.exists():
        raise ValueError("Output must be a new directory inside ignored repository tmp")
    paths = {
        name: value for name, value in vars(args).items() if name != "output" and value
    }
    raw_inputs = {name: path.read_bytes() for name, path in paths.items()}
    input_hashes = {
        name: hashlib.sha256(data).hexdigest() for name, data in raw_inputs.items()
    }
    script_hash = sha(__file__)
    loaded = {name: json.loads(data) for name, data in raw_inputs.items()}
    audit = loaded["audit"]
    if audit.get("evidenceSHA256") != input_hashes["evidence"]:
        raise ValueError("Production audit does not bind supplied evidence")
    historical = loaded["historical_examples"]
    intervals = loaded.get("historical_intervals", {}).get(
        "intervals", historical["examples"]
    )
    rows = build_rows(
        loaded["evidence"],
        loaded["result"],
        historical,
        loaded.get("references_v2", {}),
        intervals,
        audit["untrustedSampleIDs"],
    )
    if not rows:
        raise ValueError("No compatible samples")
    sources = {s["actualSource"]: s for s in loaded["manifest"]["samples"]}
    if len(sources) != len(loaded["manifest"]["samples"]):
        raise ValueError("Duplicate audio source")
    for source in sources.values():
        if sha(source["audioPath"]) != source["audioSHA256"]:
            raise ValueError("Source WAV hash differs")
    neighbors_and_diagnostics(rows)
    import numpy as np
    import pyarrow as pa
    import pyarrow.parquet as pq

    if len(rows) >= 3:
        import umap

        projection = umap.UMAP(
            n_components=2,
            n_neighbors=min(15, len(rows) - 1),
            metric="cosine",
            random_state=42,
            transform_seed=42,
            n_jobs=1,
            init="random",
        ).fit_transform(np.array([r["embedding"] for r in rows]))
    else:
        projection = np.zeros((len(rows), 2))
    for row, point in zip(rows, projection, strict=True):
        row["projection_x"], row["projection_y"] = map(float, point)
        row["audio"] = audio_data_url(row, sources)
    summary = {
        "schemaVersion": 1,
        "sampleCount": len(rows),
        "replaySampleCount": len(loaded["evidence"]["samples"]),
        "referenceCount": len(loaded.get("references_v2", {}).get("samples", [])),
        "clusterCount": len(loaded["result"]["clusters"]),
        "clusters": [
            {
                "id": c["id"],
                "sampleCount": len(c["sampleIDs"]),
                "representativeCount": len(c["representativeSampleIDs"]),
                "sampleUnionSeconds": covered_seconds(
                    [r for r in rows if r["cluster"] == c["id"]]
                ),
            }
            for c in loaded["result"]["clusters"]
        ],
        "sources": {
            source: {
                "audioDurationSeconds": spec["durationSeconds"],
                "sampleUnionSeconds": covered_seconds(
                    [
                        r
                        for r in rows
                        if r["source"] == source and r["role"] == "replay_sample"
                    ]
                ),
                "activityUnionSeconds": covered_seconds(
                    [r for r in loaded["evidence"]["activity"] if r["source"] == source]
                ),
            }
            for source, spec in sources.items()
        },
        "sampleUnionSecondsByRole": {
            role: covered_seconds([r for r in rows if r["role"] == role])
            for role in {r["role"] for r in rows}
        },
        "activityUnionSeconds": covered_seconds(loaded["evidence"]["activity"]),
        "projection": "UMAP cosine seed42; zero coordinates for fewer than three rows",
        "neighbors": "Exact normalized 256D cosine, self excluded",
        "historicalContext": "Historical context, not ground truth; interval overlaps never assign replay identity",
        "diagnosticReference": "Best independent confirmed excerpt per person, leave overlapping same-source PCM out; not calibrated or applied",
        "sourceSHA256": input_hashes,
        "audioSHA256": {name: spec["audioSHA256"] for name, spec in sources.items()},
        "scriptSHA256": script_hash,
        "packages": {
            name: importlib.metadata.version(name)
            for name in ("numpy", "umap-learn", "pyarrow", "soundfile")
        },
    }

    def write_output(staging):
        pq.write_table(pa.Table.from_pylist(rows), staging / "samples.parquet")
        with (staging / "samples.jsonl").open("x") as stream:
            for row in rows:
                stream.write(
                    json.dumps(row, ensure_ascii=False, allow_nan=False) + "\n"
                )
        summary["outputSHA256"] = {
            name: sha(staging / name) for name in ("samples.parquet", "samples.jsonl")
        }
        for name, path in paths.items():
            if sha(path) != input_hashes[name]:
                raise ValueError("Parsed input changed during export")
        for spec in sources.values():
            if sha(spec["audioPath"]) != spec["audioSHA256"]:
                raise ValueError("Audio changed during export")
        if sha(__file__) != script_hash:
            raise ValueError("Exporter changed during export")
        (staging / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    atomic_directory(destination, write_output)
    print(json.dumps({"output": str(destination), "sampleCount": len(rows)}))


if __name__ == "__main__":
    main()
