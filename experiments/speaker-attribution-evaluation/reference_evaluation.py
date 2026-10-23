#!/usr/bin/env python3
"""Offline, meeting-held-out evaluation of cached speaker representations.

Inputs and detailed outputs contain private identities; pass paths at runtime and
keep them in ignored storage. This is a NumPy reference experiment, not an app
latency benchmark. No audio is decoded and no source file is written.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import itertools
import json
import math
import os
import platform
import resource
import statistics
import sys
import time
from collections import Counter, defaultdict
from collections.abc import Iterable
from pathlib import Path
from typing import Any

import numpy as np

CAPS = (1, 3, 6, 12, 24)
SCORERS = ("maximum", "mean", "top3_mean", "centroid")


@dataclasses.dataclass(frozen=True)
class Example:
    identifier: str
    person: str | None
    meeting: str
    model: str
    vector: tuple[float, ...]
    created: float
    duration: float
    provenance: str
    origin: str
    quality: float
    exact_key: str
    rejected: tuple[str, ...] = ()


def normalized(values: Iterable[float]) -> np.ndarray:
    vector = np.asarray(tuple(values), dtype=np.float64)
    if vector.ndim != 1 or not 0 < len(vector) <= 4096 or not np.isfinite(vector).all():
        raise ValueError("Invalid embedding dimensions or values")
    scale = float(np.max(np.abs(vector)))
    if scale == 0:
        raise ValueError("Zero embedding")
    vector = vector / scale
    return vector / np.linalg.norm(vector)


def load_examples(
    snapshot: Path,
) -> tuple[list[Example], list[Example], dict[str, Any]]:
    """Read immutable canonical records. Preserve explicit negative pairs separately."""
    confirmed, negatives = [], []
    counts: Counter[str] = Counter()
    known_people = (
        {p.stem for p in (snapshot / "people").glob("*.json")}
        if (snapshot / "people").exists()
        else None
    )
    state = snapshot / "voice-library"
    deleted_people = {
        json.loads(p.read_text()) for p in (state / "deleted-people").glob("*.json")
    }
    if (state / "transaction.json").exists():
        raise ValueError("Snapshot contains a pending voice-library transaction")
    for path in sorted((state / "examples").glob("*.json")):
        value = json.loads(path.read_text())
        counts["records"] += 1
        if value.get("personID") in deleted_people or (
            value.get("personID")
            and known_people is not None
            and value["personID"] not in known_people
        ):
            counts["missing_or_deleted_person"] += 1
            continue
        if value.get("excluded") or value.get("manuallyCleared"):
            counts["excluded_or_cleared"] += 1
            continue
        representations = state / "representations" / path.name
        vectors = (
            json.loads(representations.read_text()).get("embeddings", [])
            if representations.exists()
            else value.get("embeddings", [])
        )
        if not vectors:
            counts["without_representations"] += 1
        for embedding in vectors:
            try:
                vector = normalized(embedding["values"])
            except (ValueError, KeyError, TypeError):
                counts["invalid_representations"] += 1
                continue
            model = json.dumps(embedding["type"], sort_keys=True, separators=(",", ":"))
            spans = value.get("spans") or [
                {"start": value.get("start", 0), "end": value.get("end", 0)}
            ]
            if value.get("spans") and (
                not all(
                    math.isfinite(s["start"])
                    and math.isfinite(s["end"])
                    and 0 <= s["start"] < s["end"]
                    for s in spans
                )
                or any(a["end"] > b["start"] for a, b in itertools.pairwise(spans))
                or spans[0]["start"] != value.get("start")
                or spans[-1]["end"] != value.get("end")
            ):
                counts["invalid_support_spans"] += 1
                continue
            duration = sum(max(0.0, float(s["end"]) - float(s["start"])) for s in spans)
            # Basic PCM checks describe signal extremes, not perceptual cleanliness.
            pcm = value.get("sampleQuality") or {}
            pcm_range = pcm.get("range", {})
            if not (
                pcm.get("policy") == "pcm-signal-v1"
                and pcm.get("audioRevision") == value.get("audioRevision")
                and all(
                    pcm_range.get(k) == value.get(k)
                    for k in ["audioFile", "source", "start", "end", "spans"]
                )
                and pcm.get("scanConfiguration")
                and pcm.get("sampleCount", 0) > 0
                and abs(pcm.get("sampleCount", 0) / 16000 - duration) <= 0.02
                and all(
                    isinstance(pcm.get(k), (int, float))
                    and math.isfinite(pcm[k])
                    and 0 <= pcm[k] <= 1
                    for k in ["nearSilentFraction", "fullScaleFraction"]
                )
            ):
                pcm = {}
            issue = (
                duration < 2 - 1e-6
                or pcm.get("nearSilentFraction", 0) >= 0.99
                or pcm.get("fullScaleFraction", 0) >= 0.01
            )
            exact = json.dumps(
                [
                    value["meetingID"],
                    value.get("source"),
                    value.get("audioFile"),
                    value.get("audioRevision"),
                    spans,
                    model,
                ],
                sort_keys=True,
            )
            example = Example(
                value["id"],
                value.get("personID"),
                value["meetingID"],
                model,
                tuple(float(x) for x in vector),
                float(value.get("createdAt", 0)),
                duration,
                "selected_after_manual_identity"
                if value.get("selectedReference")
                else "confirmed_without_selection_receipt",
                value.get("origin", "unspecified"),
                0.0 if issue else 1.0,
                exact,
                tuple(value.get("rejectedPersonIDs", [])),
            )
            if example.rejected:
                negatives.append(example)
            if value.get("review") == "confirmed" and example.person:
                if example.person in example.rejected:
                    counts["contradictory_positive_negative"] += 1
                else:
                    confirmed.append(example)
    # Conflicting exact-audio confirmations cannot supply a consistent ground truth.
    owners: dict[str, set[str | None]] = defaultdict(set)
    for e in confirmed:
        owners[e.exact_key].add(e.person)
    conflicts = {key for key, people in owners.items() if len(people) > 1}
    counts["conflicting_exact_audio_records"] = sum(
        e.exact_key in conflicts for e in confirmed
    )

    def vector_key(e: Example) -> tuple[str, str]:
        return e.model, hashlib.sha256(np.asarray(e.vector).tobytes()).hexdigest()

    vector_owners: dict[tuple[str, str], set[str | None]] = defaultdict(set)
    for e in confirmed:
        vector_owners[vector_key(e)].add(e.person)
    vector_conflicts = {key for key, people in vector_owners.items() if len(people) > 1}
    counts["conflicting_identical_vector_records"] = sum(
        vector_key(e) in vector_conflicts for e in confirmed
    )
    unique, seen, seen_vectors = [], set(), set()
    for e in sorted(confirmed, key=lambda x: x.identifier):
        if e.exact_key in conflicts or vector_key(e) in vector_conflicts:
            continue
        if e.exact_key in seen:
            counts["duplicate_exact_excerpt"] += 1
            continue
        # Identical cached vectors across recordings are duplicate inputs, not independent trials.
        fingerprint = vector_key(e)
        if fingerprint in seen_vectors:
            counts["duplicate_vector"] += 1
            continue
        seen.add(e.exact_key)
        seen_vectors.add(fingerprint)
        unique.append(e)
    counts["eligible_unique_confirmed"] = len(unique)
    counts["explicit_negative_pairs"] = sum(len(e.rejected) for e in negatives)
    fingerprints = []
    for path in sorted(state.rglob("*.json")):
        fingerprints.append(
            (
                str(path.relative_to(snapshot)),
                hashlib.sha256(path.read_bytes()).hexdigest(),
            )
        )
    return (
        unique,
        negatives,
        {
            "input_manifest_sha256": hashlib.sha256(
                json.dumps(fingerprints).encode()
            ).hexdigest(),
            "counts": dict(counts),
            "provenance": dict(Counter(e.provenance for e in unique)),
            "origin": dict(Counter(e.origin for e in unique)),
        },
    )


def select_profile(
    examples: list[Example], cap: int, *, signal_quality: bool = False
) -> list[Example]:
    """Port VoiceProfileSelection's quality-weighted medoid and farthest-first rule.

    App selection currently supplies quality=1; only duration changes its .1 bonus.
    signal_quality=True is a separate exploratory PCM-quality replacement policy.
    Exact score ties choose the earlier stable identifier, matching Swift.
    Call on a single person/model cohort.
    """
    if cap <= 0 or not examples:
        return []
    ordered = sorted(examples, key=lambda e: e.identifier)
    if len({(e.person, e.model) for e in ordered}) != 1:
        raise ValueError("Profile must contain one person and one compatible model")
    vectors = np.asarray([e.vector for e in ordered])
    qualities = np.asarray(
        [
            min(1.0, max(0.0, e.duration / 3)) * (e.quality if signal_quality else 1.0)
            for e in ordered
        ]
    )
    centrality = vectors @ vectors.sum(axis=0) / len(ordered) + 0.1 * qualities
    chosen = [int(np.argmax(centrality))]
    remaining = set(range(len(ordered))) - set(chosen)
    closest = vectors @ vectors[chosen[0]]
    while remaining and len(chosen) < cap:
        # Iteration in sorted index order makes tie-breaking explicit.
        next_index = max(
            sorted(remaining), key=lambda i: 1 - closest[i] + 0.1 * qualities[i]
        )
        chosen.append(next_index)
        remaining.remove(next_index)
        closest = np.maximum(closest, vectors @ vectors[next_index])
    return [ordered[i] for i in chosen]


def replay_profile(
    examples: list[Example], cap: int, replacement: bool
) -> list[Example]:
    """Simulated enrollment-order replay, not measured historical application state."""
    retained: list[Example] = []
    for example in sorted(examples, key=lambda e: (e.created, e.identifier)):
        if len(retained) < cap:
            retained.append(example)
        elif replacement:
            retained = select_profile(retained + [example], cap, signal_quality=True)
    return retained


def score_profile(query: Example, references: list[Example], method: str) -> float:
    if not references or any(e.model != query.model for e in references):
        raise ValueError("Missing or incompatible references")
    vectors = np.asarray([e.vector for e in references])
    scores = np.clip(vectors @ np.asarray(query.vector), -1.0, 1.0)
    if method == "maximum":
        return float(scores.max())
    if method == "mean":
        return float(scores.mean())
    if method == "top3_mean":
        return float(np.sort(scores)[-min(3, len(scores)) :].mean())
    if method == "centroid":
        centroid = vectors.mean(axis=0)
        norm = float(np.linalg.norm(centroid))
        return (
            float(np.clip(centroid @ np.asarray(query.vector) / norm, -1.0, 1.0))
            if norm > 0
            else -1.0
        )
    raise ValueError(f"Unknown scorer: {method}")


def build_profiles(
    training: list[Example], cap: int, selection: str
) -> dict[str, list[Example]]:
    grouped: dict[str, list[Example]] = defaultdict(list)
    for example in training:
        if example.person:
            grouped[example.person].append(example)
    return {
        person: (
            select_profile(values, cap)
            if selection == "diverse_batch"
            else replay_profile(
                values, cap, replacement=selection == "replacement_replay"
            )
        )
        for person, values in grouped.items()
    }


def classify(
    query: Example,
    profiles: dict[str, list[Example]],
    scorer: str,
    *,
    minimum_margin: float = 0.08,
    automatic_threshold: float = 0.8,
    omitted: set[str] | None = None,
) -> dict[str, Any]:
    ranked = sorted(
        (
            (person, score_profile(query, refs, scorer))
            for person, refs in profiles.items()
            if not omitted or person not in omitted
        ),
        key=lambda x: (-x[1], x[0]),
    )
    if not ranked:
        return {
            "winner": None,
            "tier": "abstained",
            "score": None,
            "margin": None,
            "ranked": [],
        }
    person, score = ranked[0]
    margin = score - (ranked[1][1] if len(ranked) > 1 else -1)
    tier = "abstained"
    if margin >= minimum_margin:
        if score >= automatic_threshold:
            tier = "automatic"
        elif len(ranked) >= 2 and score > 0:
            tier = "tentative"
    return {
        "winner": person,
        "tier": tier,
        "score": score,
        "margin": margin,
        "ranked": ranked,
    }


def summarize(rows: list[dict[str, Any]]) -> dict[str, Any]:
    counts: Counter[str] = Counter()
    for row in rows:
        counts["queries"] += 1
        counts[
            "supported_queries" if row["supported"] else "queries_without_own_profile"
        ] += 1
        if row["winner"] == row["truth"]:
            counts["top1_correct"] += 1
            if row["supported"]:
                counts["supported_top1_correct"] += 1
        if row["tier"] == "abstained":
            counts["abstained"] += 1
            counts[
                "supported_abstentions"
                if row["supported"]
                else "unsupported_rejections"
            ] += 1
        else:
            correct = row["winner"] == row["truth"]
            counts["assigned"] += 1
            counts["correct_assigned" if correct else "wrong_assigned"] += 1
            counts[
                ("supported_" if row["supported"] else "unsupported_")
                + ("correct_assigned" if correct else "wrong_assigned")
            ] += 1
            counts[row["tier"] + ("_correct" if correct else "_wrong")] += 1
        if row["winner"] != row["truth"] or row["tier"] == "abstained":
            counts["misses"] += 1
    n = counts["queries"]
    return {
        **{
            key: counts[key]
            for key in (
                "queries",
                "supported_queries",
                "queries_without_own_profile",
                "top1_correct",
                "supported_top1_correct",
                "assigned",
                "correct_assigned",
                "wrong_assigned",
                "abstained",
                "automatic_correct",
                "automatic_wrong",
                "tentative_correct",
                "tentative_wrong",
                "misses",
                "supported_correct_assigned",
                "supported_wrong_assigned",
                "supported_abstentions",
                "unsupported_wrong_assigned",
                "unsupported_rejections",
            )
        },
        "assignment_coverage": counts["assigned"] / n if n else None,
        "correct_coverage": counts["correct_assigned"] / n if n else None,
        "assignment_precision": counts["correct_assigned"] / counts["assigned"]
        if counts["assigned"]
        else None,
    }


def evaluate(
    examples: list[Example],
    *,
    caps: tuple[int, ...] = CAPS,
    scorers: tuple[str, ...] = SCORERS,
    selections: tuple[str, ...] = (
        "diverse_batch",
        "stop_replay",
        "replacement_replay",
    ),
    repeats: int = 20,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    summaries, details = [], []
    for cap in caps:
        for selection in selections:
            preparation_start, preparation_cpu = (
                time.perf_counter(),
                time.process_time(),
            )
            cached = {}
            for query in examples:
                key = (query.meeting, query.model)
                if key not in cached:
                    # Leave the entire query meeting out of every person's profile.
                    training = [
                        e
                        for e in examples
                        if e.meeting != query.meeting and e.model == query.model
                    ]
                    profiles = build_profiles(training, cap, selection)
                    assert all(
                        e.meeting != query.meeting
                        for refs in profiles.values()
                        for e in refs
                    )
                    cached[key] = profiles
            preparation_wall = time.perf_counter() - preparation_start
            preparation_cpu = time.process_time() - preparation_cpu
            sizes = [
                len(refs) for profiles in cached.values() for refs in profiles.values()
            ]
            for scorer in scorers:
                rows, latencies = [], []
                cpu_before = time.process_time()
                start = time.perf_counter()
                for _ in range(repeats):
                    for query in examples:
                        profiles = cached[(query.meeting, query.model)]
                        tick = time.perf_counter_ns()
                        result = classify(query, profiles, scorer)
                        latencies.append((time.perf_counter_ns() - tick) / 1e6)
                        if _ == 0:
                            rows.append(
                                {
                                    "query": query.identifier,
                                    "truth": query.person,
                                    "meeting": query.meeting,
                                    "provenance": query.provenance,
                                    "supported": query.person in profiles,
                                    "selection": selection,
                                    "cap": cap,
                                    "scorer": scorer,
                                    **result,
                                }
                            )
                elapsed, cpu = (
                    time.perf_counter() - start,
                    time.process_time() - cpu_before,
                )
                summaries.append(
                    {
                        "cap": cap,
                        "selection": selection,
                        "scorer": scorer,
                        "actual_references_min": min(sizes, default=0),
                        "actual_references_median": statistics.median(sizes)
                        if sizes
                        else 0,
                        "actual_references_max": max(sizes, default=0),
                        "folds": len(cached),
                        "profile_preparation_wall_seconds": preparation_wall,
                        "profile_preparation_cpu_seconds": preparation_cpu,
                        **summarize(rows),
                        "matching_calls": len(latencies),
                        "elapsed_seconds": elapsed,
                        "cpu_seconds": cpu,
                        "query_latency_ms_median": statistics.median(latencies)
                        if latencies
                        else None,
                        "query_latency_ms_p95": float(np.quantile(latencies, 0.95))
                        if latencies
                        else None,
                    }
                )
                details.extend(rows)
    return summaries, details


def evaluate_unknown(
    examples: list[Example],
    caps: tuple[int, ...] = CAPS,
    scorers: tuple[str, ...] = SCORERS,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Known-speaker labels simulate novel identities by removing all their evidence.

    Also exclude the query meeting globally. This measures false acceptance under
    the saved cohort, not a representative population of unseen voices.
    """
    summaries, details = [], []
    for cap in caps:
        cache = {}
        for query in examples:
            key = query.person, query.meeting, query.model
            if key not in cache:
                training = [
                    e
                    for e in examples
                    if e.person != query.person
                    and e.meeting != query.meeting
                    and e.model == query.model
                ]
                profiles = build_profiles(training, cap, "diverse_batch")
                assert query.person not in profiles
                cache[key] = profiles
        for scorer in scorers:
            rows = []
            for query in examples:
                result = classify(
                    query, cache[(query.person, query.meeting, query.model)], scorer
                )
                rows.append(
                    {
                        "query": query.identifier,
                        "held_out_person": query.person,
                        "meeting": query.meeting,
                        "cap": cap,
                        "scorer": scorer,
                        **result,
                    }
                )
            accepted = [r for r in rows if r["tier"] != "abstained"]
            summaries.append(
                {
                    "cap": cap,
                    "scorer": scorer,
                    "queries": len(rows),
                    "false_accepts": len(accepted),
                    "automatic_false_accepts": sum(
                        r["tier"] == "automatic" for r in rows
                    ),
                    "tentative_false_accepts": sum(
                        r["tier"] == "tentative" for r in rows
                    ),
                    "correct_rejections": len(rows) - len(accepted),
                    "false_acceptance_rate": len(accepted) / len(rows)
                    if rows
                    else None,
                }
            )
            details.extend(rows)
    return summaries, details


