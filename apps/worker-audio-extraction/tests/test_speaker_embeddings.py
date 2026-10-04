"""Published embedding identity must match the model pin without loading it."""
import unittest
from audio_extraction.speaker_embeddings import COMMUNITY1_MODEL, COMMUNITY1_REVISION, embedding_metadata, normalize_embeddings


class SpeakerEmbeddingTests(unittest.TestCase):
    def test_contract_identifies_pinned_model_and_normalization(self):
        metadata = embedding_metadata()
        self.assertEqual(metadata["speaker_embedding_provenance"], f"{COMMUNITY1_MODEL}@{COMMUNITY1_REVISION}")
        self.assertEqual(len(COMMUNITY1_REVISION), 40)
        self.assertEqual(metadata["speaker_embedding_type"]["dimension"], 256)
        self.assertEqual(metadata["speaker_embedding_type"]["normalization"], "unitL2")

    def test_contract_is_not_mutable_across_requests(self):
        metadata = embedding_metadata()
        metadata["speaker_embedding_type"]["modelID"] = "synthetic-other-model"
        self.assertNotEqual(embedding_metadata()["speaker_embedding_type"]["modelID"], "synthetic-other-model")

    def test_vectors_are_normalized_and_invalid_shapes_are_omitted(self):
        values = normalize_embeddings({"valid": [3.0] + [0.0] * 255, "short": [1, 0],
                                       "zero": [0.0] * 256, "invalid": [float("nan")] * 256})
        self.assertEqual(list(values), ["valid"])
        self.assertEqual(values["valid"], [1.0] + [0.0] * 255)
