#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# ///
"""Measure production builds in a disposable source copy."""

import argparse
import html
import io
import json
import os
import re
import shutil
import subprocess
import tarfile
import time
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def measure(source, mode, output, script="build-macos.sh"):
    events = []
    start = time.monotonic()
    env = dict(os.environ, PS4="+TRACE|${BASH_SOURCE}|${LINENO}| ")
    env.pop("SHELLOPTS", None)
    env["GDAY_BUILD_TRACE"] = str(output / f"{mode}-swift-trace.json")
    command = ["bash", "-x", str(source / "apps/client-macos-swift/scripts" / script)]
    with (output / f"{mode}-{script}.log").open("w") as log:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env,
        )
        for line in process.stdout:
            elapsed = time.monotonic() - start
            log.write(f"{elapsed:.6f} {line}")
            log.flush()
            # Top-level command boundaries; nested substitutions are excluded.
            if line.startswith("+TRACE|") and (
                "/scripts/build-macos.sh|" in line
                or "/scripts/profile-stage.sh|" in line
                or (
                    "/scripts/common.sh|" in line
                    and (
                        "/build-audio-dependencies.sh" in line
                        or "/usr/bin/xcrun swift " in line
                    )
                )
            ):
                parts = line.rstrip().split("|", 3)
                events.append(
                    {"time": elapsed, "label": parts[-1].strip(), "kind": "command"}
                )
            elif "TRACE|" not in line:
                events.append(
                    {"time": elapsed, "label": line.rstrip(), "kind": "output"}
                )
        result = process.wait()
    duration = time.monotonic() - start
    return {"mode": mode, "duration": duration, "exit_code": result, "events": events}


def prepare_staging(source):
    scripts = source / "apps/client-macos-swift/scripts"
    content = (scripts / "install-macos.sh").read_text()
    build = 'bash "$client_dir/scripts/build-macos.sh"\n'
    finder = "echo 'Opening the installer in icon view."
    if content.count(build) != 1 or finder not in content:
        raise ValueError("Installer changed; update the staging profiler.")
    content = content.replace(build, "").split(finder, 1)[0]
    (scripts / "profile-stage.sh").write_text(content)


def append_staging(run, staging):
    offset = run["duration"]
    for event in staging["events"]:
        event["time"] += offset
    run["events"].extend(staging["events"])
    run["duration"] += staging["duration"]
    run["staging_duration"] = staging["duration"]
    run["exit_code"] = staging["exit_code"]


def task_table(run, output, maximum):
    path = output / f"{run['mode']}-swift-trace.json"
    if not path.exists():
        return "<p>No Swift task trace was produced.</p>"
    try:
        trace = json.loads(path.read_text())
    except json.JSONDecodeError:
        return "<p>The task trace is incomplete. See the build log for the failure.</p>"
    tasks = [e for e in trace if e.get("ph") == "X"]
    tasks.sort(key=lambda e: e["ts"])
    rows = []
    for task in tasks:
        start, duration = task["ts"] / 1e6, task["dur"] / 1e6
        name = task["name"].replace(str(output / "source"), "<isolated source>")
        name = name.replace(str(output), "<profile output>")
        label = html.escape(name)
        if len(name) > 180:
            count = name.count(".swift")
            summary = (
                f"Compile {count} Swift source files" if count else name[:120] + "…"
            )
            label = (
                f"<details><summary>{html.escape(summary)}</summary>{label}</details>"
            )
        result = task.get("args", {}).get("result", "unknown")
        if result not in ("success", "succeeded", "unknown"):
            label += f" ({html.escape(str(result))})"
        rows.append(
            f'<tr data-duration="{duration}" data-start="{start}"><td>{label}</td>'
            f'<td>{start:.3f}s</td><td>{duration:.3f}s</td><td><div class="track">'
            f'<span style="margin-left:{start / maximum * 100:.4f}%;width:{duration / maximum * 100:.4f}%"></span></div></td></tr>'
        )
    return (
        f'<details class="tasks"><summary>Swift tasks ({len(tasks)})</summary>'
        "<p>Starts are relative to the Swift task trace, after package resolution. Durations come from build-system task start and finish events. Overlapping bars run in parallel. All bars share the release-build elapsed-time scale.</p>"
        '<label>Find a task <input type="search" class="filter"></label> '
        '<label>Sort tasks <select class="sort"><option value="start">Start time</option><option value="duration">Longest first</option></select></label>'
        "<div class='table-wrap'><table><thead><tr><th>Task</th><th>Start</th><th>Duration</th><th>Timeline</th></tr></thead><tbody>"
        + "".join(rows)
        + "</tbody></table></div></details>"
    )


