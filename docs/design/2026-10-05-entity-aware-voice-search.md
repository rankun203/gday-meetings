---
title: Entity-aware voice search with dynamic library representations
date: 2026-10-05
status: research-proposal
scope: long-term-library-search
---

# Recommendation

Use natural-language search over dynamic People, Tag, Meeting, and audio representations. The app resolves names and relations internally, retrieves matching conversational spans, and returns timestamps. Users do not need to select people in filter menus, train a model, or fine-tune it. Maintainers may train a reusable retrieval model if a defined benchmark shows that pretrained encoders are insufficient.

Start with frozen pretrained encoders and separate vectors linked by stable library relationships. Evaluate a learned entity binder and conversational-span ranker later. This is vector retrieval with structured evidence; internal constraints protect an intended identity without requiring a structured user interface. A purely approximate whole-query vector is a useful baseline, not sufficient evidence of who spoke.

For the synthetic query “Alex addressing the search interface flickering issue,” the proposed interpretation is `speaker = person UUID` plus the semantic query “addressing the search interface flickering issue.” The name selects an entity; an embedding ranks content. A generic embedding of the complete sentence cannot guarantee the right person. Someone mentioning Alex, or another person with a similar voice, must not qualify as Alex speaking.

This is a long-term proposal. The current delivery remains basic audio vector indexing and search. Nothing in this document claims the entity-aware path is implemented or validated. Related designs: [audio retrieval models](2026-10-05-audio-search-research.md) and [shared database](2026-10-05-shared-library-database.md).

# Keep four signals separate

| Signal | Appropriate use | What it cannot establish |
| --- | --- | --- |
| Person UUID and confirmed turn association | Exact speaker eligibility | Identity of an unassigned turn |
| Speaker-identity vector | Candidate associations to saved voice examples | Meaning of spoken words or identity certainty |
| Joint speech-style/text vector | Audible delivery, such as quiet or rapid speech | A private person's identity, employment role, or reliable topic meaning |
| Speech-semantic/text vector | Meaning in audio, including words missing from a transcript | Which library person spoke |

