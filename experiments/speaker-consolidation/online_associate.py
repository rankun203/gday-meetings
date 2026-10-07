"""Causal cross-window association; reference labels never enter decisions.

Without a callback trace, availability is estimated from sample end. With a
trace, embeddings wait for observed continuity and retain callback order. The
clock is submitted audio, not wall-clock latency. Frozen .72 complete-link
matching uses previous-generation unit means. Dynamic decisions are a rejected
diagnostic; sticky decisions preserve the first eligible identity association.

Three distinct outputs measure acoustic-time prospective assignment, immutable
labels at activity publication callbacks, and current-state whole-label alias
snapshots. Added-delay snapshots retain confirmation-time published evidence;
that sensitivity is not a reconstruction of callbacks during the added delay.
"""

import argparse
import json
import math
from itertools import pairwise
from pathlib import Path

from evaluate import human_view
from score import private_output, score, sha

SUPPORTED_WINDOW_POLICIES = {
    "nemotron-capacity-rollover-v1",
    "nemotron-capacity-credible-runs-300ms-total3s-v2-experiment",
}


def normalize(values):
    norm = math.sqrt(sum(v * v for v in values))
    if not norm or not all(math.isfinite(v) for v in values):
        raise ValueError("Invalid embedding")
    return [v / norm for v in values]


def cosine(a, b):
    if len(a) != len(b):
        raise ValueError("Incompatible dimensions")
    return sum(x * y for x, y in zip(a, b))


def availability_times(evidence, trace):
    if (
        trace.get("schemaVersion") != 1
        or trace.get("clock") != "submitted-audio-upper-bound"
    ):
        raise ValueError("Unsupported availability trace")
    result, confirmed, known, pending = {}, {}, {}, {}
    published, window_history = [], {}
    samples = {s["id"]: s for s in evidence["samples"]}
    previous = -1
    for index, entry in enumerate(trace["entries"]):
        now = entry["audioSubmittedThrough"]
        if entry["ordinal"] != index or not math.isfinite(now) or now < previous:
            raise ValueError("Invalid callback order")
        previous = now
        if entry["kind"] == "embeddingReady":
            identifier = entry["sampleID"]
            if identifier in result:
                raise ValueError("Duplicate sample availability")
            result[identifier] = (now, index)
            if identifier not in samples:
                raise ValueError("Unknown retained sample")
            pending[identifier] = samples[identifier]
        elif entry["kind"] == "speakerEvent":
            event = entry["event"]
            published.extend(
                {
                    "source": event["source"],
                    "localSpeakerID": row["speakerID"],
                    "start": row["start"],
                    "end": row["end"],
                }
                for row in event["intervals"]
            )
            window = event.get("continuity")
            if window is not None:
                if window["policyRevision"] not in SUPPORTED_WINDOW_POLICIES:
                    raise ValueError("Unsupported callback continuity")
                for label in window["localSpeakerIDs"]:
                    known[(window["source"], label)] = window
                window_history[(window["source"], window["generation"])] = window
        elif entry["kind"] != "speakerEvent":
            raise ValueError("Unknown callback kind")
        for identifier, sample in list(pending.items()):
            window = known.get((sample["source"], sample["localSpeakerID"]))
            if window is None or window["observedEnd"] < sample["end"]:
                continue
            if sample["start"] >= window["publicationStart"] and sample[
                "end"
            ] <= window.get("capacityReachedAt", window["observedEnd"]):
                confirmed[identifier] = (now, index, identifier)
            del pending[identifier]
    if set(result) != {s["id"] for s in evidence["samples"]}:
        raise ValueError("Availability samples differ from retained evidence")
    if any(result[s["id"]][0] < s["end"] for s in evidence["samples"]):
        raise ValueError("Embedding available before its audio")
    if published != evidence["activity"]:
        raise ValueError("Callback activity differs from retained evidence")
    expected = {(w["source"], w["generation"]): w for w in evidence["windows"]}
    if window_history != expected:
        raise ValueError("Callback windows differ from retained evidence")
    return confirmed


