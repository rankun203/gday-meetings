"""Replay private excerpts through Apple or OpenAI; retain immutable receipts."""

import argparse
import base64
import hashlib
import json
import os
import subprocess
import time
import wave
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def load_key(path):
    from dotenv import dotenv_values

    key = (
        dotenv_values(path).get("OPENAI_API_KEY")
        if path
        else os.environ.get("OPENAI_API_KEY")
    )
    if not key:
        raise ValueError("OPENAI_API_KEY is missing")
    return key


def gpt(row, output, key, pace):
    import websocket

    audio = Path(row["audio"])
    if hashlib.sha256(audio.read_bytes()).hexdigest() != row["sha256"]:
        raise ValueError("Audio fingerprint mismatch")
    with wave.open(str(audio)) as wav:
        assert (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) == (
            24000,
            1,
            2,
        )
        pcm = wav.readframes(wav.getnframes())
    config = {
        "type": "transcription",
        "audio": {
            "input": {
                "format": {"type": "audio/pcm", "rate": 24000},
                "transcription": {
                    "model": "gpt-live-transcribe",
                    "languages": ["zh", "en"]
                    if row["language"].startswith("zh")
                    else ["en"],
                    "delay": "high",
                },
                "turn_detection": None,
                "noise_reduction": None,
            }
        },
    }
    # One session per source track; fixed turns provide audio boundaries, not word timestamps.
    events, segments = [], []
    started = time.monotonic()
    ws = websocket.create_connection(
        "wss://api.openai.com/v1/realtime?intent=transcription",
        header={"Authorization": "Bearer " + key},
        timeout=120,
    )

    def receive():
        event = json.loads(ws.recv())
        # Never persist ephemeral credentials returned by a service.
        if isinstance(event.get("session"), dict):
            event["session"].pop("client_secret", None)
        events.append({"received_seconds": time.monotonic() - started, "event": event})
        if event.get("type") == "error" or event.get("type", "").endswith(".failed"):
            raise RuntimeError(
                "Transcription service rejected the request: "
                + str(event.get("error", {}).get("code", "see private receipt"))
            )
        return event

    def send(event):
        ws.send(json.dumps(event))

    try:
        receive()
        send({"type": "session.update", "session": config})
        while receive()["type"] != "session.updated":
            pass
        # Commit 20-second turns, retain session context, and reconcile by item_id.
        turn_bytes, packet_bytes = 20 * 48000, 4800
        for offset in range(0, len(pcm), turn_bytes):
            turn = pcm[offset : offset + turn_bytes]
            turn_started = time.monotonic()
            for position in range(0, len(turn), packet_bytes):
                packet = turn[position : position + packet_bytes]
                if pace > 0:
                    delay = (position + len(packet)) / 48000 / pace - (
                        time.monotonic() - turn_started
                    )
                    if delay > 0:
                        time.sleep(delay)
                send(
                    {
                        "type": "input_audio_buffer.append",
                        "audio": base64.b64encode(packet).decode(),
                    }
                )
            send({"type": "input_audio_buffer.commit"})
            committed, completed = None, {}
            while committed is None or committed not in completed:
                event = receive()
                if event["type"] == "input_audio_buffer.committed":
                    committed = event["item_id"]
                elif (
                    event["type"]
                    == "conversation.item.input_audio_transcription.completed"
                ):
                    completed[event["item_id"]] = event
            event = completed[committed]
            segments.append(
                {
                    "start": offset / 48000,
                    "end": (offset + len(turn)) / 48000,
                    "text": event["transcript"],
                    "item_id": committed,
                }
            )
    finally:
        ws.close()
        receipt = {
            "recording": row,
            "requested_session": config,
            "model": "gpt-live-transcribe",
            "pace": pace,
            "turn_seconds": 20,
            "seconds": time.monotonic() - started,
            "complete": len(segments) == (len(pcm) + 20 * 48000 - 1) // (20 * 48000),
            "segments": segments,
            "events": events,
        }
        output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2))
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("engine", choices=["apple", "gpt"])
    parser.add_argument("output", type=Path)
    parser.add_argument("--apple-binary", type=Path)
    parser.add_argument("--env-file", type=Path)
    parser.add_argument(
        "--pace",
        type=float,
        default=1,
        help="GPT audio pacing multiplier; zero sends without pacing. Not a live-latency benchmark.",
    )
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()
    key = load_key(args.env_file) if args.engine == "gpt" else None
    rows = [json.loads(x) for x in args.manifest.read_text().splitlines()]
    if args.limit:
        rows = rows[: args.limit]
    args.output.mkdir(parents=True, exist_ok=True)

    def run(row):
        output = args.output / (row["id"] + ".json")
        if output.exists():
            raise ValueError(f"Refusing to overwrite existing receipt: {row['id']}")
        if args.engine == "gpt":
            receipt = gpt(row, output, key, args.pace)
            if not receipt["complete"]:
                raise ValueError("Incomplete transcription")
        else:
            if (
                hashlib.sha256(Path(row["audio"]).read_bytes()).hexdigest()
                != row["sha256"]
            ):
                raise ValueError("Audio fingerprint mismatch")
            subprocess.run(
                [
                    str(args.apple_binary.resolve()),
                    row["audio"],
                    str(output.resolve()),
                    "zh_CN" if row["language"].startswith("zh") else "en_US",
                    "false",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            receipt = json.loads(output.read_text())
            receipt.update(recording=row, complete=True)
            output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2))
        print(f"{args.engine}: completed {row['id']}", flush=True)

    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        list(executor.map(run, rows))


if __name__ == "__main__":
    main()