def evaluate_negatives(
    negatives: list[Example], confirmed: list[Example]
) -> dict[str, Any]:
    pairs = []
    for example in negatives:
        profiles = build_profiles(
            [
                e
                for e in confirmed
                if e.meeting != example.meeting and e.model == example.model
            ],
            12,
            "diverse_batch",
        )
        for person in example.rejected:
            if person not in profiles:
                continue
            score = score_profile(example, profiles[person], "maximum")
            pairs.append(
                {
                    "query": example.identifier,
                    "meeting": example.meeting,
                    "not_person": person,
                    "score": score,
                    "above_suggestion_floor": score >= 0.55,
                    "above_automatic_floor": score >= 0.8,
                }
            )
    return {
        "usable_pairs": len(pairs),
        "independent_query_meetings": len({p["meeting"] for p in pairs}),
        "above_suggestion_floor": sum(p["above_suggestion_floor"] for p in pairs),
        "above_automatic_floor": sum(p["above_automatic_floor"] for p in pairs),
        "pairs": pairs,
        "limitation": "Not-person feedback is pairwise evidence; it does not identify another person or establish a complete open-set test.",
    }


def parity_check(production_path: Path, examples: list[Example]) -> dict[str, Any]:
    """Verify max-cosine against frozen actual Swift production query scores."""
    production = json.loads(production_path.read_text())
    profiles = {}
    for person in production["profiles"]:
        for sample in person.get("voiceSamples", []):
            embedding = sample.get("voiceEmbedding")
            if embedding:
                model = json.dumps(
                    embedding["type"], sort_keys=True, separators=(",", ":")
                )
                profiles.setdefault((person["id"], model), []).append(
                    tuple(normalized(embedding["values"]))
                )
    max_error, comparisons = 0.0, 0
    # Stored source vectors are carried in the immutable snapshot's candidate examples.
    for candidate in production.get("examples", []):
        for embedding in candidate.get("embeddings", []):
            vector = tuple(normalized(embedding["values"]))
            model = json.dumps(embedding["type"], sort_keys=True, separators=(",", ":"))
            expected = next(
                (
                    v
                    for v in production["vectors"]
                    if v["key"] == "example:" + candidate["id"]
                ),
                None,
            )
            if not expected:
                continue
            for person_score in expected["scores"]:
                refs = profiles.get((person_score["personID"], model), [])
                actual = max(float(np.asarray(v) @ vector) for v in refs)
                max_error = max(max_error, abs(actual - person_score["score"]))
                comparisons += 1
    if not comparisons:
        raise AssertionError("No production query score comparisons were available")
    if max_error > 1e-12:
        raise AssertionError(f"Production cosine parity failed: {max_error}")
    # Selection parity: reconstruct all-data caps and compare selected example IDs to Swift output.
    selected_matches, selected_total = 0, 0
    for person in production["profiles"]:
        by_model: dict[str, list[Example]] = defaultdict(list)
        for e in examples:
            if e.person == person["id"]:
                by_model[e.model].append(e)
        expected = {s["speakerID"] for s in person.get("voiceSamples", [])}
        actual = {
            e.identifier
            for values in by_model.values()
            for e in select_profile(values, 12)
        }
        selected_total += 1
        selected_matches += actual == expected
    if selected_matches != selected_total:
        raise AssertionError(
            f"Production selector parity failed: {selected_matches}/{selected_total}"
        )
    return {
        "cosine_person_comparisons": comparisons,
        "maximum_absolute_score_error": max_error,
        "profile_sets_equal": selected_matches,
        "profile_sets_compared": selected_total,
        "note": "Batch selected IDs compare exact production cap-12 output; tie/duration behavior also has synthetic tests.",
    }


