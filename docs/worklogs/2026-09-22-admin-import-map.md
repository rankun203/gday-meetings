---
date: 2026-09-22
title: Generate the Payload admin component map before builds
status: released
---

Problem: The initial scaffold left admin/importMap.ts empty. Production builds through 0.3.5 omitted the CollectionCards component, emitting getFromImportMap errors and leaving the authenticated dashboard without collection cards despite returning HTTP 200. Existing API-only upload smoke checks did not exercise dashboard rendering.

Implemented solution: Configure Payload's generator to write the exact TypeScript import map consumed by the layout and page, commit the generated map, and run generation in pnpm build before Next compilation. CI regenerates the map and rejects drift. The native container smoke test authenticates and verifies every collection card before its existing upload/download/delete checks.

Reasoning: Use Payload's own generator for built-in and future custom components. An explicit output path prevents the default importMap.js from diverging from the imported TypeScript file. Generating during compilation embeds the map in the standalone container without runtime writes. A rendered-card assertion catches this HTTP-200 failure mode.

Technical debt: None.

Validation: Reproduced the user's exact CollectionCards warning against the previous production build. The new dashboard assertion fails against that build as expected. The fixed pnpm production build and TypeScript check pass. Against a fresh production SQLite database, the authenticated dashboard renders all five cards and the full upload/download/delete smoke test passes. No missing-component warning appears in the fixed server log. Release 0.3.6 passed the dashboard and file checks inside both native architecture containers (Actions run35693358636). Anonymous registry verification confirms 0.3.6 and latest share digest sha256:8dd34a9875d15515325bc63252b094de7a7c63a56844eb7338c4e151bcfd7a48, with exactly linux/amd64 and linux/arm64.
