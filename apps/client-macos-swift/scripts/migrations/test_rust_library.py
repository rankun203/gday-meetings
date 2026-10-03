import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import rust_library as migration


class RustImportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'rust'
        self.target = self.root / 'swift'
        self.target.mkdir()
        self.folder = self.source / 'recordings' / 'session-a'
        self.folder.mkdir(parents=True)
        self.person = self.source / 'people' / 'person-a'
        self.person.mkdir(parents=True)
        self.write(self.folder / 'metadata.json', {
            'session_id': 'session-a', 'name': 'Planning meeting', 'language': 'en',
            'created_at': '2026-01-02T03:04:05Z', 'duration_secs': 8, 'tags': ['planning'],
            'notes': 'Review ![figure](assets/figure.png).',
        })
        self.write(self.folder / 'transcript.json', {'segments': [
            {'start': 0, 'end': 3, 'text': 'Review the plan.\nNext item.',
             'speaker': 'SPEAKER_00', 'track': 'microphone', 'person_id': 'person-a'}],
            'speaker_embeddings': {'SPEAKER_00': {'embedding': [2.0, 3.0], 'person_id': 'person-a'}}})
        (self.folder / 'summary.md').write_text('A short summary.')
        (self.folder / 'audio.opus').write_bytes(b'synthetic audio')
        (self.folder / 'assets').mkdir()
        (self.folder / 'assets/figure.png').write_bytes(b'synthetic asset')
        self.write(self.folder / 'todos.json', {'items': [
            {'text': 'Review plan', 'full_text': '**Participant** — Review plan', 'completed': True}]})
        self.write(self.person / 'profile.json', {'name': 'Participant', 'notes': 'Team member', 'starred': True})
        self.write(self.person / 'embeddings.json', {'samples': [
            {'embedding': [2.0, 3.0], 'session_id': 'session-a', 'duration_secs': 3,
             'confirmed_at': '2026-01-03T00:00:00Z'}] * 2})
        self.write(self.source / 'tags.json', {'tags': [{'name': 'planning', 'hidden': False, 'notes': 'Tag notes'}]})
        self.write(self.source / 'conversations/chat-a.json', {'messages': [{'role': 'user', 'content': 'Question'}]})
        self.stop = patch.object(migration, 'stopped')
        self.stop.start()
        self.addCleanup(self.stop.stop)

    @staticmethod
    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(migration.encode(value))

    def plan(self):
        return migration.build_plan(self.source, self.target, embedding_origin="runpod")

    def apply(self, plan=None):
        migration.apply(plan or self.plan(), self.root / 'backup')

    def test_preservation_embeddings_and_idempotence(self):
        (self.target / 'settings.json').write_bytes(b'existing settings')
        source_before = migration.source_inventory(self.source)
        target_before = migration.inventory(self.target)
        plan = self.plan()
        self.assertEqual(plan['manifest']['counts']['voiceSamples'], 2)
        self.apply(plan)
        self.assertEqual(migration.source_inventory(self.source), source_before)
        self.assertEqual(migration.inventory(self.root / 'backup'), target_before)
        mid = plan['manifest']['meetingIDMap']['session-a']
        folder = self.target / 'meetings' / migration.base36(mid)
        rows = [json.loads(r) for r in (folder / 'transcript.jsonl').read_text().splitlines()]
        self.assertEqual(rows[0]['text'], 'Review the plan.\nNext item.')
        self.assertFalse((folder / 'transcript.json').exists())
        content = migration.read(folder / 'content.json')
        self.assertTrue(content['todos'][0]['isCompleted'])
        person = migration.read(next((self.target / 'people').glob('*.json')))
        self.assertEqual(len(person['voiceSamples']), 2)
        for sample in person['voiceSamples']:
            self.assertEqual(sample['embedding'], [2.0, 3.0])
            self.assertEqual(sample['scope'], 'legacy:rust:runpod')
            self.assertNotIn('voiceEmbedding', sample)
            self.assertEqual(sample['speakerID'], rows[0]['speakerID'])
            self.assertEqual(sample['meetingID'], mid)
        self.assertEqual((folder / 'assets/figure.png').read_bytes(), b'synthetic asset')
        self.assertTrue((self.target / 'rust-import-archive/conversations/chat-a.json').exists())
        (folder / 'notes.md').write_text('Edited after import')
        repeated = self.plan()
        self.assertTrue(repeated['alreadyImported'])
        self.assertEqual((folder / 'notes.md').read_text(), 'Edited after import')

    def test_audio_duplicate_preserves_existing_meeting(self):
        mid = migration.identity('existing', 'meeting')
        folder = self.target / 'meetings' / migration.base36(mid)
        folder.mkdir(parents=True)
        (folder / 'renamed.opus').write_bytes(b'synthetic audio')
        self.write(folder / 'metadata.json', {'id': mid, 'audioFiles': ['renamed.opus']})
        self.write(folder / 'content.json', {'speakers': []})
        (folder / 'notes.md').write_text('Edited destination notes')
        before = migration.inventory(folder)
        plan = self.plan()
        self.assertEqual(plan['manifest']['meetingIDMap']['session-a'], mid)
        self.assertEqual(plan['manifest']['counts']['newMeetings'], 0)
        self.apply(plan)
        self.assertTrue(all(migration.inventory(folder)[k] == v for k, v in before.items()))
        self.assertTrue((folder / 'legacy-rust/transcript.json').exists())
        self.assertFalse((folder / 'audio.opus').exists())

    def test_destination_conflict_refused(self):
        plan = self.plan()
        key = next(k for k in plan['outputs'] if k.startswith('people/') and k.endswith('.json'))
        self.write(self.target / key, {'name': 'Different person'})
        with self.assertRaises(migration.MigrationError):
            self.plan()

    def test_source_or_target_change_after_planning_refused(self):
        plan = self.plan()
        (self.folder / 'audio.opus').write_bytes(b'changed')
        with self.assertRaises(migration.MigrationError):
            self.apply(plan)
        self.assertFalse((self.root / 'backup').exists())
        plan = self.plan()
        (self.target / 'new-file').write_text('new')
        with self.assertRaises(migration.MigrationError):
            self.apply(plan)

    def test_symlink_refused(self):
        (self.folder / 'external').symlink_to(self.target)
        with self.assertRaises(migration.MigrationError):
            self.plan()

    def test_invalid_embedding_and_times_refused(self):
        embeddings = self.person / 'embeddings.json'
        for value in (None, [], [0, 0]):
            with self.subTest(embedding=value):
                self.write(embeddings, {'samples': [{'session_id': 'session-a', 'embedding': value}]})
                with self.assertRaises(migration.MigrationError):
                    self.plan()
        embeddings.unlink()
        transcript = migration.read(self.folder / 'transcript.json')
        transcript['segments'][0]['end'] = -1
        self.write(self.folder / 'transcript.json', transcript)
        with self.assertRaises(migration.MigrationError):
            self.plan()

    def test_missing_person_or_metadata_refused(self):
        (self.person / 'profile.json').unlink()
        with self.assertRaises(migration.MigrationError):
            self.plan()
        (self.folder / 'metadata.json').unlink()
        with self.assertRaises(migration.MigrationError):
            self.plan()

    def test_ambiguous_audio_match_refused(self):
        for name in ('one', 'two'):
            folder = self.target / 'meetings' / name
            folder.mkdir(parents=True)
            (folder / 'audio.opus').write_bytes(b'synthetic audio')
            self.write(folder / 'metadata.json', {'id': migration.identity('test', name), 'audioFiles': ['audio.opus']})
        with self.assertRaises(migration.MigrationError):
            self.plan()

    def test_interrupted_publication_rolls_back(self):
        plan = self.plan()
        original_link = migration.os.link
        calls = 0
        def failing_link(*args):
            nonlocal calls
            calls += 1
            if calls == 3:
                raise OSError('Synthetic publication failure')
            return original_link(*args)
        with patch.object(migration.os, 'link', side_effect=failing_link):
            with self.assertRaises(OSError):
                self.apply(plan)
        self.assertEqual(migration.inventory(self.target), {})
        self.assertEqual(list(self.target.iterdir()), [])
        self.assertEqual(migration.inventory(self.root / 'backup'), {})

    def test_embedding_origin_requires_confirmation(self):
        with self.assertRaises(migration.MigrationError):
            migration.build_plan(self.source, self.target)

    def test_existing_backup_refused(self):
        (self.root / 'backup').mkdir()
        with self.assertRaises(migration.MigrationError):
            self.apply()

    def test_invalid_optional_vector_archived_and_missing_person_unresolved(self):
        transcript = migration.read(self.folder / 'transcript.json')
        transcript['speaker_embeddings']['SPEAKER_00']['embedding'] = [0, 0]
        transcript['segments'][0]['person_id'] = 'deleted-person'
        self.write(self.folder / 'transcript.json', transcript)
        plan = self.plan()
        self.assertEqual(plan['manifest']['counts']['omittedInvalidSpeakerEmbeddings'], 1)
        self.assertEqual(plan['manifest']['counts']['unresolvedPersonRows'], 1)
        self.assertEqual(plan['manifest']['counts']['unresolvedSourcePeople'], 1)
        self.apply(plan)
        folder = next((self.target / 'meetings').iterdir())
        speaker = migration.read(folder / 'content.json')['speakers'][0]
        self.assertNotIn('embedding', speaker)
        self.assertNotIn('personID', speaker)
        self.assertEqual(migration.read(folder / 'legacy-rust/transcript.json'), transcript)
        self.assertEqual(json.loads((folder / 'transcript.jsonl').read_text())['text'],
                         transcript['segments'][0]['text'])

    def test_tag_visibility_and_name_overlap_reported_without_merging(self):
        tag_id = migration.identity('existing', 'tag')
        person_id = migration.identity('existing', 'person')
        self.write(self.target / 'tags' / (tag_id + '.json'),
                   {'id': tag_id, 'name': 'planning', 'isExcluded': True})
        self.write(self.target / 'people' / (person_id + '.json'),
                   {'id': person_id, 'name': 'Participant', 'voiceSamples': []})
        plan = self.plan()
        self.assertEqual(plan['manifest']['counts']['retainedDestinationTagVisibility'], 1)
        self.assertEqual(plan['manifest']['counts']['unmergedNameOverlaps'], 1)
        self.assertNotEqual(plan['manifest']['personIDMap']['person-a'], person_id)
        self.apply(plan)
        self.assertTrue(migration.read(self.target / 'tags' / (tag_id + '.json'))['isExcluded'])
        self.assertEqual(len(list((self.target / 'people').glob('*.json'))), 2)

    def test_backup_symlink_ancestor_containment_refused(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(migration.MigrationError):
            migration.apply(self.plan(), alias / 'backup')
        self.assertFalse((self.source / 'backup').exists())

    def test_isolated_preview_bundle_may_remain_open(self):
        import plistlib
        bundle = self.root / 'Gday Meetings UI Preview.app/Contents'
        bundle.mkdir(parents=True)
        (bundle / 'Info.plist').write_bytes(plistlib.dumps({'GdayUIPreview': True}))
        self.stop.stop()
        with patch.object(migration.subprocess, 'check_output',
                          return_value=str(bundle / 'MacOS/GdayMeetings') + '\n'):
            migration.stopped()

    def test_running_app_refused(self):
        self.stop.stop()
        with patch.object(migration.subprocess, 'check_output', return_value='/Applications/Gday Meetings.app/Contents/MacOS/GdayMeetings\n'):
            with self.assertRaises(migration.MigrationError):
                self.apply()


if __name__ == '__main__':
    unittest.main()
