---
title: People name matching in library search
date: 2026-10-05
status: implemented
scope: swift-library-search
---

## Problem

Natural-language library queries treated People names as content words. The existing synthetic Preview showed no results for “Alex Morgan release,” despite having that person and content about a release. Names need phrase-level matching before content retrieval, with uncertainty retained rather than silently choosing a record.

## Implemented solution

A reusable in-memory index stores only People IDs and names. It rebuilds when those records change and matches off the main actor. Name forms include both full-name orders, words, Mandarin pinyin, and expansion into records that consist of initials. Queries use native word segmentation, preserve original UTF-16 spans, and bound phrase generation. Exact matches score 1, pinyin 0.97, initials 0.95, prefixes of at least three characters 0.9, and qualifying spelling similarities 0.6–0.95. Scores above 0.906 are confident. Whole-name evidence suppresses conflicting shorter matches while duplicate records remain distinct. Contradictory adjacent name evidence caps word matches at 0.8.

The common-word gate uses bundled English and Chinese word-frequency sets, generated from pinned wordfreq 3.1.1 at Zipf frequency at least 4. It halves common-word matches unless native contextual name detection identifies the phrase. Initials expansions check constituent words too, so ordinary phrases do not become confident initials. The dictionary contains 7,080 English and 8,350 Han-script words (140,192 bytes), with upstream attribution and a separate CC-BY-SA 4.0 data license. The app does not download a model or run Python to search.

Search shows separate People Matches and People Suggestions, each linking to the corresponding Person. Confident spans are removed once to form the content query. Uncertain mentions remain in the query. A name-only query shows People without sending an empty content request. Content results are not labeled as speech by those People: confirmed speaker projection and entity-constrained voice retrieval remain outside this feature.

## Evidence and reasoning

Before UI edits, captured and inspected the ordinary synthetic `40e64af-sidebar-review` Preview in dark appearance. Its search screen had only a content result count and empty state. The design adds a bounded People section above the existing content table, preserving the current search mode and navigation. It does not add filter menus or silently merge duplicate People.

