import itertools
import json
import math
import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compare_reference import assignment, compare


def interval(start, end, speaker):
    return dict(start=start, end=end, speaker=speaker)


class ReferenceTests(unittest.TestCase):
    def run_cli(self, reference, segments, output):
        return subprocess.run([sys.executable, '-B',
                               str(Path(__file__).resolve().parents[1] / 'compare_reference.py'),
                               '--reference', str(reference), '--segments', str(segments),
                               '--output', str(output)], capture_output=True, text=True)

    def test_cli_output_safety_and_replay_schema(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory:
            root = Path(directory)
            reference, segments = root / 'reference.json', root / 'segments.jsonl'
            reference.write_text(json.dumps({'intervals': [interval(0, 1, 'a')],
                                            'audioDurationSeconds': 1}))
            base = dict(start_seconds=0, end_seconds=1, speaker='x', update_id=0,
                        window_end_seconds=0, window_start_seconds=0, provisional=False)
            segments.write_text(json.dumps(base) + '\n')
            originals = (reference.read_bytes(), segments.read_bytes())
            for source in (reference, segments):
                for mode in ('direct', 'symlink', 'hardlink'):
                    output = source if mode == 'direct' else root / (source.name + mode)
                    if mode == 'symlink':
                        output.symlink_to(source)
                    elif mode == 'hardlink':
                        os.link(source, output)
                    result = self.run_cli(reference, segments, output)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('must not overwrite', result.stderr)
                    self.assertEqual((reference.read_bytes(), segments.read_bytes()), originals)
            worktree = Path(__file__).resolve().parents[3]
            alias = root / 'worktree'
            alias.symlink_to(worktree, target_is_directory=True)
            for output in (worktree / 'blocked-comparison.json', alias / 'blocked-comparison.json'):
                result = self.run_cli(reference, segments, output)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('outside the worktree', result.stderr)
            output = root / 'accepted.json'
            result = self.run_cli(reference, segments, output)
            self.assertEqual(result.returncode, 0, result.stderr)
            saved = output.read_bytes()
            self.assertEqual(json.loads(saved)['comparisons'][0]['disagreement_fraction'], 0)
            self.assertNotEqual(self.run_cli(reference, segments, output).returncode, 0)
            self.assertEqual(output.read_bytes(), saved)
            for index, fields in enumerate(({'update_id': 1}, {'window_end_seconds': 1},
                                            {'update_index': 0})):
                segments.write_text(json.dumps(base | fields) + '\n')
                output = root / f'replay-{index}.json'
                result = self.run_cli(reference, segments, output)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Window replay', result.stderr)
                self.assertFalse(output.exists())
            # Nemotron full-file slots are provisional too; that flag alone
            # does not identify window replay and must remain accepted.
            segments.write_text(json.dumps(dict(start_seconds=0, end_seconds=1,
                                                speaker='slot-0', provisional=True)) + '\n')
            result = self.run_cli(reference, segments, root / 'nemotron.json')
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_permutation(self):
        ref = [interval(0, 3, 'a'), interval(3, 5, 'b')]
        hyp = [interval(0, 3, 'y'), interval(3, 5, 'x')]
        self.assertEqual(compare(ref, hyp, 5)['disagreement_fraction'], 0)

    def test_overlap_and_duplicate_intervals(self):
        ref = [interval(0, 3, 'a'), interval(1, 2, 'a'), interval(1, 2, 'b')]
        result = compare(ref, [interval(0, 3, 'x')], 3)
        self.assertEqual(result['reference_speaker_seconds'], 4)
        self.assertEqual(result['missed_speaker_seconds'], 1)
        self.assertEqual(compare(ref, [interval(0, 3, 'x')], 3, exclude_overlap=True)['disagreement_fraction'], 0)

    def test_gaps_are_unknown(self):
        result = compare([interval(1, 2, 'a')], [interval(0, 3, 'x')], 3)
        self.assertEqual(result['disagreement_fraction'], 0)
        self.assertEqual(result['hypothesis_speaker_seconds_in_unknown_gaps'], 2)

    def test_split_speaker_confusion(self):
        result = compare([interval(0, 4, 'a')], [interval(0, 2, 'x'), interval(2, 4, 'y')], 4)
        self.assertEqual(result['confused_speaker_seconds'], 2)

    def test_miss_extra_and_empty(self):
        ref = [interval(0, 4, 'a')]
        self.assertEqual(compare(ref, [], 4)['disagreement_fraction'], 1)
        self.assertIsNone(compare([], [], 4)['disagreement_fraction'])
        self.assertEqual(compare(ref, [interval(0, 4, 'x'), interval(0, 4, 'y')], 4)['extra_speaker_seconds'], 4)

    def test_collar(self):
        result = compare([interval(0, 2, 'a'), interval(2, 4, 'b')], [], 4, collar=.25)
        self.assertEqual(result['scored_wall_seconds'], 3)
        self.assertEqual(result['excluded_reference_wall_seconds'], 1)

    def test_invalid(self):
        for end in (math.nan, math.inf, -1, 6):
            with self.assertRaises(ValueError):
                compare([interval(0, end, 'a')], [], 5)

    def test_assignment_matches_brute_force(self):
        rng = random.Random(7)
        for rows in range(1, 5):
            for cols in range(1, 5):
                weights = [[rng.randrange(10) for _ in range(cols)] for _ in range(rows)]
                result = assignment(weights)
                actual = sum(weights[r][c] for r, c in result.items())
                n = max(rows, cols)
                expected = max(sum(weights[r][p[r]] for r in range(rows) if p[r] < cols)
                               for p in itertools.permutations(range(n)))
                self.assertEqual(actual, expected)

    def test_assignment_empty_ties_and_invalid_weights(self):
        self.assertEqual(assignment([]), {})
        self.assertEqual(assignment([[], []]), {})
        for weights in ([[0, 0], [0, 0]], [[.1, .4], [.3, .2]],
                        [[-1, -4], [-3, -2]]):
            result = assignment(weights)
            self.assertEqual(len(set(result.values())), len(result))
            actual = sum(weights[r][c] for r, c in result.items())
            expected = max(sum(weights[r][p[r]] for r in range(2))
                           for p in itertools.permutations(range(2)))
            self.assertAlmostEqual(actual, expected)
        for weights in ([[1], [1, 2]], [[math.nan]], [[math.inf]], [[-math.inf]]):
            with self.assertRaises(ValueError):
                assignment(weights)

    def test_rounding_tolerance_does_not_allow_start_after_audio(self):
        for start in (5, 5.0000001):
            with self.assertRaises(ValueError):
                compare([interval(start, 5.0000005, 'a')], [], 5)
        result = compare([interval(4, 5.0000005, 'a')], [], 5)
        self.assertEqual(result['reference_speaker_seconds'], 1)

    def test_abutting_events_and_duplicate_hypotheses(self):
        result = compare([interval(0, 1, 'a'), interval(1, 2, 'b')],
                         [interval(0, 1, 'x'), interval(.5, 1, 'x'),
                          interval(1, 2, 'y')], 2)
        self.assertEqual(result['disagreement_fraction'], 0)
        self.assertEqual(result['reference_speaker_seconds'], 2)

    def test_collars_union_and_original_segment_boundaries(self):
        result = compare([interval(0, 1, 'a'), interval(1, 2, 'a')], [], 2, collar=.25)
        self.assertEqual(result['scored_wall_seconds'], 1)
        self.assertEqual(result['excluded_reference_wall_seconds'], 1)
        result = compare([interval(0, 1, 'a'), interval(.1, .9, 'b')], [], 1, collar=.6)
        self.assertIsNone(result['disagreement_fraction'])
        self.assertEqual(result['excluded_reference_wall_seconds'], 1)
        self.assertEqual(result['mapping'], {})

    def test_mapping_ignores_excluded_overlap_and_unknown_gaps(self):
        ref = [interval(0, 10, 'a'), interval(0, 9, 'b')]
        hyp = [interval(0, 9, 'x'), interval(9, 10, 'y'), interval(10, 20, 'z')]
        result = compare(ref, hyp, 20, exclude_overlap=True)
        self.assertEqual(result['mapping'], {'y': 'a'})
        self.assertEqual(result['excluded_reference_wall_seconds'], 9)
        self.assertEqual(result['hypothesis_speaker_seconds_in_unknown_gaps'], 10)
        self.assertEqual(result['disagreement_fraction'], 0)

    def test_gap_activity_is_separate_even_inside_collars(self):
        result = compare([interval(1, 2, 'a')], [interval(0, 3, 'x')], 3, collar=.25)
        self.assertEqual(result['hypothesis_speaker_seconds_in_unknown_gaps'], 2)
        self.assertEqual(result['scored_wall_seconds'], .5)
        self.assertEqual(result['disagreement_fraction'], 0)

    def test_error_fraction_can_exceed_one(self):
        result = compare([interval(0, 1, 'a')],
                         [interval(0, 1, name) for name in ('x', 'y', 'z')], 1)
        self.assertEqual(result['disagreement_fraction'], 2)

    def test_sweep_matches_independent_grid_and_exhaustive_mapping(self):
        # All event boundaries lie on the quarter-second grid, so midpoint
        # integration here is exact and independent of the production sweep.
        rng = random.Random(23)
        for _ in range(100):
            streams = []
            for labels in (('a', 'b', 'c'), ('x', 'y', 'z')):
                items = []
                for _ in range(rng.randrange(8)):
                    start, end = sorted(rng.sample(range(5), 2))
                    items.append(interval(start, end, rng.choice(labels)))
                streams.append(items)
            reference, hypothesis = streams
            for collar, exclude in itertools.product((0, .25), (False, True)):
                pieces, unknown, excluded = [], 0, 0
                for tick in range(16):
                    midpoint = (tick + .5) / 4
                    rs, hs = ({i['speaker'] for i in items
                               if i['start'] <= midpoint < i['end']} for items in streams)
                    in_collar = any(abs(midpoint - i[boundary]) < collar
                                    for i in reference for boundary in ('start', 'end'))
                    if not rs:
                        unknown += .25 * len(hs)
                    elif in_collar or (exclude and len(rs) > 1):
                        excluded += .25
                    else:
                        pieces.append((rs, hs))
                # Include absent labels as zero-weight dummy choices.
                correct = max(sum(.25 * len(rs & {dict(zip(('x', 'y', 'z'), permutation))[h]
                                                  for h in hs}) for rs, hs in pieces)
                              for permutation in itertools.permutations(('a', 'b', 'c')))
                denominator = sum(.25 * len(rs) for rs, _ in pieces)
                missed = sum(.25 * max(0, len(rs) - len(hs)) for rs, hs in pieces)
                extra = sum(.25 * max(0, len(hs) - len(rs)) for rs, hs in pieces)
                confused = sum(.25 * min(len(rs), len(hs)) for rs, hs in pieces) - correct
                result = compare(reference, hypothesis, 4, collar, exclude)
                for key, expected in (
                        ('scored_wall_seconds', .25 * len(pieces)),
                        ('reference_speaker_seconds', denominator),
                        ('excluded_reference_wall_seconds', excluded),
                        ('hypothesis_speaker_seconds_in_unknown_gaps', unknown),
                        ('missed_speaker_seconds', missed), ('extra_speaker_seconds', extra),
                        ('confused_speaker_seconds', confused)):
                    self.assertAlmostEqual(result[key], expected, msg=key)
                if denominator:
                    self.assertAlmostEqual(result['disagreement_fraction'],
                                           (missed + extra + confused) / denominator)
                else:
                    self.assertIsNone(result['disagreement_fraction'])


if __name__ == '__main__':
    unittest.main()
