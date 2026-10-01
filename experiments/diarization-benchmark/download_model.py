"""Explicitly fetch and verify the pinned low-latency model. No audio is sent."""
import hashlib
import json
import argparse
from pathlib import Path
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("model", choices=["nemotron", "community1"])
selection = parser.parse_args().model
if selection == "nemotron":
    REPO = "FluidInference/nemotron-3-diarization-coreml"
    REVISION = "25a90f97f254428d4b30374b76af9c74fdee8327"
    PREFIXES = ["monolithic/v2/Nemotron3Diarizer_low.mlmodelc/"]
    ASSETS = ["learnable_sil_emb.bin"]
    LOCAL_NAME = "low"
else:
    REPO = "FluidInference/speaker-diarization-coreml"
    REVISION = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    PREFIXES = [name + ".mlmodelc/" for name in ["Segmentation", "FBank", "Embedding", "PldaRho"]]
    ASSETS = ["plda-parameters.json"]
    LOCAL_NAME = "community1"
ROOT = Path(__file__).resolve().parent / ".models" / LOCAL_NAME


def fetch(url):
    return urllib.request.urlopen(url, timeout=120)


def digest(path, entry):
    if entry.get("lfs"):
        h = hashlib.sha256()
        expected = entry["lfs"]["oid"]
    else:
        h = hashlib.sha1()
        h.update(f"blob {entry['size']}\0".encode())
        expected = entry["oid"]
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return path.stat().st_size == entry["size"] and h.hexdigest() == expected


def main():
    url = f"https://huggingface.co/api/models/{REPO}/tree/{REVISION}?recursive=true&limit=1000"
    entries = []
    while url:
        with fetch(url) as response:
            entries.extend(json.load(response))
            links = response.headers.get("Link", "")
        url = next((part.split("<", 1)[1].split(">", 1)[0]
                    for part in links.split(",") if 'rel="next"' in part), None)
    wanted = [e for e in entries if e["type"] == "file" and
              (any(e["path"].startswith(prefix) for prefix in PREFIXES) or e["path"] in ASSETS)]
    if not all(any(e["path"] == prefix + "coremldata.bin" for e in wanted) for prefix in PREFIXES):
        raise RuntimeError("Pinned snapshot lacks the expected model bundle")
    manifest = []
    for entry in wanted:
        relative = entry["path"].removeprefix("monolithic/v2/")
        target = ROOT / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists() or not digest(target, entry):
            temporary = target.with_name(target.name + ".partial")
            print(f"Fetching {relative} ({entry['size']} bytes)", flush=True)
            with fetch(f"https://huggingface.co/{REPO}/resolve/{REVISION}/{entry['path']}") as source:
                with temporary.open("wb") as output:
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        output.write(block)
            if not digest(temporary, entry):
                raise RuntimeError(f"Checksum mismatch: {relative}")
            temporary.replace(target)
        manifest.append({"path": relative, "bytes": entry["size"],
                         "oid": entry.get("lfs", {}).get("oid", entry["oid"])})
    (ROOT / "manifest.json").write_text(json.dumps({"repository": REPO,
        "revision": REVISION, "files": manifest}, indent=2) + "\n")
    print(f"Verified {len(wanted)} files, {sum(e['size'] for e in wanted)} bytes at {ROOT}")


if __name__ == "__main__":
    main()
