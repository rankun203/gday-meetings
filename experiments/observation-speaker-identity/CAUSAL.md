# Recorded callback replay

This driver runs the production `SpeakerObservationClustering` reducer in callback order. It does not publish into a meeting or claim a complete live diarization timeline.

```sh
python3 experiments/observation-speaker-identity/build.py --causal --output tmp/observation-causal/replay
python3 experiments/observation-speaker-identity/replay.py \
  --evidence tmp/recorded-run/evidence.json \
  --trace tmp/recorded-run/availability.json \
  --binary tmp/observation-causal/replay \
  --output tmp/observation-causal/results
python3 -m unittest discover -s experiments/observation-speaker-identity -p test_replay.py
```

The availability adapter is shared with the existing audited replay tooling. It processes `embeddingReady` and `speakerEvent` callbacks in their recorded order. An embedding waits until observed window metadata covers its interval; only metadata already received can admit it. Final evidence is used to validate trace integrity, not to filter earlier decisions using future capacity reports. When multiple pending samples become eligible in one callback, their embedding-ready callback order is preserved. The Swift reducer receives no final windows or future activity.

Outputs record each sample's embedding-ready clock, admission clock, callback ordinal and assigned anonymous cluster (or unresolved). The clock is the recording harness's submitted-audio upper bound, **not wall-clock extraction latency**. Original recording experiments awaited extraction, so their available sample coverage need not match production asynchronous capture.

The driver compares independent prefix runs at zero, one, halfway and all observations. Swift tests additionally exercise out-of-order acoustic times, changed future suffixes, and ten anonymous voices without People profiles. Python tests verify continuity waiting, no retroactive final-window filtering, same-callback ordering and rejection of availability before audio exists.

## 2026-10-08 result

Using original traces in `tmp/speaker-consolidation-causal-trace-20261008`, the uncalibrated default reducer produced:

| Recording | Admitted embeddings | Anonymous clusters | Ambiguous assignments |
|---|---:|---:|---:|
| sample-D | 113 | 63 | 48 |
| sample-J | 82 | 71 | 7 |

Both passed deterministic prefix checks. Fragmentation is substantial; these are diagnostics, not evidence supporting live activation. Sample assignments alone do not establish DER, naming accuracy or timeline coverage. The private source-hashed build receipt and results are under `tmp/observation-causal-20261008` (`replay-verified.build.json` and each recording's `summary.json`). The earlier unsuffixed binary failed a concurrent-source-change check and was not used.
