"""Evaluate a frozen causal association policy against public source ownership.

Ownership-conditional metrics are not DER. Reference ownership enters only after
association; decision diagnostics require an entirely single-owner sample and
use prior observed samples to distinguish a new voice from a returning voice.
"""

import argparse
import hashlib
import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_named(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def dependencies():
    """Existing sibling scripts use unqualified imports; isolate their names."""
    names = ("score", "evaluate")
    saved = {name: sys.modules.get(name) for name in names}
    try:
        sys.modules["score"] = load_named(
            "consolidation_score", ROOT / "speaker-consolidation/score.py"
        )
        sys.modules["evaluate"] = load_named(
            "consolidation_evaluate", ROOT / "speaker-consolidation/evaluate.py"
        )
        online = load_named(
            "capacity_online_association",
            ROOT / "speaker-consolidation/online_associate.py",
        )
    finally:
        for name, module in saved.items():
            if module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = module
    ownership = load_named(
        "capacity_ownership_score", ROOT / "live-speaker-capacity/score.py"
    )
    return online, ownership


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def method():
    paths = {
        "wrapper": Path(__file__),
        "association": ROOT / "speaker-consolidation/online_associate.py",
        "ownershipScorer": ROOT / "live-speaker-capacity/score.py",
        "assignment": ROOT / "diarization-benchmark/compare_reference.py",
    }
    return {
        "schemaVersion": 1,
        "policy": "sticky",
        "threshold": 0.72,
        "additionalDelaySeconds": 0,
        "publicationPolicy": "strictly earlier callback ordinal; decision after confirming event",
        "sourceSHA256": {name: sha(path) for name, path in paths.items()},
    }


def freeze_policy(output, development=None):
    frozen = {"method": method()}
    if development is not None:
        evaluated = json.loads(development.read_text())
        if (
            evaluated.get("cohort") != "development"
            or evaluated.get("method") != frozen["method"]
        ):
            raise ValueError("Development evaluation does not match current method")
        if not evaluated.get("completeCohort") or not evaluated.get("samples"):
            raise ValueError("Development cohort is incomplete")
        frozen["developmentEvaluationPath"] = str(development.resolve())
        frozen["developmentEvaluationSHA256"] = sha(development)
        frozen["datasetManifestSHA256"] = evaluated["datasetManifestSHA256"]
        frozen["replayMethods"] = replay_methods(
            evaluated["samples"], require_assets=True
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x") as stream:
        json.dump(frozen, stream, indent=2)
        stream.write("\n")
    return frozen


def verify_policy(path, cohort, manifest):
    frozen = json.loads(path.read_text())
    if frozen.get("method") != method():
        raise ValueError("Frozen policy differs from current implementation")
    if cohort == "validation":
        development = Path(frozen.get("developmentEvaluationPath", ""))
        if (
            not development.is_file()
            or sha(development) != frozen.get("developmentEvaluationSHA256")
            or frozen.get("datasetManifestSHA256") != sha(manifest)
        ):
            raise ValueError(
                "Validation requires a completed, hash-bound development evaluation"
            )
        report = json.loads(development.read_text())
        if (
            report.get("cohort") != "development"
            or not report.get("completeCohort")
            or report.get("method") != method()
        ):
            raise ValueError("Invalid development evaluation")
        if frozen.get("replayMethods") != replay_methods(
            report["samples"], require_assets=True
        ):
            raise ValueError("Frozen replay methods differ from development evidence")
    return frozen


def replay_methods(samples, require_assets=False):
    """Pin each mode separately; reject mixed binaries or policies in a cohort."""
    modes = {}
    for sample in samples:
        for mode in ("on", "off"):
            audit = sample["replays"][mode]
            pinned = {
                key: audit.get(key)
                for key in (
                    "productionSHA256",
                    "testBundleSHA256",
                    "replaySourceSHA256",
                    "windowPolicyRevisions",
                    "modelAssetsSHA256",
                    "provenanceStable",
                )
            }
            if (
                not isinstance(pinned["productionSHA256"], dict)
                or not pinned["productionSHA256"]
                or not pinned["testBundleSHA256"]
                or not pinned["replaySourceSHA256"]
                or not isinstance(pinned["windowPolicyRevisions"], list)
            ):
                raise ValueError("Replay method provenance is incomplete")

            def valid_hash(value):
                return (
                    isinstance(value, str)
                    and len(value) == 64
                    and all(c in "0123456789abcdef" for c in value)
                )

            if (
                not all(
                    valid_hash(value) for value in pinned["productionSHA256"].values()
                )
                or not valid_hash(pinned["testBundleSHA256"])
                or not valid_hash(pinned["replaySourceSHA256"])
            ):
                raise ValueError("Replay method hashes are invalid")
            assets = pinned["modelAssetsSHA256"]
            if require_assets and (
                not isinstance(assets, dict)
                or not assets
                or not all(valid_hash(value) for value in assets.values())
                or pinned["provenanceStable"] is not True
            ):
                raise ValueError(
                    "Validation freeze requires model asset hashes and stable pre/post provenance"
                )
            if mode in modes and modes[mode] != pinned:
                raise ValueError("Replay methods differ within one cohort mode")
            modes[mode] = pinned
    if set(modes) != {"on", "off"}:
        raise ValueError("Both replay modes are required")
    return modes


def diagnostics(reference, evidence, result):
    def owner(sample):
        active = [
            r
            for r in reference["intervals"]
            if r["start"] < sample["end"] and r["end"] > sample["start"]
        ]
        labels = {r["speaker"] for r in active}
        if len(labels) != 1:
            return None
        covered = []
        for row in sorted(active, key=lambda r: r["start"]):
            a, b = max(row["start"], sample["start"]), min(row["end"], sample["end"])
            if covered and a <= covered[-1][1]:
                covered[-1][1] = max(covered[-1][1], b)
            else:
                covered.append([a, b])
        return (
            next(iter(labels))
            if sum(b - a for a, b in covered) >= sample["end"] - sample["start"] - 1e-6
            else None
        )

    samples = {s["id"]: s for s in evidence["samples"]}
    seen_owners, seen_labels = set(), set()
    person_owners = defaultdict(set)
    counts = Counter()
    decisions = []
    for event in result["events"]:
        known_owner = owner(samples[event["sampleID"]])
        first = event["localLabel"] not in seen_labels
        if first or event["changed"]:
            returning = known_owner in seen_owners if known_owner is not None else None
            match = event["person"] != event["localLabel"]
            prior = person_owners[event["person"]]
            if known_owner is None:
                kind = "unresolved_sample_ownership"
            elif not match:
                kind = "return_deferred" if returning else "new_voice_kept_separate"
            elif len(prior) != 1:
                kind = "ambiguous_or_unobserved_target_profile"
            elif known_owner in prior:
                kind = "correct_return_match"
            else:
                kind = (
                    "incorrect_return_match"
                    if returning
                    else "unknown_voice_false_match"
                )
            counts[kind] += 1
            decisions.append(
                {
                    "sampleID": event["sampleID"],
                    "time": event["time"],
                    "kind": kind,
                    "firstSampleForLocalLabel": first,
                    "availableSamples": event["sampleCount"],
                    "similarity": event["bestSimilarity"],
                    "margin": event["margin"],
                }
            )
        seen_labels.add(event["localLabel"])
        if known_owner is not None:
            seen_owners.add(known_owner)
            person_owners[event["person"]].add(known_owner)
    return {
        "definition": "Entire sampled span has one owner; target identity judged only by prior sampled ownership",
        "counts": dict(counts),
        "decisions": decisions,
    }


def evaluate(manifest_path, replays, policy_path, cohort, output):
    online, scorer = dependencies()
    frozen = verify_policy(policy_path, cohort, manifest_path)
    manifest = json.loads(manifest_path.read_text())
    selection_path = manifest_path.parent / "selection.json"
    if sha(selection_path) != manifest["selectionSHA256"]:
        raise ValueError("Frozen selection differs")
    selection = json.loads(selection_path.read_text())
    if set(selection["cohorts"]["development"]) & set(
        selection["cohorts"]["validation"]
    ):
        raise ValueError("Development and validation identities overlap")
    entries = [s for s in online.selected_samples(manifest) if s["cohort"] == cohort]
    if not entries:
        raise ValueError("Selected cohort is empty")
    measured = []
    for sample in entries:
        if (
            sha(sample["audioPath"]) != sample["audioSHA256"]
            or sha(sample["ownershipPath"]) != sample["ownershipSHA256"]
        ):
            raise ValueError("Dataset artifact hash differs")
        on, trace, on_audit = online.verified_replay(
            replays / (sample["id"] + "-on"), sample, True, "on"
        )
        off, _, off_audit = online.verified_replay(
            replays / (sample["id"] + "-off"), sample, False, "off"
        )
        current_methods = replay_methods(
            [{"replays": {"on": on_audit, "off": off_audit}}],
            require_assets=cohort == "validation",
        )
        if cohort == "validation" and current_methods != frozen["replayMethods"]:
            raise ValueError(
                "Validation replay model, binary, source, or window policy differs from frozen development"
            )
        result = online.associate(
            on, delay=0, threshold=0.72, policy="sticky", trace=trace
        )

        def local(evidence):
            return [
                {
                    "start": r["start"],
                    "end": r["end"],
                    "speaker": r["source"] + ":" + r["localSpeakerID"],
                }
                for r in evidence["activity"]
            ]

        systems = {
            "rawLiveOn": local(on),
            "rawLiveOff": local(off),
            "capacitySafeLocal": online.associate(dict(on, samples=[]), delay=0)[
                "intervals"
            ],
            "candidatePublication": result["publishedIntervals"],
            "currentAliasSnapshot": result["finalSnapshot"],
        }
        # Read reference ownership only after the algorithm has produced all outputs.
        reference = json.loads(Path(sample["ownershipPath"]).read_text())
        if (
            reference["audioSHA256"] != sample["audioSHA256"]
            or reference["selectionSHA256"] != manifest["selectionSHA256"]
            or reference["audioDurationSeconds"] != sample["durationSeconds"]
        ):
            raise ValueError("Ownership provenance differs")
        allowed = set(selection["cohorts"][cohort])
        if any(r["speaker"] not in allowed for r in reference["intervals"]):
            raise ValueError("Ownership identity is outside selected cohort")
        measured.append(
            {
                "sample": sample["id"],
                "scenario": sample["scenario"],
                "metrics": {
                    name: scorer.measure(reference, rows)
                    for name, rows in systems.items()
                },
                "activitySpeakerSeconds": {
                    name: sum(r["end"] - r["start"] for r in rows)
                    for name, rows in systems.items()
                },
                "labelCounts": {
                    name: len({r["speaker"] for r in rows})
                    for name, rows in systems.items()
                },
                "generations": {
                    name: audit["receipt"]["generations"]
                    for name, audit in [("on", on_audit), ("off", off_audit)]
                },
                "trustedSamples": result["trustedSamples"],
                "rejectedSamples": result["rejectedSamples"],
                "decisions": diagnostics(reference, on, result),
                "replays": {"on": on_audit, "off": off_audit},
            }
        )
    report = {
        "schemaVersion": 1,
        "cohort": cohort,
        "completeCohort": True,
        "method": method(),
        "datasetManifestSHA256": sha(manifest_path),
        "policySHA256": sha(policy_path),
        "samples": measured,
        "replayMethods": replay_methods(measured),
        "limits": [
            "Source ownership is not a speech activity annotation; these metrics are not DER",
            "Replay awaits extraction and does not measure live capture or wall-clock latency",
            "Candidate publication policy is experimental, not observed app person labels",
        ],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x") as stream:
        json.dump(report, stream, indent=2)
        stream.write("\n")
    return report


def self_test():
    class WrapperTests(unittest.TestCase):
        def test_cohort_cannot_mix_replay_implementations(self):
            audit = {
                "productionSHA256": {"Core/Synthetic.swift": "a" * 64},
                "testBundleSHA256": "b" * 64,
                "replaySourceSHA256": "c" * 64,
                "windowPolicyRevisions": ["synthetic-policy"],
            }
            sample = {
                "replays": {"on": audit, "off": dict(audit, testBundleSHA256="d" * 64)}
            }
            self.assertEqual(set(replay_methods([sample])), {"on", "off"})
            with self.assertRaisesRegex(ValueError, "model asset hashes"):
                replay_methods([sample], require_assets=True)
            bound = json.loads(json.dumps(sample))
            for mode in ("on", "off"):
                bound["replays"][mode].update(
                    modelAssetsSHA256={"model.bin": "e" * 64}, provenanceStable=True
                )
            self.assertEqual(
                set(replay_methods([bound], require_assets=True)), {"on", "off"}
            )
            bound["replays"]["on"]["provenanceStable"] = False
            with self.assertRaisesRegex(ValueError, "stable pre/post"):
                replay_methods([bound], require_assets=True)
            for field, value in [
                ("testBundleSHA256", "e" * 64),
                ("replaySourceSHA256", "e" * 64),
                ("productionSHA256", {"Core/Synthetic.swift": "e" * 64}),
                ("windowPolicyRevisions", ["another-policy"]),
            ]:
                changed = json.loads(json.dumps(sample))
                changed["replays"]["on"][field] = value
                with self.assertRaisesRegex(ValueError, "within one cohort"):
                    replay_methods([sample, changed])

        def test_complete_synthetic_evaluation_and_audio_tamper(self):
            with tempfile.TemporaryDirectory() as temp:
                root = Path(temp)

                def write(path, value):
                    path.write_text(json.dumps(value))

                selection = root / "selection.json"
                write(
                    selection,
                    {
                        "cohorts": {
                            "development": ["owner-a"],
                            "validation": ["owner-b"],
                        }
                    },
                )
                audio = root / "audio.wav"
                audio.write_bytes(b"synthetic audio hash fixture")
                ref = root / "ownership.json"
                write(
                    ref,
                    {
                        "annotationKind": "source-placement-ownership-not-speech-activity",
                        "audioDurationSeconds": 2,
                        "intervals": [{"start": 0, "end": 2, "speaker": "owner-a"}],
                        "audioSHA256": sha(audio),
                        "selectionSHA256": sha(selection),
                    },
                )
                sample = {
                    "id": "synthetic",
                    "cohort": "development",
                    "scenario": "synthetic",
                    "audioPath": str(audio),
                    "audioSHA256": sha(audio),
                    "ownershipPath": str(ref),
                    "ownershipSHA256": sha(ref),
                    "durationSeconds": 2,
                }
                manifest = root / "manifest.json"
                write(
                    manifest,
                    {
                        "selectionSHA256": sha(selection),
                        "samples": [
                            sample,
                            dict(
                                sample, id="synthetic-validation", cohort="validation"
                            ),
                        ],
                    },
                )
                window = {
                    "source": "microphone",
                    "generation": "generation-a",
                    "localSpeakerIDs": ["label-a"],
                    "publicationStart": 0,
                    "observedEnd": 2,
                    "policyRevision": "nemotron-capacity-rollover-v1",
                }
                evidence = {
                    "windows": [window],
                    "samples": [],
                    "activity": [
                        {
                            "source": "microphone",
                            "localSpeakerID": "label-a",
                            "start": 0,
                            "end": 2,
                        }
                    ],
                }
                trace = {
                    "schemaVersion": 1,
                    "clock": "submitted-audio-upper-bound",
                    "entries": [
                        {
                            "ordinal": 0,
                            "audioSubmittedThrough": 2,
                            "kind": "speakerEvent",
                            "event": {
                                "source": "microphone",
                                "continuity": window,
                                "intervals": [
                                    {"speakerID": "label-a", "start": 0, "end": 2}
                                ],
                            },
                        }
                    ],
                }
                for mode in ("on", "off"):
                    folder = root / ("synthetic-" + mode)
                    folder.mkdir()
                    write(folder / "evidence.json", evidence)
                    write(folder / "availability.json", trace)
                    write(
                        folder / "receipt.json",
                        {
                            "complete": True,
                            "failureCount": 0,
                            "gapCount": 0,
                            "extractionFailures": 0,
                            "sampleCount": 0,
                            "generations": 1,
                            "durationSeconds": 2,
                        },
                    )
                    write(
                        folder.with_suffix(".run.json"),
                        {
                            "status": "completed",
                            "returncode": 0,
                            "sample": "synthetic",
                            "rollover": mode,
                            "inputSHA256": sha(audio),
                            "productionSHA256": {"Core/Synthetic.swift": "a" * 64},
                            "testBundleSHA256": "b" * 64,
                            "replaySourceSHA256": "c" * 64,
                            "modelAssetsSHA256": {"models/synthetic.bin": "e" * 64},
                            "provenanceStable": True,
                            "artifacts": {
                                name: sha(folder / name)
                                for name in [
                                    "evidence.json",
                                    "availability.json",
                                    "receipt.json",
                                ]
                            },
                        },
                    )
                policy = root / "policy.json"
                freeze_policy(policy)
                result = evaluate(
                    manifest, root, policy, "development", root / "result.json"
                )
                self.assertEqual(
                    result["samples"][0]["metrics"]["candidatePublication"][
                        "conditionalConfusionFraction"
                    ],
                    0,
                )
                validation_policy = root / "validation-policy.json"
                frozen = freeze_policy(validation_policy, root / "result.json")
                self.assertIn("replayMethods", frozen)
                for mode in ("on", "off"):
                    source = root / ("synthetic-" + mode)
                    target = root / ("synthetic-validation-" + mode)
                    shutil.copytree(source, target)
                    run = json.loads(source.with_suffix(".run.json").read_text())
                    run.update(sample="synthetic-validation", testBundleSHA256="d" * 64)
                    write(target.with_suffix(".run.json"), run)
                with self.assertRaisesRegex(ValueError, "Validation replay"):
                    evaluate(
                        manifest,
                        root,
                        validation_policy,
                        "validation",
                        root / "invalid-binary.json",
                    )
                audio.write_bytes(b"changed")
                with self.assertRaises(ValueError):
                    evaluate(
                        manifest, root, policy, "development", root / "tampered.json"
                    )

        def test_dependency_names_are_restored(self):
            sentinel = object()
            old = sys.modules.get("score")
            sys.modules["score"] = sentinel
            try:
                online, scorer = dependencies()
                self.assertIs(sys.modules["score"], sentinel)
                self.assertTrue(callable(online.verified_replay))
                self.assertTrue(callable(scorer.measure))
            finally:
                if old is None:
                    sys.modules.pop("score", None)
                else:
                    sys.modules["score"] = old

        def test_policy_hash_and_validation_gate(self):
            with tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                policy = root / "policy.json"
                manifest = root / "manifest.json"
                manifest.write_text("{}")
                frozen = freeze_policy(policy)
                verify_policy(policy, "development", manifest)
                with self.assertRaises(ValueError):
                    verify_policy(policy, "validation", manifest)
                frozen["method"]["threshold"] = 0.1
                policy.write_text(json.dumps(frozen))
                with self.assertRaises(ValueError):
                    verify_policy(policy, "development", manifest)

    result = unittest.TextTestRunner().run(
        unittest.defaultTestLoader.loadTestsFromTestCase(WrapperTests)
    )
    if not result.wasSuccessful():
        raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--freeze-policy", type=Path)
    parser.add_argument("--development-evaluation", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--replay-root", type=Path)
    parser.add_argument("--policy", type=Path)
    parser.add_argument("--cohort", choices=["development", "validation"])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    _, scorer = dependencies()
    if args.freeze_policy:
        return freeze_policy(
            scorer.private_output(args.freeze_policy), args.development_evaluation
        )
    if not all(
        (args.manifest, args.replay_root, args.policy, args.cohort, args.output)
    ):
        parser.error(
            "Evaluation requires manifest, replay root, policy, cohort, and output"
        )
    report = evaluate(
        args.manifest,
        args.replay_root,
        args.policy,
        args.cohort,
        scorer.private_output(args.output),
    )
    print(json.dumps({"cohort": report["cohort"], "samples": len(report["samples"])}))


if __name__ == "__main__":
    main()
