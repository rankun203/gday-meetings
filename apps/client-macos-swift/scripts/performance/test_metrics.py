"""Synthetic checks for measurement semantics, not application performance."""

import json
import tempfile
import unittest
from pathlib import Path

from analyze import load_runs, percentile
from trace_metrics import union_seconds, xml_rows


class MetricsTests(unittest.TestCase):
    def test_interval_union_clips_and_does_not_double_count(self):
        self.assertAlmostEqual(union_seconds([(-1, 2), (1, 4), (8, 14)], 10), 6)
        self.assertEqual(union_seconds([], 10), 0)

    def test_missing_table_is_not_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "missing.xml"
            path.write_text("<trace-query-result/>")
            with self.assertRaises(ValueError):
                list(xml_rows(path, "metal-gpu-intervals"))

    def test_reference_resolution_and_schema_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "values.xml"
            path.write_text(
                '<root><schema name="sample"><col><mnemonic>value</mnemonic></col></schema>'
                '<row><number id="1">7</number></row><row><number ref="1"/></row></root>'
            )
            self.assertEqual(
                [r["value"]["text"] for r in xml_rows(path, "sample")], ["7", "7"]
            )
            with self.assertRaises(ValueError):
                list(xml_rows(path, "wrong-schema"))

    def test_percentile_interpolates(self):
        self.assertEqual(percentile([10, 20], 0.95), 19.5)
        self.assertIsNone(percentile([], 0.5))

    def test_guard_stop_is_not_completed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "metrics.jsonl"
            row = {
                "schema_version": 1,
                "run_id": "synthetic",
                "event": "end",
                "phase": "safety_stop",
                "task": "summary",
                "mode": "visible",
                "pid": 123,
                "elapsed_s": 2,
                "process_cpu_ns": 1000000000,
                "main_cpu_ns": 500000000,
                "initial_payload_utf8_bytes": 100,
                "actual_payload_utf8_bytes": 101,
                "lines": 1,
                "delivery_count": 1,
                "physical_footprint_bytes": 1024,
            }
            path.write_text(json.dumps(row) + "\n")
            result = load_runs([path])[0]["summary"]
            self.assertFalse(result["completed"])
            self.assertIsNone(result["devices"])
            self.assertEqual(result["mean_main_cpu_pct"], 25)
            self.assertEqual(result["achieved_hz"], 0.5)
            row["phase"] = "complete"
            path.write_text(json.dumps(row) + "\n")
            self.assertTrue(load_runs([path])[0]["summary"]["completed"])
            (path.parent / "instruments").mkdir()
            (path.parent / "result.json").write_text(json.dumps({"completed": False}))
            failed = load_runs([path])[0]["summary"]
            self.assertFalse(failed["completed"])
            self.assertTrue(failed["profiled"])
            self.assertIsNone(failed["devices"])


if __name__ == "__main__":
    unittest.main()