def associate(evidence, delay=1.0, threshold=0.72, policy="dynamic", trace=None):
    if delay < 0:
        raise ValueError("Availability delay cannot be negative")
    windows = {}
    for w in evidence["windows"]:
        if w["policyRevision"] not in SUPPORTED_WINDOW_POLICIES:
            raise ValueError("Unsupported window policy")
        for label in w["localSpeakerIDs"]:
            key = (w["source"], label)
            if key in windows:
                raise ValueError("Local label reused across windows")
            windows[key] = w

    def key(row):
        return row["source"], row["localSpeakerID"]

    def trusted(row):
        w = windows.get(key(row))
        return (
            w
            and row["start"] >= w["publicationStart"]
            and row["end"]
            <= min(w["observedEnd"], w.get("capacityReachedAt", w["observedEnd"]))
        )

    ready = (
        availability_times(evidence, trace)
        if trace is not None
        else {s["id"]: (s["end"], s["id"]) for s in evidence["samples"]}
    )
    samples = sorted(
        (
            s
            for s in evidence["samples"]
            if (s["id"] in ready if trace is not None else trusted(s))
        ),
        key=lambda s: ready[s["id"]],
    )
    if policy not in ("dynamic", "sticky"):
        raise ValueError("Unknown association policy")
    types = {json.dumps(s["embedding"]["type"], sort_keys=True) for s in samples}
    if len(types) > 1:
        raise ValueError("Mixed embedding contracts")
    if (
        samples
        and samples[0]["embedding"]["type"]["compatibilityVersion"]
        != "gday-span-feature-center-v2"
    ):
        raise ValueError("Expected corrected embeddings")
    # Each unit keeps all past samples. A person candidate consists of past
    # units; complete-link matching avoids chaining through one close unit.
    sums, counts, means, assignments, events = {}, {}, {}, {}, []
    histories = {}
    for sample in samples:
        k = key(sample)
        now = ready[sample["id"]][0] + delay
        w = windows[k]
        v = normalize(sample["embedding"]["values"])
        if k not in sums:
            sums[k], counts[k] = [0.0] * len(v), 0
        sums[k] = [a + b for a, b in zip(sums[k], v)]
        counts[k] += 1
        means[k] = normalize(sums[k])
        known_activity = evidence["activity"]
        if trace is not None:
            known_activity = []
            for entry in trace["entries"]:
                if entry["ordinal"] > ready[sample["id"]][1]:
                    break
                if entry["kind"] == "speakerEvent":
                    event = entry["event"]
                    known_activity.extend(
                        {
                            "source": event["source"],
                            "localSpeakerID": row["speakerID"],
                            "start": row["start"],
                            "end": row["end"],
                        }
                        for row in event["intervals"]
                    )

        def conflict(other, k=k, known_activity=known_activity, now=now):
            if other[0] != k[0]:
                return False
            left = [r for r in known_activity if key(r) == k and r["start"] < now]
            right = [r for r in known_activity if key(r) == other and r["start"] < now]
            return any(
                max(a["start"], b["start"]) < min(a["end"], b["end"], now)
                for a in left
                for b in right
            )

        candidates = {}
        for other, mean in means.items():
            if other == k:
                continue
            ow = windows[other]
            # No same-window merging. Candidate activity and vectors must
            # already exist in a generation that finished before this one.
            if ow["observedEnd"] > w["publicationStart"]:
                continue
            person = assignments[other]
            candidates.setdefault(person, []).append(mean)
        ranked = sorted(
            (
                (min(cosine(means[k], m) for m in group), person)
                for person, group in candidates.items()
                if not any(
                    other != k and assigned == person and conflict(other)
                    for other, assigned in assignments.items()
                )
            ),
            reverse=True,
        )
        own = ":".join(k)
        person = ranked[0][1] if ranked and ranked[0][0] >= threshold else own
        old = assignments.get(k, own)
        if policy == "sticky" and old != own:
            person = old
        assignments[k] = person
        histories.setdefault(k, []).append((now, person, len(events)))
        events.append(
            {
                "time": now,
                "sampleID": sample["id"],
                "localLabel": own,
                "callbackOrdinal": ready[sample["id"]][1]
                if trace is not None
                else None,
                "person": person,
                "changed": old != person,
                "sampleCount": counts[k],
                "bestSimilarity": ranked[0][0] if ranked else None,
                "runnerUpSimilarity": ranked[1][0] if len(ranked) > 1 else None,
                "margin": ranked[0][0] - ranked[1][0] if len(ranked) > 1 else None,
            }
        )

    def timeline(snapshot_time=None, event_limit=None, snapshot_ordinal=None):
        intervals = []
        activity, current_windows = evidence["activity"], windows
        if trace is not None and snapshot_time is not None:
            ordinal = (
                events[event_limit]["callbackOrdinal"]
                if event_limit is not None and event_limit >= 0
                else -1
            )
            # A before/after association snapshot shares callback-visible activity.
            # event_limit controls identity decisions, not publication visibility.
            if snapshot_ordinal is not None:
                ordinal = snapshot_ordinal
            activity, current_windows = [], {}
            for entry in trace["entries"]:
                if entry["ordinal"] > ordinal:
                    break
                if entry["kind"] != "speakerEvent":
                    continue
                event = entry["event"]
                activity.extend(
                    {
                        "source": event["source"],
                        "localSpeakerID": row["speakerID"],
                        "start": row["start"],
                        "end": row["end"],
                    }
                    for row in event["intervals"]
                )
                window = event.get("continuity")
                if window is not None:
                    for label in window["localSpeakerIDs"]:
                        current_windows[(window["source"], label)] = window
        for row in activity:
            if snapshot_time is not None:
                if row["start"] >= snapshot_time:
                    continue
                row = dict(row, end=min(row["end"], snapshot_time))
            k = key(row)
            w = current_windows.get(k)
            trust_end = (
                min(w["observedEnd"], w.get("capacityReachedAt", w["observedEnd"]))
                if w
                else -1
            )
            boundaries = sorted(
                {
                    row["start"],
                    row["end"],
                    *[
                        t
                        for t, _, _ in histories.get(k, [])
                        if row["start"] < t < row["end"]
                    ],
                    *[
                        t
                        for t in ([w["publicationStart"], trust_end] if w else [])
                        if row["start"] < t < row["end"]
                    ],
                }
            )
            for a, b in pairwise(boundaries):
                person = ":".join(k)
                if w and (a < w["publicationStart"] or b > trust_end):
                    person = "unresolved:" + person
                if w and a >= w["publicationStart"] and b <= trust_end:
                    for t, assigned, event_index in histories.get(k, []):
                        limit = a if snapshot_time is None else snapshot_time
                        if t <= limit:
                            if event_limit is not None and event_index > event_limit:
                                break
                            person = assigned
                        else:
                            break
                intervals.append({"start": a, "end": b, "speaker": person})
        return intervals

    snapshots = []
    if policy == "sticky":
        for index, event in enumerate(events):
            if event["changed"]:
                snapshots.append(
                    {
                        "time": event["time"],
                        "sampleID": event["sampleID"],
                        "before": timeline(
                            event["time"], index - 1, event["callbackOrdinal"]
                        ),
                        "after": timeline(
                            event["time"], index, event["callbackOrdinal"]
                        ),
                    }
                )
    final_time = max(
        [r["end"] for r in evidence["activity"]]
        + [e["time"] for e in events]
        + (
            [trace["entries"][-1]["audioSubmittedThrough"]]
            if trace is not None
            else [0]
        )
    )
    published = []
    if trace is not None:
        visible_windows = {}
        for entry in trace["entries"]:
            if entry["kind"] != "speakerEvent":
                continue
            event = entry["event"]
            window = event.get("continuity")
            if window is not None:
                for label in window["localSpeakerIDs"]:
                    visible_windows[(window["source"], label)] = window
            for row in event["intervals"]:
                k = (event["source"], row["speakerID"])
                w = visible_windows.get(k)
                stop = (
                    min(w["observedEnd"], w.get("capacityReachedAt", w["observedEnd"]))
                    if w
                    else -1
                )
                cuts = sorted(
                    {
                        row["start"],
                        row["end"],
                        *([stop] if row["start"] < stop < row["end"] else []),
                    }
                )
                for a, b in pairwise(cuts):
                    person = ":".join(k)
                    if w and (a < w["publicationStart"] or b > stop):
                        person = "unresolved:" + person
                    if w and a >= w["publicationStart"] and b <= stop:
                        for decision in events:
                            if decision["callbackOrdinal"] >= entry["ordinal"]:
                                break
                            if (
                                decision["localLabel"] == ":".join(k)
                                and decision["time"] <= entry["audioSubmittedThrough"]
                            ):
                                person = decision["person"]
                    published.append({"start": a, "end": b, "speaker": person})
    return {
        "intervals": timeline(),
        "publishedIntervals": published,
        "finalSnapshot": timeline(
            final_time,
            snapshot_ordinal=(
                trace["entries"][-1]["ordinal"] if trace is not None else None
            ),
        ),
        "snapshots": snapshots,
        "events": events,
        "trustedSamples": len(samples),
        "rejectedSamples": len(evidence["samples"]) - len(samples),
    }


