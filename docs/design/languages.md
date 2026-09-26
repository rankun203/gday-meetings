---
title: Standard meeting languages
date: 2026-09-26
status: implemented
scope: swift-app-language-selection
---

# Standard meeting languages

Language is a meeting setting. New Recording, meeting details, and Default Language use the same offline list, even without a provider. Provider catalogs describe support; they do not replace the menu.

The standard choices retain the existing eleven app languages and add Italian and Cantonese, preserving the other language families previously exposed by This Mac. English appears once. Regional model variants belong to adapters.

| Choice | Saved code | Preferred This Mac locale | Batch equivalents, in order |
| --- | --- | --- | --- |
| English | `en` | `en-US` | `en`, `en-us` |
| Chinese (Simplified) | `zh-cn` | `zh-CN` | `zh-cn`, `zh-hans`, `zh-hans-cn` |
| Chinese (Traditional) | `zh-tw` | `zh-TW` | `zh-tw`, `zh-hant`, `zh-hant-tw` |
| Cantonese | `yue` | `yue-CN` | `yue`, `yue-cn` |
| Japanese | `ja` | `ja-JP` | `ja`, `ja-jp` |
| Korean | `ko` | `ko-KR` | `ko`, `ko-kr` |
| Spanish | `es` | `es-ES` | `es`, `es-es` |
| French | `fr` | `fr-FR` | `fr`, `fr-fr` |
| German | `de` | `de-DE` | `de`, `de-de` |
| Italian | `it` | `it-IT` | `it`, `it-it` |
| Portuguese | `pt` | `pt-BR` | `pt`, `pt-br` |
| Russian | `ru` | `ru-RU` | `ru`, `ru-ru` |
| Arabic | `ar` | `ar-SA` | `ar`, `ar-sa` |

A listed preference does not establish provider support or recognition accuracy. This Mac checks the exact preferred locale against runtime support and shows unavailable choices without a download action. Its model panel shows installed entries first, with the actual locale. RunPod checks the built-in worker catalog; a website checks its saved or explicitly loaded catalog. Unsupported choices fail before audio upload. Neither Chinese script choice falls back to bare `zh` or the other script.

Existing meeting and default codes are not rewritten. Recognized regional aliases display as the standard choice and new transcription attempts use the mapping above; for example, an old `en-AU` value stays stored but This Mac resolves it to the sole English model, `en-US`. Chinese script aliases resolve explicitly; bare `zh` remains a saved custom value because it specifies no output script. Unknown imported codes remain visible and can submit only when the batch provider reports that exact code.

Before uploading audio, a new transcription attempt stores both the unchanged meeting-language snapshot and the exact resolved provider code. Retries keep the provider code. Older pending attempts without that field retain their original request code; they are not remapped mid-request. Existing submitted jobs and saved results require no language discovery.

Adding a new standard choice requires a catalog entry, explicit adapter mappings, and boundary tests. It does not require changing every meeting's data or adopting a provider's entire regional list. Mixed-language recognition and separate spoken-language/output-script fields remain the broader live-transcription design's future work.
