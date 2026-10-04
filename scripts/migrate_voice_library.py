#!/usr/bin/env python3
"""One-time pre-1.0 migration. Run with uv run --no-project; stop the app first."""
import argparse
import copy
import math
import time
import json
import os
import shutil
import tempfile
import uuid
from pathlib import Path


def identifier(value):
    return str(uuid.UUID(value)).upper()


def write_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as stream:
        os.chmod(path, 0o600)
        json.dump(value, stream, separators=(",", ":"), sort_keys=True, allow_nan=False)
        stream.flush()
        os.fsync(stream.fileno())


def require(value, fields):
    if not isinstance(value, dict):
        raise ValueError("Expected a JSON object.")
    for key, kind in fields.items():
        item = value.get(key)
        if kind == "number":
            valid = type(item) in (int, float) and math.isfinite(item)
        elif kind == "uuid":
            identifier(item)
            valid = True
        else:
            valid = type(item) is kind
        if not valid:
            raise ValueError("Invalid or missing required field: " + key)


def optional(value, fields):
    for key, kind in fields.items():
        if value.get(key) is not None:
            require(value, {key: kind})


def validate_range(value):
    require(value, {"audioFile": str, "source": str, "start": "number", "end": "number"})


def validate_decision(value):
    require(value, {"meetingID": "uuid", "speakerID": "uuid"})
    optional(value, {"personID": "uuid"})


def validate_embedding(value):
    require(value, {"type": dict, "values": list})
    require(value["type"], {"modelID": str, "revision": str, "compatibilityVersion": str,
                             "dimension": int, "normalization": str})
    optional(value, {"provenance": str})
    if any(type(x) not in (int, float) or not math.isfinite(x) for x in value["values"]):
        raise ValueError("Invalid embedding values.")


def validate_document(document):
    require(document, {"version": int, "examples": list, "jobs": list, "decisions": list,
                       "undo": list, "deletedPersonIDs": list})
    if document["version"] != 1:
        raise ValueError("Unsupported voice-library version.")
    for example in document["examples"]:
        require(example, {"id": "uuid", "meetingID": "uuid", "speakerID": "uuid", "source": str,
                          "review": str, "rejectedPersonIDs": list, "excluded": bool, "manuallyCleared": bool,
                          "embeddings": list, "groupID": "uuid", "manuallyGrouped": bool, "createdAt": "number"})
        if example["review"] not in ("unassigned", "suggested", "confirmed", "rejected"):
            raise ValueError("Unsupported review state.")
        if example.get("origin") not in (None, "legacyProfile", "savedSpeaker", "liveSpeech", "discovery"):
            raise ValueError("Unsupported example origin.")
        optional(example, {"audioFile": str, "audioRevision": str, "start": "number", "end": "number",
                           "requiresAudioReview": bool, "sourceResolutionIssue": str, "legacyEmbeddings": list})
        if example.get("firstPassage") is not None:
            validate_range(example["firstPassage"])
        for key in ("personID", "suggestedPersonID", "legacyPersonID"):
            if example.get(key) is not None:
                identifier(example[key])
        for person in example["rejectedPersonIDs"]:
            identifier(person)
        for vector in example["embeddings"] + (example.get("legacyEmbeddings") or []):
            validate_embedding(vector)
    for decision in document["decisions"]:
        validate_decision(decision)
    for job in document["jobs"]:
        require(job, {"id": "uuid", "providerID": "uuid", "providerName": str, "type": dict,
                      "discover": bool, "exampleIDs": list, "discoveryInputs": list,
                      "completedRecordingIDs": list, "completedExampleIDs": list,
                      "failures": dict, "state": str, "createdAt": "number"})
        validate_embedding({"type": job["type"], "values": []})
        for key in ("exampleIDs", "completedRecordingIDs", "completedExampleIDs", "fullyAnalyzedRecordingIDs"):
            if job.get(key) is not None:
                require(job, {key: list})
                for item in job[key]:
                    identifier(item)
        if any(type(key) is not str or type(value) is not str for key, value in job["failures"].items()):
            raise ValueError("Invalid failure messages.")
        for item in job["discoveryInputs"]:
            require(item, {"meetingID": "uuid", "audioFiles": list, "audioRevisions": dict})
            if any(type(file) is not str for file in item["audioFiles"]) or any(type(key) is not str or type(value) is not str for key, value in item["audioRevisions"].items()):
                raise ValueError("Invalid discovery audio files.")
        if job["state"] not in ("queued", "running", "paused", "completed", "failed"):
            raise ValueError("Unsupported preparation state.")
    for undo in document["undo"]:
        require(undo, {"examples": list, "decisions": list})
        for item in undo["examples"]:
            require(item, {"id": "uuid", "review": str, "rejectedPersonIDs": list,
                           "excluded": bool, "manuallyCleared": bool, "groupID": "uuid", "manuallyGrouped": bool})
            if item["review"] not in ("unassigned", "suggested", "confirmed", "rejected"):
                raise ValueError("Invalid undo review state.")
            optional(item, {"personID": "uuid", "suggestedPersonID": "uuid", "requiresAudioReview": bool, "reviewedAudioRevision": str})
            for person in item["rejectedPersonIDs"]:
                identifier(person)
            if item.get("reviewedRange") is not None:
                validate_range(item["reviewedRange"])
        for decision in undo["decisions"]:
            validate_decision(decision)
    for person in document["deletedPersonIDs"]:
        identifier(person)