def verified_replay(folder, sample, require_trace=False, rollover="on"):
    """Reject incomplete, failed, mismatched, or altered replay evidence."""
    folder = Path(folder)
    run_path = folder.with_suffix(".run.json")
    run = json.loads(run_path.read_text())
    if (
        run.get("status") != "completed"
        or run.get("returncode") != 0
        or run.get("sample") != sample["id"]
        or run.get("rollover") != rollover
        or run.get("inputSHA256") != sample["audioSHA256"]
    ):
        raise ValueError("Replay run did not complete for this input and policy")
    names = ["evidence.json", "receipt.json"] + (
        ["availability.json"] if require_trace else []
    )
    artifacts = run.get("artifacts", {})
    for name in names:
        if artifacts.get(name) != sha(folder / name):
            raise ValueError("Replay artifact hash differs: " + name)
    receipt = json.loads((folder / "receipt.json").read_text())
    if receipt.get("complete") is not True or any(
        receipt.get(k) != 0 for k in ("failureCount", "gapCount", "extractionFailures")
    ):
        raise ValueError("Replay contains incomplete capture or extraction")
    if abs(receipt.get("durationSeconds", -1) - sample["durationSeconds"]) > 0.001:
        raise ValueError("Replay duration differs")
    evidence = json.loads((folder / "evidence.json").read_text())
    if receipt.get("sampleCount") != len(evidence["samples"]):
        raise ValueError("Replay sample count differs")
    trace = (
        json.loads((folder / "availability.json").read_text())
        if require_trace
        else None
    )
    if trace is not None:
        availability_times(evidence, trace)
    production = run.get("productionSHA256")
    bundle = run.get("testBundleSHA256")
    replay_source = run.get("replaySourceSHA256")

    def valid_hash(value):
        return (
            isinstance(value, str)
            and len(value) == 64
            and all(c in "0123456789abcdef" for c in value)
        )

    if require_trace and (
        not isinstance(production, dict)
        or not production
        or not all(
            isinstance(k, str) and k and valid_hash(v) for k, v in production.items()
        )
        or not valid_hash(bundle)
        or not valid_hash(replay_source)
    ):
        raise ValueError(
            "Traced replay lacks pinned production, binary, or replay-source hashes"
        )
    return (
        evidence,
        trace,
        {
            "runSHA256": sha(run_path),
            "receiptSHA256": sha(folder / "receipt.json"),
            "artifacts": {name: artifacts[name] for name in names},
            "receipt": receipt,
            "productionSHA256": production,
            "testBundleSHA256": bundle,
            "replaySourceSHA256": replay_source,
            "modelAssetsSHA256": run.get("modelAssetsSHA256"),
            "provenanceStable": run.get("provenanceStable"),
            "windowPolicyRevisions": sorted(
                {w["policyRevision"] for w in evidence.get("windows", [])}
            ),
        },
    )