def evaluate_acoustic_reports(
    report_paths: list[Path], annotations: list[dict[str, Any]]
) -> dict[str, Any]:
    """Score explicit known identity points only; unannotated speech has no ground truth.

    Repeated timing passes repeat the same annotations, so counts stay per pass.
    They never become extra independent accuracy observations or a DER estimate.
    """
    if not annotations or len(
        {(a["track"], float(a["at"])) for a in annotations}
    ) != len(annotations):
        raise ValueError("Supply unique explicit identity annotation points")
    methods, revisions = [], set()
    for path in report_paths:
        report = json.loads(path.read_text())
        revisions.add((report["sourceRevision"], report["modelRevision"]))
        passes = []
        for run in report["runs"]:
            scored = []
            for annotation in annotations:
                assignments = [
                    r
                    for r in run["assignments"]
                    if r["track"] == annotation["track"]
                    and r["start"] <= annotation["at"] < r["end"]
                ]
                if len(assignments) > 1:
                    status = "ambiguous_intervals"
                elif not assignments or assignments[0].get("personID") is None:
                    status = "unassigned"
                else:
                    status = (
                        "correct"
                        if assignments[0]["personID"] == annotation["personID"]
                        else "wrong"
                    )
                scored.append(
                    {
                        "annotation": annotation,
                        "status": status,
                        "assignments": assignments,
                    }
                )
            passes.append(
                {
                    "index": run["index"],
                    "correct": sum(r["status"] == "correct" for r in scored),
                    "wrong": sum(r["status"] == "wrong" for r in scored),
                    "unassigned": sum(r["status"] == "unassigned" for r in scored),
                    "ambiguous": sum(
                        r["status"] == "ambiguous_intervals" for r in scored
                    ),
                    "details": scored,
                }
            )
        metrics = {}
        for stage in ["scan", "incremental", "total"]:
            for metric in ["wall", "cpu", "peakRSSBytes"]:
                values = [r[stage][metric] for r in report["runs"]]
                metrics[stage + "_" + metric + "_median"] = (
                    statistics.median(values) if values else None
                )
                metrics[stage + "_" + metric + "_p95"] = (
                    float(np.quantile(values, 0.95)) if values else None
                )
        methods.append(
            {
                "mode": report["mode"],
                "accuracy_passes": passes,
                "timing": metrics,
                "model_load": report.get("modelLoad"),
                "additional_extractor_calls": [
                    r["additionalExtractorCalls"] for r in report["runs"]
                ],
                "baseline_extractor_calls": [
                    r["baselineExtractorCalls"] for r in report["runs"]
                ],
                "mixed_cluster_counts": [
                    sum(c["mixed"] for c in r["clusters"]) for r in report["runs"]
                ],
            }
        )
    if len(revisions) > 1:
        raise ValueError("Compare methods from one source and model revision")
    return {
        "known_annotation_points": len(annotations),
        "distinct_annotated_identities": len({a["personID"] for a in annotations}),
        "methods": methods,
        "source_and_model_revisions": [list(v) for v in revisions],
        "limitation": "Sparse identity points from one selected failure; repeated timing passes are correlated, no full-recording DER or general accuracy estimate.",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        required=True,
        help="Private JSON: snapshot, output, optional productionMatching, repeats",
    )
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    output = Path(config["output"]).resolve()
    repository = Path(__file__).resolve().parents[2]
    if output.is_relative_to(repository):
        relative = output.relative_to(repository)
        if not relative.parts or (
            relative.parts[0] != "tmp" and ".local" not in relative.parts
        ):
            raise ValueError(
                "Private experiment outputs must use ignored tmp/ or .local/ storage"
            )
    output.mkdir(parents=True, exist_ok=True)
    started, cpu_started = time.perf_counter(), time.process_time()
    examples, negatives, audit = load_examples(Path(config["snapshot"]))
    if not examples:
        raise ValueError("No confirmed compatible examples")
    summaries, details = evaluate(examples, repeats=int(config.get("repeats", 20)))
    unknown_summaries, unknown_details = evaluate_unknown(examples)
    parity = (
        parity_check(Path(config["productionMatching"]), examples)
        if config.get("productionMatching")
        else None
    )
    report = {
        "version": 1,
        "audit": audit,
        "people": len({e.person for e in examples}),
        "meetings": len({e.meeting for e in examples}),
        "queries_by_provenance": dict(Counter(e.provenance for e in examples)),
        "thresholds": {
            "automatic": 0.8,
            "minimum_margin": 0.08,
            "tentative_floor": "positive score with at least two candidate identities",
        },
        "calibration": "None. Shared production gates are descriptive; aggregation scorers require independent calibration before deployment.",
        "query_ground_truth": "Persisted confirmed identity. A missing selection receipt does not establish the historical review interaction.",
        "replay": "Retrospective enrollment-createdAt replay with deterministic ID ties; no complete historical enrollment/deletion journal is available.",
        "parity": parity,
        "summaries": summaries,
        "unknown_person_summaries": unknown_summaries,
        "negative_pairs": evaluate_negatives(negatives, examples),
        "resources": {
            "wall_seconds": time.perf_counter() - started,
            "cpu_seconds": time.process_time() - cpu_started,
            "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
            * (1 if sys.platform == "darwin" else 1024),
            "python_version": platform.python_version(),
            "numpy_version": np.__version__,
            "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "thread_limits": {
                k: os.environ.get(k)
                for k in [
                    "VECLIB_MAXIMUM_THREADS",
                    "OPENBLAS_NUM_THREADS",
                    "OMP_NUM_THREADS",
                ]
            },
            "runtime": "Python/NumPy cached vectors; no decode, model extraction, UI publication or Swift end-to-end timing",
        },
    }
    (output / "reference-results.json").write_text(json.dumps(report, indent=2))
    (output / "reference-query-details.json").write_text(json.dumps(details, indent=2))
    (output / "unknown-person-details.json").write_text(
        json.dumps(unknown_details, indent=2)
    )
    if config.get("acousticReports"):
        acoustic = evaluate_acoustic_reports(
            [Path(p) for p in config["acousticReports"]], config["annotations"]
        )
        (output / "acoustic-comparison.json").write_text(json.dumps(acoustic, indent=2))
    print(
        json.dumps(
            {
                "queries": len(examples),
                "people": report["people"],
                "meetings": report["meetings"],
                "configurations": len(summaries),
                "parity": parity,
                "resources": report["resources"],
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
