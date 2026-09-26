---
title: Rename the packaged macOS app
date: 2026-09-27
status: complete
scope: macos-packaging
---

## Problem

The native app was packaged as Gday Meetings Swift even though its display name is Gday Meetings.

## Implemented solution

Build and installer output now use `Gday Meetings.app`. The bundle name, installer instructions, and setup documentation use the same name. Installation removes the former generated staging copy after checking that it is stopped. The source folder remains `apps/client-macos-swift`.

## Reasoning

The implementation language does not belong in the installed product name. The bundle identifier, executable, library location, and legacy-library migration path stay unchanged so this packaging change does not create a new app identity or lose access to existing data. Historical archive client metadata also stays unchanged.

## Validation

Shell syntax and source property-list checks passed. `make build-macos` built `apps/client-macos-swift/.build/macos/Gday Meetings.app`; packaged property-list validation and strict signature verification passed. The existing Command Line Tools missing linker search-path warnings remain. The app was not launched, and the running installed copy was not replaced. Installer naming and staging cleanup were reviewed without opening Finder.

## Technical debt

The legacy library path and generated installer cleanup retain the old name for compatibility. Remove them only when support for those earlier installations is retired. The Rust and native clients now share a bundle filename; they retain separate identities and libraries and should be installed in different folders when both are needed.
