"""Create ignored native fixtures with the real metadata payload and shared vectors.

Input reads are authorized library reads. All writes are restricted to a new
experiment runs/native directory; no live library record or model is modified.
"""
import argparse
import json
import os
import sqlite3
import subprocess
import uuid
from pathlib import Path

import numpy as np

QUERY_INDICES = [0, 8, 16, 24, 32, 36, 40, 44, 48, 52, 56]
FILES = ["metadata.json", "content.json", "transcript.jsonl", "transcript.json",
         "live-transcript.json", "notes.md", "summary.md", "transcript-checkpoint.json"]


def base36(number):
    alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    result = ""
    while number:
        number, digit = divmod(number, 36)
        result = alphabet[digit] + result
    return result or "0"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--library", required=True, type=Path)
    p.add_argument("--vectors", required=True, type=Path)
    p.add_argument("--base-vectors", required=True, type=Path)
    p.add_argument("--queries", required=True, type=Path)
    p.add_argument("--append-vectors", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--scales", type=int, default=10)
    p.add_argument("--reconstruct-payload", action="store_true", help="Use a disclosed representative payload if the live index has changed")
    args = p.parse_args()
    out = args.output.resolve()
    if "/experiments/search-index-scale/runs/native/" not in str(out) + "/":
        raise SystemExit("Output must stay in ignored experiment runs/native.")
    out.mkdir(parents=True, exist_ok=True)
    (out / "base-artifacts").mkdir(exist_ok=True)
    root = out / "library" / "meetings"
    root.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(f"file:{args.library / 'index.db'}?mode=ro", uri=True)
    c.execute("begin")
    rows = c.execute("select meeting,artifact,vectors from provider_semantic_meetings where dimensions=384 order by meeting").fetchall()
    base = args.base_vectors.read_bytes()
    source_windows = sum(len(r[2]) // 1536 for r in rows)
    source_metadata_bytes = sum(len(r[1]) for r in rows)
    reconstructed = b"".join(r[2] for r in rows) != base
    if reconstructed:
        if not args.reconstruct_payload:
            raise SystemExit("The live projection differs from the exported base vectors. Use a consistent source snapshot.")
        if source_windows < 39066 or len(rows) > 366:
            raise SystemExit("Reconstruction expects at least 39066 windows and at most 366 meetings")
        parts = [[identity, json.loads(artifact), vectors] for identity, artifact, vectors in rows]
        remove = source_windows - 39066
        while remove:
            for row in reversed(parts):
                if remove and len(row[1]["windows"]) > 1:
                    row[1]["windows"].pop()
                    row[2] = row[2][:-1536]
                    remove -= 1
        while len(parts) < 366:
            row = max(parts, key=lambda item: len(item[1]["windows"]))
            middle = len(row[1]["windows"]) // 2
            second = dict(row[1])
            second["windows"] = row[1]["windows"][middle:]
            row[1]["windows"] = row[1]["windows"][:middle]
            parts.append([row[0], second, row[2][middle * 1536:]])
            row[2] = row[2][:middle * 1536]
        rows = [(identity, json.dumps(artifact, ensure_ascii=False, separators=(",", ":")).encode(), vectors)
                for identity, artifact, vectors in parts]

    folders = {}
    for path in (args.library / "meetings").iterdir():
        try:
            key = str(uuid.UUID(int=int(path.name.split("_")[-1], 36))).upper()
        except (ValueError, OverflowError):
            continue
        if key in folders:
            raise RuntimeError("Duplicate source meeting identity")
        folders[key] = path
    c.close()
    queries = np.load(args.queries)[QUERY_INDICES].astype("<f4")
    queries.tofile(out / "queries.f32")
    (out / "query-indices.json").write_text(json.dumps(QUERY_INDICES))
    (out / "vector-path.txt").write_text(str(args.vectors.resolve()) + "\n")
    (out / "append-path.txt").write_text(str(args.append_vectors.resolve()) + "\n")
    row_offsets = []
    offset = 0
    source_bytes = 0
    for number, (meeting_id, artifact, vectors) in enumerate(rows):
        (out / "base-artifacts" / f"{number:04d}.json").write_bytes(artifact)
        source_bytes += len(artifact)
        row_offsets.append(offset)
        offset += len(vectors)
    assert offset == 39066 * 384 * 4
    if args.vectors.stat().st_size < args.scales * offset:
        raise SystemExit("Shared all.f32 has not reached the requested scale")
    for scale in range(1, args.scales + 1):
        manifest = []
        for number, (original_id, artifact, vectors) in enumerate(rows):
            source = folders[original_id.upper()]
            new_id = uuid.UUID(f"00000000-0000-4000-8000-{scale * 1000000 + number:012d}")
            folder_name = "20261006_" + base36(new_id.int)
            target = root / folder_name
            target.mkdir()
            existing = [source / name for name in FILES if (source / name).exists()]
            if any(path.is_symlink() for path in existing):
                raise RuntimeError("Symbolic source file is not supported")
            # APFS copy-on-write keeps each regular file independent without
            # physically duplicating long transcript inputs at every scale.
            subprocess.run(["/bin/cp", "-c", "-p", *map(str, existing), str(target)], check=True)
            metadata = target / "metadata.json"
            old_stat = metadata.stat()
            raw = metadata.read_text()
            decoded = json.loads(raw)
            assert decoded["id"].upper() == original_id.upper()
            raw = raw.replace(decoded["id"], str(new_id).upper())
            metadata.write_text(raw)
            os.utime(metadata, ns=(old_stat.st_atime_ns, old_stat.st_mtime_ns))
            manifest.append({"id": str(new_id).upper(), "folder": folder_name,
                             "artifact": f"base-artifacts/{number:04d}.json",
                             "byteOffset": (scale - 1) * offset + row_offsets[number],
                             "windows": len(vectors) // (384 * 4)})
        (out / f"block-{scale}.json").write_text(json.dumps(manifest))
        print(json.dumps({"preparedScale": scale, "meetings": len(manifest)}), flush=True)
    (out / "fixture.json").write_text(json.dumps({"baseMeetings": len(rows), "baseWindows": 39066,
        "metadataBytesPerBlock": source_bytes, "vectorBytesPerBlock": offset,
        "scales": args.scales, "queryIndices": QUERY_INDICES,
        "payloadReconstructed": reconstructed, "sourceWindowsAtSnapshot": source_windows,
        "sourceMetadataBytesAtSnapshot": source_metadata_bytes,
        "sourceFiles": "Regular APFS clones; representative real metadata payload, synthetic meeting IDs; native fingerprints"}, indent=2))


if __name__ == "__main__":
    main()