def package_stages(run, start, end, source):
    """Name package operations from paired SwiftPM output observations."""
    pending = {}
    stages = []
    names = set()
    patterns = [
        ("Download", r"^Fetching (https://\S+)", r"^Fetched (https://\S+)"),
        (
            "Select version for",
            r"^Computing version for (https://\S+)",
            r"^Computed (https://\S+) at (\S+)",
        ),
        (
            "Check out",
            r"^Creating working copy for (https://\S+)",
            r"^Working copy of (https://\S+) resolved at (\S+)",
        ),
    ]
    for event in run["events"]:
        if event["kind"] != "output" or not start <= event["time"] <= end:
            continue
        for action, beginning, ending in patterns:
            match = re.match(beginning, event["label"])
            if match:
                url = match[1]
                names.add(url.rsplit("/", 1)[-1].removesuffix(".git"))
                pending[action, url] = event["time"]
            match = re.match(ending, event["label"])
            if match and (action, match[1]) in pending:
                url = match[1]
                name = url.rsplit("/", 1)[-1].removesuffix(".git")
                version = match[2] if len(match.groups()) > 1 else ""
                if len(version) == 40:
                    version = version[:7]
                label = f"{action} {name}" + (f" ({version})" if version else "")
                description = (
                    "Fetch package source from " + url + "."
                    if action == "Download"
                    else "Resolve the package version and load its manifest."
                    if action == "Select version for"
                    else "Create the local source checkout used by the compiler."
                )
                stages.append(
                    (
                        label,
                        pending.pop((action, url)),
                        event["time"],
                        description
                        + " Timing uses observed start and finish messages.",
                    )
                )
    lockfile = source / "Package.resolved"
    if lockfile.exists():
        pins = json.loads(lockfile.read_text()).get("pins", [])
        names.update(
            pin["location"].rsplit("/", 1)[-1].removesuffix(".git") for pin in pins
        )
    package_names = ", ".join(sorted(names)) or "the configured Swift packages"
    # Retain unobserved manifest/startup time without attributing it to a package download.
    cursor = start
    gaps = []
    for a, b in sorted((stage[1], stage[2]) for stage in stages):
        if a > cursor:
            gaps.append((cursor, a))
        cursor = max(cursor, b)
    if cursor < end:
        gaps.append((cursor, end))
    if gaps:
        stages.append(
            (
                "Load package manifests and validate resolution"
                if stages
                else "Validate cached packages and load manifests",
                gaps[0][0],
                gaps[-1][1],
                f"Packages: {package_names}. Includes Swift startup and manifest work outside the named operations; these internal steps were not separately traced.",
                gaps,
            )
        )
    return stages


