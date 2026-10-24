---
title: Recognition library management — five cases
date: 2026-10-24
updated: 2026-10-24
status: research
scope: people-library-review-and-reference-selection
---

# Recognition library management — five cases

The goal is a useful recognition library with as little human review as possible. Five systems offer complementary lessons: simple person management, incremental grouping, explicit confirmation, controlled reference admission, and selective sample review.

For Gday, the strongest direction is to save identity corrections durably, select clear references that add useful coverage, and ask another question only when its answer can improve recognition or resolve a conflict. Confirm should retire repetitive questions; Ignore and Try Another should offer suitable alternatives.

## Comparison map

| Case | Main unit people manage | Main workflow | Design choice to examine |
| --- | --- | --- | --- |
| Apple Photos | Person and their photos | Name, review suggestions, merge duplicate people, correct membership | Make review optional and make corrections discoverable. |
| Immich | Incrementally formed face cluster | Detect, group, name or merge, process unmatched faces | Bootstrap from dense evidence while accommodating new arrivals. |
| digiKam | Confirmed and unconfirmed face regions | Seed names, recognize, confirm or reject, rebuild derived training data | Explicit evidence states and the cost of exhaustive confirmation. |
| Amazon Rekognition | User plus associated face vectors | Index suitable faces, create user, associate, search, disassociate | Keep identity, samples, admission, and update outcomes separate. |
| FiftyOne | Samples, labels, embeddings, and selected subsets | Inspect similarity, reduce duplication, choose representatives, review difficult cases | Spend annotation effort on useful coverage rather than volume. |

## 1. Apple Photos: correction within an organized library

**Documented workflow.** Photos offers naming, merging duplicate person groups, and an explicit Review More Photos flow with accept/reject choices and Done. Additional review is entered from a person's collection. The iPhone/iPad guide separates choosing a key photo, correcting a misidentified photo, and changing how often a person is featured. Those are different actions with different purposes. [Mac guide](https://support.apple.com/en-gb/guide/photos/phtad9d981ab/12.0/mac/27), [iPhone and iPad guide](https://support.apple.com/en-us/108795).

**Important boundary.** The cited guides explain membership and presentation. They do not document which photos become recognition references, a reference budget, or the effect of a key photo on matching. We should not infer that choosing a thumbnail trains recognition.

**Design lesson for Gday.** A person's meetings can be useful before every voice sample has been reviewed. Keep a clear route to inspect evidence, correct one mistaken association, or merge duplicate people. Use a completion state that allows leaving confidently; maintenance should not be a prerequisite to ordinary meeting use. A chosen display sample should remain separate from the active recognition references.

**Question for discussion:** should People primarily show the person's meetings, with review as a focused secondary action, or foreground outstanding recognition opportunities? The current navigation can support both, but a raw unreviewed count should not imply required work.

## 2. Immich: incremental grouping and conservative discovery

