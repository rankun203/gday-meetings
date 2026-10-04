"""Embedding-space identity shared with the Community-1 Core ML conversion.

The converted embedding model is not fine-tuned:
https://huggingface.co/FluidInference/speaker-diarization-coreml
"""

import math

COMMUNITY1_MODEL = "pyannote/speaker-diarization-community-1"
COMMUNITY1_REVISION = "3533c8cf8e369892e6b79ff1bf80f7b0286a54ee"


def embedding_metadata():
    """Describe the pinned model and its normalized output vectors."""
    return {
        "speaker_embedding_type": {
            "modelID": "FluidInference/community1-wespeaker-resnet34",
            "revision": "df2625ac79a7ac6b65ad868fee6d80f320da4232",
            "compatibilityVersion": "gday-span-mask-v1",
            "dimension": 256,
            "normalization": "unitL2",
        },
        "speaker_embedding_provenance": f"{COMMUNITY1_MODEL}@{COMMUNITY1_REVISION}",
    }


def normalize_embeddings(embeddings):
    """Keep only finite vectors in the declared Community-1 embedding space."""
    result = {}
    for label, values in embeddings.items():
        if len(values) != 256 or not all(math.isfinite(value) for value in values):
            continue
        scale = max(map(abs, values))
        if scale <= 0:
            continue
        scaled = [value / scale for value in values]
        norm = math.sqrt(sum(value * value for value in scaled))
        result[label] = [value / norm for value in scaled]
    return result
