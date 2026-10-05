#!/usr/bin/env python3
"""Import a Microsoft Teams meeting transcript as a gday-meetings session.

Teams transcripts carry real speaker names but no audio and no voice
embeddings, so the imported session is transcript-only: the AI overview,
timestamp jumps and speaker filtering all work, there is just nothing to play.

Speakers are mapped to the People library by name. Teams writes names as
"Surname, Given" (sometimes with a "(SP)" suffix), while the People library
uses short display names, so matching is done on the given/surname tokens.
Anything that doesn't match keeps its Teams name and is left unlinked — the
web UI shows it as an unconfirmed speaker you can assign with one click.

Usage:
    uv run --no-project apps/client-macos-rust/scripts/import_teams_transcript.py TRANSCRIPT.json \\
        --name "Weekly Planning Review" \\
        --started-at 2026-01-15T09:00:00Z \\
        [--duration-secs 3600] [--tags work,planning] [--language zh] \\
        [--data-dir ~/.local/share/com.gdaymeetings.macos.rust] [--dry-run]

TRANSCRIPT.json is the Stream transcript document — the one with
`{"$schema": ".../transcript.json", "entries": [...]}`. Get it from the
Recap tab's Download button, or from a HAR via har_transcript.py.
"""

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_DATA_DIR = Path.home() / ".local/share/com.gdaymeetings.macos.rust"
# Historical location: use it until the Rust app performs its exclusive migration.
LEGACY_DATA_DIR = Path.home() / ".local/share/org.rankun.meeting-notes"


def default_data_dir() -> Path:
    if DEFAULT_DATA_DIR.exists() or DEFAULT_DATA_DIR.is_symlink():
        return DEFAULT_DATA_DIR
    if LEGACY_DATA_DIR.is_dir():
        return LEGACY_DATA_DIR
    return DEFAULT_DATA_DIR

# Teams "(SP)" and similar vendor/affiliation suffixes are not part of the name.
SUFFIX_RE = re.compile(r"\s*\((?:SP|EXT|Contractor|Guest)\)\s*$", re.IGNORECASE)


# ── Session identity ──

BASE36 = "0123456789abcdefghijklmnopqrstuvwxyz"


def base36(n: int) -> str:
    """Match the daemon's session-id scheme: base36 of nanos since the epoch."""
    out = ""
    while n:
        out = BASE36[n % 36] + out
        n //= 36
    return out or "0"


def session_id_for(started: datetime) -> str:
    return base36(int(started.timestamp() * 1_000_000_000))


def parse_time(value: str) -> datetime:
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def rfc3339(dt: datetime) -> str:
    """The daemon writes chrono's UTC format: microseconds + trailing Z."""
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"


def offset_to_seconds(offset: str) -> float:
    h, m, s = offset.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


# ── Speaker mapping ──

def name_tokens(display_name: str) -> set:
    """Comparable name parts. 'Lee, Alex' and 'Alex Lee' both -> {lee, alex}."""
    cleaned = SUFFIX_RE.sub("", display_name)
    return {t.lower() for t in re.split(r"[,\s]+", cleaned) if t}


def readable_name(display_name: str) -> str:
    """'Park, Jordan (SP)' -> 'Jordan Park'."""
    cleaned = SUFFIX_RE.sub("", display_name).strip()
    if "," in cleaned:
        surname, given = cleaned.split(",", 1)
        return f"{given.strip()} {surname.strip()}".strip()
    return cleaned


def load_people(data_dir: Path) -> list:
    people = []
    people_dir = data_dir / "people"
    for profile in sorted(people_dir.glob("*/profile.json")):
        try:
            people.append(json.loads(profile.read_text()))
        except (OSError, json.JSONDecodeError) as e:
            print(f"  warning: skipping {profile}: {e}", file=sys.stderr)
    return people


def match_person(display_name: str, people: list, overrides: dict):
    """Resolve a Teams speaker to (person_id, name). person_id is None if unknown."""
    if display_name in overrides:
        pid = overrides[display_name]
        for p in people:
            if p["id"] == pid:
                return p["id"], p["name"]
        raise SystemExit(f"--map target not found in People library: {pid}")

    tokens = name_tokens(display_name)
    for p in people:
        # A person matches when their whole display name appears in the Teams
        # name: "Alex" ⊂ {lee, alex}, "Jordan Park" ⊂ {park, jordan}. Requiring
        # containment rather than overlap keeps "Sam Kim" off "Kim, Robin".
        p_tokens = name_tokens(p["name"])
        if p_tokens and p_tokens <= tokens:
            return p["id"], p["name"]
    return None, readable_name(display_name)


# ── Conversion ──

def build_transcript(doc: dict, people: list, overrides: dict, language: str):
    """Convert a Stream transcript into the app's transcript.json shape."""
    speakers = {}   # teams display name -> synthetic speaker id
    resolved = {}   # synthetic speaker id -> (person_id, name, teams name)
    segments = []

    for entry in doc["entries"]:
        teams_name = entry.get("speakerDisplayName") or "Unknown"
        if teams_name not in speakers:
            speaker_id = f"teams_SPEAKER_{len(speakers):02d}"
            speakers[teams_name] = speaker_id
            person_id, name = match_person(teams_name, people, overrides)
            resolved[speaker_id] = (person_id, name, teams_name)
        speaker_id = speakers[teams_name]
        person_id, name, _ = resolved[speaker_id]

        segments.append({
            "start": round(offset_to_seconds(entry["startOffset"]), 3),
            "end": round(offset_to_seconds(entry["endOffset"]), 3),
            "text": entry["text"],
            "speaker": speaker_id,
            "person_id": person_id,
            "person_name": name,
            # Teams' own recognition confidence, in the slot the UI reads for
            # attribution confidence. Names come from the meeting roster rather
            # than from voice matching, so this is exact, not a guess.
            "attribution_confidence": 1.0 if person_id else None,
            "source_type": "system_mix",
            "track": "teams_transcript",
            "words": [],
        })

    segments.sort(key=lambda s: s["start"])

    # speaker_embeddings has no embeddings here, but FilesDb reads it to build
    # the person -> sessions index and to count unconfirmed speakers, so every
    # speaker still needs an entry.
    speaker_embeddings = {
        speaker_id: {
            "embedding": [],
            "person_id": person_id,
            "person_name": name,
            "confidence": 1.0 if person_id else 0.0,
        }
        for speaker_id, (person_id, name, _) in resolved.items()
    }

    transcript = {
        "language": language,
        "model": "microsoft-teams",
        "segments": segments,
        "speaker_embeddings": speaker_embeddings,
    }
    return transcript, resolved


