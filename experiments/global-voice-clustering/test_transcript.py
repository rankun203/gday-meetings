"""Synthetic transcript selection, physical coverage, and passage restoration checks."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from transcript import build_transcripts, passage_rows, file_source


def row(sid='r1', start=0., end=4., text='Example passage.', **extra):
    return dict(id=sid, start=start, end=end, text=text, source='system', speaker='sys_1', speakerID='speaker-a', **extra)


def evidence(sid='s1', start=0., end=4., **extra):
    return {'id': sid, 'meeting_id': 'meeting-a', 'source': 'system', 'audio_file': 'system.opus',
            'audio_revision': 'revision-a', 'eligible': True, 'support_spans': [dict(start=start, end=end)], **extra}


def anchored(sid, text, location, speaker='speaker-a', **extra):
    return {**row(sid, text=text), 'sourceSpans': [dict(rowID='original-a', text=text,
            range=dict(location=location, length=len(text.encode('utf-16-le')) // 2))], 'speakerID': speaker, **extra}


class TranscriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.folder = self.root / 'library/meetings/meeting-copy'
        self.folder.mkdir(parents=True)
        self.source = {'meetings': [dict(id='meeting-a', folder='meeting-copy', meeting_order=0,
                       metadata=dict(audioFiles=['system.opus']))]}
        (self.folder / 'system.opus').write_bytes(b'synthetic')
        self.content = dict(speakers=[dict(id='speaker-a', track='system_mix', label='sys_1')],
                            transcriptSource=dict(id='source-a'), speakerLabelSource=dict(resultID='labels-a'))
        self.write('content.json', self.content)

    def write(self, name, value):
        (self.folder / name).write_text(json.dumps(value))

    def read(self, rows, samples=None):
        (self.folder / 'transcript.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
        return build_transcripts(self.source, self.root, samples or [])

    def test_saved_word_and_run_timing_project_through_utf16_and_leading_space(self):
        first = anchored('one', '  😀 Hello', 0, start=10, end=12)
        second = anchored('two', ' there now.', 10, start=12, end=14)
        first['timing'] = dict(text=first['text'], spans=[
            dict(range=dict(location=2, length=2), start=10, end=10.5, granularity='word'),
            dict(range=dict(location=5, length=5), start=11, end=12, granularity='word')])
        second['timing'] = dict(text=second['text'], spans=[
            dict(range=dict(location=1, length=10), start=12, end=14, granularity='run')])
        result = self.read([first, second])['rows'][0]
        self.assertEqual(result['text'], '😀 Hello there now.')
        self.assertEqual(result['constituent_row_ids'], ['one', 'two'])
        self.assertEqual([(v['location'], v['length'], v['granularity']) for v in result['text_timing']],
                         [(0, 2, 'word'), (3, 5, 'word'), (9, 10, 'run')])
        self.assertEqual(result['text_timing'][0]['start'], 10)

    def test_stale_and_malformed_timing_leave_original_text_unhighlighted(self):
        valid = dict(range=dict(location=0, length=2), start=0, end=1, granularity='word')
        for timing in [dict(text='Old', spans=[valid]), dict(text='😀 Hi', spans=[{**valid, 'range':dict(location=1, length=1)}]),
                       dict(text='😀 Hi', spans=[{**valid, 'start':float('nan')}]),
                       dict(text='😀 Hi', spans=[{**valid, 'range':dict(location=0, length=99)}]),
                       dict(text='😀 Hi', spans=[valid, valid]), dict(text='😀 Hi', spans=[None])]:
            result = self.read([row(text='😀 Hi', timing=timing)])['rows'][0]
            self.assertEqual(result['text_timing'], [])
            self.assertEqual(result['text'], '😀 Hi')

    def test_untimed_constituents_keep_offsets_and_recording_times_stay_separate(self):
        self.write('transcription-source-source-a.json', dict(version=1, source=dict(id='source-a'),
            audio=[dict(trackID='track0', revision='r', recordingOffset=10)]))
        parts = [anchored('one', '  A', 0, start=10, end=11), anchored('two', ' B', 3, start=11, end=12)]
        parts[1]['timing'] = dict(text=' B', spans=[dict(range=dict(location=1, length=1), start=11,
                                                        end=12, granularity='word')])
        result = self.read(parts)['rows'][0]
        self.assertEqual(result['text'], 'A B')
        self.assertEqual(result['text_timing'], [dict(location=2, length=1, start=11, end=12, granularity='word')])
        self.assertEqual(result['audio_start'], 0)
        self.assertEqual(result['recording_offset'], 10)

    def test_full_speech_support_requires_exact_copied_audio_hash(self):
        self.write('diarization-projection-labels-a.json', dict(version=1, sourceID='source-a',
            resultID='labels-a', audio=[dict(trackID='track0', revision='app-token', source='system')]))
        digest = hashlib.sha256(b'synthetic').hexdigest()
        good = evidence(audio_revision=digest, origin='full-recording-speech-detection', source='custom-file')
        self.assertEqual(self.read([row()], [good])['rows'][0]['coverage'], 'full')
        self.assertEqual(self.read([row()], [{**good, 'audio_revision': 'stale'}])['rows'][0]['coverage'], 'none')

    def test_selected_current_edits_override_immutable_source_and_history(self):
        self.write('transcription-source-source-a.json', dict(version=1, source=dict(id='source-a'),
                   segments=[row(text='Older analysis.')]))
        self.write('transcript-revisions.json', dict(revisions=[dict(segments=[row(text='Older history.')])]))
        result = self.read([row(text='Current edited passage.')])
        self.assertEqual(result['rows'][0]['text'], 'Current edited passage.')
        self.assertEqual(result['meetings'][0]['transcript_source']['id'], 'source-a')

    def test_partial_overlap_does_not_cover_passage(self):
        result = self.read([row(end=20.)], [evidence(end=2.)])['rows'][0]
        self.assertEqual(result['coverage'], 'partial')
        self.assertAlmostEqual(result['coverage_fraction'], .1)
        self.assertEqual(result['coverage_intervals'], [dict(sample_id='s1', start=0., end=2.)])

    def test_union_coverage_and_duplicate_aliases(self):
        result = self.read([row()], [evidence('a', end=2.), evidence('b', end=2.),
                                    evidence('c', start=2.)])['rows'][0]
        self.assertEqual(result['coverage'], 'full')
        self.assertEqual(result['covered_seconds'], 4.)
        self.assertEqual(len(result['sample_ids']), 3)

    def test_fragment_gaps_remain_uncovered(self):
        sample = evidence()
        sample['support_spans'] = [dict(start=0., end=1.), dict(start=3., end=4.)]
        result = self.read([row()], [sample])['rows'][0]
        self.assertEqual(result['coverage'], 'partial')
        self.assertEqual(result['covered_seconds'], 2.)

    def test_exact_source_revision_and_file(self):
        self.write('diarization-projection-labels-a.json', dict(version=1, resultID='labels-a', sourceID='source-a',
                   audio=[dict(trackID='track0', source='system', revision='revision-a')]))
        samples = [evidence('wrong-source', source='microphone'), evidence('wrong-revision', audio_revision='old'),
                   evidence('wrong-file', audio_file='other.opus'), evidence('right')]
        result = self.read([row()], samples)['rows'][0]
        self.assertEqual(result['sample_ids'], ['right'])

    def test_original_track_ordinals_preserved_when_file_missing(self):
        self.source['meetings'][0]['metadata']['audioFiles'] = ['microphone.opus', 'system.opus']
        result = self.read([row(analysisTrackID='track0')])['rows'][0]
        self.assertEqual(result['track_index'], 0)
        self.assertEqual(result['recording_key'], 'meeting-a/0')
        self.assertFalse(result['audio_available'])
        self.assertEqual(result['audio_file'], 'microphone.opus')

    def test_multi_source_ambiguity_and_single_import_fallback(self):
        self.source['meetings'][0]['metadata']['audioFiles'] = ['one.wav', 'two.wav']
        result = self.read([row()])['rows'][0]
        self.assertEqual(result['coverage'], 'source_unresolved')
        self.assertIsNone(result['recording_key'])
        self.source['meetings'][0]['metadata']['audioFiles'] = ['one.wav']
        result = self.read([row()])['rows'][0]
        self.assertEqual(result['track_index'], 0)

    def test_custom_analysis_track_falls_back_and_recovered_source_stems_match(self):
        result = self.read([row(analysisTrackID='custom-track')])['rows'][0]
        self.assertEqual(result['track_index'], 0)
        self.assertEqual(file_source('mic-compatible-12345678-1234-1234-1234-123456789abc.opus'), 'microphone')
        self.assertEqual(file_source('system_mix.opus'), 'system')
        self.assertEqual(file_source('mic-compatible-example.opus'), 'unknown')

    def test_invalid_selected_binding_does_not_fabricate_offsets(self):
        self.write('diarization-projection-labels-a.json', dict(version=1, resultID='labels-a', sourceID='other',
                   audio=[dict(trackID='track0', source='system', revision='revision-a', recordingOffset=5.)]))
        result = self.read([row()])
        self.assertEqual(result['coverage']['failed_meetings'], 1)
        self.assertEqual(result['rows'], [])
        self.assertFalse(result['meetings'][0]['mix_available'])

    def test_empty_meeting_has_track_and_mix_receipts(self):
        result = self.read([])
        receipt = result['meetings'][0]
        self.assertTrue(receipt['mix_available'])
        self.assertEqual(receipt['audio_tracks'][0]['recording_key'], 'meeting-a/0')
        self.assertEqual(receipt['audio_tracks'][0]['recording_offset'], 0.)
        self.assertTrue(receipt['audio_tracks'][0]['available'])

    def test_measured_eligibility_controls_evidence_despite_metadata_flags(self):
        self.source['samples'] = [dict(id='measured', eligible=True, embedding=[1., 0.]),
                                  dict(id='zero', eligible=True, embedding=[0., 0.])]
        result = self.read([row()], [evidence('measured', manuallyCleared=True), evidence('zero')])['rows'][0]
        self.assertEqual(result['sample_ids'], ['measured'])

    def test_offset_applied_once_and_no_session_offset_guessed(self):
        self.write('diarization-projection-labels-a.json', dict(version=1, resultID='labels-a', sourceID='source-a',
                   audio=[dict(trackID='track0', source='system', revision='revision-a', recordingOffset=10.)]))
        result = self.read([row(start=10., end=14., analysisTrackID='track0', session='session-a')],
                           [evidence()])['rows'][0]
        self.assertEqual(result['coverage'], 'full')
        self.assertEqual(result['audio_start'], 0.)
        self.assertEqual(result['coverage_intervals'][0]['start'], 10.)

    def test_excluded_unrepresented_and_cleared_evidence_not_counted(self):
        self.source['samples'] = [dict(id='present', eligible=True, embedding=[1.,0.]), dict(id='excluded', eligible=False, embedding=[1.,0.]),
                                  dict(id='cleared', eligible=False, embedding=[1.,0.])]
        result = self.read([row()], [evidence('present'), evidence('missing'),
                   evidence('excluded', excluded=True), evidence('cleared', manuallyCleared=True)])['rows'][0]
        self.assertEqual(result['sample_ids'], ['present'])

    def test_missing_transcript_stays_missing_despite_analysis_artifact(self):
        self.write('transcription-source-source-a.json', dict(version=1, source=dict(id='source-a'), segments=[row()]))
        result = build_transcripts(self.source, self.root, [])
        self.assertEqual(result['rows'], [])
        self.assertEqual(result['meetings'][0]['status'], 'missing')
        self.assertEqual(result['coverage']['meetings'], 1)

    def test_unfinished_checkpoint_uses_committed_prefix_and_tail(self):
        prefix = (json.dumps(row()) + '\n').encode()
        (self.folder / 'transcript.jsonl').write_bytes(prefix + b'{incomplete-tail')
        self.write('transcript-checkpoint.json', dict(version=2, bytes=len(prefix), rows=1,
                   segments=[row('r2', start=4., end=5.)], finished=False))
        result = build_transcripts(self.source, self.root, [])
        self.assertEqual(result['coverage']['canonical_rows'], 2)
        self.assertEqual(result['meetings'][0]['status'], 'checkpoint')

    def test_invalid_rows_fail_meeting_without_partial_replacement(self):
        result = self.read([row(), row('r2', start=-1.)])
        self.assertEqual(result['rows'], [])
        self.assertEqual(result['coverage']['failed_meetings'], 1)

    def test_utf16_passage_grouping_preserves_constituents(self):
        rows = [anchored('r1', 'Hi🙂', 0), anchored('r2', ' there.', 4)]
        result = self.read(rows)
        self.assertEqual(result['coverage']['canonical_rows'], 2)
        self.assertEqual(len(result['rows']), 1)
        self.assertEqual(result['rows'][0]['text'], 'Hi🙂 there.')
        self.assertEqual(result['rows'][0]['constituent_row_ids'], ['r1', 'r2'])

    def test_bad_anchor_manual_identity_and_supported_voice_change_split_passages(self):
        a, b = anchored('r1', 'Hi', 0), anchored('r2', ' there.', 2)
        self.assertEqual(len(passage_rows([a, b], {})), 1)
        for changed in [{**b, 'personID': 'person-a'}, {**b, 'session': 'other'},
                        {**b, 'speakerID': 'speaker-b'}, {**b, 'analysisTrackID': 'track1'},
                        {**b, 'sourceSpans': []}]:
            self.assertEqual(len(passage_rows([a, changed], {})), 2)

    def test_uncertain_words_keep_partial_saved_person_scope(self):
        self.content['speakers'][0].update(personID='person-a', manuallyAssigned=True,
            voiceReviewOrigin=dict(speakerID='speaker-a', transcriptAssociationTier='automatic'),
            manualReviewThrough=dict(system=2.))
        self.write('content.json', self.content)
        a = anchored('r1', 'Hi', 0, end=2.)
        b = anchored('r2', ' there.', 2, start=2., end=4., associationUncertain=True)
        result = self.read([a, b])['rows'][0]
        self.assertEqual(result['saved_person_id'], 'person-a')
        self.assertEqual(result['saved_person_coverage'], 'partial')
        self.assertTrue(result['has_unattributed_words'])


if __name__ == '__main__':
    unittest.main()