def legacy_profiles(root):
    profiles = []
    for path in sorted((root / "people").glob("*.json")):
        if path.is_symlink():
            raise ValueError("A person record is a symbolic link.")
        person = json.loads(path.read_bytes())
        identifier(person["id"])
        for sample in person.get("voiceSamples", []):
            identifier(sample["meetingID"])
            identifier(sample["speakerID"])
            vector = sample.get("voiceEmbedding")
            if vector is None:
                values = sample["embedding"]
                vector = {"type": {"modelID": "unknown", "revision": "unknown", "compatibilityVersion": "unknown",
                                   "dimension": len(values), "normalization": "unknown"},
                          "values": values, "provenance": sample["scope"]}
            validate_embedding(vector)
            profiles.append((person["id"], sample, vector))
    return profiles


COMMUNITY1_TYPE = {"modelID": "FluidInference/community1-wespeaker-resnet34", "revision": "df2625ac79a7ac6b65ad868fee6d80f320da4232", "compatibilityVersion": "gday-span-mask-v1", "dimension": 256, "normalization": "unitL2"}


def resolve_embedding(vector):
    vector = copy.deepcopy(vector)
    provenance = vector.get("provenance", "")
    values = vector["values"]
    if vector["type"]["modelID"] == "unknown" and (provenance == "legacy:rust:runpod" or provenance.startswith("runpod:")) and len(values) == 256 and all(math.isfinite(x) for x in values):
        scale = max(map(abs, values))
        if scale > 0:
            scaled = [value / scale for value in values]
            norm = math.sqrt(sum(value * value for value in scaled))
            vector["type"] = dict(COMMUNITY1_TYPE)
            vector["values"] = [value / norm for value in scaled]
    return vector


def normalize_legacy(document, profiles):
    document = copy.deepcopy(document)
    for example in document["examples"]:
        vectors = []
        for vector in example["embeddings"] + (example.pop("legacyEmbeddings", None) or []):
            vector = resolve_embedding(vector)
            if vector not in vectors:
                vectors.append(vector)
        example["embeddings"] = vectors
        owner = example.pop("legacyPersonID", None)
        if owner is not None and example.get("personID") is None and example["review"] not in ("confirmed", "rejected") and not example["manuallyCleared"] and example.get("suggestedPersonID") is None:
            example["suggestedPersonID"] = owner
            example["review"] = "suggested"
        example.pop("requiresAudioReview", None)
    for undo in document["undo"]:
        for example in undo["examples"]:
            example.pop("requiresAudioReview", None)
            example.pop("reviewedRange", None)
            example.pop("reviewedAudioRevision", None)
    return document


