"""Local ReDimNet2 inference with the checkpoint's original audio frontend.

Download the official source and checkpoints under ignored tmp/. Loading never
downloads code or weights. Input is mono float PCM at 16 kHz; output is unit L2.
"""
import hashlib
import importlib
from pathlib import Path
import sys

import numpy as np
import torch


SOURCE_REVISION = 'c5bbe0b76e37df698c403f8844e41304ceab6307'
MODELS = {
    'redimnet2_b6_vb2_vox2_lm': 'b6-vb2+vox2_v0-lm.pt',
    'redimnet2_b3_vb2_vox2_cnc2_lm': 'b3-vb2+vox2+cnc2_v0-lm.pt',
}


class EmbeddingFromFeatures(torch.nn.Module):
    """Expose the trained backbone and pooling without spectral operations."""

    def __init__(self, model):
        super().__init__()
        self.backbone = model.backbone
        self.pool = model.pool
        self.bn = model.bn
        self.linear = model.linear
        self.bn2 = model.bn2
        self.before_pool_offset = model.before_pool_offset

    def forward(self, features):
        if features.ndim == 3:
            features = features.unsqueeze(1)
        output = self.backbone(features)
        if output.ndim == 4:
            output = output.flatten(1, 2)
        if self.before_pool_offset is not None:
            output = output[:, :, self.before_pool_offset:]
        output = self.linear(self.bn(self.pool(output)))
        return self.bn2(output) if self.bn2 is not None else output


class ReDimNetAdapter:
    def __init__(self, model, device, metadata):
        self.device = torch.device(device)
        self.torch_model = model.eval()
        # Keep preprocessing on CPU for a reproducible execution split. These
        # checkpoints use convolutional DFT features; no frontend is substituted.
        self.torch_model.spec.cpu()
        self.embedding_model = EmbeddingFromFeatures(model).eval().to(self.device)
        self.metadata = metadata

    def features(self, waveform):
        """Return original CPU features for a batch of 16 kHz waveforms."""
        waveform = waveform.to(device='cpu', dtype=torch.float32)
        if self.torch_model.pad_right_samples is not None:
            waveform = torch.nn.functional.pad(
                waveform, (0, self.torch_model.pad_right_samples))
        with torch.inference_mode():
            return self.torch_model.spec(waveform)

    def embedding_from_features(self, features):
        with torch.inference_mode():
            return self.embedding_model(features.to(self.device))

    def embed(self, waveform, sample_rate=16000):
        audio = np.asarray(waveform, dtype=np.float32)
        if audio.ndim != 1:
            raise ValueError('Audio must be a mono waveform.')
        return self.embed_batch(audio[np.newaxis, :], sample_rate)[0]

    def embed_batch(self, waveforms, sample_rate=16000):
        """Embed equal-length waveforms without padding their context."""
        if sample_rate != 16000:
            raise ValueError('ReDimNet2 requires 16 kHz audio.')
        audio = np.asarray(waveforms, dtype=np.float32)
        if audio.ndim != 2 or audio.shape[0] < 1 or audio.shape[1] < 512:
            raise ValueError('Audio must be a batch of mono waveforms with at least 512 samples each.')
        if not np.isfinite(audio).all():
            raise ValueError('Audio contains nonfinite samples.')
        features = self.features(torch.from_numpy(audio.copy()))
        output = self.embedding_from_features(features).detach().cpu().numpy()
        if output.shape != (audio.shape[0], self.metadata['embedding_dimension']):
            raise ValueError('Model returned an unexpected embedding shape.')
        vectors = output.astype(np.float32)
        norms = np.linalg.norm(vectors.astype(np.float64), axis=1, keepdims=True)
        if not np.isfinite(vectors).all() or not np.isfinite(norms).all() or (norms <= 0).any():
            raise ValueError('Model returned an invalid embedding.')
        return (vectors / norms).astype(np.float32)


def load_model(model_id, model_dir, code_dir, device='cpu'):
    """Load one official checkpoint once; caller owns the adapter's lifetime."""
    if model_id not in MODELS:
        raise ValueError(f'Unknown ReDimNet2 model: {model_id}')
    source = Path(code_dir).resolve()
    checkpoint = Path(model_dir).resolve() / MODELS[model_id]
    if not (source / 'redimnet2' / '__init__.py').is_file():
        raise ValueError('code_dir must contain the official redimnet2 package.')
    existing = sys.modules.get('redimnet2')
    if existing is not None and Path(existing.__file__).resolve().parent.parent != source:
        raise ValueError('A different redimnet2 source directory is already loaded.')
    sys.path.insert(0, str(source))
    try:
        package = importlib.import_module('redimnet2')
    finally:
        sys.path.remove(str(source))
    payload = torch.load(checkpoint, map_location='cpu', weights_only=True)
    model = package.ReDimNet2Wrap(**payload['model_config'])
    model.load_state_dict(payload['state_dict'], strict=True)
    if model.return_all_outputs:
        raise ValueError('Checkpoint must return a single speaker embedding.')
    metadata = {
        'model_id': model_id, 'checkpoint': checkpoint.name,
        'checkpoint_sha256': hashlib.sha256(checkpoint.read_bytes()).hexdigest(),
        'checkpoint_bytes': checkpoint.stat().st_size,
        'model_config': payload['model_config'],
        'parameter_count': sum(parameter.numel() for parameter in model.parameters()),
        'embedding_dimension': model.embed_dim, 'sample_rate': 16000,
        'device': str(device), 'frontend_device': 'cpu', 'normalization': 'unit_l2',
        'source_revision_expected': SOURCE_REVISION,
    }
    return ReDimNetAdapter(model, device, metadata)
