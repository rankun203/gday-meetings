---
title: Build and install the macOS client
date: 2026-09-27
status: active
scope: macos-setup
---

# Build and install the macOS client

## SwiftUI client (Command Line Tools only)

The native SwiftUI client needs macOS 26 or later and Apple's Command Line Tools with Swift 6.2 and macOS SDK 26 or later. Install the tools with `xcode-select --install`, finish the installer, clone this repository, and run `make install-macos`. Finder opens with **Gday Meetings.app** and an **Applications** shortcut. Full Xcode is optional: its users can also open `apps/client-macos-swift/Package.swift`. For macOS 14.2 or 15, use [v0.3.0](https://github.com/rankun203/meeting-notes/releases/tag/v0.3.0).

Use `make doctor-macos`, `make build-macos`, `make start-macos`, and `make test-macos` for the Swift client. It uses its own library and app identity. See its [guide](../apps/client-macos-swift/README.md) for native recording permissions, server settings, and feature details.

The remaining instructions describe the **Rust/browser client**, which retains the original `make install` command.

## Requirements

- **macOS 14.2 or newer**, with a logged-in desktop session for Finder installation and launching the app. The build targets the current Rust host architecture; it does not create a universal binary. Apple Silicon is the currently validated development platform.
- **Xcode Command Line Tools**: Git, Make, Clang and a macOS SDK (14.2 or newer). Full Xcode is optional. Install with `xcode-select --install`, then finish the installer before continuing. See [Apple's installation instructions](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools).
- **Stable Rust and Cargo**, installed using [rustup](https://rustup.rs). Reopen Terminal after installation, or run `source "$HOME/.cargo/env"`. For an older toolchain, run `rustup update stable`.
- **CMake** for the bundled Opus audio encoder. If using Homebrew, run `brew install cmake`; otherwise install CMake and put its command-line tools on PATH. Homebrew itself is optional. The build script supplies the compatibility policy floor needed by the bundled Opus project on CMake 4.
- Internet access for the first Cargo dependency download, free disk space for Rust build artifacts, and a writable checkout. Initial compilation can take several minutes and build artifacts can occupy several GB.

The client does not require Node.js, pnpm, Python, Docker, a GPU, or the server/worker dependencies. Cargo builds the native audio encoders. Git, Rust, Make and CMake are build-time tools; users do not need them to run the finished app. Media-file import additionally uses `ffmpeg` on the app's PATH. Transcription and AI features require their separately configured services; recording itself runs locally.

## Clone, check, install

After installing the prerequisites:

```sh
git clone https://github.com/rankun203/meeting-notes.git
cd meeting-notes
make doctor
make install
```

`make install` checks prerequisites, compiles the release binary, creates the app bundle, signs it locally, verifies the signature, stages a separate installer copy, and opens a dedicated Finder window in icon view. Drag **Gday Meetings Rust.app** onto **Applications**, then open the installed app. Your default Finder view is unchanged. macOS may request permission for the terminal to control Finder; if declined, the installer opens normally and prints a reminder to press **Command-1** for icon view. Quit an existing copy before replacing it. Finder may request permission to write to Applications; do not run `sudo make`.

Signing is automatic and **ad-hoc**: no Apple Developer account, paid membership, certificate, or provisioning profile is required. This is a local build, not a notarized distribution. Neither these scripts nor the app disable Gatekeeper.

For development, `make start` builds and launches without installing; `make build` only builds. `make doctor` only checks tools and prints versions—it does not install software or change system settings. Build/start/install run the same preflight automatically. If Make itself is missing, install the Command Line Tools first; a Make target cannot diagnose a missing Make executable.

## First launch

The app lives in the menu bar and opens its browser UI on an automatically selected local port. Allow the requested microphone and screen/system-audio recording permissions in **System Settings → Privacy & Security**. Restart the app if macOS requests it. Closing the browser does not quit the client; use **Quit Gday Meetings** in its waveform menu.

Runtime logs are in `~/Library/Logs/Gday Meetings/` (or `GDAY_MEETINGS_LOG_DIR`). **Show Logs** opens the current file in Console.app. Build errors appear in the terminal, not in the runtime log.

## When something fails

Preflight reports missing tools with installation guidance before compiling. Build, signing, verification, installer-copy and Finder failures keep the original command output and exit status, then explain the failed step. Other script failures report the script and line.

| Failure | Action |
| --- | --- |
| Missing Git/Make/Clang or SDK | Finish `xcode-select --install`; check `xcode-select -p` if you already have Xcode. Update Command Line Tools if the SDK is too old. |
| Missing Cargo/Rust | Install Rust through rustup and reopen Terminal. |
| Dependency requires a newer Rust | `rustup update stable`; confirm `rustc --version` in this checkout. |
| Missing CMake | Install CMake and ensure `cmake --version` works. |
| Cargo download failure | Check network/proxy access to crates.io; retry the same command. |
| Packaging/copy failure | Check free disk space and ownership/write access to the checkout. |
| Signing/verification failure | Read codesign's diagnostic, rebuild, and do not install a bundle that fails verification. No certificate should be necessary. |
| Finder cannot open | Use a logged-in desktop session; the message gives the installer directory to open manually. |
| App exits during launch | Read the terminal output and daily runtime log. Remove a fixed `--port` or use `--port 0` for conflicts. |
| Existing app is running | Stop recordings and quit that app before rebuilding/replacing its bundle. |

For a bug report, include `make doctor` output and the failing step's terminal output. Review logs for private meeting information or credentials before sharing them.
