"""Replay complete recordings through an isolated Apple SpeechTranscriber harness."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("recordings", type=Path)
    ap.add_argument("binary", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--realtime", action="store_true")
    ap.add_argument("--limit", type=int)
    a = ap.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    probe = subprocess.run(
        [str(a.binary.resolve()), "--probe"], check=True, capture_output=True, text=True
    )
    info = json.loads(probe.stdout)
    (a.output / "probe.json").write_text(json.dumps(info, indent=2) + "\n")
    signature = {
        "binary_sha256": hashlib.sha256(a.binary.read_bytes()).hexdigest(),
        "realtime": a.realtime,
    }
    manifest = a.output / "manifest.json"
    if manifest.exists() and json.loads(manifest.read_text()) != signature:
        raise ValueError("Run configuration changed")
    manifest.write_text(json.dumps(signature, indent=2) + "\n")
    records = [json.loads(x) for x in a.recordings.read_text().splitlines()]
    if a.limit:
        records = records[: a.limit]
    for r in records:
        output = a.output / (r["recording_id"] + ".json")
        digest = hashlib.sha256(Path(r["audio_path"]).read_bytes()).hexdigest()
        if digest != r["audio_sha256"]:
            raise ValueError("Source audio changed")
        if output.exists():
            if json.loads(output.read_text())["audio_sha256"] != digest:
                raise ValueError("Cached audio mismatch")
            continue
        language = r["language"]
        preferred = "en-US" if language == "en" else "zh-CN"
        installed = info["installed"]
        locale = next((v for v in installed if v.replace("_", "-") == preferred), None)
        if not locale:
            locale = next(
                (v for v in installed if v.split("_")[0].split("-")[0] == language),
                None,
            )
        if not locale:
            raise RuntimeError(
                f"No installed Apple locale for {language}; no recordings submitted"
            )
        subprocess.run(
            [
                str(a.binary.resolve()),
                r["audio_path"],
                str(output),
                locale,
                str(a.realtime).lower(),
            ],
            check=True,
            timeout=r["duration_seconds"] * 2 + 180,
        )
        value = json.loads(output.read_text())
        value.update(recording_id=r["recording_id"], audio_sha256=digest)
        output.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
        print("Completed", r["recording_id"], flush=True)


if __name__ == "__main__":
    main()
