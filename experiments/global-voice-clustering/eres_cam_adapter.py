"""Local official ERes2NetV2 and WeSpeaker CAM++ LM embedding backbones.

Code and checkpoints are supplied explicitly; this module never downloads data.
Waveforms are mono float samples at 16 kHz. Frontends reproduce the respective
official inference scripts, including their different amplitude/window settings.
"""

import hashlib
import importlib
from importlib.machinery import ModuleSpec
from pathlib import Path
import subprocess
import sys
import types

import numpy as np
import torch
import torchaudio
import torchaudio.compliance.kaldi as kaldi


ERES = 'eres2netv2-w24s4ep4'
CAM = 'wespeaker-campplus-lm'


def _sha256(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


class Adapter:
    def __init__(self, model_id, code_dir, checkpoint_dir, device='cpu'):
        if model_id not in (ERES, CAM):
            raise ValueError(f'Unknown model: {model_id}')
        self.model_id = model_id
        self.device = torch.device(device)
        code_dir = Path(code_dir).resolve()
        checkpoint_dir = Path(checkpoint_dir).resolve()
        # Use upstream architecture files unchanged. WeSpeaker's top-level CLI
        # initializer imports unrelated frontends with obsolete torchaudio APIs;
        # namespace packages expose only the requested architecture and pooling.
        package = 'speakerlab' if model_id == ERES else 'wespeaker'
        if package in sys.modules:
            existing = Path(next(iter(sys.modules[package].__path__))).resolve()
            if not existing.is_relative_to(code_dir):
                raise ValueError(f'{package} is already imported from another checkout.')
        sys.path.insert(0, str(code_dir))
        if model_id == CAM:
            for name, directory in [('wespeaker', code_dir / 'wespeaker'),
                                    ('wespeaker.models', code_dir / 'wespeaker/models')]:
                if name not in sys.modules:
                    module = types.ModuleType(name)
                    module.__path__ = [str(directory)]
                    module.__spec__ = ModuleSpec(name, loader=None, is_package=True)
                    module.__spec__.submodule_search_locations = module.__path__
                    sys.modules[name] = module
        if model_id == ERES:
            cls = importlib.import_module('speakerlab.models.eres2net.ERes2NetV2').ERes2NetV2
            model = cls(feat_dim=80, embedding_size=192, baseWidth=24, scale=4, expansion=4)
            checkpoint = checkpoint_dir / 'pretrained_eres2netv2w24s4ep4.ckpt'
            identity = 'iic/speech_eres2netv2w24s4ep4_sv_zh-cn_16k-common@v1.0.1'
        else:
            cls = importlib.import_module('wespeaker.models.campplus').CAMPPlus
            model = cls(feat_dim=80, embed_dim=512, pooling_func='TSTP')
            checkpoint = checkpoint_dir / 'avg_model.pt'
            identity = 'Wespeaker/wespeaker-voxceleb-campplus-LM'
        state = torch.load(checkpoint, map_location='cpu', weights_only=True)
        if model_id == CAM:
            # The published training checkpoint includes its speaker classifier.
            # Embedding inference excludes that training-only projection.
            state.pop('projection.weight', None)
        model.load_state_dict(state, strict=True)
        self.torch_model = model.eval().to(self.device)
        self.embedding_model = self.torch_model
        parameter = next(self.torch_model.parameters())
        revision = subprocess.run(['git', '-C', str(code_dir), 'rev-parse', 'HEAD'],
                                  text=True, capture_output=True, check=True).stdout.strip()
        self.metadata = dict(model_id=model_id, identity=identity, code_revision=revision,
                             checkpoint=checkpoint.name,
                             checkpoint_sha256=_sha256(checkpoint),
                             checkpoint_bytes=checkpoint.stat().st_size,
                             parameters=sum(p.numel() for p in model.parameters()),
                             embedding_dimension=192 if model_id == ERES else 512,
                             sample_rate=16000, device=str(self.device),
                             backend=parameter.device.type, dtype=str(parameter.dtype),
                             torch_version=str(torch.__version__), torchaudio_version=str(torchaudio.__version__),
                             frontend_device='cpu',
                             feature_bins=80, frame_length_ms=25, frame_shift_ms=10,
                             dither=0, mean_normalization=True,
                             waveform_scale=1 if model_id == ERES else 32768,
                             window_type='povey' if model_id == ERES else 'hamming')

    def features(self, waveform):
        """Return CPU float32 features shaped [1, frames, 80]."""
        waveform = torch.as_tensor(waveform, dtype=torch.float32, device='cpu')
        if waveform.ndim == 2 and waveform.shape[0] == 1:
            waveform = waveform.squeeze(0)
        if waveform.ndim != 1 or waveform.numel() < 400:
            raise ValueError('Expected at least 400 mono samples at 16 kHz.')
        if not torch.isfinite(waveform).all():
            raise ValueError('Waveform contains nonfinite samples.')
        args = dict(num_mel_bins=80, sample_frequency=16000, dither=0)
        if self.model_id == CAM:
            waveform = waveform * 32768
            args.update(frame_length=25, frame_shift=10, window_type='hamming', use_energy=False)
        feat = kaldi.fbank(waveform.unsqueeze(0), **args)
        return (feat - feat.mean(0, keepdim=True)).unsqueeze(0)

    def embedding_from_features(self, features):
        """Run the backbone on [batch, frames, 80], retaining Torch output."""
        return self.torch_model(features)

    def embed_batch(self, waveforms):
        waveforms = np.asarray(waveforms)
        if waveforms.ndim != 2 or waveforms.shape[0] == 0:
            raise ValueError('Expected a nonempty batch of equal-length mono waveforms.')
        feats = torch.cat([self.features(waveform) for waveform in waveforms]).to(self.device)
        with torch.inference_mode():
            vectors = self.embedding_from_features(feats).detach().cpu().numpy()
        norms = np.linalg.norm(vectors, axis=1, keepdims=True)
        if not np.isfinite(vectors).all() or np.any(norms <= 0):
            raise ValueError('Model returned an invalid embedding.')
        return vectors / norms

    def embed(self, waveform):
        return self.embed_batch(np.asarray(waveform)[None, :])[0]


def load_model(model_id, model_dir=None, code_dir=None, device='cpu', *, checkpoint_dir=None):
    if model_dir is not None and checkpoint_dir is not None:
        raise ValueError('Specify one checkpoint directory.')
    directory = checkpoint_dir if checkpoint_dir is not None else model_dir
    if directory is None or code_dir is None:
        raise ValueError('Provide the checkpoint directory and upstream code directory.')
    return Adapter(model_id, code_dir, directory, device)
