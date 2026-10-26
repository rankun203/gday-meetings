---
title: Repository instructions
date: 2026-09-26
updated: 2026-10-22
status: active
scope: repository-workflow
---

# Repository workflow

- If `~/AGENTS.md` exists, read and follow its instructions in addition to this file.
- Push back on user requests when implementing them would require hacks that introduce technical debt.
- Scale planning, review, and validation to the change. Keep small tasks lightweight while completing the checks needed to support the result.

## Understand the task and preserve intent

- Establish the user's intended outcome, constraints, and acceptance criteria before implementing. For new features, cover the complete journey from discovering the action through completion, correction, and returning later.
- Reconcile later corrections with earlier requests and replies. Distinguish accepted decisions, superseded approaches, proposals, and verified behavior. Consult saved conversation history when available context is incomplete; keep private conversation extracts out of tracked files.
- Before revising an existing solution, read its design rationale, relevant worklog, and tests. Preserve intended behavior, including less visible navigation, restoration, recovery, and accessibility capabilities. Explain any necessary tradeoff.
- When the user is still testing and asks to collect feedback, record and organize the issues without replacing the running build or resetting data. Respect any explicit authorization to make changes during testing.
- Keep progress updates concise: findings, decisions, remaining uncertainty, and the next useful check. Ask for clarification when missing information materially affects the outcome; continue independent authorized work where possible.

## Design and investigate

- For bugs, reproduce the failure when practical and distinguish observed evidence from hypotheses. Trace ownership, dependencies, state transitions, and persistence before choosing a fix. Record reproduction limits when the failure cannot be reproduced.
- Fix the cause at the layer that owns the behavior. When several surfaces disagree about the same fact, inspect their shared model and queries before patching each surface separately.
- Define relevant lifecycle states and transitions: initialization, updates, cancellation, failure, retry, completion, dismissal, reopening, and restoration. Include concurrent background work and stale results where applicable.
- Keep changes focused. Prefer supported platform behavior and existing abstractions when they fit; avoid new infrastructure or fixed-value workarounds without evidence that they solve the underlying problem.
- When consolidating or removing an interface or subsystem, inventory its capabilities and preserve the ones users still need. Add regression coverage for behavior at risk.

## Responsiveness and concurrency

- Match performance evidence to the tested source revision and build configuration. Separate measured bottlenecks from suspected causes; compare equivalent workloads before and after changes.
- Reduce repeated computation, scans, and broad invalidation before introducing more concurrency or changing storage technology. Inspect both background work and the cost of publishing its results to the UI.
- Move filesystem access and substantial independent computation off the main actor when suitable. Use immutable inputs, cancellation, and dependency or revision checks so stale results cannot overwrite newer state.
- Keep UI operations on the main actor and state mutations under an explicit ordering model. Coalesce redundant derived refreshes while preserving user-action and Undo ordering.
- Keep view evaluation cheap and scope observation to the consumers that need each change. Cheap, bounded work may stay on the main actor; account for scheduling, copying, and reconciliation costs before moving it.

## Delegation and independent review

- When delegating, give each agent a bounded scope, ownership, shared constraints, and acceptance criteria, including lifecycle and regression checks. Avoid overlapping edits. The primary agent owns integration and final verification.
- Honor explicitly requested review tools and models. Report unavailability rather than silently substituting or claiming the requested review happened.
- Ask independent reviewers to examine architecture, correctness, lifecycle, regressions, and whether each change is necessary. Evaluate findings yourself, fix valid issues, rerun relevant checks, and obtain follow-up review for substantive fixes.
- Summarize material findings, accepted or rejected recommendations and their reasons, resulting changes, and remaining limits.

## Writing (all apps and documents)

- Before making any repository edit, read [docs/writing.md](docs/writing.md).
- Avoid unnecessary secondary labels and descriptions. Let the layout do the explaining.
- Every document must include front matter.
- All UI text and documentation across every app must follow Apple's clarity guidance as summarized in that document. This includes labels, messages, accessibility text, examples, design documents, and worklogs.
- Review all added or changed wording against the guide before finishing. When editing an existing document or UI flow, check its surrounding wording for consistency. Use concrete descriptions and actions; remove vague reassurance and promotional filler.
- Use synthetic, generic content in code, tests, previews, comments, and documentation. Never copy real meeting titles, attendee names, transcript passages, project details, or library identifiers from the user's data into the repository. Reproduce bugs with the smallest synthetic example that preserves the relevant structure.

## UI design before implementation

- Before changing UI, capture and inspect a screenshot of the existing screen and the relevant interaction state. Use the running app or an isolated preview; preserve active recordings and user work.
- Use that evidence to describe the current problem and the intended layout, controls, and behavior before editing UI code. Do not implement a UI change without a concrete design.
- After implementation, capture the changed UI and compare it with the design. Check the affected interactions and record validation limits in the worklog.

## Validation and handoff