def selected_samples(manifest, requested=None):
    available = {entry["id"] for entry in manifest["samples"]}
    if len(available) != len(manifest["samples"]) or not available:
        raise ValueError("Manifest has duplicate or no samples")
    if requested is not None and (not requested or set(requested) - available):
        raise ValueError("Requested samples are empty or unknown")
    return [
        entry
        for entry in manifest["samples"]
        if requested is None or entry["id"] in requested
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--availability", action="store_true", help="Require recorded callback sidecars"
    )
    parser.add_argument("--samples", nargs="+", help="Explicit sample IDs to evaluate")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    selected = selected_samples(manifest, args.samples)
    out = private_output(args.output)
    out.mkdir(parents=True, exist_ok=False)
    measured = []
    for entry in selected:
        path = args.manifest.parent / (entry["id"] + "-on") / "evidence.json"
        evidence, trace, _ = verified_replay(path.parent, entry, args.availability)
        if sha(entry["referencesPath"]) != entry["referencesSHA256"]:
            raise ValueError("Reference hash differs")
        systems = {
            "live": [
                {
                    "start": r["start"],
                    "end": r["end"],
                    "speaker": r["source"] + ":" + r["localSpeakerID"],
                }
                for r in evidence["activity"]
            ]
        }
        # Separate the effect of anonymizing saturated activity from matching.
        # This baseline preserves local labels and the complete audio support.
        systems["capacity-safe-local"] = associate(dict(evidence, samples=[]), delay=0)[
            "intervals"
        ]
        audits = {}
        for policy, delay in [
            ("dynamic", 0.0),
            ("dynamic", 1.0),
            ("sticky", 0.0),
            ("sticky", 1.0),
        ]:
            name = f"{policy}-delay-{delay:g}"
            result = associate(evidence, delay, policy=policy, trace=trace)
            systems[name] = result["intervals"]
            if trace is not None:
                systems[name + "-published"] = result["publishedIntervals"]
            if policy == "sticky":
                systems[name + "-snapshot"] = result["finalSnapshot"]
            audits[name] = {
                k: v
                for k, v in result.items()
                if k
                not in ("intervals", "finalSnapshot", "snapshots", "publishedIntervals")
            }
            (out / f"{entry['id']}-{name}.json").write_text(
                json.dumps(result, indent=2) + "\n"
            )
        # References enter only after association has finished.
        refs = json.loads(Path(entry["referencesPath"]).read_text())
        for policy, delay in [("sticky", 0.0), ("sticky", 1.0)]:
            name = f"{policy}-delay-{delay:g}"
            result = json.loads((out / f"{entry['id']}-{name}.json").read_text())
            snapshots = []
            for snapshot in result["snapshots"]:
                t = snapshot["time"]
                views = {}
                for category in ("random", "speaker_coverage"):
                    reference = {
                        "audioDurationSeconds": t,
                        "intervals": [],
                        "reviewedRegions": [],
                    }
                    for clip in refs["human"]:
                        if clip["category"] != category:
                            continue
                        for field in ("intervals", "reviewedRegions"):
                            for row in clip[field]:
                                a, b = (
                                    row["start"] + clip["start"],
                                    min(t, row["end"] + clip["start"]),
                                )
                                if a < b:
                                    reference[field].append(dict(row, start=a, end=b))
                    if reference["reviewedRegions"]:
                        views[category] = {
                            phase: score(reference, snapshot[phase])
                            for phase in ("before", "after")
                        }
                snapshots.append(
                    {"time": t, "sampleID": snapshot["sampleID"], "metrics": views}
                )
            audits[name]["snapshotCheckpoints"] = snapshots
        measured.append(
            {
                "sample": entry["id"],
                "evidenceSHA256": sha(path),
                "audits": audits,
                "silver": {
                    name: score(refs["silver"], rows) for name, rows in systems.items()
                },
                "humanRandom": human_view(refs["human"], systems, "random"),
                "humanTargeted": human_view(refs["human"], systems, "speaker_coverage"),
            }
        )
    (out / "evaluation.json").write_text(
        json.dumps(
            {
                "method": "causal-cross-window-channel-mean-v1",
                "threshold": 0.72,
                "delays": [0, 1],
                "availabilityClock": trace["clock"]
                if trace
                else "estimated-sample-end",
                "scriptSHA256": sha(__file__),
                "manifestSHA256": sha(args.manifest),
                "limitations": [
                    "Callback time is submitted audio upper bound, not wall-clock inference latency"
                    if args.availability
                    else "Availability estimated from sample end",
                    "Ideal sample coverage from awaited extraction",
                    "Audio-time approximation, callback publication labels, and alias snapshots are separate",
                    "Added-delay snapshots freeze activity visibility at the confirming callback",
                ],
                "samples": measured,
            },
            indent=2,
        )
        + "\n"
    )
    for sample in measured:
        print(
            sample["sample"],
            {
                view: {
                    name: round(value["views"][0]["disagreement_fraction"] * 100, 2)
                    for name, value in sample[view].items()
                }
                for view in ("silver", "humanRandom", "humanTargeted")
            },
        )


if __name__ == "__main__":
    main()
