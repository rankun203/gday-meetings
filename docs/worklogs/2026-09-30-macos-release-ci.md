---
title: macOS release builds across toolchains
date: 2026-09-30
status: in-progress
scope: macos-build
---

# macOS release builds across toolchains

## Problem

A source install failed at three `locked` closures where a local `policy`
binding shared the instance property's name. A fresh release build accepted
the same expressions with Apple Swift 6.4. The failing compiler version was
not recorded, so the exact toolchain difference remains unconfirmed. Previous
Preview builds already used release configuration; the repository had no
macOS CI workflow.

## Implemented solution

- Qualify all three property reads as `self.policy` in `AudioCapture.swift`.
- Build and ad-hoc sign the release app on every push, pull request, and manual
  workflow run. Independent Apple Silicon jobs use `macos-15`, `macos-26`, and
  `xcode-27`, with `fail-fast: false` and no build cache restoration.
- Put reusable build steps in `.github/actions/build-macos/action.yml` and the
  workflow in `.github/workflows/macos-build.yml`. Record OS, architecture,
  developer directory, Swift, and SDK versions in each job.
- Require local release validation for Swift changes in repository guidance.
- Select Xcode 26.0.1 on macOS 15, whose default Xcode predates the APIs used
  by the app. Require Swift 6.2 and macOS SDK 26 in source-build preflight and
  documentation. Keep the macOS 14.2 runtime deployment target unchanged.

## Reasoning

Explicit property access removes the ambiguous local binding without changing
locking or audio behavior. Different OS and compiler images cover failures
that a single local release build cannot detect. GitHub discovers workflows
under `.github/workflows`; `.github/actions` holds the requested reusable action.
macOS 15 precedes 26, so there is no macOS 25 leg. The macOS 27 image currently
uses the `xcode-27` preview label. All three jobs are required by the workflow;
preview failures are not ignored.

Runner labels and host versions were checked against the official
[runner inventory](https://github.com/actions/runner-images) and
[Xcode 27 image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

## Technical debt

- The matrix uses Xcode 26.0.1 on macOS 15 and default Xcode on newer images,
  and covers Apple Silicon only.
  This provides three independent environments without downloading toolchains,
  but does not establish compatibility with every supported Swift version,
  Command Line Tools installation, or Intel Mac. Add explicit older compiler
  and Intel jobs when expanding compatibility coverage.
- macOS 27 uses a preview runner that may change or become unavailable. Replace
  its label with the stable macOS 27 label when GitHub publishes one.

## Notes

`make format-macos`, `make lint-macos`, and diff whitespace checks passed.
An isolated checkout containing only the committed sources and three Swift
fixes passed the full release build, Info.plist validation, ad-hoc signing, and
signature verification with Apple Swift 6.4. Existing unrelated working-tree
edits were excluded from this build and commit.

Both CI YAML files parsed. Actionlint 1.7.12 passed with a command-line exception
only for its outdated unknown-`xcode-27` diagnostic; GitHub documents that label.
No lint suppression was added to the repository. Independent agent review
confirmed the matrix, action, permissions, and pinned checkout reference.
The build preflight passed shell syntax validation, the local toolchain check,
and six synthetic compiler, SDK, and runtime version cases.

Local compilation retains missing Command Line Tools search-directory linker
warnings. The bundled Autoconf probes also report that `-single_module` is
obsolete, then reject that flag; the actual builds do not use it. These are
existing toolchain/vendor diagnostics, not new app deprecations. Follow-up:
update or repair Command Line Tools for the missing paths and refresh bundled
upstream configure scripts when dependency releases remove the obsolete probe.

Hosted matrix validation is pending the push. The original failing compiler
remains unidentified, so its exact installation cannot yet be reproduced.
