"""Negative controls ensure the scaling gate catches growing work, not just saturation."""

import json
import tempfile
import unittest
from pathlib import Path

from scaling import growth, metrics


class ScalingContractTests(unittest.TestCase):
    def test_deferred_cpu_is_included_in_equal_work_cost(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "metrics.jsonl"
            base = {
                "schema_version": 1,
                "run_id": "synthetic",
                "task": "notes",
                "mode": "component-append",
                "pid": 123,
                "initial_payload_utf8_bytes": 100,
                "actual_payload_utf8_bytes": 101,
                "lines": 1,
                "delivery_count": 1,
                "disk_write_bytes": 4096,
                "physical_footprint_bytes": 140,
            }
            rows = [
                {
                    **base,
                    "event": "begin",
                    "phase": "typing",
                    "elapsed_s": 0,
                    "process_cpu_ns": 0,
                    "main_cpu_ns": 0,
                    "physical_footprint_bytes": 100,
                },
                {**base, "event": "action", "elapsed_s": 0.1, "action_duration_s": 0.2},
                {
                    **base,
                    "event": "phase",
                    "phase": "hold",
                    "elapsed_s": 1,
                    "process_cpu_ns": 1000000000,
                    "main_cpu_ns": 500000000,
                },
                {
                    **base,
                    "event": "end",
                    "phase": "finished",
                    "elapsed_s": 6,
                    "process_cpu_ns": 3000000000,
                    "main_cpu_ns": 2000000000,
                },
            ]
            path.write_text("\n".join(json.dumps(row) for row in rows))
            result = metrics(path, 1)
            self.assertEqual(result["main_cpu_ms_per_operation"], 2000)
            self.assertEqual(result["process_cpu_ms_per_operation"], 3000)
            self.assertEqual(result["incremental_peak_footprint_bytes"], 40)
            with self.assertRaises(ValueError):
                metrics(path, 2)

    def test_constant_work_passes_on_fast_and_slow_devices(self):
        for speed in [0.01, 1, 100]:
            self.assertEqual(
                growth(
                    [speed * x for x in [9, 10, 11]],
                    [speed * x for x in [10, 11, 12]],
                    2,
                )["status"],
                "pass",
            )

    def test_linear_and_quadratic_costs_fail(self):
        for factor in [10, 100]:
            self.assertEqual(
                growth([9, 10, 11], [factor * x for x in [9, 10, 11]], 2)["status"],
                "fail",
            )

    def test_saturated_cpu_still_fails_when_cost_per_operation_grows(self):
        # Both windows used 100% of a core, but the larger payload completed ten times fewer actions.
        self.assertEqual(growth([1000 / 100] * 3, [1000 / 10] * 3, 2)["status"], "fail")

    def test_noise_missing_repeats_and_counter_resolution_are_inconclusive(self):
        for small, large in [
            ([1, 10, 100], [1, 20, 100]),
            ([1, 1], [1, 1]),
            ([0, 0, 0], [1, 1, 1]),
            ([None] * 3, [1] * 3),
        ]:
            self.assertEqual(growth(small, large, 2)["status"], "inconclusive")
        self.assertEqual(growth([0] * 3, [0] * 3, 2)["status"], "inconclusive")
        self.assertEqual(
            growth([0] * 3, [0] * 3, 2, zero_is_valid=True)["status"], "pass"
        )


if __name__ == "__main__":
    unittest.main()
