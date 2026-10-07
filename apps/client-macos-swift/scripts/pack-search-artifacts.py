"""One-time development migration from JSON embeddings to packed binary plists.

Dry-run by default. Quit Gday Meetings before --apply. Isolated UI Preview bundles may stay open.
Keep --backup outside the library. Source documents and index.db are untouched.
"""

import argparse
import hashlib
import json
import math
import plistlib
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path


def pack(source):
    artifact = json.loads(source)
    dimensions = len(artifact["windows"][0]["vector"]) if artifact["windows"] else 0
    if dimensions not in (0, 384, 768):
        raise ValueError("Unsupported dimensions")
    fp32, int8 = bytearray(), bytearray()
    for window in artifact["windows"]:
        vector = window["vector"]
        if len(vector) != dimensions or not all(math.isfinite(v) for v in vector):
            raise ValueError("Invalid vector")
        packed = struct.pack(f"<{dimensions}f", *vector)
        values = struct.unpack(f"<{dimensions}f", packed)
        norm = math.sqrt(sum(v * v for v in values))
        if not math.isfinite(norm) or abs(norm - 1) >= 0.0001:
            raise ValueError("Vector is not normalized")
        fp32.extend(packed)
        int8.extend(int(max(-127, min(127, v * 127 / norm))) & 255 for v in values)
        window["vector"] = []
    return plistlib.dumps(
        {
            "version": 1,
            "dimensions": dimensions,
            "metadata": artifact,
            "fp32": bytes(fp32),
            "int8": bytes(int8),
        },
        fmt=plistlib.FMT_BINARY,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--backup", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument(
        "--isolated-copy",
        action="store_true",
        help="Allow running apps when converting a disposable library copy under a temporary directory.",
    )
    args = parser.parse_args()
    library = args.library.resolve(strict=True)
    if args.apply:
        temporary_roots = (
            Path(tempfile.gettempdir()).resolve(),
            Path("/tmp").resolve(),
        )
        if args.isolated_copy and not any(
            library != root and library.is_relative_to(root) for root in temporary_roots
        ):
            parser.error(
                "--isolated-copy requires a library below a temporary directory"
            )
        processes = (
            ""
            if args.isolated_copy
            else subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True)
        )
        for line in processes.splitlines():
            executable = Path(line.strip())
            if executable.name != "GdayMeetings":
                continue
            try:
                info = plistlib.loads(
                    (executable.parent.parent / "Info.plist").read_bytes()
                )
            except (OSError, ValueError):
                info = {}
            # UIPreview.makeStore always creates an isolated temporary library.
            if info.get("GdayUIPreview") is not True:
                parser.error("Quit Gday Meetings before converting saved embeddings.")
        if args.backup is None:
            parser.error("--apply requires --backup outside the library")
        backup = args.backup.resolve()
        if backup == library or library in backup.parents:
            parser.error("Choose a backup folder outside the library")
    count = 0
    for path in sorted(
        (library / "meetings").glob("*/providers/local-search/*/embeddings.json")
    ):
        if path.is_symlink() or not path.resolve().is_relative_to(library):
            raise ValueError("Embedding path escapes the library")
        source = path.read_bytes()
        packed = pack(source)
        target = path.with_name("embeddings.packed")
        if target.exists() and target.read_bytes() != packed:
            # A newly indexed artifact wins; never overwrite it with older JSON.
            raise ValueError(
                "A different packed artifact already exists; review before migration"
            )
        if args.apply:
            saved = backup / path.relative_to(library)
            if saved.exists() and saved.read_bytes() != source:
                raise ValueError("Backup differs; choose a new backup folder")
            saved.parent.mkdir(parents=True, exist_ok=True)
            if not saved.exists():
                shutil.copy2(path, saved)
            if saved.read_bytes() != source:
                raise ValueError("Backup verification failed")
            with tempfile.NamedTemporaryFile(
                dir=target.parent, prefix=".packing-", delete=False
            ) as handle:
                handle.write(packed)
                temporary = Path(handle.name)
            if (
                hashlib.sha256(path.read_bytes()).digest()
                != hashlib.sha256(source).digest()
            ):
                temporary.unlink()
                raise ValueError("Embedding changed during migration")
            temporary.replace(target)
            assert plistlib.loads(target.read_bytes()) == plistlib.loads(packed)
            path.unlink()
        count += 1
    print(json.dumps({"artifacts": count, "applied": args.apply}))


if __name__ == "__main__":
    main()