**Documented workflow and mechanism.** Immich extracts face embeddings, indexes them, and uses a DBSCAN-derived process. Dense neighborhoods can establish people; isolated faces can remain unassigned. Incoming faces can join existing people. Incremental processing retains existing clusters, so batching can affect the result. The interface offers naming, merging, hiding, and selecting a feature photo. Its guide suggests manually assigning some unassigned faces followed by a Missing recognition job when starting over would waste existing work. [Facial recognition](https://docs.immich.app/features/facial-recognition/).

**Maintenance choice.** A separate guide proposes building stronger initial clusters with a higher minimum neighborhood size, then lowering it and processing missing faces. It recommends exploring settings before investing in names. This is a documented setup strategy, not evidence that the values suit audio. [Better facial clusters](https://docs.immich.app/guides/better-facial-clusters/).

**Design lesson for Gday.** Start a proposed voice group with clear, coherent evidence and leave weak outliers unresolved. After a correction, re-evaluate relevant unmatched evidence without requiring a global reset. Preserve the distinction between a machine cluster and a person: grouping changes must not invalidate the user's identity decisions.

**Risk to examine.** Density can be inflated by correlated observations. Ten adjacent voice excerpts from one speaker turn are much weaker independent coverage than ten meetings under different conditions. Arrival order and processing boundaries also deserve regression tests.

**Question for discussion:** should a second sample be proposed because it represents another coherent recording condition, rather than because it is another member of the same meeting label?

## 3. digiKam: explicit confirmation and repairable evidence

**Documented workflow.** Detected faces start as Unknown. Naming confirms a face; subsequent recognition produces Unconfirmed suggestions. Confirm accepts the identity, Reject returns it to Unknown, and Delete removes an invalid face region. Ignore is reversible. Ordinary image tags are distinct from face identity tags. The manual warns that one wrong confirmation can produce further wrong suggestions. It also explicitly says rejected faces are not remembered as negative decisions and may be suggested again. [People view](https://docs.digikam.org/en/left_sidebar/people_view.html).

**Quality and maintenance.** The FAQ explains that very small, blurry, or poor-quality faces can be filtered from recognition training. Maintenance distinguishes rebuilding training data from face-tag thumbnails from resetting faces and training, which requires identification again. [Quality FAQ](https://www.digikam.org/documentation/faq/), [maintenance guide](https://docs.digikam.org/en/maintenance_tools/maintenance_faces.html).

**Design lesson for Gday.** Preserve clear unknown, suggested, confirmed, excluded, and active-reference states. Keep durable identity decisions while rebuilding derived representations. A confirmed identity can remain useful for organization even when its audio is unsuitable for recognition.

**Tradeoff to avoid.** Requiring confirmation of every match would conflict with our minimum-review objective. Repeated rejection is also avoidable: Gday should preserve “not this person” against the exact evidence and retain compatible negative decisions across regeneration. Scope exclusions carefully so ignoring one noisy excerpt does not exclude all speech from the person.

**Question for discussion:** should review surface only useful additions and conflicts, with all other unconfirmed associations available in maintenance without contributing to the review count?

## 4. Amazon Rekognition: controlled admission into a person representation

**Documented data model.** Collections retain face vectors and user representations built from multiple associated faces. User representations can capture variation across appearances. Search can target individual faces or users. [Collections](https://docs.aws.amazon.com/rekognition/latest/dg/collections.html).

**Documented workflow.** IndexFaces filters unsuitable images and returns reasons for unindexed faces. AssociateFaces links stored faces to a user, applies a user-match threshold after initial enrollment, returns individual unsuccessful associations, and exposes created/updating/active status. It supports idempotent requests and limits a user to 100 faces. DisassociateFaces removes selected links and returns individual outcomes. These are service contracts; applications own their review interface. [IndexFaces](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_IndexFaces.html), [AssociateFaces](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_AssociateFaces.html), [DisassociateFaces](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_DisassociateFaces.html).

**Design lesson for Gday.** Keep the person record, durable evidence, active reference set, and derived matching representation separate. Report why an assignment produced a new reference, reused coverage, or needs attention. Support safe retry and partial failure without losing the identity correction. A full reference budget should trigger comparison or replacement, rather than a permanent inability to learn.

**Tradeoff to examine.** Admission consistency guards reduce contamination but can reject the new recording condition that caused a recognition miss. A user's exact confirmation and a machine-selected replacement need different treatment. AWS's capacity and score scale are not recommendations for our model.

**Question for discussion:** when a manual correction disagrees with the existing profile, can a trustworthy anchored excerpt be enrolled directly while only uncertain substitutions require one additional review?

## 5. FiftyOne: curation by coverage, difficulty, and redundancy

**Documented capabilities.** FiftyOne separates exact/near duplicates, uniqueness, representativeness, hardness, and likely annotation mistakes. Representativeness identifies typical cluster members; uniqueness identifies less-repeated content. Hardness uses prediction uncertainty, while mistakenness flags possible label errors. These are distinct signals rather than one universal usefulness score. [FiftyOne Brain](https://docs.voxel51.com/brain/index.html).

Its similarity API can find near duplicates, choose a requested number of diverse samples, inspect unique/duplicate views, and remove samples from a similarity index. These support a workflow of selecting a smaller subset for inspection while retaining the source collection. [Similarity API](https://docs.voxel51.com/api/fiftyone.brain.similarity.html).

**Design lesson for Gday.** Select one clear representative per useful voice condition, then consider missing coverage and identity conflicts. Adjacent duplicate excerpts should compete for one opportunity. A more difficult sample should receive attention only when the answer could change a useful decision. Retain all evidence for maintenance while bounding the active profile and the user-facing questions independently.

**Important limit.** These tools do not prove a sample has the correct identity or provide a calibrated voice-confidence score. Extreme novelty can be noise. A desired subset size is a processing budget, not proof that every selected member is useful. Gday should prefer a stopping rule based on remaining value, with capacity as a secondary bound.

**Question for discussion:** can each proposed review have an understandable reason, such as a clearer replacement, another recording condition, or conflicting identity evidence?

## Proposed combined workflow

Combine these approaches into the following workflow:

1. **Discover:** retain source-linked observations and compatible representations. Group coherent voice evidence; leave uncertain and mixed speech unresolved. Separate “stored evidence” from “questions worth asking.”
2. **Identify:** a user names the voice at an explicit scope. Save the person association immediately through the existing durable decision path. A new person does not require a pre-existing recognition profile.
3. **Choose evidence:** use the selected passage as an identity anchor. Compare a small shortlist of clear excerpts supported as the same voice. Prefer a representative sample over a noisy outlier. Record why the selected excerpt is supported by the decision.
4. **Assess contribution:** evaluate whether it adds missing coverage, replaces weaker evidence, or is already represented. Keep the identity decision even when admission is unnecessary or preparation fails.
5. **Ask selectively:** request an answer only for a useful unresolved identity or admission question. Confirm retires redundant questions. Ignore and Try Another explicitly seek alternatives. Stop when no useful question remains; do not refill from every stored turn.
6. **Maintain:** expose active references, associated evidence, excluded samples, and decisions through a secondary view. Support correction, reassignment, exclusion reversal, person merge, and Undo. Merging must reconcile conflicting evidence; splitting a mistaken group must preserve unaffected confirmations.
7. **Refresh safely:** rebuild model-specific representations and derived coverage from durable decisions. Recompute affected profiles after removal or reassignment. Preserve completed status while updating; reject stale background results. A user can leave and return without losing decisions or restarting redundant review.

## Data and lifecycle distinctions

| Concept | What it means | What must remain independent |
| --- | --- | --- |
| Person | Stable identity and profile details | A temporary cluster or display name |
| Observation | Specific audio and support ranges | Other excerpts sharing a diarization label |
| Identity decision | Who the user identified, scope, and provenance | Whether audio is suitable for recognition |
| Representation | Embedding with a compatible model contract | The durable identity decision |
| Active reference | Evidence currently selected for matching | All stored or confirmed evidence |
| Review opportunity | A useful unresolved question | Every unreviewed observation |
| Coverage result | Reason a question is currently redundant | A permanent confirmation or exclusion |

Most of these distinctions already exist in parts of Gday's model. Implementation should consolidate ownership and derived queries before adding records or a new storage system. Persist a new concept only if restoration or provenance requires it.

The hardest transitions are correction after automatic enrollment, removal of the sole supporting reference, mixed-label substitution, a new person with no suitable audio, Undo after background completion, and model replacement. Derived suppression must become invalid when its supporting evidence changes. A confirmed sample removed from the active budget can retain its confirmed identity; removing a person's evidence must not silently transfer confirmation elsewhere.

## Decisions to make together

| Decision | Proposed starting point | Evidence still needed |
| --- | --- | --- |
| Main review count | Count useful opportunities, excluding redundant stored samples | User understanding when counts shrink after confirmation |
| Automatic enrollment after assignment | Enroll suitable same-voice evidence with decision provenance | Mixed-label and cross-condition error rate |
| Replacement confirmation | Ask only when same-voice continuity is uncertain | Reliable continuity policy for short or noisy anchors |
| Review continuation | Action-specific, allowing useful next questions | Completion clarity and repeated-question rate |
| Reference budget | Bounded active set with quality-aware replacement | Accuracy and latency versus reference count |
| Low-similarity correction | Preserve correction; distinguish anchored evidence from uncertain substitution | Contamination risk versus recovery of missed speakers |
| Maintenance | Retain all evidence; show active contribution and its reason | Whether users can repair a mistaken identity without a reset |

## Evaluation plan and limits

Compare the current baseline with quality-only, diversity-only, and combined coverage/quality selection, then add correction priority as an ablation. Use held-out meetings and include unknown speakers, mixed labels, different recording conditions, short speech, and poor audio. Keep correlated excerpts from the same meeting out of the held-out evaluation when that meeting supplies enrollment evidence.

Measure human listening time, questions and repeated questions per person, false identity assignments, missed known speakers, profile contamination, preparation latency, and recovery after correction. Track whether an added reference changes held-out behavior; neither reference count nor a green completion icon establishes improvement.

No product comparison here establishes which policy will win for voice recordings. The strongest transferable lessons are separating durable decisions from derived representations, making corrections reversible, selecting useful evidence, and exposing why further review is needed. Thresholds, reference capacity, and acoustic continuity require local evaluation.

## Research notes

Sources are official product guides, API references, and developer documentation accessed October 24, 2026. The comparison examines documented workflows and algorithms; it does not include hands-on product testing or recognition benchmarks. Versioned documentation can differ from an installed release.

The cases cover both user interfaces and supporting infrastructure. Rekognition and FiftyOne expose enrollment and curation capabilities rather than a consumer People interface. A generic vector database supplies storage and similarity search; the application still owns identity decisions and review workflows.

Apple's public guides do not expose its reference-selection algorithm. Image-system thresholds cannot be transferred directly to voice embeddings. The design lessons are our interpretation of the cited sources; the evaluation plan above describes how to test them for Gday.

The [People voice-library design](2026-10-03-people-voice-library.md) records the agreed behavior and outstanding code issues.
