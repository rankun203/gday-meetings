---
title: Repository instructions
date: 2026-09-26
status: active
scope: repository-workflow
---

# Repository workflow

- Push back on user requests when implementing them would require hacks that introduce technical debt.

## Writing (all apps and documents)

- Before making any repository edit, read [docs/writing.md](docs/writing.md).
- Every document must include front matter.
- All UI text and documentation across every app must follow Apple's clarity guidance as summarized in that document. This includes labels, messages, accessibility text, examples, design documents, and worklogs.
- Review all added or changed wording against the guide before finishing. When editing an existing document or UI flow, check its surrounding wording for consistency. Use concrete descriptions and actions; remove vague reassurance and promotional filler.
- Use synthetic, generic content in code, tests, previews, comments, and documentation. Never copy real meeting titles, attendee names, transcript passages, project details, or library identifiers from the user's data into the repository. Reproduce bugs with the smallest synthetic example that preserves the relevant structure.

## UI design before implementation

- Before changing UI, capture and inspect a screenshot of the existing screen and the relevant interaction state. Use the running app or an isolated preview; preserve active recordings and user work.
- Use that evidence to describe the current problem and the intended layout, controls, and behavior before editing UI code. Do not implement a UI change without a concrete design.
- After implementation, capture the changed UI and compare it with the design. Check the affected interactions and record validation limits in the worklog.

## Branches and validation

- This is a single-maintainer repository. Work directly on the default branch (`master`).
- Do not create feature branches or pull requests unless the user explicitly asks for one.
- Use Conventional Commits format for commit messages (for example, `feat: add export support` or `fix(audio): handle device loss`).
- Before committing, inspect the complete diff and run the relevant checks.
- For Swift macOS changes, validate a release build before finishing. Use `make build-macos` in an isolated checkout if a development bundle is running. Formatting, tests, and debug builds do not replace release validation. Check the macOS CI matrix after pushing and report any failed or unavailable runner.
- For standalone or temporary Python scripts, use `uv run --no-project` and add required third-party packages with `--with` (for example, `uv run --no-project --with httpx script.py`). Use the repository's normal project environment for project-owned Python code.

## Current APIs and deprecations (all apps)

- Prefer the latest stable, supported APIs and platform features across all apps in this repository, while respecting their declared minimum platform versions.
- Treat deprecation warnings as actionable maintenance work. When encountered during development or validation, investigate and migrate affected code to the supported replacement; do not silently ignore or suppress the warnings.
- Check current official documentation for replacement APIs and validate the resulting behavior. Do not introduce deprecated APIs into new code.
- If migration is blocked by a dependency or a supported older platform, document the warning, reason, compatibility fallback, and concrete follow-up in the worklog. Report remaining warnings explicitly; do not describe a build as warning-free when it is not.

## Experiments

- Put new experiments in `experiments/<name>/`, with reproducible scripts, a `README.md` for running them, and a self-contained `RESULTS.md`.
- Structure `RESULTS.md` with Findings, References (brief literature review), Experiment Setup, and results such as comparison matrices; include ablations when useful. Define each method, metric, and other referenced concept in a concise paragraph, and record limitations.
- Keep private inputs, model downloads, and generated artifacts in ignored directories; commit source, synthetic fixtures, and aggregate reports.

## Worklogs

When a task changes repository code, create or update a concise worklog under
`docs/worklogs/` named `YYYY-MM-DD-short-name.md`. Use a YAML metadata header
and record progress, key decisions, results, and blockers as the task evolves,
without repeating information. Do not create a worklog for a task that makes no
repository code changes unless the user explicitly requests one.

- **Problem:** what was wrong or missing.
- **Implemented solution:** what changed and where.
- **Reasoning:** why this approach was chosen, including important tradeoffs or
  rejected alternatives.
- **Technical debt:** state whether the sub-task introduced or retained any
  shortcut, deferred compromise, compatibility bridge, temporary duplication,
  or database/schema debt. For each applicable item, record why it was
  accepted, its operational or maintenance consequence, and the concrete
  future remediation. Write `None` when the assessment found no added or
  retained technical debt.
- **Notes:** optional related context worth preserving, such as compatibility,
  migration, validation, release, or remaining-blocker details.
