---
title: Entity-aware voice search research
date: 2026-10-05
status: research-complete-implementation-deferred
scope: long-term-library-search
---

# Problem

The long-term search goal combines People, Tags, Meetings, spoken content, and voice evidence. Basic joint speech-style embeddings cannot establish who spoke or reliably recover spoken meaning. Natural-language queries must support multiple people discussing a topic and return timestamps without requiring manual filter selection.

# Research result

The proposal is in [Entity-aware voice search](../design/2026-10-05-entity-aware-voice-search.md). It compares frozen pretrained multivector retrieval with a maintainer-trained reusable entity binder and conversational-span ranker. It specifies what to embed for names, aliases, supplied profiles, confirmed voice examples, attributed topic contexts, tag definitions/examples, and meeting contexts; it also describes prototype calculation and updates.

Users do not train or fine-tune models. They encode and index their current library. Maintainers may train a reusable model if a defined evaluation shows a benefit, using dynamic entity representations so previously unseen People and Tags work at inference. Natural language is the primary input; clarification is reserved for genuine ambiguity.

# Reasoning

Stable entity relationships preserve attribution while vector representations supply semantic and acoustic relevance. Multi-person discussion needs a bounded sequence of turns with participant evidence, not an impossible requirement that two people are the sole speaker of one turn. Names, mentions, attendance, and confirmed speaking are distinct relations.

The proposal covers primary-source research on dense entity retrieval, speech/style representations, contextual retrieval, late chunking, ColBERT, filtered ANN, and contrastive training. Training plans include hard negatives, randomized name binding, and held-out identities, tags, meetings, and libraries. No model was downloaded or trained for this research.

# Validation and limits

Reviewed wording against the repository writing guide, checked synthetic examples, and checked the Markdown diff. Findings are architecture recommendations, not measured app retrieval results. A speech-semantic model, conversational window policy, optional suggested-association scope, and the benefit of maintainer training remain decisions for later experiments. Today's basic audio vector index and search implementation scope is unchanged.

# Local evaluation dataset

A follow-up evaluation measured how a query finds People. The dataset is built from the maintainer's own library and stays on the maintainer's Mac in the git-ignored `tmp/entity-linking-eval/` folder. It contains real names and speech, so never copy it into tracked files, tests, or documentation.

| Path | Content |
| --- | --- |
| `tmp/entity-linking-eval/dataset.json`, `eval.py` | First synthetic set: 29 people, 37 queries |
| `tmp/entity-linking-eval/v2/build_dataset.py` | Builds `catalog.json` (People names and notes plus 5 synthetic hard cases) and `queries.json` (360 English and Chinese queries, 403 name mentions) |
| `tmp/entity-linking-eval/v2/eval_names.py` | Name-linking ablation; `--models` compares embedding models, `--ner` adds the common-word gate |
| `tmp/entity-linking-eval/v2/extract_speech.py` | Builds `speech.json`: up to 40 sampled 400-character chunks of confirmed speech for each person with at least 1,500 characters |
| `tmp/entity-linking-eval/v2/eval_roles.py` | Role-description test: 15 roles in English and Chinese, ranked against 79 speakers |
| `tmp/entity-linking-eval/v2/*_results.txt` | Latest outputs |

Regenerate with `uv run --no-project --with sentence-transformers --with transformers --with pypinyin --with wordfreq --with jieba python <script>`. Add `--with gliner --with sentencepiece --with tiktoken --with protobuf` for `--ner`, and `--with peft` for Jina v5.

Findings on 2026-10-05:

- Whole-query similarity against People profiles finds the wrong people because the topic words dominate. Phrase-level matching is required.
- Name linking reached 0.98 mention recall and 0.94 exact candidate sets with lexical rules alone: exact and prefix name tokens, fuzzy spelling, pinyin for Chinese characters, initials, and a penalty when an adjacent surname contradicts a record. Pinyin added the most (0.79 to 0.94 found). Embedding models changed name results by at most 1 point.
- A named-entity gate used only for names that are common words removed most false matches in queries without a person, but it missed some lowercase names that are also words, such as "will".
- Role descriptions are hard to resolve from speech alone. The best speech-only result was Jina v5 text nano with query expansion: Recall@5 of 0.93 in English and 0.80 in Chinese. Its CC BY-NC weights block shipping it. Supplied People notes work well where they exist, but the role queries were written from those notes, which inflates that score. The notes-plus-speech fusion also favors people who have notes.
- EmbeddingGemma was not tested because its gated download requires a Hugging Face login.

# Technical debt

None introduced. This task changes research documents only. Entity-aware retrieval, internal relation resolution, and any learned binder/ranker remain explicitly deferred implementation rather than released capabilities.
