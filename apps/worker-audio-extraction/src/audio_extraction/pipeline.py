"""WhisperX transcription + alignment + diarization pipeline."""

import logging
import os
import subprocess
import sys
import time
import warnings

import numpy as np
import pandas as pd
import requests as req
import torch
import whisperx
from pyannote.audio import Pipeline as PyannotePipeline
from pyannote.audio.pipelines.speaker_diarization import DiarizeOutput
from whisperx.diarize import DiarizationPipeline

from .speaker_embeddings import COMMUNITY1_MODEL, COMMUNITY1_REVISION, embedding_metadata, normalize_embeddings

# Suppress known harmless warnings from pyannote internals:
# - TF32 reproducibility warning (pyannote disables TF32 intentionally)
# - std() degrees-of-freedom warning on very short segments
warnings.filterwarnings("ignore", message="TensorFloat-32.*has been disabled")
warnings.filterwarnings("ignore", message="std\\(\\): degrees of freedom")
warnings.filterwarnings("ignore", message="Passing `gradient_checkpointing` to a config")

logger = logging.getLogger(__name__)


class TranscriptionPipeline:
    """Manages WhisperX models and runs the full extraction pipeline."""

    def __init__(
        self,
        model_size: str = "large-v2",
        device: str = "cuda",
        compute_type: str = "float16",
        batch_size: int = 16,
        hf_token: str | None = None,
        segmentation_batch_size: int = 32,
        embedding_batch_size: int = 4,
    ):
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self.batch_size = batch_size
        self.hf_token = hf_token
        self.segmentation_batch_size = segmentation_batch_size
        self.embedding_batch_size = embedding_batch_size

        logger.info(
            "Loading WhisperX model: %s on %s (%s)", model_size, device, compute_type
        )
        self.model = whisperx.load_model(
            model_size, device, compute_type=compute_type
        )

        self._align_models: dict[str, tuple] = {}
        self._diarize_model = None

    # ------------------------------------------------------------------
    # Model loading
    # ------------------------------------------------------------------

    def _get_diarize_model(self) -> DiarizationPipeline | None:
        """Load diarization model on first use. Requires HF_TOKEN."""
        if self._diarize_model is None and not self.hf_token:
            logger.warning("Diarization requested but HF_TOKEN is not set. "
                           "Set HF_TOKEN env var in RunPod endpoint settings. "
                           "Skipping diarization.")
            return None
        if self._diarize_model is None:
            logger.info("Loading diarization pipeline")

            os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
            os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
            os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"

            model_name = COMMUNITY1_MODEL
            pipeline = self._load_pyannote_pipeline(model_name)

            pipeline.segmentation_batch_size = self.segmentation_batch_size
            pipeline.embedding_batch_size = self.embedding_batch_size
            logger.info("Diarization batch sizes: segmentation=%d, embedding=%d",
                        self.segmentation_batch_size, self.embedding_batch_size)

            logger.info("Moving diarization pipeline to %s...", self.device)
            t0 = time.time()
            pipeline = pipeline.to(torch.device(self.device))
            logger.info("Moved to %s in %.1fs", self.device, time.time() - t0)

            # Wrap in DiarizationPipeline without re-downloading
            self._diarize_model = object.__new__(DiarizationPipeline)
            self._diarize_model.model = pipeline
            logger.info("Diarization pipeline ready")
        return self._diarize_model

    def _load_pyannote_pipeline(self, model_name: str) -> PyannotePipeline:
        """Load pyannote pipeline, trying offline cache first."""
        # Try cache first (offline) — instant when pre-cached at Docker build time
        logger.info("Loading from cache (offline)...")
        t0 = time.time()
        os.environ["HF_HUB_OFFLINE"] = "1"
        try:
            pipeline = PyannotePipeline.from_pretrained(
                model_name, revision=COMMUNITY1_REVISION, token=self.hf_token
            )
            logger.info("Loaded from cache in %.1fs", time.time() - t0)
            return pipeline
        except Exception as e:
            logger.info("Cache miss (%.1fs): %s: %s", time.time() - t0, type(e).__name__, e)
        finally:
            os.environ.pop("HF_HUB_OFFLINE", None)

        # Cache miss — verify access, download via subprocess (avoids hangs
        # in RunPod's serverless worker), then load from cache.
        self._verify_hf_access()
        self._download_pyannote_subprocess(model_name)

        logger.info("Loading from cache after download...")
        t0 = time.time()
        os.environ["HF_HUB_OFFLINE"] = "1"
        try:
            pipeline = PyannotePipeline.from_pretrained(
                model_name, revision=COMMUNITY1_REVISION, token=self.hf_token
            )
        finally:
            os.environ.pop("HF_HUB_OFFLINE", None)
        logger.info("Loaded from cache in %.1fs", time.time() - t0)
        return pipeline

    def _download_pyannote_subprocess(self, model_name: str):
        """Download pyannote models in a subprocess to avoid hangs."""
        logger.info("Downloading models via subprocess...")
        t0 = time.time()
        download_script = """
import os
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
from pyannote.audio import Pipeline
pipeline = Pipeline.from_pretrained(os.environ["_MODEL"], revision=os.environ["_REVISION"], token=os.environ["_TOKEN"])
print('DOWNLOAD_OK')
"""
        env = {**os.environ, "_MODEL": model_name, "_REVISION": COMMUNITY1_REVISION, "_TOKEN": self.hf_token}
        result = subprocess.run(
            [sys.executable, "-c", download_script],
            capture_output=True, text=True, timeout=180, env=env,
        )
        if "DOWNLOAD_OK" not in result.stdout:
            logger.error("Subprocess stdout: %s", result.stdout[-500:] if result.stdout else "(empty)")
            logger.error("Subprocess stderr: %s", result.stderr[-500:] if result.stderr else "(empty)")
            raise RuntimeError("Failed to download diarization models in subprocess")
        logger.info("Download done in %.1fs", time.time() - t0)

    def _verify_hf_access(self):
        """Pre-check that HF_TOKEN can access required gated models."""
        gated_models = [
            "pyannote/speaker-diarization-community-1",
            "pyannote/segmentation-3.0",
        ]
        for model in gated_models:
            url = f"https://huggingface.co/api/models/{model}"
            logger.info("Checking access: %s", model)
            try:
                resp = req.get(url, headers={"Authorization": f"Bearer {self.hf_token}"}, timeout=10)
                if resp.status_code == 401:
                    raise RuntimeError(
                        f"HF_TOKEN is invalid or expired. Check your token at https://huggingface.co/settings/tokens"
                    )
                elif resp.status_code == 403:
                    raise RuntimeError(
                        f"Access denied to {model}. Accept the license at https://huggingface.co/{model}"
                    )
                elif resp.status_code != 200:
                    logger.warning("Unexpected status %d for %s, proceeding anyway", resp.status_code, model)
                else:
                    logger.info("Access OK: %s", model)
            except req.ConnectionError as e:
                raise RuntimeError(f"Cannot reach HuggingFace API: {e}")
            except req.Timeout:
                raise RuntimeError(f"HuggingFace API timeout checking {model}")

    def _get_align_model(self, language: str):
        """Load and cache alignment model per language."""
        if language not in self._align_models:
            logger.info("Loading alignment model for language: %s", language)
            model_a, metadata = whisperx.load_align_model(
                language_code=language, device=self.device
            )
            self._align_models[language] = (model_a, metadata)
        return self._align_models[language]

    # ------------------------------------------------------------------
    # Pipeline steps
    # ------------------------------------------------------------------

    def _transcribe(self, audio: np.ndarray, language: str) -> dict:
        """Run WhisperX speech-to-text."""
        logger.info("Transcribing (%.1fs audio)", len(audio) / 16000)
        t0 = time.time()
        result = self.model.transcribe(audio, batch_size=self.batch_size, language=language)
        logger.info("Transcription done in %.1fs", time.time() - t0)
        return result

    def _align(self, segments: list[dict], audio: np.ndarray, language: str) -> dict:
        """Run forced alignment for word-level timestamps."""
        logger.info("Aligning %d segments", len(segments))
        t0 = time.time()
        model_a, metadata = self._get_align_model(language)
        result = whisperx.align(
            segments, model_a, metadata, audio, self.device,
            return_char_alignments=False,
        )
        logger.info("Alignment done in %.1fs", time.time() - t0)
        return result

    def _diarize(
        self,
        audio: np.ndarray,
        min_speakers: int | None = None,
        max_speakers: int | None = None,
    ) -> tuple[any, dict[str, list[float]]]:
        """Run speaker diarization. Returns (annotation, speaker_embeddings)."""
        diarize_model = self._get_diarize_model()
        if diarize_model is None:
            logger.warning("Diarization model not available, returning empty result")
            return None, {}

        logger.info("Diarizing %.1fs of audio...", len(audio) / 16000)
        t0 = time.time()

        kwargs = {}
        if min_speakers is not None:
            kwargs["min_speakers"] = min_speakers
        if max_speakers is not None:
            kwargs["max_speakers"] = max_speakers

        # Progress hook — pyannote calls this at each pipeline step
        step_times: dict[str, float] = {}
        def _progress_hook(step_name, step_artifact, file=None, **kw):
            completed = kw.get("completed")
            total = kw.get("total")
            if completed is not None and total is not None:
                if completed == total or completed % max(total // 5, 1) == 0:
                    logger.info("  diarize/%s: %d/%d (%.0f%%)",
                                step_name, completed, total, 100 * completed / total)
            else:
                elapsed = time.time() - t0
                step_times[step_name] = elapsed
                logger.info("  diarize/%s done (%.1fs elapsed)", step_name, elapsed)

        # Pass waveform dict directly to avoid torchcodec dependency
        waveform = torch.from_numpy(audio).unsqueeze(0)  # (1, samples)
        audio_input = {"waveform": waveform, "sample_rate": 16000}
        diarize_output = diarize_model.model(
            audio_input, return_embeddings=True, hook=_progress_hook, **kwargs
        )

        # Extract annotation and embeddings
        annotation, speaker_embeddings = _parse_diarize_output(diarize_output)

        logger.info("Diarization done in %.1fs (%d speakers)",
                     time.time() - t0, len(speaker_embeddings))
        return annotation, speaker_embeddings

    # ------------------------------------------------------------------
    # Main entry point
    # ------------------------------------------------------------------

    def process_track(
        self,
        audio_path: str,
        language: str = "en",
        diarize: bool = True,
        speaker_prefix: str = "mic",
        min_speakers: int | None = None,
        max_speakers: int | None = None,
        audio: np.ndarray | None = None,
    ) -> dict:
        """Process a single audio track through the full pipeline.

        Args:
            audio_path: Path to audio file.
            language: Language code for transcription.
            diarize: Whether to run speaker diarization.
            speaker_prefix: Prefix for speaker IDs (avoids cross-track collisions).
            min_speakers: Minimum expected speakers.
            max_speakers: Maximum expected speakers.
            audio: Pre-decoded audio array (skips loading if provided).

        Returns:
            dict with: duration_secs, segments, speaker_embeddings
        """
        if audio is None:
            audio = whisperx.load_audio(audio_path)
        duration_secs = len(audio) / 16000
        step_timings: dict[str, float] = {}

        # Step 1: Transcribe
        t0 = time.time()
        result = self._transcribe(audio, language)
        step_timings["transcribe"] = time.time() - t0

        # Step 2: Align (word-level timestamps)
        t0 = time.time()
        result = self._align(result["segments"], audio, result["language"])
        step_timings["align"] = time.time() - t0

        # Step 3: Diarize (speaker labels + embeddings)
        speaker_embeddings = {}
        if diarize:
            logger.info("Diarization requested")
            t0 = time.time()
            annotation, speaker_embeddings = self._diarize(
                audio, min_speakers, max_speakers
            )
            step_timings["diarize"] = time.time() - t0
            if annotation is None:
                logger.warning("Diarization returned no annotation — speakers will not be assigned")
            else:
                t0 = time.time()
                diarize_segments = pd.DataFrame(
                    [
                        {"start": turn.start, "end": turn.end, "speaker": speaker}
                        for turn, _, speaker in annotation.itertracks(yield_label=True)
                    ]
                )
                result = whisperx.assign_word_speakers(
                    diarize_segments, result, fill_nearest=True
                )
                step_timings["assign_speakers"] = time.time() - t0

        # Prefix speaker IDs to avoid cross-track collisions
        segments = _prefix_speakers(result["segments"], speaker_prefix)
        speaker_embeddings = {
            f"{speaker_prefix}_{k}": v for k, v in normalize_embeddings(speaker_embeddings).items()
        }

        return {
            "duration_secs": round(duration_secs, 2),
            "segments": segments,
            "speaker_embeddings": speaker_embeddings,
            **embedding_metadata(),
            "step_timings": step_timings,
        }


# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

def _has_valid_embedding(embedding: list[float]) -> bool:
    """Return False if embedding contains any NaN or Inf values."""
    return not any(v != v or v == float('inf') or v == float('-inf') for v in embedding)


def _parse_diarize_output(output) -> tuple[any, dict[str, list[float]]]:
    """Extract annotation and speaker embeddings from pyannote output."""
    speaker_embeddings = {}

    if isinstance(output, DiarizeOutput):
        # pyannote-audio 4.x
        annotation = output.speaker_diarization
        raw = output.speaker_embeddings
        if raw is not None and hasattr(raw, 'shape') and raw.shape[0] > 0:
            labels = annotation.labels()
            for i, label in enumerate(labels):
                if i >= raw.shape[0]:
                    break
                emb = raw[i].tolist()
                if _has_valid_embedding(emb):
                    speaker_embeddings[label] = emb
                else:
                    logger.warning("Skipping speaker %s: invalid embedding (NaN/Inf)", label)
            logger.info("Parsed DiarizeOutput: %d speakers, embedding shape %s", len(labels), raw.shape)
        else:
            logger.warning("DiarizeOutput has no speaker embeddings (raw=%s)", type(raw).__name__)
    elif isinstance(output, tuple):
        # Legacy: tuple of (Annotation, embeddings_dict)
        annotation, raw = output
        if raw:
            for k, v in raw.items():
                emb = v if isinstance(v, list) else v.tolist()
                if _has_valid_embedding(emb):
                    speaker_embeddings[k] = emb
                else:
                    logger.warning("Skipping speaker %s: invalid embedding (NaN/Inf)", k)
            logger.info("Parsed tuple output: %d speakers", len(speaker_embeddings))
        else:
            logger.warning("Diarize tuple output has empty embeddings")
    else:
        logger.warning("Unexpected diarize output type: %s — treating as Annotation", type(output).__name__)
        annotation = output

    return annotation, speaker_embeddings


def _prefix_speakers(segments: list[dict], prefix: str) -> list[dict]:
    """Add track prefix to speaker IDs in segments."""
    for seg in segments:
        if "speaker" in seg and seg["speaker"]:
            seg["speaker"] = f"{prefix}_{seg['speaker']}"
        if "words" in seg:
            for word in seg["words"]:
                if "speaker" in word and word["speaker"]:
                    word["speaker"] = f"{prefix}_{word['speaker']}"
    return segments
