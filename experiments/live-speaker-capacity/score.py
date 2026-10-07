"""Score known source ownership without pretending utterance bounds are VAD."""

import argparse
import hashlib
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "diarization-benchmark"))
import itertools

from compare_reference import assignment
from private_paths import private_output


def ratio(numerator, denominator):
    return numerator / denominator if denominator else None


def ownership_breakdown(reference, spans, mapping):
    """Use the recording's single global mapping for every placement and owner.

    A turn means one source placement, not a detected utterance or speech span.
    First arrivals sort by timestamp then owner ID when starts are simultaneous.
    """
    rows = sorted(
        reference["intervals"],
        key=lambda row: (row["start"], row["speaker"], row["end"]),
    )
    arrivals, visits = {}, Counter()
    totals = defaultdict(Counter)
    turns = []

    def finish(value):
        result = dict(value)
        result.update(
            ownershipCoverage=ratio(
                value["coveredOwnedSeconds"], value["ownedSeconds"]
            ),
            conditionalConfusionFraction=ratio(
                value["conditionalConfusedSeconds"], value["pairedExclusiveSeconds"]
            ),
            mappedOwnerCoverage=ratio(
                value["mappedOwnerSeconds"], value["ownedSeconds"]
            ),
            exclusiveCorrectOwnershipFraction=ratio(
                value["correctExclusiveSeconds"], value["exclusiveOwnedSeconds"]
            ),
        )
        return result

    for index, row in enumerate(rows):
        owner = row["speaker"]
        if owner not in arrivals:
            arrivals[owner] = len(arrivals) + 1
        first = visits[owner] == 0
        visits[owner] += 1
        values = Counter(
            {
                key: 0.0
                for key in (
                    "ownedSeconds",
                    "coveredOwnedSeconds",
                    "uncoveredOwnedSeconds",
                    "exclusiveOwnedSeconds",
                    "pairedExclusiveSeconds",
                    "conditionalConfusedSeconds",
                    "correctExclusiveSeconds",
                    "mappedOwnerSeconds",
                    "multipleLabelsOnExclusiveOwnershipSeconds",
                )
            }
        )
        for a, b, owners, labels in spans:
            seconds = max(0, min(b, row["end"]) - max(a, row["start"]))
            if not seconds or owner not in owners:
                continue
            values["ownedSeconds"] += seconds
            values["coveredOwnedSeconds" if labels else "uncoveredOwnedSeconds"] += (
                seconds
            )
            if owner in {mapping.get(label) for label in labels}:
                values["mappedOwnerSeconds"] += seconds
            if len(owners) == 1:
                values["exclusiveOwnedSeconds"] += seconds
                if len(labels) == 1:
                    values["pairedExclusiveSeconds"] += seconds
                    correct = mapping.get(next(iter(labels))) == owner
                    values[
                        "correctExclusiveSeconds"
                        if correct
                        else "conditionalConfusedSeconds"
                    ] += seconds
                elif len(labels) > 1:
                    values["multipleLabelsOnExclusiveOwnershipSeconds"] += seconds
        groups = [
            "firstAppearance" if first else "return",
            "arrivalsAfterEight" if arrivals[owner] > 8 else "firstEightArrivals",
            ("firstAppearance" if first else "return")
            + ("AfterEight" if arrivals[owner] > 8 else "WithinEight"),
        ]
        for group in ["owner:" + owner, *groups]:
            totals[group].update(values)
        turns.append(
            {
                "turnIndex": index,
                "owner": owner,
                "start": row["start"],
                "end": row["end"],
                "arrivalOrdinal": arrivals[owner],
                "appearance": "first" if first else "return",
                "metrics": finish(values),
            }
        )
    return {
        "mappingScope": "one global recording mapping; never refitted by owner, turn, or stratum",
        "turnDefinition": "one source placement, including internal pauses; simultaneous first arrivals use owner-ID order",
        "owners": {
            owner: {
                "arrivalOrdinal": ordinal,
                "placementCount": visits[owner],
                "metrics": finish(totals["owner:" + owner]),
            }
            for owner, ordinal in arrivals.items()
        },
        "strata": {
            name: finish(value)
            for name, value in totals.items()
            if not name.startswith("owner:")
        },
        "turns": turns,
    }


