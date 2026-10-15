"""Synthetic input validation; no credentials, audio conversion, or network."""
import copy
import unittest

from run import validate_manifest


def fixture():
    return {'context': 'Example vocabulary', 'clips': [
        {'id': 'clip-1', 'audio': '/example/audio.wav', 'start': 0, 'end': 10, 'original': 'Example text'}]}


class ManifestTests(unittest.TestCase):
    def test_valid_bounded_clips(self):
        self.assertEqual(len(validate_manifest(fixture())), 1)

    def test_paths_and_duplicate_identifiers_are_rejected(self):
        for identifier in ['../outside', '/outside', '.', '', 'a/b', 'a\\b']:
            data = fixture()
            data['clips'][0]['id'] = identifier
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                validate_manifest(data)
        data = fixture()
        data['clips'].append(copy.deepcopy(data['clips'][0]))
        with self.assertRaises(ValueError):
            validate_manifest(data)

    def test_invalid_timing_cannot_bypass_duration_limit(self):
        for start, end in [(-1, 2), (2, 1), (1, 1), (0, float('nan')), (0, float('inf')), (False, 1), ('0', 1), (0, 181)]:
            data = fixture()
            data['clips'][0].update(start=start, end=end)
            with self.subTest(start=start, end=end), self.assertRaises(ValueError):
                validate_manifest(data)

    def test_invalid_shape_and_count_are_rejected(self):
        for data in [None, {}, {'context': '', 'clips': []}, {'context': '', 'clips': [None]},
                     {'context': '', 'clips': [fixture()['clips'][0]] * 7}]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                validate_manifest(data)


if __name__ == '__main__':
    unittest.main()
