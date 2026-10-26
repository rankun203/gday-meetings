"""Installed Community-1 WeSpeaker graph with the production speech-span policy.

The caller supplies canonical 16 kHz mono samples. This isolates model changes
from the Swift audio decoder and resampler used in earlier experiment runs.
"""

import hashlib
import math
from pathlib import Path

import numpy as np


MODEL_ID = 'community1-wespeaker-coreml'


def _sha256(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def validate_waveform(waveform):
    values = np.asarray(waveform, dtype=np.float32)
    if values.ndim != 1 or not 32000 <= values.size <= 160000:
        raise ValueError('Expected two to ten seconds of mono speech at 16 kHz.')
    if not np.isfinite(values).all():
        raise ValueError('Waveform contains nonfinite samples.')
    return values


def active_frame_count(sample_count):
    if not 32000 <= sample_count <= 160000:
        raise ValueError('Expected between 32000 and 160000 samples.')
    return (sample_count - 400) // 160 + 1


def centered_features(features, sample_count):
    """Match SpeechSpanFeaturePolicy, calculating means in double precision."""
    active = active_frame_count(sample_count)
    features = np.asarray(features, dtype=np.float64)
    if features.shape != (1, 1, 80, 998) or not np.isfinite(features).all():
        raise ValueError('The FBank model returned invalid speech features.')
    result = np.zeros_like(features)
    real = features[..., :active]
    result[..., :active] = real - real.mean(axis=-1, keepdims=True)
    if not np.isfinite(result).all():
        raise ValueError('Centering produced invalid speech features.')
    return result.astype(np.float32)


def duration_weights(sample_count):
    active_frame_count(sample_count)
    active = max(1, min(589, math.floor(sample_count / 160000 * 589 + .5)))
    weights = np.zeros((1, 589), dtype=np.float32)
    weights[:, :active] = 1
    return weights


class Adapter:
    def __init__(self, model_id, model_dir, device='coreml'):
        if model_id != MODEL_ID:
            raise ValueError(f'Unknown model: {model_id}')
        if device != 'coreml':
            raise ValueError('The installed baseline uses Core ML compute units.')
        import coremltools as ct

        directory = Path(model_dir).resolve()
        paths = {name: directory / (name + '.mlmodelc') for name in ('FBank', 'Embedding')}
        for path in paths.values():
            if not path.is_dir():
                raise ValueError(f'Compiled model directory is missing: {path.name}')
        self.fbank = ct.models.CompiledMLModel(str(paths['FBank']), compute_units=ct.ComputeUnit.CPU_ONLY)
        self.embedding = ct.models.CompiledMLModel(str(paths['Embedding']), compute_units=ct.ComputeUnit.ALL)
        files = sorted(p for path in paths.values() for p in path.rglob('*') if p.is_file())
        source = Path(__file__).resolve().parents[2] / 'apps/client-macos-swift/Sources/GdayMeetings/Core/CommunityVoiceEmbeddingExtractor.swift'
        self.metadata = dict(
            model_id=model_id, identity='installed Community-1 WeSpeaker embedding',
            compatibility_version='gday-span-feature-center-v2', dimension=256,
            device=device, sample_rate=16000, audio_samples=160000,
            fbank_compute_units='CPU_ONLY', embedding_compute_units='ALL',
            models={str(p.relative_to(directory)): _sha256(p) for p in files},
            model_bytes=sum(p.stat().st_size for p in files),
            production_policy_sha256=_sha256(source),
            normalization_policy_sha256=_sha256(source.parent / 'LocalModels/TypedVoiceEmbedding.swift'),
            pipeline='canonical mono float32 audio -> installed FBank -> active-frame centering -> duration mask -> installed WeSpeaker -> unit L2',
            frontend_shape=[1, 1, 80, 998], mask_shape=[1, 589],
            active_frames='floor((sample_count-400)/160)+1',
            mask_rounding='floor(sample_count/160000*589+0.5)',
            normalization='unitL2; double precision matching TypedVoiceEmbedding',
        )

    def embed(self, waveform):
        samples = validate_waveform(waveform)
        audio = np.zeros((1, 1, 160000), dtype=np.float32)
        audio[0, 0, :samples.size] = samples
        output = self.fbank.predict({'audio': audio})
        features = centered_features(output['fbank_features'], samples.size)
        result = self.embedding.predict({'fbank_features': features,
                                         'weights': duration_weights(samples.size)})
        vector = np.asarray(result['embedding'], dtype=np.float64)
        if vector.shape != (1, 256) or not np.isfinite(vector).all():
            raise ValueError('The embedding model returned an invalid vector.')
        scale = np.max(np.abs(vector))
        if scale <= 0:
            raise ValueError('The embedding model returned a zero or invalid vector.')
        scaled = vector[0] / scale
        norm = math.sqrt(sum(float(value) * float(value) for value in scaled))
        return scaled / norm

    def embed_batch(self, waveforms):
        waveforms = np.asarray(waveforms)
        if waveforms.ndim != 2 or waveforms.shape[0] == 0:
            raise ValueError('Expected a nonempty batch of equal-length mono waveforms.')
        return np.stack([self.embed(waveform) for waveform in waveforms])


def load_model(model_id, model_dir, device='coreml'):
    return Adapter(model_id, model_dir, device)
