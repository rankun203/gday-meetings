#!/usr/bin/env -S uv run --no-project --with wordfreq==3.1.1 python
"""Regenerate the bundled dictionary from pinned wordfreq data, without a model."""
import json
from pathlib import Path

from wordfreq import get_frequency_dict

words = {
    language: sorted(
        word
        for word, frequency in get_frequency_dict(language).items()
        if frequency >= 1e-5  # Zipf = log10(frequency) + 9, so this is Zipf >= 4.
        and word.isalpha()
        and (
            word.isascii()
            if language == "en"
            else all("\u3400" <= character <= "\u9fff" for character in word)
        )
    )
    for language in ("en", "zh")
}
target = Path(__file__).resolve().parents[1] / "Sources/GdayMeetings/Resources/frequent-words.json"
target.write_text(
    json.dumps(
        {"source": "wordfreq 3.1.1", "zipfThreshold": 4, "license": "CC-BY-SA-4.0", "words": words},
        ensure_ascii=False,
        separators=(",", ":"),
    ) + "\n",
    encoding="utf-8",
)
print(f"Wrote {sum(map(len, words.values())):,} words ({target.stat().st_size:,} bytes).")