def document_from_profiles(profiles):
    result = {"version": 1, "examples": [], "jobs": [], "decisions": [], "undo": [], "deletedPersonIDs": []}
    for person, sample, vector in profiles:
        result["examples"].append({"id": str(uuid.uuid4()).upper(), "meetingID": sample["meetingID"],
            "speakerID": sample["speakerID"], "source": "unknown", "review": "suggested", "suggestedPersonID": person,
            "rejectedPersonIDs": [], "excluded": False, "manuallyCleared": False, "embeddings": [resolve_embedding(vector)],
            "groupID": str(uuid.uuid4()).upper(), "manuallyGrouped": False, "createdAt": time.time() - 978307200,
            "origin": "legacyProfile"})
    return result


def migrate(root, apply=False, app_stopped=False):
    source = root / "voice-library.json"
    destination = root / "voice-library"
    backup = root / "voice-library.json.pre-sharded-backup"
    if source.is_symlink() or root.is_symlink():
        raise ValueError("The source and data folder must not be symbolic links.")
    if destination.exists() or backup.exists():
        raise ValueError("The destination or migration backup already exists; no files were changed.")
    profiles = legacy_profiles(root)
    source_exists = source.exists()
    if not source_exists and not profiles:
        raise ValueError("No voice-library.json or legacy person voice samples were found.")
    original = source.read_bytes() if source_exists else json.dumps(document_from_profiles(profiles)).encode()
    document = json.loads(original)
    validate_document(document)
    document = normalize_legacy(document, profiles)
    validate_document(document)
    records = {}
    def add(path, value):
        if path in records:
            raise ValueError("Duplicate voice-library record: " + path)
        records[path] = value
    for example in document.get("examples", []):
        example = dict(example)
        key = identifier(example["id"])
        # Validate required identities without changing the source document.
        identifier(example["meetingID"])
        identifier(example["speakerID"])
        vectors = {"embeddings": example.get("embeddings", [])}
        example["embeddings"] = []
        add(f"examples/{key}.json", example)
        if vectors["embeddings"]:
            add(f"representations/{key}.json", vectors)
    for job in document.get("jobs", []):
        add(f"jobs/{identifier(job['id'])}.json", job)
    for decision in document.get("decisions", []):
        key = identifier(decision["meetingID"]) + "-" + identifier(decision["speakerID"])
        add(f"decisions/{key}.json", decision)
    for index, undo in enumerate(document.get("undo", [])):
        add(f"undo/{index:03d}.json", undo)
    for person in document.get("deletedPersonIDs", []):
        add(f"deleted-people/{identifier(person)}.json", person)
    if not apply:
        return {"records": len(records), "applied": False}
    if not app_stopped:
        raise ValueError("Quit Gday Meetings, then pass --app-stopped with --apply.")
    staging = Path(tempfile.mkdtemp(prefix=".voice-library-migration-", dir=root))
    try:
        for name, value in records.items():
            write_json(staging / name, value)
            if json.loads((staging / name).read_text()) != value:
                raise ValueError("Verification failed: " + name)
        write_json(staging / "state.json", {"version": 1, "revision": str(uuid.uuid4()).upper()})
        with (staging / ".lock").open("xb") as stream:
            os.chmod(staging / ".lock", 0o600)
            stream.flush()
            os.fsync(stream.fileno())
        for folder, _, _ in os.walk(staging, topdown=False):
            descriptor = os.open(folder, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        # The unchanged original is the rollback backup; never overwrite one.
        if source_exists and source.read_bytes() != original:
            raise ValueError("The source changed during migration. Stop the app and retry.")
        with backup.open("xb") as stream:
            os.chmod(backup, 0o600)
            stream.write(original)
            stream.flush()
            os.fsync(stream.fileno())
        staging.rename(destination)
        descriptor = os.open(root, os.O_RDONLY)
        try:
            os.fsync(descriptor)
            # Retirement prevents an old app from silently editing stale evidence.
            if source_exists:
                source.unlink()
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        return {"records": len(records), "applied": True, "backup": str(backup)}
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("data_folder", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--app-stopped", action="store_true")
    args = parser.parse_args()
    print(json.dumps(migrate(args.data_folder, args.apply, args.app_stopped), indent=2))


if __name__ == "__main__":
    main()
