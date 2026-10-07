"""Temporal correspondence capability probe; no voice fingerprint confirmation.

Frozen first hypothesis: at the first positive-duration publication after a
bootstrap, require at least 3 seconds of exclusive old/new overlap, 80% of the
new label's exclusive context support, and a 20%-of-support runner-up margin.
An empty generation announcement is not publication. Decisions use preceding
callbacks plus the current published window's continuity metadata, before its
activity is assigned. No owner labels, future context, or channel numbers enter
association. Saturated bootstrap windows have zero trusted continuation.
"""

import argparse
import json
import math
from collections import defaultdict
from itertools import pairwise
from pathlib import Path

from evaluate_online import dependencies, sha

MIN_SECONDS = 3.0
MIN_SHARE = 0.8
MIN_MARGIN = 0.2
CONTEXT_POLICY = "bootstrap-context-v1-experiment"


def label_key(source, label):
    return source, label


def group(key):
    return "group:" + ":".join(key)


def capacity_safe_baseline(evidence):
    online, _ = dependencies()
    return online.associate(dict(evidence, samples=[]), delay=0)["intervals"]


def clipped(row, start, end):
    a, b = max(row["start"], start), min(row["end"], end)
    return dict(row, start=a, end=b) if a < b else None


def trusted_activity(rows, windows):
    result = []
    for row in rows:
        window = windows.get(label_key(row["source"], row["localSpeakerID"]))
        if window is None:
            continue
        item = clipped(
            row,
            window["publicationStart"],
            min(
                window["observedEnd"],
                window.get("capacityReachedAt", window["observedEnd"]),
            ),
        )
        if item is not None:
            result.append(item)
    return result


def correspondence(old, context, aliases):
    """Integrate durations once, with exclusive local labels on each side."""
    edges = defaultdict(list)
    for side, rows in enumerate((old, context)):
        for row in rows:
            key = label_key(row["source"], row["localSpeakerID"])
            edges[row["start"]].append((side, key, 1))
            edges[row["end"]].append((side, key, -1))
    active = [defaultdict(int), defaultdict(int)]
    support = defaultdict(float)
    votes = defaultdict(lambda: defaultdict(float))
    overlaps = set()
    for a, b in pairwise(sorted(edges)):
        for side, key, change in edges[a]:
            active[side][key] += change
        prior, current = (
            {key for key, count in side.items() if count > 0} for side in active
        )
        if len(current) > 1:
            ordered = sorted(current)
            for i, left in enumerate(ordered):
                for right in ordered[i + 1 :]:
                    overlaps.add((left, right))
        if len(current) != 1:
            continue
        key = next(iter(current))
        support[key] += b - a
        if len(prior) == 1:
            earlier = next(iter(prior))
            votes[key][aliases.get(earlier, group(earlier))] += b - a
    candidates = {}
    details = []
    for key, seconds in sorted(support.items()):
        ranked = sorted(votes[key].items(), key=lambda item: (-item[1], item[0]))
        matched = ranked[0][1] if ranked else 0.0
        runner = ranked[1][1] if len(ranked) > 1 else 0.0
        accepted = bool(
            ranked
            and matched >= MIN_SECONDS
            and matched / seconds >= MIN_SHARE
            and (matched - runner) / seconds >= MIN_MARGIN
        )
        if accepted:
            candidates[key] = ranked[0][0]
        details.append(
            {
                "localLabel": ":".join(key),
                "exclusiveContextSeconds": seconds,
                "bestMatchedSeconds": matched,
                "runnerUpSeconds": runner,
                "agreement": matched / seconds,
                "margin": (matched - runner) / seconds,
                "candidate": ranked[0][0] if ranked else None,
                "accepted": accepted,
            }
        )
    conflicts = set()
    for left, right in overlaps:
        if (
            left in candidates
            and right in candidates
            and candidates[left] == candidates[right]
        ):
            conflicts.update((left, right))
    for key in conflicts:
        del candidates[key]
    for detail in details:
        if tuple(detail["localLabel"].split(":", 1)) in conflicts:
            detail.update(
                accepted=False, rejection="known_overlapping_new_labels_share_candidate"
            )
    return candidates, details


