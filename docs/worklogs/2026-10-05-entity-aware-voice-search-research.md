---
title: Entity-aware voice search research
date: 2026-10-05
status: research-complete-name-matching-implemented
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

Reviewed wording against the repository writing guide, checked synthetic examples, and checked the Markdown diff. Findings are architecture recommendations, not measured app retrieval results. A speech-semantic model, conversational window policy, optional suggested-association scope, and the benefit of maintainer training remain decisions for later experiments. The audio vector index remains unchanged by this research. The later [People name matching implementation](2026-10-05-people-name-search.md) adds lexical name resolution and residual content queries; speaker projection, role retrieval, and learned ranking remain deferred.

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

All names and examples below are synthetic stand-ins that preserve the structure of the real cases.

## Findings: finding people by name

Comparing the whole query with each person's profile fails. In the first synthetic set, "alex and amy talked about recent stock market crashes" scored an equity trader and an investor-relations profile at or above "Alexander" on two of three models, because the topic words dominate the vector. Linking must start from short query phrases, each compared with every name.

Results on 360 queries, with half used to tune the cutoff and half to measure it:

| Step added | Names found | Wrong extra people per query | Fully correct |
| --- | --- | --- | --- |
| Exact name words | 0.78 | 0.13 | 0.72 |
| + spelling tolerance | 0.83 | 0.18 | 0.77 |
| + pinyin for Chinese characters | 0.94 | 0.13 | 0.86 |
| + initials and surname-conflict penalty | 0.99 | 0.05 | 0.94 |

- **Pinyin matters most.** Chinese transcripts call a person 浩然 while People stores "Haoran Lin". Converting characters to pinyin, in both name orders, matched all 26 Chinese-character queries.
- **Initials.** A record named only "HT" matches "HT", "ht's update", "Tang Hui", "hui tang", and 唐辉. A similar name, such as "Hui Tan", may rank below it.
- **Extra or conflicting surnames.** "Alexander Wang" finds a record named only "Alexander". When an adjacent surname contradicts a record, that record's score is capped, so "Wang" does not pull in "Bo Wang" or "Nina Wang". A prefix such as "alex" scores 0.90, just under the tuned cutoff of 0.906, so it ranks as a candidate rather than a confident match.
- **Known false matches from initials.** "Lena Zhao" also matches "LZ", and the characters 明讲 in 宇明讲了 read as "ming jiang" and match "MJ". Apply initials only to whole words after Chinese word segmentation.
- **Names that are also common words.** A named-entity detector runs only when the matched text is a frequent dictionary word, such as "grace", "bill", "rose", or 礼物 (pinyin "liwu", matching "Li Wu"). For "how long is the grace period", the detector finds no person, so the match is halved and ranks lower. For "rose talked about the budget", the match keeps its score. Other names, such as "ruoxi", skip the detector. The gate raised queries without a person from 9/14 to 13/14 correct, but it halved some lowercase names, such as "bill talked about chip shortages".
- **Duplicate names.** Two records named "Alex" both appear in results, each labeled with its own record. Records never merge. The walkthrough page previously said an ambiguous name triggers a question; that line came from an earlier filter-menu design and was corrected.
- **Embedding models.** For names, every multilingual model changed results by at most 1 point, because the lexical steps do the work. The cheapest model is enough.

## Findings: finding people by role

Out of scope: search resolves only People names. These results are kept for reference.

Role queries were ranked against 79 people with confirmed speech, using 15 roles asked in English and Chinese. Ground truth came from People notes, which the speech-based methods never saw. In "expanded" queries, the role is rewritten with topics that role usually discusses, for example "backend developer: API, service, database, Java". These expansions were written by hand to simulate an LLM rewrite.

| Model | Names found | Speech only, expanded: top-5 hit (English / Chinese) | CPU time to embed 2,321 chunks | License |
| --- | --- | --- | --- | --- |
| multilingual-e5-small | 0.95 | 0.80 / 0.67 | 27 s | MIT |
| Granite 97M multilingual R2 | 1.00 | 0.73 / 0.67 | 292 s | Apache 2.0 |
| Bekko v1 a8m | 0.99 | 0.67 / 0.60 | 67 s | MIT |
| Bekko v1 a25m | 0.99 | 0.73 / 0.73 | 33 s | MIT |
| Potion multilingual 128M (static) | 0.99 | 0.47 / 0.60 | 1 s | MIT |
| Jina v5 text nano | 0.99 | 0.93 / 0.80 | 133 s | CC BY-NC |
| EmbeddingGemma 300M | Not run | Not run | — | Gated download |

- Raw role phrases scored poorly against speech with every model. Query expansion produced the largest gain.
- Jina v5 text nano performed best, but its non-commercial license blocks shipping it. Bekko v1 a25m and multilingual-e5-small are the practical candidates.
- People notes scored 0.80–1.00 top-5 where present. That score is inflated because the role queries were written from the notes. The notes-plus-speech fusion also favors people who have notes.
- Each query is worth about 0.07, so differences of one or two queries are noise. Times come from single runs; the Granite time is unexpectedly high and needs a repeat.
- EmbeddingGemma needs a Hugging Face login and license acceptance before it can be tested.

## Proposal: audio windows and transcript versions

The current voice index embeds fixed 30-second windows per audio file, keyed by the audio digest, independent of any transcript. Keep that rule and add a second layer:

1. **Audio windows.** Embed each window once per audio digest and model revision. Never rebuild them when the transcript changes. Measure shorter windows, because a 30-second window usually mixes speakers.
2. **Speaker projection.** For each window, record the overlapping turns of the selected transcript revision and their People associations, tagged with the revision ID. This compares time ranges only and runs no model.

When the selected transcript revision changes, such as from Live Transcription to a recorded transcription, or speaker associations change, queue a projection update for that meeting. Discard updates that finish after a newer selection. Only the selected revision drives attribution; combining revisions would double-count turns and produce conflicting speakers. Store transcript-text vectors per revision so switching back does not re-embed.

## Proposal: audio without a transcript

Windows cover the whole audio file, so untranscribed audio is still indexed.

- Topic and style search can return untranscribed windows, labeled as having no transcript and no known speaker. Topic search over audio still requires a speech-semantic encoder; the current vectors describe speaking style.
- Person-constrained search uses only windows with a confirmed turn. The optional suggested-speaker scope can compare a window's voice with saved voice examples and show visibly marked suggested matches.
- Detect speech that no transcript turn covers, report it in index status, for example "12 minutes of speech have no transcript", and offer transcription again.

## Open items

- Segmented initials matching is implemented in [People name matching](2026-10-05-people-name-search.md), with tests for whole-name precedence and Chinese segmentation. Evaluate its remaining native-tokenizer limits against the local dataset.
- Test EmbeddingGemma after authorization, and repeat the Granite timing.
- Choose audio window size, and decide how a query-rewrite step for role descriptions would run locally.
- Update the design document with the phrase-level linking steps and the transcript-revision rules.

# Technical debt

None introduced by this research document. The later name-matching implementation has its own worklog and limitations. Confirmed-speaker retrieval, internal speaker projection, and any learned binder/ranker remain deferred capabilities.