[Apple recommends NLTokenizer for scripts without space-delimited words](https://developer.apple.com/documentation/naturallanguage/tokenizing-natural-language-text), and documents [NLTagger person-name detection](https://developer.apple.com/documentation/naturallanguage/identifying-people-places-and-organizations) and [Mandarin-to-Latin transliteration](https://developer.apple.com/documentation/foundation/stringtransform/mandarintolatin). These run locally. Frequency is a separate signal; lexical part-of-speech tags are not a frequency dictionary. The bundled data retains [wordfreq's upstream notice](https://github.com/rspeer/wordfreq/blob/master/NOTICE.md). The generator is maintained under the Swift client's scripts directory.

## Technical debt

Native segmentation, name detection, and pinyin pronunciation are imperfect, especially for lowercase names, polyphonic Chinese characters, and mixed-language sentences. These limits are accepted to keep this step local and lightweight. Lower confidence remains visible as a suggestion; the original query and matched spans are retained. Remediation: evaluate this implementation against the authorized local evaluation set before changing thresholds or adopting an additional detector. No real evaluation names or speech are copied into tracked files.

For partial matches to multiword names, a whitespace-separated adjacent non-grammatical token is ambiguous without native name evidence. With only the synthetic record “Bo Wang,” “alex wang” therefore scores at most 0.8 and preserves the entire content query. The same conservative rule can turn noun-topic phrases such as “wang budget” into suggestions. Full-name matches, verb/connector contexts, and unspaced Chinese segmentation retain their existing behavior. This is an intentional precision tradeoff; better contextual detection can recover confident partial-name matches without dropping unknown given names.

The frequency dictionary deliberately covers only English and Han-script Chinese words at the recorded threshold. Other scripts can still match names but do not receive equivalent frequency gating. Expanding coverage requires a licensed corpus and language-specific evaluation. The data license applies to the derived resource, not application code.

## Validation

Focused tests cover exact and reversed names, duplicate records, surname conflicts, prefix and spelling suggestions, pinyin and initials, common-word and segmentation safeguards, original-query spans, residual content requests, name-only queries, and People changes. Thirty focused matcher, session, and existing search tests passed in debug with no warnings. Global alias dictionaries, length buckets, cached character arrays, banded edit distance, phrase memoization, and an ASCII transliteration fast path reduced the adversarial 500-record debug workload from 504–617 ms to 242–305 ms for ordinary queries, and from 22.76 s to 261 ms for a 160-word query. Index construction fell from 151 ms to 43 ms. These intentionally similar synthetic names stress spelling candidates; they are not representative user latency measurements. Fifteen focused tests passed in release. For 500 varied synthetic names, the real resolver including bundled dictionary and native analysis took 207 ms cold and 3.43 ms warm. The adversarial catalog built in 33.7 ms; five queries took 129.6, 47.8, 8.58, 8.41, and 8.62 ms, and the 160-word query took 14.35 ms. These are elapsed test timings on this Mac; tests ran concurrently, so first-call values include initialization and contention. No microsecond latency claim is made.

People changes while Voice or Fusion results are visible restart provider preparation using the submitted query, preserving an unsent search-field draft. This covers a name-only query becoming a topic after a rename or deletion, and recovery after preparation failed. The latest-name-resolution barrier prevents an older cancelled resolution from releasing provider preparation early. A final 25-test debug run, including the provider-refresh regression and existing local search tests, passed without warnings. At that checkpoint, the combined release and after-build UI checks were pending; their final outcomes are recorded below. The isolated debug Preview UI check was blocked by a CUA app-selection call that timed out; no after-build visual validation is claimed from that attempt.

The final conservative adjacent-name correction passed all 15 focused matcher/session tests, including unknown lowercase given names, noun-topic ambiguity, full-name confidence, verb contexts, unspaced Chinese, and provider refresh. The correction adds only a bounded per-candidate check; the final combined release validates its optimized build.

The first after-build visual validation attempt was blocked. The UI automation app-selection call stalled for the separate debug bundle; selecting the standard synthetic Preview returned no accessible window. A three-second sample of that Preview showed an idle main event loop, not a sampled layout or persistence stall. The test-only Preview was stopped before final packaging; the installed app was preserved. That attempt produced no screenshot or interaction result for the new People result section.

The final combined release passed on October 6 in 176.24 seconds with no compiler warnings or errors. `make build-macos-preview` ran the release build and packaged revision `40e64af-people-persistence-review`; macOS 26.0 minimum, SDK 27.0, bundle metadata, and strict signature verification passed. Formatting, lint, and `git diff --check` passed. The installed app was not replaced. At release validation, the changes were uncommitted and remote CI had not run. Commit, push, and CI results are recorded separately.

A bounded October 6 retry succeeded with the standard isolated release Preview `40e64af-people-persistence-review`. Screenshots and accessibility checks show that “alex” produces a People suggestion separately from content results, and opening it selects the synthetic person's profile and associated meeting. “Alex Morgan” produces only the confident People match; “Alex Morgan release” retains that match and displays “Topic: release” with three content matches. “schedule” shows three content matches without a People section. The People directory also filters “alex” to one person and displays its count footer. These checks used synthetic records in dark appearance; they do not measure search latency or provider-backed Voice/Fusion behavior. Screenshots are in the task's computer-use output.

## Full-suite scheduling follow-up

The model-conversion validation run saturated the main actor long enough to exceed the session tests' five-second polling deadline. These tests now await the session's published loading completion through a buffered asynchronous signal, with a one-minute test cancellation bound. This changes test synchronization only; matcher and search behavior remain unchanged. The revised session tests passed in the 987-test full-suite run without compiler warnings. The final split-validation run passed all 987 tests outside one separately validated, timing-sensitive live-transcript test.
