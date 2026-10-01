"""Plan benchmark runs; launch only when requested, preserving historical results."""
import argparse
import json
from pathlib import Path
import time

import run_private


def historical_successes(plan):
    """Different or absent fingerprints are historical, never cache hits."""
    config = plan["config"]
    records = list(plan["output"].glob("*.run.json")) + list(plan["output"].glob("*/run.json"))
    historical = []
    for path in sorted(records):
        try:
            value = json.loads(path.read_text())
            prior = value.get("config", value)
            if (value.get("returncode") == 0 and
                    all(prior.get(key) == config[key] for key in ("sample", "model", "mode", "paced")) and
                    value.get("fingerprint") != plan["fingerprint"]):
                historical.append(str(path))
        except (OSError, ValueError, TypeError):
            continue
    return historical


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--execute", action="store_true", help="Launch planned runs; the default only prints the plan")
    parser.add_argument("--rerun-historical", action="store_true",
                        help="Allow new runs when successful historical results have a different or absent fingerprint")
    args = parser.parse_args()
    failures, historical_jobs = [], []
    # Nemotron saved-file mode already exercises chronological 20 ms native replay.
    jobs = [("offline", False, sample, model)
            for sample in "CABD" for model in ["community1", "nemotron"]]
    jobs += [("replay", False, sample, "community1") for sample in "CABD"]
    jobs += [("replay", True, sample, model)
             for sample in "CD" for model in ["community1", "nemotron"]]
    for mode, paced, sample, model in jobs:
        options = ["--manifest", str(args.manifest), "--output-directory", str(args.output_directory),
                   "--sample", sample, "--model", model, "--mode", mode, "--wall-limit-seconds", "900"]
        if paced:
            options += ["--paced", "--max-seconds", "60"]
        private_args = run_private.parser().parse_args(options)
        plan = run_private.prepare(private_args)
        match = run_private.successful_match(plan)
        historical = historical_successes(plan)
        status = ("reused_exact_match" if match else
                  "historical_different_fingerprint" if historical else "pending")
        print(json.dumps({"name": plan["name"], "status": status,
                          "exact_record": str(match) if match else None,
                          "historical_records": historical}), flush=True)
        if match:
            continue
        if historical and not args.rerun_historical:
            historical_jobs.append(plan["name"])
            continue
        if not args.execute:
            continue
        start = time.monotonic()
        code = run_private.execute(plan, private_args)
        print(json.dumps({"name": plan["name"], "exit": code,
                          "seconds": time.monotonic() - start}), flush=True)
        if code:
            failures.append(plan["name"])
        if code in (129, 130, 143):
            break  # Cancellation must not launch the next benchmark.
    print(json.dumps({"failed_runs": failures, "historical_runs_not_repeated": historical_jobs,
                      "execution_requested": args.execute}), flush=True)
    return int(bool(failures or (args.execute and historical_jobs)))


if __name__ == "__main__":
    raise SystemExit(main())
