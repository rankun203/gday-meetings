#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .fixtures
# Samantha was available locally on the validation Mac. This command does not install voices.
/usr/bin/say -v Samantha -r 165 -o .fixtures/generated-speech.wav \
  --file-format=WAVE --data-format=LEF32@16000 \
  'This is a synthetic audio test. The first speaker describes a quiet morning and a short walk through a garden. We are checking whether the software can process words and pauses. The next sentence contains ordinary numbers: one, two, three, four, and five. After a brief pause, the test continues with another complete sentence. No personal information appears in this generated sample. The final sentence marks the end of the test.'
shasum -a 256 .fixtures/generated-speech.wav