def associate(evidence, trace):
    online, _ = dependencies()
    if (
        trace.get("schemaVersion") != 2
        or trace.get("contextPolicyRevision") != CONTEXT_POLICY
        or trace.get("clock") != "submitted-audio-upper-bound"
    ):
        raise ValueError("Expected ordered schema 2 bootstrap context trace")
    activity = []
    published = []
    contexts = defaultdict(list)
    windows = {}
    generations = {}
    aliases = {}
    decided = set()
    audits = []
    samples = {s["id"]: s for s in evidence["samples"]}
    ready = set()
    clock = -1

    def assign(rows):
        output = []
        for row in rows:
            key = label_key(row["source"], row["localSpeakerID"])
            window = windows.get(key)
            if window is None:
                output.append(
                    {
                        "start": row["start"],
                        "end": row["end"],
                        "speaker": "unresolved:" + ":".join(key),
                    }
                )
                continue
            stop = min(
                window["observedEnd"],
                window.get("capacityReachedAt", window["observedEnd"]),
            )
            cuts = sorted(
                {
                    row["start"],
                    row["end"],
                    *[
                        t
                        for t in (window["publicationStart"], stop)
                        if row["start"] < t < row["end"]
                    ],
                }
            )
            for a, b in pairwise(cuts):
                name = (
                    aliases.get(key, group(key))
                    if a >= window["publicationStart"] and b <= stop
                    else "unresolved:" + ":".join(key)
                )
                output.append({"start": a, "end": b, "speaker": name})
        return output

    for index, entry in enumerate(trace["entries"]):
        now = entry["audioSubmittedThrough"]
        if entry["ordinal"] != index or not math.isfinite(now) or now < clock:
            raise ValueError("Invalid callback ordering")
        clock = now
        kind = entry["kind"]
        if kind == "embeddingReady":
            identifier = entry["sampleID"]
            if (
                identifier not in samples
                or identifier in ready
                or samples[identifier]["end"] > now
            ):
                raise ValueError("Invalid embedding callback")
            ready.add(identifier)
            continue
        if kind == "bootstrapContext":
            context = entry["bootstrapContext"]
            if context["policyRevision"] not in online.SUPPORTED_WINDOW_POLICIES:
                raise ValueError("Unsupported context capacity policy")
            if (
                not 0
                <= context["contextOrigin"]
                <= context["start"]
                < context["end"]
                <= context["handoff"]
                <= now
            ):
                raise ValueError("Context is outside known replay bounds")
            namespace = (context["source"], context["generation"])
            if namespace in decided:
                raise ValueError("Context arrived after first positive publication")
            identities = [speaker["id"] for speaker in context["speakers"]]
            if not identities or len(set(identities)) != len(identities):
                raise ValueError("Context identity namespace is empty or duplicated")
            capacity = context.get("capacityReachedAt")
            if capacity is not None and (
                not math.isfinite(capacity)
                or not context["contextOrigin"] <= capacity <= now
            ):
                raise ValueError("Context capacity timestamp is invalid")
            if contexts[namespace]:
                prior = contexts[namespace][-1]
                if (
                    context["start"] < prior["end"]
                    or any(
                        context[field] != prior[field]
                        for field in ("contextOrigin", "handoff", "policyRevision")
                    )
                    or set(identities)
                    != {speaker["id"] for speaker in prior["speakers"]}
                ):
                    raise ValueError(
                        "Context bounds, policy, or identity namespace changed"
                    )
                if (
                    "capacityReachedAt" in prior
                    and capacity != prior["capacityReachedAt"]
                ):
                    raise ValueError("First context capacity timestamp changed")
                if (
                    "capacityReachedAt" not in prior
                    and capacity is not None
                    and capacity < prior["end"]
                ):
                    raise ValueError(
                        "Context capacity timestamp predates already observed context"
                    )
            for row in context["intervals"]:
                if row["speakerID"] not in identities:
                    raise ValueError(
                        "Context interval refers to an unknown local identity"
                    )
                if not context["start"] <= row["start"] < row["end"] <= context["end"]:
                    raise ValueError("Context activity is outside callback bounds")
            contexts[namespace].append(context)
            continue
        if kind != "speakerEvent":
            raise ValueError("Unknown callback kind")
        event = entry["event"]
        namespace = (event["source"], event["generation"])
        window = event.get("continuity")
        if window is not None:
            if (window["source"], window["generation"]) != namespace:
                raise ValueError("Publication continuity belongs to another namespace")
            if window["policyRevision"] not in online.SUPPORTED_WINDOW_POLICIES:
                raise ValueError("Unsupported publication capacity policy")
            generations[namespace] = window
            for label in window["localSpeakerIDs"]:
                windows[label_key(window["source"], label)] = window
        if event["end"] > event["start"] and namespace not in decided:
            decided.add(namespace)
            observed = contexts.get(namespace, [])
            if observed:
                origin = observed[0]["contextOrigin"]
                handoff = observed[0]["handoff"]
                if window is None:
                    raise ValueError(
                        "Context publication lacks trusted-window metadata"
                    )
                if (
                    window["publicationStart"] != handoff
                    or window["policyRevision"] != observed[0]["policyRevision"]
                    or set(window["localSpeakerIDs"])
                    != {speaker["id"] for speaker in observed[0]["speakers"]}
                ):
                    raise ValueError(
                        "Context handoff, policy, or identities differ from published window"
                    )
                known_capacity = observed[-1].get("capacityReachedAt")
                window_capacity = window.get("capacityReachedAt")
                if window_capacity is not None and (
                    not math.isfinite(window_capacity)
                    or not origin <= window_capacity <= now
                ):
                    raise ValueError("Published capacity timestamp is invalid")
                if known_capacity is not None and window_capacity != known_capacity:
                    raise ValueError(
                        "Published first capacity timestamp differs from context"
                    )
                if any(
                    c["contextOrigin"] != origin or c["handoff"] != handoff
                    for c in observed
                ):
                    raise ValueError("Bootstrap context changed origin or handoff")
                cuts = [
                    c["capacityReachedAt"] for c in observed if "capacityReachedAt" in c
                ]
                if window and "capacityReachedAt" in window:
                    cuts.append(window["capacityReachedAt"])
                stop = min([handoff, *cuts])
                zero_trust = (
                    window is None
                    or min(
                        window["observedEnd"],
                        window.get("capacityReachedAt", window["observedEnd"]),
                    )
                    <= handoff
                )
                new = []
                for c in observed:
                    for row in c["intervals"]:
                        value = clipped(
                            {
                                "source": c["source"],
                                "localSpeakerID": row["speakerID"],
                                "start": row["start"],
                                "end": row["end"],
                            },
                            origin,
                            stop,
                        )
                        if value:
                            new.append(value)
                old = [
                    value
                    for row in trusted_activity(activity, windows)
                    if row["source"] == event["source"]
                    if (value := clipped(row, origin, handoff)) is not None
                ]
                proposed, details = correspondence(old, new, aliases)
                if not zero_trust:
                    aliases.update(proposed)
                audits.append(
                    {
                        "generation": event["generation"],
                        "source": event["source"],
                        "callbackOrdinal": index,
                        "audioSubmittedThrough": now,
                        "contextOrigin": origin,
                        "handoff": handoff,
                        "contextTrustedEnd": stop,
                        "saturatedBootstrapZeroTrust": zero_trust,
                        "admittedAliases": 0 if zero_trust else len(proposed),
                        "candidates": details,
                    }
                )
        rows = [
            {
                "source": event["source"],
                "localSpeakerID": row["speakerID"],
                "start": row["start"],
                "end": row["end"],
            }
            for row in event["intervals"]
        ]
        published.extend(assign(rows))
        activity.extend(rows)
    if ready != set(samples) or activity != evidence["activity"]:
        raise ValueError(
            "Callback samples or publication differ from retained evidence"
        )
    expected = {(w["source"], w["generation"]): w for w in evidence.get("windows", [])}
    if generations != expected:
        raise ValueError("Callback windows differ from retained evidence")
    return {
        "publishedIntervals": published,
        "finalSnapshot": assign(activity),
        "decisions": audits,
        "aliases": {":".join(key): value for key, value in aliases.items()},
        "contextCallbacks": sum(len(values) for values in contexts.values()),
        "contextNeverPublished": True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--replay-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--samples", nargs="+", help="Optional development-only subset")
    args = parser.parse_args()
    online, scorer = dependencies()
    manifest = json.loads(args.manifest.read_text())
    measurements = []
    # Validation outcomes are deliberately unavailable to this development probe.
    entries = [
        s for s in online.selected_samples(manifest) if s["cohort"] == "development"
    ]
    complete_cohort = len(entries)
    if args.samples:
        if set(args.samples) - {entry["id"] for entry in entries}:
            raise ValueError("Probe only accepts known development samples")
        entries = [entry for entry in entries if entry["id"] in args.samples]
    if not entries:
        raise ValueError("No development samples")
    selection_path = args.manifest.parent / "selection.json"
    if sha(selection_path) != manifest["selectionSHA256"]:
        raise ValueError("Frozen selection hash differs")
    selection = json.loads(selection_path.read_text())
    if set(selection["cohorts"]["development"]) & set(
        selection["cohorts"]["validation"]
    ):
        raise ValueError("Dataset development and validation identities overlap")
    replay_contract = None
    for sample in entries:
        folder = args.replay_root / (sample["id"] + "-on")
        evidence, _, receipt = online.verified_replay(folder, sample, False, "on")
        run = json.loads(folder.with_suffix(".run.json").read_text())
        trace_path = folder / "availability.json"
        if sha(trace_path) != run["artifacts"].get("availability.json"):
            raise ValueError("Context trace hash differs")
        trace = json.loads(trace_path.read_text())
        contract = {
            key: receipt.get(key)
            for key in (
                "productionSHA256",
                "testBundleSHA256",
                "replaySourceSHA256",
                "modelAssetsSHA256",
                "provenanceStable",
                "windowPolicyRevisions",
            )
        }
        if not all(contract.values()) or contract["provenanceStable"] is not True:
            raise ValueError(
                "Context probe requires complete, stable replay provenance"
            )
        if replay_contract is not None and replay_contract != contract:
            raise ValueError("Context cohort mixes replay implementations")
        replay_contract = contract
        candidate = associate(evidence, trace)
        if (
            sha(sample["ownershipPath"]) != sample["ownershipSHA256"]
            or sha(sample["audioPath"]) != sample["audioSHA256"]
        ):
            raise ValueError("Dataset input hash differs")
        reference = json.loads(Path(sample["ownershipPath"]).read_text())
        if (
            reference["audioSHA256"] != sample["audioSHA256"]
            or reference["selectionSHA256"] != manifest["selectionSHA256"]
            or reference["audioDurationSeconds"] != sample["durationSeconds"]
            or any(
                row["speaker"] not in selection["cohorts"]["development"]
                for row in reference["intervals"]
            )
        ):
            raise ValueError("Ownership does not match frozen development inputs")
        baseline = [
            {
                "start": r["start"],
                "end": r["end"],
                "speaker": r["source"] + ":" + r["localSpeakerID"],
            }
            for r in evidence["activity"]
        ]
        systems = {
            "rawLiveOn": baseline,
            "capacitySafeLocal": capacity_safe_baseline(evidence),
            "contextPublication": candidate["publishedIntervals"],
            "contextSnapshot": candidate["finalSnapshot"],
        }
        original_seconds = sum(row["end"] - row["start"] for row in baseline)
        if any(
            abs(sum(row["end"] - row["start"] for row in rows) - original_seconds)
            > 1e-6
            for rows in systems.values()
        ):
            raise ValueError("Context changed published activity coverage")
        measurements.append(
            {
                "sample": sample["id"],
                "metrics": {
                    name: scorer.measure(reference, rows)
                    for name, rows in systems.items()
                },
                "decisions": candidate["decisions"],
                "aliases": candidate["aliases"],
                "contextCallbacks": candidate["contextCallbacks"],
                "replay": receipt,
                "availabilitySHA256": sha(trace_path),
                "activitySpeakerSeconds": original_seconds,
            }
        )
    result = {
        "method": "bootstrap-temporal-correspondence-v1-experiment",
        "cohort": "development",
        "completeCohort": len(entries) == complete_cohort,
        "replayMethod": replay_contract,
        "criteria": {
            "minimumMatchedSeconds": MIN_SECONDS,
            "minimumExclusiveSupportShare": MIN_SHARE,
            "minimumMarginShare": MIN_MARGIN,
        },
        "manifestSHA256": sha(args.manifest),
        "scriptSHA256": sha(__file__),
        "scorerSHA256": sha(ROOT_SCORE),
        "associationUtilitiesSHA256": sha(
            Path(__file__).parents[1] / "speaker-consolidation/online_associate.py"
        ),
        "wrapperSHA256": sha(Path(__file__).with_name("evaluate_online.py")),
        "checksSHA256": sha(Path(__file__).with_name("test_bootstrap_associate.py")),
        "assignmentImplementationSHA256": sha(
            Path(__file__).parents[1] / "diarization-benchmark/compare_reference.py"
        ),
        "samples": measurements,
        "limits": [
            "Temporal correspondence capability probe, not fresh voice fingerprint confirmation",
            "Source ownership metrics are not DER",
            "No validation cohort read",
        ],
    }
    output = scorer.private_output(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")


ROOT_SCORE = Path(__file__).with_name("score.py")
if __name__ == "__main__":
    main()
