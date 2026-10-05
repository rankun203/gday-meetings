#!/usr/bin/env -S uv run --no-project --with torch==2.8.0 --with torchaudio==2.8.0 --with transformers==4.57.3 --python 3.12 python
"""Regenerate synthetic CLSP preprocessing goldens; tokenizer assets stay local."""

import argparse
import json
import pathlib

parser = argparse.ArgumentParser()
parser.add_argument("--tokenizer-directory", type=pathlib.Path, required=True)
args = parser.parse_args()
import torch
import torchaudio
from transformers import RobertaTokenizer

root = (
    pathlib.Path(__file__).resolve().parents[1]
    / "Tests/GdayMeetingsTests/Fixtures/CLSP"
)
torch.set_num_threads(1)
cases = []
for name, n in [("silence", 4000), ("impulse", 4167), ("mixed", 4321)]:
    t = torch.arange(n, dtype=torch.float32)
    if name == "silence":
        x = torch.zeros(n)
    elif name == "impulse":
        x = torch.zeros(n)
        x[0] = 1
        x[159] = -0.5
        x[-1] = 0.75
    else:
        x = (
            0.2 * torch.sin(t * 0.071)
            + 0.1 * torch.cos(t * 0.123)
            + ((t % 17) - 8) * 0.001
            + 0.03
        )
    y = torchaudio.compliance.kaldi.fbank(
        x[None],
        sample_frequency=16000,
        num_mel_bins=128,
        low_freq=20,
        high_freq=-400,
        dither=0,
        snip_edges=False,
        energy_floor=1e-10,
    )
    cases.append(
        dict(
            name=name,
            input=x.tolist(),
            expected=y.flatten().tolist(),
            frames=y.shape[0],
        )
    )
resamples = []
for rate in [8000, 22050, 44100, 48000]:
    t = torch.arange(rate // 4 + 7, dtype=torch.float32)
    x = 0.2 * torch.sin(t * 0.071) + 0.1 * torch.cos(t * 0.123) + ((t % 17) - 8) * 0.001
    y = torchaudio.functional.resample(x, rate, 16000)
    resamples.append(dict(rate=rate, input=x.tolist(), expected=y.tolist()))
tokenizer = RobertaTokenizer.from_pretrained(
    args.tokenizer_directory, local_files_only=True
)
texts = [
    "A calm, low-pitched voice.",
    "  Voice\nwith pauses.",
    "声音平静，语速缓慢。",
    "Voice 🙂 café <mask>",
    "<s> literal </s>",
    " ".join(["voice"] * 600),
]
texts += [
    "can't don't we're I'M",
    "\t  voice\r\n pause  ",
    "café cafe\u0301 naïve",
    "日本語 한국어 العربية עברית",
    "👩🏽‍💻 voice 🚀",
    "<mask>hello",
    "hello<mask> there",
    "<pad> <unk> <s> </s>",
    "word <s> phrase </s> word",
    "a" * 4096,
]
tokens = [dict(text=t, ids=tokenizer(t, truncation=True)["input_ids"]) for t in texts]
(root / "golden.json").write_text(
    json.dumps(
        dict(
            source="torchaudio 2.8.0 / transformers 4.57.3",
            fbank=cases,
            resample=resamples,
            tokens=tokens,
        ),
        separators=(",", ":"),
    )
    + "\n"
)
