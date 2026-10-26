"""Synthetic coverage and lifecycle checks for full-recording speech detection."""
import unittest
from full_speech import CONFIG, FRAME, RATE, embedding_windows, speech_segments, coverage_samples


class FullSpeechTests(unittest.TestCase):
    def test_hysteresis_keeps_short_speech(self):
        probabilities = [0, .8, .2, .2, .2, .2, .2, 0]
        segments = speech_segments(probabilities, len(probabilities) * FRAME)
        self.assertEqual(segments, [dict(start_sample=FRAME, end_sample=2 * FRAME)])

    def test_end_of_recording_retains_speech(self):
        self.assertEqual(speech_segments([0, .8, .8], 1100),
                         [dict(start_sample=512, end_sample=1100)])

    def test_hysteresis_ignores_brief_pause(self):
        segments = speech_segments([.8, .2, .2, .8, .8], 2500)
        self.assertEqual(segments, [dict(start_sample=0, end_sample=2500)])

    def test_silence_empty(self):
        self.assertEqual(speech_segments([0] * 10, 5120), [])
        self.assertEqual(embedding_windows([], 5120), [])

    def test_nonfinite_failure(self):
        with self.assertRaises(ValueError):
            speech_segments([float('nan')], FRAME)

    def test_long_segments_disjoint_complete_and_supported(self):
        for duration in (2, 4.999, 5, 5.001, 6, 10, 10.001, 51.01):
            end = int(duration * RATE)
            segments = [dict(start_sample=0, end_sample=end)]
            windows = embedding_windows(segments, end)
            self.assertEqual(coverage_samples(segments, windows), end)
            self.assertEqual(sum(w['end_sample'] - w['start_sample'] for w in windows), end)
            self.assertTrue(all(2 * RATE <= w['end_sample'] - w['start_sample'] <= 5 * RATE for w in windows))
            self.assertTrue(all(a['end_sample'] == b['start_sample'] for a, b in zip(windows, windows[1:])))
            self.assertTrue(all(w['overlap_with_previous_window_samples'] == 0 for w in windows))

    def test_short_speech_padding_at_both_edges(self):
        for start, end in ((0, 500), (159500, 160000), (79500, 80000)):
            segments = [dict(start_sample=start, end_sample=end)]
            windows = embedding_windows(segments, 160000)
            self.assertEqual(coverage_samples(segments, windows), end - start)
            window = windows[0]
            self.assertEqual(window['end_sample'] - window['start_sample'], 2 * RATE)
            self.assertEqual(window['speech_start_sample'], start)
            self.assertTrue(window['potential_mixed_speakers'])
            self.assertEqual(window['status'], 'short_speech_context_padded')

    def test_short_recording_reports_model_limit(self):
        segments = [dict(start_sample=0, end_sample=1000)]
        windows = embedding_windows(segments, 1000)
        self.assertEqual(windows[0]['status'], 'recording_shorter_than_model_minimum')
        self.assertEqual(coverage_samples(segments, windows), 1000)

    def test_padding_overlap_explicit_and_coverage_counts_once(self):
        segments = [dict(start_sample=40000, end_sample=41000),
                    dict(start_sample=42000, end_sample=43000)]
        windows = embedding_windows(segments, 160000)
        self.assertGreater(windows[1]['overlap_with_previous_window_samples'], 0)
        self.assertEqual(coverage_samples(segments, windows), 2000)

    def test_invalid_intervals_fail(self):
        with self.assertRaises(ValueError):
            embedding_windows([dict(start_sample=10, end_sample=5)], 1000)


if __name__ == '__main__':
    unittest.main()
