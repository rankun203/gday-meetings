---
title: CLSP and native inference attribution
date: 2026-10-06
status: active
scope: clsp-code-model-and-tokenizer-distribution
---

# CLSP and native inference attribution

The app's Swift inference support and separately prepared model distribution use the components below. Model files are downloaded separately; these notices do not mean the weights are bundled in the app. Retain this notice and the accompanying license texts when redistributing the converted models or native inference code.

| Component | Pinned source | License |
| --- | --- | --- |
| CLSP code and weights | [yfyeung/CLSP, 30355ce67960e4cc1562e4e5fa154baf86a21430](https://huggingface.co/yfyeung/CLSP/tree/30355ce67960e4cc1562e4e5fa154baf86a21430) | Apache 2.0 |
| SPEAR XLarge v1 speech/audio encoder, inherited by CLSP | [marcoyang/spear-xlarge-speech-audio, aa4e9beef49cf6883a0b152db899811dfa568f77](https://huggingface.co/marcoyang/spear-xlarge-speech-audio/tree/aa4e9beef49cf6883a0b152db899811dfa568f77) | Apache 2.0 |
| RoBERTa-base encoder and tokenizer assets | [FacebookAI/roberta-base, e2da8e2f811d1448a5b465c236feacd80ffbac7b](https://huggingface.co/FacebookAI/roberta-base/tree/e2da8e2f811d1448a5b465c236feacd80ffbac7b) | MIT |
| Hugging Face Swift Tokenizers | [swift-transformers, c21fdcde390313a6d98d8e33a346f2c3486c3ab0](https://github.com/huggingface/swift-transformers/tree/c21fdcde390313a6d98d8e33a346f2c3486c3ab0) | Apache 2.0 |
| RoBERTa reference implementation | [Transformers 4.57.3](https://github.com/huggingface/transformers/tree/v4.57.3/src/transformers/models/roberta) | Apache 2.0 |
| Kaldi-compatible filter-bank reference | [Torchaudio 2.8.0](https://github.com/pytorch/audio/blob/v2.8.0/src/torchaudio/compliance/kaldi.py) | BSD 2-Clause |

CLSP's model implementation retains **Copyright 2025 Yifan Yang**. Its Zipformer and supporting modules retain **Copyright 2022–2023 Xiaomi Corp.**, with authors Daniel Povey and Zengwei Yao. The upstream source credits [icefall](https://github.com/k2-fsa/icefall) and adaptations of [ESPnet convolution and subsampling](https://github.com/espnet/espnet), both Apache 2.0. Those upstream notices remain applicable to derived implementations.

RoBERTa's original [fairseq license](https://github.com/facebookresearch/fairseq/blob/main/LICENSE) retains **Copyright (c) Facebook, Inc. and its affiliates.** Torchaudio retains **Copyright (c) 2017 Facebook Inc. (Soumith Chintala), All rights reserved.** The Transformers tokenizer source retains **Copyright 2018 The Open AI Team Authors and The HuggingFace Inc. team.** Hugging Face Swift Tokenizers is distributed under the included Apache 2.0 license.

## Modifications

This distribution prepares CLSP for Core ML execution on macOS, with Swift audio preprocessing and text tokenization. Export adapters may replace framework-specific operators with equivalent primitive operations. The conversion manifest and validation report identify actual model precision, input shapes, changes, and numerical results. This is a derived distribution, not an upstream release or endorsement. Use the CLSP checkpoint's fine-tuned weights; do not replace its inherited encoder with SPEAR v2 or fresh RoBERTa weights.

## Citation

Upstream requests citation of Yifan Yang and collaborators, *Towards Fine-Grained and Multi-Granular Contrastive Language-Speech Pre-training*, ACL 2026. See the [CLSP model card](https://huggingface.co/yfyeung/CLSP/blob/30355ce67960e4cc1562e4e5fa154baf86a21430/README.md) for the complete citation. The inherited speech encoder is described in Xiaoyu Yang and collaborators, *SPEAR: A Unified SSL Framework for Learning Speech and Audio Representations*.

## License scope

The pinned CLSP and SPEAR model cards declare Apache 2.0, and RoBERTa's model card declares MIT. No separate upstream NOTICE file was present in those pinned Hugging Face repository file lists. The prepared distribution includes full Apache 2.0, MIT, and BSD 2-Clause license texts and the component attribution above. Training data, upstream example recordings, and repository artwork are not included; their rights are not granted by this notice.
