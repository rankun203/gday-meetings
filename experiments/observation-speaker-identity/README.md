# Observation identity regression evaluation

Compile a source-hashed standalone runner and score the five existing private replay documents without re-running models or modifying the meeting library:

```sh
python3 experiments/observation-speaker-identity/build.py --output tmp/observation-evaluation/candidate
python3 experiments/observation-speaker-identity/evaluate.py \
  --manifest tmp/speaker-consolidation-trusted-20261008/manifest.json \
  --runner tmp/observation-evaluation/candidate --output tmp/observation-evaluation/candidate-results
```

Pass `--baseline` to the builder and a different output path to compile the current trusted-channel policy. The candidate configuration is explicit in `Consolidate.swift`: cosine admission 0.72, runner-up margin 0.08, at most 12 matching representatives, 15 seconds maximum local continuity. These parameters are a frozen experimental starting point, not independently calibrated settings. The output includes exact configuration and clustering wall time. Build receipts bind every Swift source and binary; evaluation verifies evidence and reference receipts and records their hashes.

The scorer keeps unresolved activity under anonymous local labels and reports its duration. Random human-reviewed excerpts establish a limited accuracy view; speaker-coverage-selected excerpts are selection-biased. Saved RunPod worker references measure disagreement, not truth. Existing recordings are regression/development diagnostics and cannot establish new held-out generalization. The batch sorts samples by acoustic end, so it does not validate asynchronous causal publication or live latency. No projection coordinates enter identity decisions.

Run harness safety checks:

```sh
python3 -m unittest discover -s experiments/observation-speaker-identity -p 'test_*.py'
```

All audio, embeddings, names, raw results, and receipts remain in ignored `tmp/`. See the [worklog](../../docs/worklogs/2026-10-08-observation-speaker-identity.md) for design, acceptance, findings, and remaining work.