- Complete developer-owned checks before handing a build to the user: inspect the diff, perform static review, run meaningful regression tests and mocked-state checks, and exercise the affected workflow where tools permit.
- Test relevant failure, retry, cancellation, stale-response, and restoration cases as well as successful paths. Use tests that protect intended behavior rather than merely mirror implementation details.
- Distinguish compilation, automated tests, rendered UI checks, and interaction checks in the results. Report blocked checks and warnings plainly; a successful build does not establish end-to-end usability.
- Give the user the exact build or commit, a concise change summary, validation results and limits, and a focused test sequence. Reserve user testing for real-world judgments and transitions that remain difficult to verify automatically.
- For Swift macOS changes, validate a release build before finishing. Use `make build-macos` in an isolated checkout if a development bundle is running. Formatting, tests, and debug builds do not replace release validation. Check the macOS CI matrix after pushing and report any failed or unavailable runner.

## Repository and test-data safety

### Real-library trial data

- While the user uses the main app, validate library-dependent changes with an isolated copy of the latest 20 completed meetings. Exclude active captures and incomplete finalization. Preserve the main app, its library, and active work.
- Follow the preparation practice recorded in `docs/worklogs/2026-10-21-people-review.md`: copy relevant voice examples, representations, decisions, and legacy person references restricted to those meetings; omit copied pending tasks, resumable jobs, Undo history, and disposable indexes. Disable remote providers and automatic processing in the copy.
- Use independent files (APFS clones or copies, never hard links or symlinks), a distinct app bundle identity, and an explicit isolated data directory. Check for pending source transactions and verify source files stayed unchanged during capture; discard an inconsistent fixture and retry later. Keep a reproducible baseline and back up trial work before an authorized reset.
- Keep private fixtures, preparation scripts containing local paths, manifests, and builds under ignored `tmp/`. Record aggregate validation results only in tracked documents; use synthetic data in committed tests and previews. Verify the packaged app targets the isolated directory before launching it.

### Repository changes

- This is a single-maintainer repository. Work directly on the default branch (`master`).
- Do not create feature branches or pull requests unless the user explicitly asks for one.
- Use Conventional Commits format for commit messages (for example, `feat: add export support` or `fix(audio): handle device loss`).
- Before committing, inspect the complete diff and run the relevant checks.
- Fix a bug at its cause, reasoning from first principles and established best practice. Do not patch over the symptom.
- Preserve unrelated work. Before staging, inspect ignore rules and ensure private inputs, credentials, caches, and generated artifacts are excluded. After an authorized commit and push, check relevant CI and report the repository state.
- Use isolated test environments and reproducible baselines. Preserve user data and active work; back up the affected test data before an authorized reset and verify the target library or directory.
- Store temporary artifacts and recovery bundles under the repository's ignored `tmp/` directory when appropriate, and verify that Git ignores them. Before a planned interruption, save the necessary source state, artifacts, decisions, validation results, and resume instructions in a durable location.
- For standalone or temporary Python scripts, use `uv run --no-project` and add required third-party packages with `--with` (for example, `uv run --no-project --with httpx script.py`). Use the repository's normal project environment for project-owned Python code.

## Current APIs and deprecations (all apps)

- Prefer the latest stable, supported APIs and platform features across all apps in this repository, while respecting their declared minimum platform versions.
- Treat deprecation warnings as actionable maintenance work. When encountered during development or validation, investigate and migrate affected code to the supported replacement; do not silently ignore or suppress the warnings.
- Check current official documentation for replacement APIs and validate the resulting behavior. Do not introduce deprecated APIs into new code.
- If migration is blocked by a dependency or a supported older platform, document the warning, reason, compatibility fallback, and concrete follow-up in the worklog. Report remaining warnings explicitly; do not describe a build as warning-free when it is not.

## Experiments

- Put new experiments in `experiments/<name>/`, with reproducible scripts, a `README.md` for running them, and a self-contained `RESULTS.md`.
- Structure `RESULTS.md` with Findings, References (brief literature review), Experiment Setup, and results such as comparison matrices; include ablations when useful. Define each method, metric, and other referenced concept in a concise paragraph, and record limitations.
- Maintain `RESULTS.md` as one coherent account of the whole experiment. Integrate each update into the relevant setup, definitions, comparison matrices, findings, and limitations; revise affected conclusions and remove stale or duplicate material. Do not merely append new rounds, progress updates, or chapters. Keep each topic in one clear location and distinguish completed measurements from pending work.
- Keep private inputs, model downloads, and generated artifacts in ignored directories; commit source, synthetic fixtures, and aggregate reports.

## Worklogs

When a task changes repository code, create or update a concise worklog under
`docs/worklogs/` named `YYYY-MM-DD-short-name.md`. Use a YAML metadata header
and record progress, key decisions, results, and blockers as the task evolves,
without repeating information. Do not create a worklog for a task that makes no
repository code changes unless the user explicitly requests one.

Maintain one coherent worklog per task across testing rounds, agents, and
resumed sessions. Update the relevant sections instead of creating a new log
for each iteration. Preserve important earlier reasoning, mark superseded
approaches clearly, and distinguish proposed, implemented, and verified work.
Keep unrelated tasks in their own worklogs.

- **Problem:** what was wrong or missing.
- **User Intention:** record the user's intention in full per topic when it is known from the
  conversation.
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
  migration, validation, release, or remaining-blocker details. Include the
  relevant test results, independent review outcomes, and validation limits.
