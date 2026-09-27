---
title: Give the Rust app a distinct bundle name
date: 2026-09-27
status: complete
scope: rust-macos-packaging
---

## Problem

The Rust and native clients both produced `Gday Meetings.app`, causing an installation filename conflict.

## Implemented solution

The Rust build and installer now produce `Gday Meetings Rust.app`. Bundle name and display name, installation documentation, and bundle-launch test fixtures use the new name. Installer staging removes its former generated copy after checking that it is stopped.

## Reasoning

A distinct filename lets both apps coexist in Applications. The source folder, executable, bundle identifier, and existing library paths are unchanged. No installed app is moved or replaced.

## Validation

Shell syntax, source and packaged property lists, release build, and strict signature verification passed. Both packaged name keys read `Gday Meetings Rust`. All three existing CLI parsing tests passed, including Finder launch and explicit arguments using the renamed bundle path. No app launch or installed-app replacement was performed; installer staging cleanup was reviewed without opening Finder.

## Technical debt

Installer cleanup retains the former generated staging filename for compatibility with earlier builds. Remove this cleanup when those installer outputs are no longer supported. The earlier native-app rename worklog describes the temporary filename conflict; this change resolves it.
