"""Generate a deterministic ASR/retrieval pilot; scripts are intended speech, not human gold."""

import argparse
import hashlib
import json
import subprocess
import wave
from pathlib import Path

import numpy as np

THEMES = [
    ("garden workshop", "园艺讲座"),
    ("museum tour", "博物馆导览"),
    ("science fair", "科学展览"),
    ("theatre rehearsal", "戏剧排练"),
    ("camping trip", "露营活动"),
    ("pottery class", "陶艺课程"),
]


def write_audio(path, data):
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(16000)
        f.writeframes((np.clip(data, -1, 1) * 32767).astype("<i2").tobytes())


def read_audio(path):
    with wave.open(str(path), "rb") as f:
        assert f.getframerate() == 16000 and f.getnchannels() == 1
        return (
            np.frombuffer(f.readframes(f.getnframes()), "<i2").astype(np.float32)
            / 32768
        )


def write_jsonl(path, rows):
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("output", type=Path)
    ap.add_argument(
        "--resume",
        action="store_true",
        help="Reuse unchanged synthesized utterances; regenerate manifests and mixtures.",
    )
    a = ap.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    if any(a.output.iterdir()) and not a.resume:
        raise ValueError("Choose an empty output directory or use --resume")
    records = []
    windows = []
    queries = []
    rng = np.random.default_rng(42)
    for i, (en, zh) in enumerate(THEMES):
        for lang in ["en", "zh"]:
            sid = f"s{i:02d}-{lang}"
            voice = "Samantha" if lang == "en" else "Tingting"
            number = 15 + i * 7 if i < 5 else 49
            assert number != 50, "Approved and rejected budgets must differ"
            text = (
                [
                    f"This meeting concerns the {en}. We need to confirm the arrangements.",
                    f"The initial proposal is to hold the {en} on Tuesday.",
                    f"Correction: the {en} will take place on Friday, not Tuesday. Friday is the final decision.",
                    f"The approved materials budget for the {en} is {number} hundred dollars. It is not fifty hundred dollars.",
                    f"Who will arrange transport for the {en}? We have not chosen anyone yet.",
                    f"The catering discussion is postponed. No food supplier has been selected for the {en}.",
                ]
                if lang == "en"
                else [
                    f"这次会议讨论{zh}。我们需要确认具体安排。",
                    f"最初的建议是星期二举办{zh}。",
                    f"更正一下，{zh}定在星期五，不是星期二。最终决定是星期五。",
                    f"{zh}批准的材料预算是{number * 100}元，不是五千元。",
                    f"谁来安排{zh}的交通？目前还没有确定负责人。",
                    f"餐饮问题以后再讨论。{zh}还没有选定食品供应商。",
                ]
            )
            chunks = []
            bounds = []
            cursor = 0
            for j, t in enumerate(text):
                stem = a.output / f"{sid}-{j}"
                txt = stem.with_suffix(".txt")
                cached = (
                    a.resume
                    and txt.exists()
                    and txt.read_text() == t
                    and stem.with_suffix(".wav").exists()
                )
                if not cached:
                    pending_text = stem.with_suffix(".pending.txt")
                    pending_text.write_text(t)
                    subprocess.run(
                        [
                            "say",
                            "-v",
                            voice,
                            "-r",
                            "175",
                            "-f",
                            str(pending_text),
                            "-o",
                            str(stem.with_suffix(".aiff")),
                        ],
                        check=True,
                    )
                    subprocess.run(
                        [
                            "ffmpeg",
                            "-v",
                            "error",
                            "-y",
                            "-i",
                            str(stem.with_suffix(".aiff")),
                            "-ar",
                            "16000",
                            "-ac",
                            "1",
                            str(stem.with_suffix(".pending.wav")),
                        ],
                        check=True,
                    )
                    pending_audio = stem.with_suffix(".pending.wav")
                    pending_data = read_audio(pending_audio)
                    if (
                        len(pending_data) < 4800
                        or float(np.sqrt(np.mean(pending_data**2))) < 0.0001
                    ):
                        raise ValueError(
                            "Speech synthesis produced missing or silent audio"
                        )
                    pending_audio.replace(stem.with_suffix(".wav"))
                    pending_text.replace(txt)
                data = read_audio(stem.with_suffix(".wav"))
                if len(data) < 4800 or float(np.sqrt(np.mean(data**2))) < 0.0001:
                    raise ValueError(
                        "Speech synthesis produced missing or silent audio; check local speech-service access"
                    )
                padding = np.zeros(8000, dtype=np.float32)
                bounds.append((cursor / 16000, (cursor + len(data)) / 16000))
                chunks.extend([data, padding])
                cursor += len(data) + len(padding)
            clean = np.concatenate(chunks)
            noise = rng.standard_normal(len(clean))
            scale = np.sqrt(np.mean(clean**2)) / 10 ** (10 / 20)
            noisy = clean + noise * scale
            peak = np.max(np.abs(noisy))
            noisy = noisy / max(1, peak / 0.98)
            for condition, data in [("clean", clean), ("noise10db", noisy)]:
                rid = f"{sid}-{condition}"
                path = a.output / f"{rid}.wav"
                write_audio(path, data)
                records.append(
                    {
                        "recording_id": rid,
                        "scenario_id": sid,
                        "template_family": f"theme{i}",
                        "language": lang,
                        "condition": condition,
                        "audio_path": str(path.resolve()),
                        "voice": voice,
                        "duration_seconds": len(data) / 16000,
                        "audio_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "reference_kind": "intended TTS script",
                    }
                )
                for j, ((start, end), t) in enumerate(zip(bounds, text)):
                    windows.append(
                        {
                            "segment_id": f"{sid}-w{j}",
                            "recording_id": rid,
                            "scenario_id": sid,
                            "language": lang,
                            "condition": condition,
                            "start": start,
                            "end": end,
                            "reference": t,
                        }
                    )
            qs = [
                (
                    f"On which day is the {en} finally scheduled?",
                    f"{zh}最后决定在哪一天举办？",
                    2,
                    "correction",
                ),
                (
                    f"What materials budget was approved for the {en}?",
                    f"{zh}批准的材料预算是多少？",
                    3,
                    "number",
                ),
                (
                    f"Which company was selected to supply food for the {en}?",
                    f"{zh}选定了哪家食品供应商？",
                    None,
                    "unanswerable",
                ),
            ]
            for j, (eq, zq, pos, kind) in enumerate(qs):
                for qlang, q in [("en", eq), ("zh", zq)]:
                    queries.append(
                        {
                            "query_id": f"{sid}-q{j}-{qlang}",
                            "scenario_id": sid,
                            "query": q,
                            "language": qlang,
                            "kind": kind,
                            "cross_language": qlang != lang,
                            "positives": [] if pos is None else [f"{sid}-w{pos}"],
                        }
                    )
    write_jsonl(a.output / "recordings.jsonl", records)
    write_jsonl(a.output / "windows.jsonl", windows)
    write_jsonl(a.output / "queries.jsonl", queries)
    (a.output / "manifest.json").write_text(
        json.dumps(
            {
                "seed": 42,
                "scenarios": 12,
                "template_families": 6,
                "conditions": ["clean", "noise10db"],
                "limitations": [
                    "Templated pilot; not independent held-out meetings",
                    "TTS scripts are not audio-verified gold",
                    "Paired noise is global RMS 10 dB, not active-speech SNR",
                    "One system voice per language",
                ],
                "generator_sha256": hashlib.sha256(
                    Path(__file__).read_bytes()
                ).hexdigest(),
            },
            indent=2,
        )
        + "\n"
    )
    print(
        json.dumps(
            {
                "recordings": len(records),
                "windows": len(windows),
                "queries": len(queries),
            }
        )
    )


if __name__ == "__main__":
    main()