def stage_rows(run, output):
    commands = [e for e in run["events"] if e["kind"] == "command"]

    def boundary(predicate, default):
        return next((e["time"] for e in commands if predicate(e["label"])), default)

    native = boundary(lambda x: "/build-audio-dependencies.sh" in x, 0)
    swift = boundary(lambda x: "/usr/bin/xcrun swift build " in x, native)
    production = next(
        (e["time"] for e in run["events"] if "Building for production" in e["label"]),
        swift,
    )
    platform = boundary(lambda x: x.startswith("binary_dir="), run["duration"])
    assembly = boundary(
        lambda x: x.startswith("mkdir -p") and "/Contents/MacOS" in x, platform
    )
    signing = boundary(lambda x: x.startswith("/usr/bin/codesign --force"), assembly)
    verify = boundary(lambda x: x.startswith("/usr/bin/codesign --verify"), signing)
    staging = run["duration"] - run.get("staging_duration", 0)
    source = output / "source/apps/client-macos-swift"
    audio_script = source / "scripts/build-audio-dependencies.sh"
    libraries = []
    if audio_script.exists():
        for name in re.findall(
            r"^build_library (libogg-\S+|opus-\S+|opusfile-\S+)",
            audio_script.read_text(),
            re.MULTILINE,
        ):
            package, version = name.rsplit("-", 1)
            libraries.append(
                f"{'Ogg' if package == 'libogg' else 'Opus' if package == 'opus' else 'opusfile'} {version}"
            )
    library_names = ", ".join(libraries) or "Ogg, Opus, and opusfile"
    stages = [
        (
            "Check tools and app state",
            0,
            native,
            "Check the toolchain and confirm the output app is stopped.",
        ),
        (
            f"Build {library_names} from local archives"
            if run["mode"] == "clean"
            else f"Reuse cached {library_names}",
            native,
            swift,
            "No network download: source archives are checked into the repository. Verify checksums, extract, compile, and install static libraries. Ogg provides container support, Opus the audio codec, and opusfile the decoder. Ogg and Opus build in parallel; opusfile follows. Individual library timings were not recorded."
            if run["mode"] == "clean"
            else "Validate the existing build signature and reuse the installed static libraries. No download or recompilation.",
        ),
    ]
    stages.extend(package_stages(run, swift, production, source))
    trace_path = output / f"{run['mode']}-swift-trace.json"
    tasks = []
    if trace_path.exists():
        try:
            tasks = [
                t for t in json.loads(trace_path.read_text()) if t.get("ph") == "X"
            ]
        except json.JSONDecodeError:
            pass
    # Identify source compilation targets from the measured source snapshot.
    owners = defaultdict(set)
    for sources in [source / "Sources", *source.glob(".build/checkouts/*/Sources")]:
        for path in sources.glob("**/*.swift"):
            relative = path.relative_to(sources)
            if len(relative.parts) > 1:
                owners[path.name].add(relative.parts[0])
    groups = defaultdict(list)
    for task in tasks:
        name = task["name"]
        if name.startswith("Compiling") and ".swift" in name:
            scores = Counter(
                owner
                for file in re.findall(r"[\w+.-]+\.swift", name)
                for owner in owners[file]
            )
            target = scores.most_common(1)[0][0] if scores else "Swift sources"
            label = f"Compile {target}"
        elif name.startswith("Compiling"):
            label = "Prepare imported Swift and C modules"
        elif name.startswith("Compile"):
            label = "Compile native bridges and dependencies"
        elif name.startswith("Link"):
            label = "Link app and dependency binaries"
        elif name.startswith(("Copy", "Process", "Register", "Touch")):
            label = "Prepare package resources"
        elif name.startswith(
            ("Compute", "Gather", "Discovering", "Planning", "Create", "Write", "Scan")
        ):
            label = "Plan targets and prepare compiler inputs"
        else:
            label = "Finalize build outputs and check caches"
        groups[label].append((task["ts"] / 1e6, (task["ts"] + task["dur"]) / 1e6))
    for label, intervals in groups.items():
        first = min(a for a, _ in intervals)
        last = max(b for _, b in intervals)
        merged = []
        for a, b in sorted(intervals):
            if merged and a <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], b)
            else:
                merged.append([a, b])
        stages.append(
            (
                label,
                production + first,
                production + last,
                f"{len(intervals)} tasks across {last - first:.2f}s. Other stages may run at the same time.",
                [(production + a, production + b) for a, b in merged],
            )
        )
    task_end = production + max(
        (b for intervals in groups.values() for _, b in intervals), default=0
    )
    stages.extend(
        [
            (
                "Finish Swift build and locate the executable",
                min(task_end, platform),
                platform,
                "Includes build cleanup and the output-directory query.",
            ),
            (
                "Validate macOS compatibility",
                platform,
                assembly,
                "Check the linked SDK and minimum macOS version; confirm the app is stopped.",
            ),
            (
                "Assemble the app bundle",
                assembly,
                signing,
                "Copy the executable, package resources, icon, configuration, and licenses.",
            ),
            (
                "Sign the app",
                signing,
                verify,
                "Apply the configured code-signing identity.",
            ),
            (
                "Verify the app signature",
                verify,
                staging,
                "Check the completed app signature.",
            ),
            (
                "Prepare the installer",
                staging,
                run["duration"],
                "Copy the signed app and installer assets, add the Applications shortcut, and verify the staged signature.",
            ),
        ]
    )
    return sorted(stages, key=lambda row: row[1])


