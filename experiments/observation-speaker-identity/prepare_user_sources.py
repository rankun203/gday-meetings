"""Decode user-authorized recordings without changing originals or inventing truth labels."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import wave


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError('Use a new output directory')
    args.output.mkdir(parents=True)
    inputs = json.loads(args.inputs.read_text())
    records = []
    for index, directory in enumerate(inputs['meetingDirectories'], 1):
        meeting = Path(directory)
        metadata = json.loads((meeting / 'metadata.json').read_text())
        for filename in metadata['audioFiles']:
            source = 'microphone' if 'microphone' in filename else 'system'
            original = meeting / filename
            alias = f'recent-{index:02}-{source}'
            output = args.output / (alias + '.wav')
            before = sha(original)
            command = ['ffmpeg', '-v', 'error', '-nostdin', '-i', str(original), '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', str(output)]
            subprocess.run(command, check=True)
            if before != sha(original):
                raise ValueError('Original source changed during decoding')
            with wave.open(str(output)) as stream:
                frames = stream.getnframes()
                pcm = hashlib.sha256()
                while data := stream.readframes(16000 * 60):
                    pcm.update(data)
                if stream.getnchannels() != 1 or stream.getframerate() != 16000 or stream.getsampwidth() != 2:
                    raise ValueError('Unexpected PCM format')
            records.append(dict(id=alias, cohort='unreviewed-private', actualSource=source, replayInternalSource='microphone',
                                meetingDirectory=str(meeting), sourceAudioPath=str(original), sourceAudioSHA256=before,
                                metadataPath=str(meeting / 'metadata.json'), metadataSHA256=sha(meeting / 'metadata.json'),
                                audioPath=str(output.resolve()), audioSHA256=sha(output), pcmSHA256=pcm.hexdigest(),
                                durationSeconds=frames / 16000, decodedSampleCount=frames,
                                humanReferenceStatus='absent; saved/manual live labels are not ground truth',
                                decodeCommand=command))
            print(json.dumps(dict(sample=alias, durationSeconds=frames / 16000)), flush=True)
    manifest = dict(schemaVersion=1, inputsPath=str(args.inputs.resolve()), inputsSHA256=sha(args.inputs),
                    preparerSHA256=sha(__file__), sourcePasses='independent complete tracks, no mixing or cropping',
                    limitations=['Independent source passes do not reproduce simultaneous capture or model contention',
                                 'No human diarization accuracy claim without reviewed references'], samples=records)
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