def measure(reference, hypothesis):
    if (
        reference.get("annotationKind")
        != "source-placement-ownership-not-speech-activity"
    ):
        raise ValueError("Expected source-placement ownership")
    duration = reference["audioDurationSeconds"]
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("Invalid duration")
    edges = defaultdict(list)
    edges[0.0], edges[duration] = [], []
    for kind, rows in enumerate((reference["intervals"], hypothesis)):
        for row in rows:
            a, b, speaker = row["start"], row["end"], row["speaker"]
            if not isinstance(speaker, str) or not speaker:
                raise ValueError("Missing speaker")
            if not all(math.isfinite(t) for t in (a, b)) or not 0 <= a < b <= duration:
                raise ValueError("Interval outside recording")
            edges[a].append((kind, speaker, 1))
            edges[b].append((kind, speaker, -1))
    states = [Counter(), Counter()]
    spans, contingency = [], defaultdict(float)
    points = sorted(edges)
    for a, b in itertools.pairwise(points):
        for kind, speaker, delta in edges[a]:
            states[kind][speaker] += delta
        owners, labels = (
            {key for key, count in state.items() if count > 0} for state in states
        )
        spans.append((a, b, owners, labels))
        if len(owners) == len(labels) == 1:
            contingency[(next(iter(owners)), next(iter(labels)))] += b - a
    owners = sorted({owner for owner, _ in contingency})
    labels = sorted({label for _, label in contingency})
    weights = [[contingency[(owner, label)] for owner in owners] for label in labels]
    mapping = {labels[h]: owners[r] for h, r in assignment(weights).items()}
    owner_totals, label_totals = defaultdict(float), defaultdict(float)
    for (owner, label), seconds in contingency.items():
        owner_totals[owner] += seconds
        label_totals[label] += seconds
    paired = sum(contingency.values())
    correct = sum(
        seconds
        for (owner, label), seconds in contingency.items()
        if mapping.get(label) == owner
    )
    precision = ratio(
        sum(s * s / label_totals[h] for (r, h), s in contingency.items()), paired
    )
    recall = ratio(
        sum(s * s / owner_totals[r] for (r, h), s in contingency.items()), paired
    )
    owned = covered = silence = false_silence = ambiguous = 0.0
    overlap = overlap_correct = overlap_labels = overlap_owners = 0.0
    for a, b, owners, labels in spans:
        seconds = b - a
        if owners:
            owned += seconds
            if labels:
                covered += seconds
            if len(owners) == 1 and len(labels) > 1:
                ambiguous += seconds
            if len(owners) > 1:
                overlap += seconds
                overlap_correct += seconds * len(
                    owners & {mapping[h] for h in labels if h in mapping}
                )
                overlap_labels += seconds * len(labels)
                overlap_owners += seconds * len(owners)
        else:
            silence += seconds
            if labels:
                false_silence += seconds
    return {
        "metricKind": "ownership-conditional-not-DER",
        "mapping": mapping,
        "pairedExclusiveSeconds": paired,
        "conditionalConfusedSeconds": paired - correct,
        "conditionalConfusionFraction": ratio(paired - correct, paired),
        "mergePrecision": precision,
        "splitRecall": recall,
        "ownedWallSeconds": owned,
        "coveredOwnedWallSeconds": covered,
        "ownershipCoverage": ratio(covered, owned),
        "multipleLabelsOnExclusiveOwnershipSeconds": ambiguous,
        "injectedSilenceSeconds": silence,
        "activityInInjectedSilenceSeconds": false_silence,
        "injectedSilenceActivityFraction": ratio(false_silence, silence),
        "overlapOwnershipWallSeconds": overlap,
        "overlapMatchedOwnerSeconds": overlap_correct,
        "overlapPredictedLabelSeconds": overlap_labels,
        "overlapReferenceOwnerSeconds": overlap_owners,
        "overlapOwnerSetPrecision": ratio(overlap_correct, overlap_labels),
        "overlapOwnerSetRecall": ratio(overlap_correct, overlap_owners),
        "ownershipBreakdown": ownership_breakdown(reference, spans, mapping),
    }


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ownership", type=Path, required=True)
    parser.add_argument(
        "--hypothesis",
        type=Path,
        required=True,
        help="JSON list of start/end/speaker intervals",
    )
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = measure(
        json.loads(args.ownership.read_text()), json.loads(args.hypothesis.read_text())
    )
    result["inputSHA256"] = {
        "ownership": sha(args.ownership),
        "hypothesis": sha(args.hypothesis),
        "scorer": sha(__file__),
        "assignmentImplementation": sha(
            Path(__file__).resolve().parents[1]
            / "diarization-benchmark"
            / "compare_reference.py"
        ),
    }
    with private_output(args.output).open("x") as stream:
        json.dump(result, stream, indent=2, sort_keys=True)
        stream.write("\n")


if __name__ == "__main__":
    main()