CLSP is designed for speaking style. SONAR aligns speech and text for linguistic meaning. Their objectives support separate retrieval branches; they do not demonstrate that one model handles the entire example. Semantic audio retrieval still requires a measured model choice with acceptable licensing and Mac performance. [CLSP authors](https://github.com/yfyeung/CLSP), [SONAR authors](https://github.com/facebookresearch/SONAR).

Do not add or average vectors from these different spaces. A person can have several saved voice examples to cover recording conditions; compare compatible identity vectors against those examples without training a new model. Inferred associations stay distinct from confirmed ones and retain model revision, evidence, and confidence. A similarity score is not a calibrated identity probability.

# What to embed for People, Tags, and Meetings

An entity has a stable UUID plus a **set of representations**, not one permanent vector. Proposed inputs and update rules are below. All profiles and aliases come from supplied library information; inferred traits must not become profile facts.

| Entity representation | Input and calculation | Update behavior |
| --- | --- | --- |
| Person name and profile | Encode canonical name, aliases, and supplied description with a frozen text encoder. Keep alias vectors or exact alias lookup alongside the profile vector. | Re-encode changed text only. Name spelling alone carries little semantic information and cannot distinguish two people with the same name. |
| Person voice examples | Encode confirmed, clean audio examples with the compatible speaker-identity encoder. Keep several examples or a small set of clusters across recording conditions. | Add/remove examples using their source digests and association provenance. Never turn unconfirmed matches into training labels automatically. |
| Person topic contexts | Encode confirmed attributed utterances or conversational contexts with a semantic encoder. Retain representative clusters, with links to original spans. | Incrementally replace changed spans; recompute affected prototypes. Use as contextual evidence for entity disambiguation, not as a rule that the person can only discuss past topics. |
| Tag definition | Encode tag name, aliases, and user-supplied definition together; keep exact tag membership separately. | Re-encode definition changes immediately. A name-only tag has weak semantic context until examples or a definition exist. |
| Tag examples | Encode actual tagged meeting passages, summaries, or audio-semantic spans, respecting their provenance and granularity. | Keep multiple topic prototypes for a broad tag. Meeting-level membership does not prove every sentence is about the tag's subject. |
| Meeting context | Encode title, summary, and separate passage/conversation vectors. Store date and participant relations as metadata. | Re-encode only changed content. A meeting centroid is candidate retrieval context, not timestamp evidence. |

For normalized compatible vectors `v_i`, an optional prototype is `normalize(sum(w_i * v_i))`. Weights can bound per-meeting influence and exclude low-quality or overlapping voice examples. Keep the supporting vectors: a single mean can erase distinct topics, languages, or microphone conditions. Cluster within one embedding space, retain a capped number of medoids or normalized centroids, and compare maximum or top-m mean similarity as benchmarked alternatives. These are proposed aggregation rules, not trained claims. Clustering, encoding, and rebuilding prototypes are indexing work, not end-user model training.

Never average a name vector, a speaker-identity vector, and a CLSP vector. They are different spaces. Even when a profile and transcript share a text space, retain their roles so topic similarity cannot replace identity evidence. A normalized centroid needs recomputation when its members are removed; keep source sums/counts or recompute from the retained bounded examples rather than averaging centroids equally.

The dynamic binding is `name/alias → entity UUID → related vectors and spans`. A name can change without changing the person's audio vectors. A new person or tag needs only frozen encoding and relationship indexing. Dense entity retrieval provides precedent for describing entities at inference rather than using a fixed classifier output for every known entity. “Zero-shot” here means a trained retriever can encounter new entities; it does not mean the retriever itself was never trained. [Dense entity retrieval paper](https://arxiv.org/abs/1911.03814).

# Query interpretation remains retrieval

1. Search the current People, Tags, and Meetings names and explicit aliases. Prefer exact normalized matches; use lexical or embedding retrieval of entity descriptions only to suggest candidates for misspellings and indirect descriptions. Retain the original query.
2. Resolve the relation as well as the entity: **spoken by**, **mentions**, **meeting includes**, and **tagged with** are different scopes. Natural phrasing is the primary input. A bounded parser or learned retrieval binder can select candidate entities and relations internally; it must only refer to existing IDs and abstain when uncertain. It does not need an autonomous tool loop.
3. For an unambiguous query, search immediately. The interface may show a compact interpretation for correction, but selecting chips or filters is never a prerequisite. Only genuinely ambiguous identities or relations need clarification. An ambiguous name never silently combines different People records.
4. Evaluate hard constraints before ranking. Run lexical, speech-semantic, and optional style retrieval over eligible evidence. Apply every constraint to every provider before publishing its first snapshot.
5. Fuse relevant branches and return playable spans with their meeting, speaker association, and match source. No result-generation model is required.

Entity linking research demonstrates retrieving candidate entity descriptions separately from mention context, followed by disambiguation. BLINK is evidence for that architecture, not a recommended dependency: its released Wikipedia setup does not establish performance on a private People Library. Start with the smaller local catalog and explicit aliases. [BLINK authors](https://github.com/facebookresearch/BLINK).

“Alex and Sam talk about interface design” should retrieve a conversation window containing contributions from both resolved people, with topic evidence in that window. It should not require both people to be the sole speaker of one turn, nor settle for both names on a meeting's attendee list. Start candidate windows at turn boundaries, extend through nearby responses, and bound duration and gaps. Compare several window sizes on held-out data; no universal duration is established here. Return the window timestamp and each person's supporting turn timestamps. A response such as “yes, that approach works” may contribute through conversational context without repeating the topic. Distant turns on unrelated subjects cannot jointly satisfy the query.

Distinguish this conversational relation from “Alex or Sam,” “Alex mentions Sam,” and “meetings with Alex and Sam.” Infer it internally when clear; request clarification only when needed. An ambiguous tag name that is also an ordinary topic must not silently become a hard tag constraint.

Unknown names, no eligible turns, and incomplete indexing produce distinct states. Never remove a person or tag constraint to fill the result list. An explicit **Include Suggested Speaker Matches** option could later broaden association evidence, with suggested results visibly marked. It must not rewrite People records.

# Evidence and ranking granularity

Use a stable audio span reference: meeting ID, track ID, start/end, audio digest, and preprocessing revision. Link spans to speaker turns and association revisions. A topic match must overlap the selected person's speech, not merely occur elsewhere in a meeting that lists the person as an attendee. A summary match can establish meeting relevance but cannot manufacture a timestamp or attribute the summary's topic to that person.

For windows that include multiple speakers, retain each turn interval. Restrict playback to eligible overlapping turns or clearly identify mixed speech; do not label an entire mixed window as one person's voice. If embeddings are too coarse to distinguish who discussed the topic, return meeting-level evidence or report the limitation. Smaller turn embeddings and bounded neighboring context are candidates to evaluate.

Apply reciprocal rank fusion only after constraint enforcement. Fuse timestamped evidence first, then group by meeting while retaining the best eligible spans. One provider gets one contribution per deduplicated span; overlapping windows must not win merely through repetition. Do not let a text match from one speaker and a style match from a different speaker jointly satisfy one query. RRF combines rankings; it does not enforce conjunction or create missing evidence. [Original RRF paper](https://cormack.uwaterloo.ca/cormack/cormacksigir09-rrf.pdf).

Exact similarity over a filtered subset is the first baseline. A global top-k followed by filtering can miss valid results outside that initial pool. Later ANN adoption needs filter-aware retrieval or measured adaptive expansion with explicit limits, checked against exhaustive filtered search. ACORN provides a research example of predicate-aware graph traversal; it is not a decision to add another database. [ACORN paper](https://arxiv.org/abs/2403.04871).

# Alternatives worth evaluating

| Approach | Value without end-user training | Limit and decision |
| --- | --- | --- |
| Separate vectors for topic, style, entity descriptions, and identity | Each representation has a clear purpose; library updates do not retrain models | Recommended foundation. Keep spaces and ranking evidence separate. |
| Deterministic context on text chunks | Existing meeting title, confirmed speaker label, and tag descriptions can improve contextual matching | Supplement only. Names in text are not identity guarantees; metadata changes can require text re-embedding. Preserve raw transcript separately. |
| Model-generated context | May resolve references before embedding | Not the default: extra generation cost and possible invented attribution. Research only with provenance and correction rules. |
| Late chunking | Embeds text in document context before pooling individual chunks; proposed method works without additional training | Text experiment for pronouns and neighboring context, not proof of audio or person identity. Requires a compatible long-context encoder. |
| ColBERT-style late interaction | Keeps token-level vectors and compares query tokens to document tokens | Potential topic reranking improvement, but higher storage and compute. A released pretrained model could be used without user fine-tuning; token matches still cannot enforce speaker relations. |
| One concatenated name/topic/audio vector | Simple interface | Reject as an identity constraint: approximate similarity can trade off the wrong person against a strong topic match, and unrelated embedding spaces are incompatible. |

Context prepending is supported by Anthropic's contextual retrieval experiments, but those text-corpus results do not establish gains on meeting audio. Late chunking and ColBERT address different losses of context: chunk boundaries and token-level matching. Evaluate them separately after the exact filtered baseline. [Contextual retrieval](https://www.anthropic.com/engineering/contextual-retrieval), [late chunking paper](https://arxiv.org/abs/2409.04701), [ColBERT paper](https://arxiv.org/abs/2004.12832).

# Frozen and learned designs

**Training-free library adaptation:** use pretrained text, speech-semantic, style, and identity encoders without updating their weights. Retrieve candidate entities from their names/descriptions and candidate audio spans from their separate vectors. Bind entity candidates to stored turn relationships, form conversational windows, and score topic relevance plus requested participant coverage. This can be implemented as deterministic stages or a fixed inference graph; it remains search. It supports new library entities immediately, but pronouns, unusual names, relation parsing, and subtle conversation relevance need measured handling.

**Pure approximate multivector retrieval:** represent a conversation by topic vectors, contextual text vectors containing supplied names, and participant/profile vectors; score query parts against these vectors using late interaction. This may improve candidate recall without an explicit first entity-resolution stage. It also risks satisfying “Alex” through a mention and “design” through another speaker, or preferring a namesake. Role-tagged vectors and provenance checks are still needed for attribution. ColBERT demonstrates token-level late interaction for text, not a ready-made guarantee for this entity/audio task. The comparison should test this approach rather than rule it out, with wrong-person errors reported separately from topic relevance.

**Maintainer-trained reusable model:** train a binder/ranker on query, dynamic entity descriptions, attributed turns, and conversational windows. Candidate entity descriptions and example vectors are inputs at inference; entity UUIDs are lookup references, not learned fixed classes. Use shared encoders or small learned projections within a documented compatible architecture, with role and temporal encodings for “speaker,” “mentioned person,” “tag,” and “turn.” A learned projection can align useful representations, but arbitrary cross-space vector addition is not an alternative to training it.

An initial learned system could leave the large audio encoders frozen and train a small scoring head or late-interaction module over cached representations. It would rank a bounded candidate set and predict evidence coverage for each requested participant. A later dual encoder could distill that ranker for faster first-stage retrieval. These are proposed architectures, not models verified to solve the task. Keeping candidate retrieval and reranking separate also exposes misses that a ranker cannot recover.

## Training task and data

Train on natural-language query and relevant timestamp-window pairs, with entity references grounded in the accompanying temporary catalog. Include one-person topics, two-person discussions, speaking versus mentioning, tag meanings, aliases, and ASR omissions. Use licensed or consented multi-speaker recordings and supplied annotations; synthetic text can expand query wording but cannot establish real audio relevance. Do not require users to curate a training dataset.

Create hard negatives that differ in one requirement: right topic/wrong speaker, right people/wrong topic, one of two people absent, a person only mentioned, both people elsewhere in the meeting, same-name distinct entities, and correct tag words without actual requested membership. Avoid treating another valid window from the same conversation as a negative. Contrastive query-positive-negative losses are available in Sentence Transformers, but loss choice does not repair incorrect relevance labels. Add relation/participant-coverage supervision and evaluate whether it improves the compositional task. [Official contrastive-loss documentation](https://sbert.net/docs/package_reference/sentence_transformer/losses.html).

Randomize synthetic names and catalog IDs consistently within examples, swap aliases, and counterbalance topics across speakers. This discourages memorizing “Alex talks about design.” Hold out people, names, tag definitions, meetings, and libraries—not just query paraphrases. Test unseen entities and renamed entities using new descriptions at inference. Include unfamiliar names, homonyms, and missing profile text. Compare against the frozen baseline and exact relational evidence before accepting any gain.

No user performs post-training or fine-tuning. The app downloads a versioned reusable model and only encodes its current library. Maintainer training uses a separate, explicitly authorized corpus; private libraries and search corrections are not uploaded automatically. Trained weights can memorize training data, so removing a record from a training corpus does not imply its influence vanished from weights. Use an appropriately governed reusable corpus and track training provenance. Local derived embeddings remain sensitive artifacts, with the same deletion and access rules as their source material.

Start with cached frozen features to bound training cost, then benchmark small heads against full encoder training. Record training hardware/time, dataset size, artifact size, cold/warm inference, and re-index requirements. No justified sample-count or accuracy promise exists yet. Ship a learned variant only if it generalizes to unseen libraries and improves wrong-person, relation, and timestamp metrics—not just aggregate semantic similarity.

# Storage and changes

Keep authoritative names, aliases, tags, associations, and meeting records in their existing folder documents. Persist embeddings and reproducible manifests in the data folder. Project entity lookup, span relationships, and provider vectors through the shared database access layer into namespaced `index.db` tables. The generated `index.db.md` describes installed schemas. Cloud folders sync source artifacts; each Mac retains its own SQLite indexes.

The proposed search request carries immutable entity IDs, relation operators, association policy, and a library revision alongside the semantic query. Providers advertise which constraints and modalities they support. A provider that cannot enforce a required constraint is excluded with an explanation, never allowed to publish unconstrained hits. Streams retain request IDs, sequence numbers, cancellation, and final/partial coverage state.

| Library change | Required behavior |
| --- | --- |
| Rename | Preserve UUID; update lookup/display immediately. Keep an old alias only through an explicit alias policy. Raw audio vectors need no rebuild. |
| Merge | Redirect old IDs to the surviving record, preserve association provenance, and deduplicate hits. Do not automatically retain contradictory confirmed associations. |
| Delete or unassign | Remove eligibility promptly and invalidate affected in-flight queries. Do not turn an already resolved deleted person into an unrestricted query. Source audio may remain searchable without that attribution. |
| Correct speaker or labeling | Reproject affected turn relationships using revisions; reuse audio embeddings only when their actual audio window is unchanged. |
| Change tags or meeting title | Update relational filters and entity lookup; rebuild only context embeddings that depended on the changed fields. |
| Change audio or encoder | Invalidate incompatible artifacts by digest/model/preprocessing version. Identical dimensions alone do not establish compatibility. |

Late events based on an older association revision must not resurrect removed attribution. Rebuild publication should preserve a coherent generation while changed or deleted entities are excluded immediately. Heavy encoders and optional ANN structures load on demand. Introduce `index-l2.db` only after contention or startup measurements justify it.

# Evaluation and cost limits

Build a consented or synthetic fixture with at least two similar voices, duplicate names, renamed/merged/deleted entities, aliases, overlapping turns, several tags, and withheld transcript words. Test the same topic spoken by the wrong person, one person mentioned by another, a person attending but not speaking, and a relevant summary with no supporting attributed span. Use explicit judgments of speaker, topic, timestamp, and tag correctness.

Compare lexical-only, unfiltered whole-query embeddings, entity-filtered semantic retrieval, separate style retrieval, and constrained fusion. Measure wrong-person rate separately from Recall@10 and nDCG@10. Check ambiguity abstention, filtered ANN recall against exhaustive search, deletion freshness, and streaming reordering/cancellation. Mutation invariants must pass exactly; approximate semantic relevance is assessed separately.

Start with bounded exact scans, paged vector reads, one active local inference job, cancellation, and a bounded candidate pool for any reranker. Record cold/warm query latency, first useful result, memory, index throughput, artifact growth, and idle/startup overhead. Example storage arithmetic: 100,000 float32 vectors at 512 dimensions use 204.8 MB before metadata or index overhead; additional representations add their own cost. Token-level multivectors multiply storage by the retained token count. These are estimates, not measured app performance targets.

Do not load every model at launch or run an entity-resolution model for an unambiguous explicit filter. Do not adopt a larger model, multivector index, or L2 database until it improves held-out retrieval enough to justify measured cost.

# Decisions for a later implementation

- Default to confirmed speaker associations; decide whether suggested associations belong in an explicit optional scope.
- Choose the supported natural-language relations and ambiguity interaction; natural language remains the primary input without mandatory filter selection.
- Measure a deployable speech-semantic encoder separately from CLSP, including languages and licensing.
- Decide span/window sizes and mixed-speaker evidence presentation using retrieval tests.
- Compare frozen multivector retrieval against a maintainer-trained reusable binder/ranker on unseen entities before committing to training. End users only encode and index their library.

# Technical debt

None introduced by this research-only proposal. Existing limitations remain: voice-style embeddings do not supply spoken semantic retrieval, and the current basic vector search does not implement entity-aware constraints. No model, dependency, schema, or source-code change is included here.