def transcript_md(transcript: dict) -> str:
    lines = []
    for seg in transcript["segments"]:
        speaker = seg.get("person_name") or seg.get("speaker") or "Unknown"
        mins, secs = divmod(int(seg["start"]), 60)
        lines.append(f"[{mins:02d}:{secs:02d}] **{speaker}**: {seg['text'].strip()}")
    return "\n".join(lines) + "\n"


def metadata_md(meta: dict) -> str:
    key_order = [
        "session_id", "name", "state", "language", "format",
        "raw_sample_rate", "created_at", "updated_at", "started_at",
        "duration_secs", "tags", "notes", "auto_stop",
    ]
    lines = ["---"]
    for key in key_order:
        val = meta.get(key)
        if val is None:
            continue
        if isinstance(val, list):
            lines.append(f"{key}:")
            lines.extend(f"  - {v}" for v in val)
        elif isinstance(val, bool):
            lines.append(f"{key}: {str(val).lower()}")
        elif isinstance(val, str):
            lines.append(f'{key}: "{val}"' if key.endswith("_at") else f"{key}: {val}")
        else:
            lines.append(f"{key}: {val}")
    lines.append("---")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("transcript", type=Path, help="Stream transcript JSON")
    ap.add_argument("--name", required=True, help="Meeting name")
    ap.add_argument("--started-at", required=True,
                    help="Meeting start, ISO 8601 (e.g. 2026-01-15T09:00:00Z)")
    ap.add_argument("--duration-secs", type=float,
                    help="Meeting duration; defaults to the last segment's end")
    ap.add_argument("--language", default="en", help="Language code (default: en)")
    ap.add_argument("--tags", default="", help="Comma-separated tags")
    ap.add_argument("--notes", help="Session notes")
    ap.add_argument("--map", action="append", default=[], metavar="TEAMS_NAME=PERSON_ID",
                    help="Force a speaker mapping; repeatable")
    ap.add_argument("--data-dir", type=Path, default=default_data_dir())
    ap.add_argument("--dry-run", action="store_true",
                    help="Report the speaker mapping without writing anything")
    args = ap.parse_args()

    overrides = {}
    for item in args.map:
        if "=" not in item:
            raise SystemExit(f"--map needs TEAMS_NAME=PERSON_ID, got: {item}")
        k, v = item.split("=", 1)
        overrides[k.strip()] = v.strip()

    doc = json.loads(args.transcript.read_text(encoding="utf-8"))
    if not doc.get("entries"):
        raise SystemExit("transcript has no entries")

    started = parse_time(args.started_at)
    session_id = session_id_for(started)
    people = load_people(args.data_dir)

    transcript, resolved = build_transcript(doc, people, overrides, args.language)

    duration = args.duration_secs
    if duration is None:
        duration = max(s["end"] for s in transcript["segments"])

    print(f"Session {session_id}  \"{args.name}\"")
    print(f"  {len(transcript['segments'])} segments, {duration / 60:.0f} min\n")
    print("  Speaker mapping:")
    for speaker_id, (person_id, name, teams_name) in sorted(resolved.items()):
        status = person_id if person_id else "UNLINKED — assign in the web UI"
        print(f"    {teams_name:<28} -> {name:<16} {status}")

    if args.dry_run:
        print("\n  (dry run — nothing written)")
        return 0

    session_dir = args.data_dir / "recordings" / session_id
    if session_dir.exists():
        raise SystemExit(f"\nsession dir already exists: {session_dir}")
    session_dir.mkdir(parents=True)

    now = datetime.now(timezone.utc)
    meta = {
        "session_id": session_id,
        "name": args.name,
        "state": "stopped",
        "language": args.language,
        # No format/mp3/opus/raw_sample_rate: those describe an encoder that
        # never ran. The daemon treats them as optional and the web UI hides
        # the Format tile for a stopped session with no audio files.
        "created_at": rfc3339(started),
        "updated_at": rfc3339(now),
        "started_at": rfc3339(started),
        "duration_secs": duration,
        # No audio, therefore no sources. The daemon reads duration_secs from
        # here because there are no files to measure.
        "sources": [],
        "audio_extraction": None,
        "tags": [t.strip() for t in args.tags.split(",") if t.strip()],
        "notes": args.notes,
        "auto_stop": False,
    }

    (session_dir / "metadata.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (session_dir / "metadata.md").write_text(metadata_md(meta), encoding="utf-8")
    (session_dir / "transcript.json").write_text(
        json.dumps(transcript, ensure_ascii=False), encoding="utf-8")
    (session_dir / "transcript.md").write_text(transcript_md(transcript), encoding="utf-8")

    print(f"\n  Wrote {session_dir}")
    print("  Restart the daemon to pick it up, then generate the AI overview.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
