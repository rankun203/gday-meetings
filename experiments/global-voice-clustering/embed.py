#!/usr/bin/env python3
"""Extract homogeneous Community-1 vectors from an isolated fixture, without a sample cap."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import statistics
import struct
from datetime import datetime, timezone


def stable(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


def file_sha256(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def compile_runner(repo, destination):
    app = repo / 'apps/client-macos-swift'
    core = app / 'Sources/GdayMeetings/Core'
    fluid = app / '.build/checkouts/FluidAudio/Sources/FluidAudio/Shared'
    native = app / '.build/native-audio-arm64/install'
    module = destination / 'OpusFileBridge'
    module.mkdir(parents=True, exist_ok=True)
    header = app / 'Sources/OpusFileBridge/include/OpusFileBridge.h'
    (module / 'module.modulemap').write_text(f'module OpusFileBridge {{ header "{header}" export * }}\n')
    obj = destination / 'OpusFileBridge.o'
    subprocess.run(['clang', '-O2', '-c', str(app / 'Sources/OpusFileBridge/OpusFileBridge.c'),
                    '-I', str(header.parent), '-I', str(native / 'include'), '-I', str(native / 'include/opus'), '-o', str(obj)], check=True)
    binary = destination / 'extractor'
    sources = [repo / 'experiments/global-voice-clustering/EmbeddingExtractor.swift',
               core / 'CommunityVoiceEmbeddingExtractor.swift', core / 'LocalModels/TypedVoiceEmbedding.swift',
               core / 'RecordingSignposts.swift', core / 'StreamingAudioReader.swift',
               app / 'Sources/GdayMeetings/Services/AudioPlaybackPreparation.swift']
    sources += [fluid / name for name in ['AppLogger.swift', 'AudioSampleSource.swift', 'AudioSourceFactory.swift']]
    subprocess.run(['swiftc', '-O', '-module-cache-path', str(destination / 'module-cache'),
                    '-I', str(destination), *map(str, sources), str(obj),
                    '-L', str(native / 'lib'), '-lopusfile', '-lopus', '-logg', '-o', str(binary)], check=True)
    return binary


def read_results(path, repair=False):
    if not path.exists():
        return {}
    data = path.read_bytes()
    lines = data.splitlines(keepends=True)
    results = {}
    position = 0
    for index, line in enumerate(lines):
        try:
            result = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            if index != len(lines) - 1:
                raise ValueError('The embedding checkpoint contains an invalid interior record.')
            if repair:
                with path.open('r+b') as handle:
                    handle.truncate(position)
            break
        results[result['key']] = result
        position += len(line)
    if repair and data and position == len(data) and not data.endswith(b'\n'):
        with path.open('ab') as handle:
            handle.write(b'\n')
    return results


def provenance(repo, input_path, jobs_path, models):
    app = repo / 'apps/client-macos-swift'
    core = app / 'Sources/GdayMeetings/Core'
    fluid = app / '.build/checkouts/FluidAudio/Sources/FluidAudio/Shared'
    paths = [core / 'CommunityVoiceEmbeddingExtractor.swift', core / 'LocalModels/TypedVoiceEmbedding.swift',
             core / 'RecordingSignposts.swift', core / 'StreamingAudioReader.swift',
             app / 'Sources/GdayMeetings/Services/AudioPlaybackPreparation.swift',
             app / 'Sources/OpusFileBridge/OpusFileBridge.c', app / 'Sources/OpusFileBridge/include/OpusFileBridge.h']
    paths += [fluid / name for name in ['AppLogger.swift', 'AudioSampleSource.swift', 'AudioSourceFactory.swift']]
    paths += sorted((app / '.build/native-audio-arm64/install/lib').glob('*.a'))
    model_paths = [p for name in ['FBank.mlmodelc', 'Embedding.mlmodelc'] for p in (models / name).rglob('*') if p.is_file()]
    digest = file_sha256
    return dict(input_sha256=digest(input_path), jobs_sha256=digest(jobs_path),
                cli_source_sha256=digest(repo / 'experiments/global-voice-clustering/EmbeddingExtractor.swift'),
                production_sources={str(p.relative_to(repo)): digest(p) for p in paths},
                models={str(p.relative_to(models)): digest(p) for p in sorted(model_paths)},
                audio_files={str(p.relative_to(input_path.parent)): digest(p) for p in sorted({Path(j[k]) for j in json.loads(jobs_path.read_text()) for k in ['audioPath', 'originalAudioPath'] if k in j})},
                decoder_receipt_sha256=digest(input_path.parent / 'decoded-audio/receipt.json') if (input_path.parent / 'decoded-audio/receipt.json').exists() else None,
                configuration=dict(sample_rate=16000, fbank_compute_units='cpuOnly', embedding_compute_units='all',
                                   normalization='TypedVoiceEmbedding.normalizing', pipeline='CommunityDiarization discovery',
                                   span_frame_rounding='nearest', maximum_samples=160000,
                                   aac_decode='ffmpeg pcm_f32le WAV; retain source sample rate and channels'))


def decode_aac_jobs(jobs, root):
    selected = [j for j in jobs if Path(j['audioPath']).suffix.lower() == '.m4a']
    if not selected:
        return
    directory = root / 'decoded-audio'
    directory.mkdir(exist_ok=True)
    receipt_path = directory / 'receipt.json'
    receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
    version = subprocess.run(['ffmpeg', '-version'], capture_output=True, text=True, check=True).stdout.splitlines()[0]
    digest = file_sha256
    prepared = {}
    for job in selected:
        original = Path(job['audioPath'])
        if original in prepared:
            job['originalAudioPath'] = str(original)
            job['audioPath'] = str(prepared[original])
            continue
        key = hashlib.sha256(str(original.relative_to(root)).encode()).hexdigest()
        decoded = directory / (key + '.wav')
        command = ['ffmpeg', '-v', 'error', '-nostdin', '-i', str(original), '-map', '0:a:0', '-c:a', 'pcm_f32le', str(decoded)]
        original_hash = digest(original)
        prior = receipt.get(key)
        if not (prior and decoded.exists() and prior['original_sha256'] == original_hash
                and prior['decoded_sha256'] == digest(decoded) and prior['ffmpeg_version'] == version):
            temporary = decoded.with_suffix('.partial.wav')
            temporary.unlink(missing_ok=True)
            subprocess.run(command[:-1] + [str(temporary)], check=True)
            temporary.replace(decoded)
            receipt[key] = dict(original_path=str(original.relative_to(root)), original_sha256=original_hash,
                                decoded_path=str(decoded.relative_to(root)), decoded_sha256=digest(decoded),
                                ffmpeg_version=version, command=command,
                                reason='Native AAC AudioSourceFactory conversion failed with OSStatus -1; native bounded reader raised CoreAudio fmt? exception.')
        prepared[original] = decoded
        job['originalAudioPath'] = str(original)
        job['audioPath'] = str(decoded)
    receipt_path.write_text(json.dumps(receipt, sort_keys=True, indent=2))


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')
    temporary.replace(path)


def canonical_wav_frames(path):
    """Read actual 16 kHz mono float WAV frames and reject truncated payloads."""
    size = path.stat().st_size
    sample_count = None
    format_ok = False
    with path.open('rb') as handle:
        header = handle.read(12)
        if len(header) != 12 or header[:4] != b'RIFF' or header[8:] != b'WAVE':
            raise ValueError('Fallback audio must be a RIFF WAV file.')
        while handle.tell() + 8 <= size:
            kind, length = struct.unpack('<4sI', handle.read(8))
            offset = handle.tell()
            if offset + length > size:
                raise ValueError('Fallback WAV contains truncated audio or metadata.')
            if kind == b'fmt ':
                data = handle.read(length)
                if len(data) < 16:
                    raise ValueError('Fallback WAV has an incomplete format.')
                encoding, channels, rate, _, alignment, bits = struct.unpack('<HHIIHH', data[:16])
                floating = encoding == 3 or (encoding == 65534 and len(data) >= 40 and struct.unpack('<H', data[24:26])[0] == 3)
                format_ok = floating and channels == 1 and rate == 16000 and alignment == 4 and bits == 32
            elif kind == b'data':
                if length % 4 or sample_count is not None:
                    raise ValueError('Fallback WAV has invalid frame alignment or repeated audio data.')
                sample_count = length // 4
            handle.seek(offset + length + length % 2)
    if not format_ok or sample_count is None:
        raise ValueError('Fallback WAV must contain 16 kHz mono 32-bit float audio.')
    return sample_count


def recover_eof_jobs(repo, input_path, jobs_path, models, binary, results_path, primary_receipt):
    """Retry the exact decoded-EOF error on the VAD's canonical decode timeline.

    The production extractor and model remain unchanged. Only these failed AAC
    jobs use direct ffmpeg resampling instead of the source-rate WAV resampler.
    """
    root = input_path.parent
    jobs = json.loads(jobs_path.read_text())
    results = read_results(results_path)
    error_text = 'The excerpt is outside the decoded audio.'
    selected = [job for job in jobs if results.get(job['key'], {}).get('error') == error_text
                and not results[job['key']].get('embedding')
                and Path(job.get('originalAudioPath', '')).suffix.lower() == '.m4a']
    directory = root / 'embedding-fallback'
    receipt_path = directory / 'receipt.json'
    if not selected and not receipt_path.exists():
        return None
    directory.mkdir(exist_ok=True)
    previous = json.loads(receipt_path.read_text()) if receipt_path.exists() else None
    if previous:
        planned_keys = {job['key'] for job in json.loads((directory / 'jobs.json').read_text())}
        if any(job['key'] not in planned_keys for job in selected):
            raise ValueError('New decoded-EOF failures differ from the preserved fallback plan.')
        selected = [job for job in jobs if job['key'] in planned_keys]
    if previous and previous['primary_extraction'] != primary_receipt:
        raise ValueError('Fallback primary inputs changed; use a new fixture output directory.')
    manifest_path = root / 'full-speech-manifest.json'
    manifest_hash = file_sha256(manifest_path)
    expected_counts = {}
    for row in json.loads(manifest_path.read_text())['recordings']:
        if row.get('status') == 'complete':
            expected_counts.setdefault(row['audio_sha256'], set()).add(row['decoded_samples'])
    version = subprocess.run(['ffmpeg', '-version'], capture_output=True, text=True, check=True).stdout.splitlines()[0]
    sources, replacements = {}, {}
    for job in selected:
        original = Path(job['originalAudioPath'])
        if original in replacements:
            continue
        source_hash = file_sha256(original)
        if source_hash not in expected_counts or len(expected_counts[source_hash]) != 1:
            raise ValueError('Fallback source has no unique completed VAD frame count.')
        expected = next(iter(expected_counts[source_hash]))
        key = hashlib.sha256(str(original.relative_to(root)).encode()).hexdigest()
        decoded = directory / (key + '.wav')
        command = ['ffmpeg', '-v', 'error', '-nostdin', '-i', str(original), '-map', '0:a:0',
                   '-ac', '1', '-ar', '16000', '-c:a', 'pcm_f32le', str(decoded)]
        prior_source = previous.get('sources', {}).get(key) if previous else None
        if previous:
            if not (prior_source and prior_source['original_sha256'] == source_hash and decoded.exists()
                    and prior_source['decoded_sha256'] == file_sha256(decoded)):
                raise ValueError('Fallback source or decoded checkpoint changed.')
        else:
            temporary = decoded.with_suffix('.partial.wav')
            temporary.unlink(missing_ok=True)
            subprocess.run(command[:-1] + [str(temporary)], check=True)
            temporary.replace(decoded)
        frames = canonical_wav_frames(decoded)
        if frames != expected:
            raise ValueError('Canonical fallback decode differs from the VAD sample count; speech was not truncated or clamped.')
        sources[key] = dict(original_path=str(original.relative_to(root)), original_sha256=source_hash,
                            decoded_path=str(decoded.relative_to(root)), decoded_sha256=file_sha256(decoded),
                            decoded_samples=frames, vad_decoded_samples=expected, command=command)
        replacements[original] = (decoded, frames)
    fallback_jobs = []
    for job in selected:
        decoded, frames = replacements[Path(job['originalAudioPath'])]
        if any(math.floor(span['end'] * 16000 + .5) > frames or math.floor(span['start'] * 16000 + .5) < 0
               for span in job['spans']):
            raise ValueError('Fallback excerpt exceeds the canonical decoded audio; original speech bounds are preserved.')
        fallback_jobs.append({**job, 'audioPath': str(decoded)})
    fallback_jobs_path = directory / 'jobs.json'
    job_bytes = (json.dumps(fallback_jobs, sort_keys=True, indent=2) + '\n').encode()
    if fallback_jobs_path.exists() and fallback_jobs_path.read_bytes() != job_bytes:
        raise ValueError('Fallback jobs changed.')
    atomic_json(fallback_jobs_path, fallback_jobs)
    receipt = dict(primary_extraction=primary_receipt, sources=sources, ffmpeg_version=version,
                   jobs_sha256=file_sha256(fallback_jobs_path), vad_manifest_sha256=manifest_hash,
                   fallback_source_sha256=file_sha256(Path(__file__)),
                   configuration=dict(reason=error_text, preparation='Direct ffmpeg 16 kHz mono float WAV using the VAD decode timeline.',
                                      unchanged='Production extractor, models, keys, and excerpt spans.',
                                      difference='Primary AAC preparation retains source rate and channels before production resampling; fallback performs mono conversion and resampling in ffmpeg.'))
    if previous and previous != receipt:
        raise ValueError('Fallback provenance changed; use a new fixture output directory.')
    if not previous:
        atomic_json(directory / 'primary-failures.json', {job['key']: results[job['key']] for job in selected})
        atomic_json(receipt_path, receipt)
    fallback_results_path = directory / 'results.jsonl'
    checkpoint = read_results(fallback_results_path, repair=True)
    if any(not checkpoint.get(job['key'], {}).get('embedding') for job in selected):
        with (directory / 'attempts.jsonl').open('a') as handle:
            handle.write(json.dumps(dict(started_at=datetime.now(timezone.utc).isoformat(),
                                        runner_binary_sha256=file_sha256(binary))) + '\n')
        process = subprocess.run([str(binary), str(fallback_jobs_path), str(models), str(fallback_results_path), '0'],
                                 stderr=subprocess.PIPE, text=True)
        with (directory / 'backend.log').open('a') as handle:
            handle.write(process.stderr)
        process.check_returncode()
    # Recheck every source/model and prepared file before accepting any vector.
    if provenance(repo, input_path, jobs_path, models) != primary_receipt:
        raise ValueError('Primary source or model changed during fallback extraction.')
    if file_sha256(manifest_path) != manifest_hash or file_sha256(fallback_jobs_path) != receipt['jobs_sha256']:
        raise ValueError('Fallback manifest or job input changed during extraction.')
    for source in sources.values():
        if (file_sha256(root / source['original_path']) != source['original_sha256']
                or file_sha256(root / source['decoded_path']) != source['decoded_sha256']):
            raise ValueError('Fallback audio changed during extraction.')
    recovered = read_results(fallback_results_path)
    accepted = {job['key']: recovered[job['key']] for job in selected
                if recovered.get(job['key'], {}).get('embedding')}
    for record in accepted.values():
        vector = record['embedding'].get('values', [])
        if not vector or not all(math.isfinite(value) for value in vector) or not any(value != 0 for value in vector):
            raise ValueError('Fallback returned an invalid embedding.')
    with results_path.open('a') as handle:
        for key, record in accepted.items():
            if results.get(key, {}).get('embedding'):
                continue
            handle.write(json.dumps({**record, 'preparation_fallback': 'embedding-fallback/receipt.json'}) + '\n')
    summary = dict(attempted=len(selected), recovered=len(accepted), receipt='embedding-fallback/receipt.json',
                   original_failed_attempts='embedding-fallback/primary-failures.json',
                   unresolved=len(selected) - len(accepted))
    atomic_json(directory / 'summary.json', summary)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--models', type=Path, required=True)
    parser.add_argument('--max-jobs', type=int, default=0, help='Benchmark only; 0 extracts every unique excerpt.')
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    path = args.input.resolve()
    root = path.parent
    document = json.loads(path.read_text())
    meetings = {m['id']: m for m in document['meetings']}
    jobs = {}
    rows = []
    for example in document['examples']:
        meeting = meetings[example['meetingID']]
        spans = example.get('spans') or [dict(start=example['start'], end=example['end'])]
        physical = [example['meetingID'], example.get('audioFile'), example.get('audioRevision'), spans]
        key = hashlib.sha256(stable(physical).encode()).hexdigest()
        audio = root / 'library/meetings' / meeting['folder'] / example['audioFile']
        # Fail closed if a malformed fixture points outside its independent copy.
        audio.resolve().relative_to((root / 'library/meetings').resolve())
        if audio.is_symlink():
            raise ValueError('The fixture contains a symbolic link.')
        speaker = next((s for s in meeting['speakers'] if s['id'] == example.get('speakerID')), {})
        local = (f"{example['meetingID']}:{example.get('detectedSpeakerResultID')}:{example['detectedSpeakerID']}"
                 if example.get('detectedSpeakerID') else f"{example['meetingID']}:{example.get('speakerID')}")
        spans_valid = (0 < len(spans) <= 8
            and all(math.isfinite(s['start']) and math.isfinite(s['end']) and 0 <= s['start'] < s['end'] for s in spans)
            and all(a['end'] <= b['start'] for a, b in zip(spans, spans[1:])))
        duration = sum(s['end'] - s['start'] for s in spans) if spans_valid else 0
        count = sum(math.floor(s['end'] * 16000 + 0.5) - math.floor(s['start'] * 16000 + 0.5) for s in spans) if spans_valid else 0
        eligible = (not example.get('excluded') and not example.get('manuallyCleared') and spans_valid and 2 - 1e-6 <= duration <= 10 + 1e-6 and 32000 <= count <= 160000
                    and not (example.get('sampleQuality') or {}).get('issue') and audio.is_file())
        if eligible:
            jobs[key] = dict(key=key, audioPath=str(audio), spans=spans)
        confirmed = example.get('review') == 'confirmed' and bool(example.get('personID'))
        rows.append(dict(id=example['id'], example_id=example['id'], meeting_id=example['meetingID'],
                         meeting_order=meeting['meeting_order'], speaker_id=example.get('speakerID'),
                         local_speaker=local, local_label=speaker.get('label'), eligible=eligible,
                         person_id=example.get('personID') if confirmed else None,
                         association_person_id=example.get('personID') or example.get('namedPersonID'),
                         confirmed=confirmed, active_reference=bool(confirmed and eligible),
                         rejected_person_ids=example.get('rejectedPersonIDs', []), density_key=key,
                         density_meeting_key=local, support_spans=example.get('speechSpans') or spans, embedding_spans=spans,
                         speech_detection=example.get('speech_detection'),
                         duration=sum(s['end'] - s['start'] for s in spans), audio_path=str(audio.relative_to(root)),
                         source=example.get('source'), audio_revision=example.get('audioRevision'), quality=1.0,
                         sample_quality=example.get('sampleQuality'), origin=example.get('origin'),
                         selected_reference=example.get('selectedReference')))
    ordered = sorted(jobs.values(), key=lambda j: (j['audioPath'], j['spans'][0]['start']))
    job_path = root / 'embedding-jobs.json'
    job_path.write_text(json.dumps(ordered))
    print(f'examples={len(rows)} eligible={sum(r["eligible"] for r in rows)} unique_jobs={len(jobs)}', flush=True)
    if args.prepare_only:
        return
    decode_aac_jobs(ordered, root)
    job_path.write_text(json.dumps(ordered))
    repo = Path(__file__).resolve().parents[2]
    receipt_path = root / 'embedding-provenance.json'
    receipt = provenance(repo, path, job_path, args.models.resolve())
    results_path = root / 'embedding-results.jsonl'
    if receipt_path.exists():
        previous = json.loads(receipt_path.read_text())
        if previous['extraction'] != receipt:
            raise ValueError('Extraction inputs or model files changed; use a new fixture output directory.')
    elif results_path.exists():
        raise ValueError('The embedding checkpoint has no provenance receipt.')
    else:
        receipt_path.write_text(json.dumps(dict(extraction=receipt), indent=2))
    read_results(results_path, repair=True)
    build = root / 'embedding-build'
    build.mkdir(exist_ok=True)
    binary = compile_runner(repo, build)
    audit = json.loads(receipt_path.read_text())
    audit.setdefault('runner_builds', []).append(dict(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        cli_source_sha256=hashlib.sha256((Path(__file__).parent / 'EmbeddingExtractor.swift').read_bytes()).hexdigest()))
    receipt_path.write_text(json.dumps(audit, indent=2))
    results_path = root / 'embedding-results.jsonl'
    process = subprocess.run([str(binary), str(job_path), str(args.models.resolve()), str(results_path), str(args.max_jobs)],
                             stderr=subprocess.PIPE, text=True)
    diagnostics_path = root / 'embedding-backend.log'
    with diagnostics_path.open('a') as diagnostics:
        diagnostics.write(process.stderr)
    process.check_returncode()
    if provenance(repo, path, job_path, args.models.resolve()) != receipt:
        raise ValueError('Extraction inputs changed during inference; discard this checkpoint.')
    fallback_summary = (recover_eof_jobs(repo, path, job_path, args.models.resolve(), binary, results_path, receipt)
                        if document['metadata'].get('full_speech') and not args.max_jobs else None)
    diagnostics = diagnostics_path.read_text()
    results = read_results(results_path)
    enriched = []
    for row in rows:
        result = results.get(row['density_key'])
        if not result or not result.get('embedding'):
            continue
        typed = result['embedding']
        enriched.append({**row, 'embedding': typed['values'], 'embedding_type': typed['type'], 'model': stable(typed['type'])})
    document['samples'] = enriched
    document['metadata']['embedding_rows'] = len(enriched)
    document['metadata']['examples_without_embeddings'] = len(rows) - len(enriched)
    document['metadata']['availability'].update(embedding_rows=len(enriched), examples_without_embeddings=len(rows) - len(enriched), eligible_rows=sum(r['eligible'] for r in enriched), confirmed_rows=sum(r['confirmed'] for r in enriched), audio_available_rows=sum(bool(r['audio_path']) for r in enriched))
    if document['metadata'].get('full_speech'):
        document['metadata']['full_speech']['embedded_windows'] = len(enriched)
        document['metadata']['full_speech']['failed_embedding_windows'] = sum(row['eligible'] for row in rows) - len(enriched)
    if fallback_summary:
        document['metadata']['embedding_fallback'] = fallback_summary
    previous_limitations = document['metadata'].get('limitations', [])
    document['metadata']['limitations'] = [
        'Every eligible saved physical excerpt was recomputed with the homogeneous production discovery embedding path. Full discovery and current app processing were not replayed.',
        'Two AAC source files were decoded to float WAV with ffmpeg after native AAC decoding failed; source rate and channel count were preserved. Production resampling and embedding extraction remain identical.',
        'Eligibility uses stored signal quality and saved overlap-free support; fresh signal quality and overlap were not reassessed.',
        'Human confirmations are partial reference labels.',
        'quality=1 is a neutral comparison weight; stored raw signal metadata is preserved.']
    if document['metadata'].get('full_speech'):
        document['metadata']['limitations'] = previous_limitations + [
            'All eligible full-recording speech windows were submitted to the production embedding extractor; detected speech support is separate from short-window context.',
            'VAD speech detection does not separate simultaneous speakers or guarantee one speaker per window.',
            'Resource monitoring covers preparation and inference, with accelerator attribution reported as unavailable.']
    if fallback_summary:
        document['metadata']['limitations'].append('Decoded-EOF AAC failures use direct ffmpeg 16 kHz mono float WAV preparation matching the VAD timeline; the production extractor and models remain unchanged. Original spans and failed attempts are preserved in embedding-fallback/.')
    document['metadata']['extraction'] = dict(unique_jobs=len(jobs), completed_unique=len(results),
        successful_unique=sum(bool(r.get('embedding')) for r in results.values()), enriched_rows=len(enriched),
        complete=all(key in results and results[key].get('embedding') for key in jobs),
        attempted_unique=len(results), failed_unique=sum(not r.get('embedding') for r in results.values()),
        timing_seconds=dict(minimum=min((r['seconds'] for r in results.values()), default=0), median=statistics.median(r['seconds'] for r in results.values()) if results else 0, total=sum(r['seconds'] for r in results.values())),
        provenance='embedding-provenance.json',
        backend_warnings=([warning for marker, warning in [
            ('create_directories: Operation not permitted', 'CoreML could not create the default external cache; inference completed with fallback.'),
            ('Audio files cannot be non-interleaved', 'AVAudioFile ignored the noninterleaved CAF output setting.')] if marker in diagnostics]),
        pipeline='Production CommunityVoiceEmbeddingExtractor and FluidAudio AudioSourceFactory')
    if document['metadata']['extraction']['complete']:
        temporary = root / 'enriched-input.json.partial'
        temporary.write_text(json.dumps(document))
        temporary.replace(root / 'enriched-input.json')
    print(json.dumps(document['metadata']['extraction']), flush=True)


if __name__ == '__main__':
    main()
