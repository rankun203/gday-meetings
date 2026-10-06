"""Generate generic query-length probes using the installed Granite tokenizer."""

import argparse
import json
from pathlib import Path

from tokenizers import Tokenizer

p = argparse.ArgumentParser()
p.add_argument("--tokenizer", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
tokenizer = Tokenizer.from_file(str(a.tokenizer))
tokenizer.no_truncation()
tokenizer.no_padding()
seeds = [
    "What are the next steps for the release plan and testing schedule?",
    "Summarize the discussion about customer feedback and product quality.",
    "What decisions were made about the project timeline and budget?",
    "Describe the proposed changes to documentation and onboarding.",
]
for length in [8, 32, 64, 96, 128, 256, 512]:
    shape = 128 if length <= 128 else 512
    probes = []
    for sentence in seeds:
        # Truncate a generic repeated sentence token stream, keeping BOS/EOS.
        tokens = tokenizer.encode((sentence + " ") * 100).ids
        ids = [tokens[0]] + tokens[1 : length - 1] + [tokens[-1]]
        probes.append(
            {
                "ids": ids + [tokenizer.token_to_id("<|endoftext|>")] * (shape - length),
                "mask": [1] * length + [0] * (shape - length),
            }
        )
    (a.output / f"length-{length}.json").write_text(json.dumps(probes))