def render(runs, output):
    maximum = max(run["duration"] for run in runs)
    sections = []
    for run in runs:
        rows = []
        stages = stage_rows(run, output)
        for stage in stages:
            label, start, end, description = stage[:4]
            intervals = stage[4] if len(stage) == 5 else [(start, end)]
            elapsed = sum(max(0, b - a) for a, b in intervals)
            bars = "".join(
                f"<span class='segment' style='left:{a / maximum * 100:.4f}%;width:{max(0, b - a) / maximum * 100:.4f}%'></span>"
                for a, b in intervals
            )
            rows.append(
                f"<tr><td><strong>{html.escape(label)}</strong><div class='description'>{html.escape(description)}</div></td>"
                f"<td>{start:.2f}s</td><td>{elapsed:.2f}s</td>"
                f"<td><div class='track'>{bars}</div></td></tr>"
            )
        sections.append(
            f"<h2>{html.escape(run['mode'].capitalize())} — {run['duration']:.2f}s</h2>"
            + (
                "<p>Compiled app and dependency artifacts were reused. No source compilation ran.</p>"
                if run["mode"] == "cached"
                and not any(stage[0].startswith("Compile ") for stage in stages)
                else ""
            )
            + "<div class='table-wrap'><table><thead><tr><th>Stage</th><th>Start</th><th>Active time</th><th>Timeline</th></tr></thead><tbody>"
            + "".join(rows)
            + "</tbody></table></div>"
            + task_table(run, output, maximum)
        )
    metadata_path = output / "metadata.json"
    metadata = json.loads(metadata_path.read_text()) if metadata_path.exists() else {}
    source_label = html.escape(
        f"Source: {metadata.get('source', 'working-tree snapshot')} · commit {metadata.get('commit', 'not recorded')}"
    )
    summaries = "".join(
        f"<li>{html.escape(r['mode'].capitalize())}: {r['duration']:.2f}s, exit {r['exit_code']}"
        f"<div class='track'><span style='width:{r['duration'] / maximum * 100:.4f}%'></span></div></li>"
        for r in runs
    )
    document = """<!doctype html><!--\n---\ntitle: macOS build timeline\ndate: 2026-10-06\nstatus: generated\nscope: build-profile\n---\n--><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>macOS build timeline</title>
<style>body{font:15px system-ui;margin:32px;color:#202124}.table-wrap{overflow-x:auto}table{min-width:650px;border-collapse:collapse;width:100%;table-layout:fixed}th,td{text-align:left;padding:8px;border-bottom:1px solid #ddd;overflow-wrap:anywhere}th:first-child{width:45%}th:nth-child(2),th:nth-child(3){width:8%}.track{position:relative;height:18px;background:#eee}.track span{display:block;height:18px;background:#2970cc;min-width:1px}.track .segment{position:absolute;top:0}pre{white-space:pre-wrap;overflow-wrap:anywhere}.description{font-size:13px;color:#555;margin-top:4px}summary{padding:12px;cursor:pointer}</style>
<h1>macOS build timeline</h1><p>Measured release builds of the same source. Clean means no checkout-local artifacts; system and network caches remain warm. Cached means an unchanged second build. Named stages show the build from tool checks to installer staging. Compilation stages overlap because targets run in parallel. Bars show periods with at least one task active in each stage, leaving gaps visible. Active time excludes those gaps and counts overlapping tasks once within a stage. Times across stages cannot be added because stages overlap. Task starts are aligned to the observed build-start message, so stage positions are approximate; task durations are measured by the build system. Installer staging runs after successful builds; Finder interaction is excluded.</p>"""
    (output / "timeline.html").write_text(
        document
        + "<p>"
        + source_label
        + "</p><ul>"
        + summaries
        + "</ul>"
        + f"<p>Shared timeline scale: 0–{maximum:.2f} seconds.</p>"
        + "".join(sections)
        + """<script>
for (const panel of document.querySelectorAll('.tasks')) {
  const tbody = panel.querySelector('tbody');
  panel.querySelector('.filter').addEventListener('input', event => {
    const query = event.target.value.toLowerCase();
    for (const row of tbody.rows) row.hidden = !row.cells[0].textContent.toLowerCase().includes(query);
  });
  panel.querySelector('.sort').addEventListener('change', event => {
    const key = event.target.value;
    const rows = [...tbody.rows].sort((a,b) => key === 'duration'
      ? Number(b.dataset.duration) - Number(a.dataset.duration)
      : Number(a.dataset.start) - Number(b.dataset.start));
    tbody.append(...rows);
  });
}
</script></html>"""
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, default=Path(__file__).parent / "artifacts"
    )
    parser.add_argument(
        "--source",
        choices=["working-tree", "committed"],
        default="working-tree",
        help="Choose current files or the committed HEAD snapshot.",
    )
    parser.add_argument(
        "--render-only",
        action="store_true",
        help="Regenerate the report from existing measurements.",
    )
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if args.render_only:
        render(json.loads((output / "timings.json").read_text()), output)
        return
    help_text = subprocess.run(
        ["xcrun", "swift", "build", "--help-hidden"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    if "--experimental-trace-events-file" not in help_text:
        parser.error(
            "This toolchain does not support Swift task traces. Use Swift 6.4 or later."
        )
    source = output / "source"
    if source.exists():
        parser.error(
            "Output already contains a source copy. Choose a new --output directory."
        )
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    # Include current edits, but never copy the user library or local build caches.
    source.mkdir()
    if args.source == "committed":
        archive = subprocess.run(
            [
                "git",
                "archive",
                revision,
                "apps/client-macos-swift",
                "apps/packaging/macos",
            ],
            cwd=ROOT,
            capture_output=True,
            check=True,
        ).stdout
        with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
            bundle.extractall(source, filter="data")
    else:
        shutil.copytree(
            ROOT / "apps/client-macos-swift",
            source / "apps/client-macos-swift",
            ignore=shutil.ignore_patterns(".build", ".swiftpm", ".DS_Store"),
        )
        shutil.copytree(ROOT / "apps/packaging/macos", source / "apps/packaging/macos")
    metadata = {
        "source": args.source,
        "commit": revision,
        "toolchain": subprocess.run(
            ["xcrun", "swift", "--version"], capture_output=True, text=True, check=True
        ).stdout.strip(),
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2))
    prepare_staging(source)
    # Enable the toolchain's task trace only in the disposable copy.
    common = source / "apps/client-macos-swift/scripts/common.sh"
    content = common.read_text()
    old = '/usr/bin/xcrun swift "$@" --package-path'
    new = '/usr/bin/xcrun swift "$@" --experimental-trace-events-file "$GDAY_BUILD_TRACE" --package-path'
    if content.count(old) != 1:
        parser.error("Swift invocation changed; update the profiling injection.")
    common.write_text(content.replace(old, new))
    runs = []
    for mode in ("clean", "cached"):
        print(f"Starting {mode} release build in {source}", flush=True)
        run = measure(source, mode, output)
        if run["exit_code"] == 0:
            staging = measure(source, mode, output, "profile-stage.sh")
            append_staging(run, staging)
        runs.append(run)
        (output / "timings.json").write_text(json.dumps(runs, indent=2))
        render(runs, output)
        print(f"{mode}: {run['duration']:.2f}s, exit {run['exit_code']}", flush=True)
        if run["exit_code"]:
            raise SystemExit(run["exit_code"])
    print(output / "timeline.html")


if __name__ == "__main__":
    main()
