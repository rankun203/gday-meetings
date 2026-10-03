"""Validate Instruments XML and aggregate observed CPU and accelerator intervals."""

import hashlib
import json
import math
import os
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path

TABLES = {
    "cpu": "time-profile",
    "ane": "ane-hw-intervals",
    "gpu": "metal-gpu-intervals",
    "coreml": "coreml-os-signpost",
}


def tree_bytes(base):
    total = 0
    for root, dirs, files in os.walk(base, followlinks=False):
        dirs[:] = [d for d in dirs if not (Path(root) / d).is_symlink()]
        for name in files:
            p = Path(root) / name
            try:
                if not p.is_symlink():
                    total += p.stat().st_size
            except FileNotFoundError:
                pass
    return total


def atomic_json(path, value):
    if path.is_symlink():
        raise ValueError("Cannot replace a symlink")
    temp = path.with_name(path.name + ".tmp")
    # Exclusive creation also prevents overwriting a stale or substituted temp file.
    with temp.open("x") as f:
        json.dump(value, f, indent=2, allow_nan=False)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def xml_rows(path, expected):
    """Resolve shared XML values before discarding rows; reject missing schemas."""
    ids, cols, schema_seen = {}, [], False
    with path.open("rb") as stream:
        for _, e in ET.iterparse(stream, events=["end"]):
            if e.tag == "schema":
                if schema_seen or e.get("name") != expected:
                    raise ValueError(f"Unexpected schema in {path.name}")
                cols = [c.findtext("mnemonic") for c in e.findall("col")]
                schema_seen = True
            if e.get("id"):
                value = {"text": e.text, "fmt": e.get("fmt", "")}
                if e.tag == "process":
                    child = e.find("pid")
                    if child is not None:
                        pv = ids.get(child.get("ref") or child.get("id"))
                        if pv and pv["text"] is not None:
                            value["pid"] = int(pv["text"])
                ids[e.get("id")] = value
            if e.tag == "row":
                if not schema_seen or len(e) != len(cols):
                    raise ValueError(
                        f"Missing schema or mismatched row width: {path.name}"
                    )
                values = []
                for child in e:
                    ref = child.get("ref")
                    if ref and ref not in ids:
                        raise ValueError(f"Unresolved XML reference in {path.name}")
                    values.append(
                        ids.get(
                            ref or child.get("id"),
                            {"text": child.text, "fmt": child.get("fmt", "")},
                        )
                    )
                yield dict(zip(cols, values))
                e.clear()
    if not schema_seen:
        raise ValueError(f"Missing {expected} table, not an observed zero")


def union_seconds(intervals, duration):
    total, end = 0.0, 0.0
    for start, stop in sorted(intervals):
        start, stop = max(0.0, start), min(duration, stop)
        if stop > start:
            total += max(0.0, stop - max(start, end))
            end = max(end, stop)
    return total


def interval(row):
    start = int(row["start"]["text"]) / 1e9
    delta = int(row["duration"]["text"]) / 1e9
    if delta < 0:
        raise ValueError("Negative interval duration")
    return start, start + delta


def parse_accelerators(paths, duration, app_pid):
    all_gpu, ane, nemotron = [], [], []
    processes, channels = defaultdict(list), defaultdict(list)
    states, counts, labels = Counter(), Counter(), defaultdict(Counter)
    process_ids, app_gpu = {}, []
    app_count, nemotron_count = 0, 0
    for row in xml_rows(paths["gpu"], TABLES["gpu"]):
        state = row["state"]["fmt"]
        states[state] += 1
        if state != "Active":
            continue
        span = interval(row)
        proc = row["process"]["fmt"] or "Unattributed"
        pid = row["process"].get("pid")
        if pid is not None:
            process_ids[proc] = pid
        label = row["event-label"]["fmt"]
        processes[proc].append(span)
        channels[row["channel-name"]["fmt"]].append(span)
        all_gpu.append(span)
        counts[proc] += 1
        labels[proc][label.split("  ")[0]] += 1
        if pid == app_pid:
            app_gpu.append(span)
            app_count += 1
            if "Nemotron" in label and "MpsGraphInference" in label:
                nemotron.append(span)
                nemotron_count += 1
    ane_states, ane_count = Counter(), 0
    for row in xml_rows(paths["ane"], TABLES["ane"]):
        ane_states[row["state"]["fmt"]] += 1
        ane_count += 1
        if row["state"]["fmt"] == "Active":
            ane.append(interval(row))
    coreml_count = sum(1 for _ in xml_rows(paths["coreml"], TABLES["coreml"]))

    def metric(spans):
        seconds = union_seconds(spans, duration)
        if not math.isfinite(seconds) or not 0 <= seconds <= duration + 1e-6:
            raise ValueError("Invalid interval union")
        return {"union_s": seconds, "active_fraction": seconds / duration}

    gp = metric(all_gpu)
    ne = metric(ane)
    return {
        "duration_s": duration,
        "states": dict(states),
        "gpu_active_union_s": gp["union_s"],
        "gpu_active_fraction": gp["active_fraction"],
        "gpu_app_intervals": app_count,
        "gpu_app_union_s": metric(app_gpu)["union_s"],
        "nemotron_intervals": nemotron_count,
        "nemotron_union_s": metric(nemotron)["union_s"],
        "processes": {
            p: {"count": counts[p], **metric(spans), "labels": labels[p].most_common(8)}
            for p, spans in processes.items()
        },
        "process_ids_private": process_ids,
        "channels": {c: metric(spans) for c, spans in channels.items()},
        "coreml_rows": coreml_count,
        "ane_intervals": ane_count,
        "ane_states": dict(ane_states),
        "ane_union_s": ne["union_s"],
        "ane_active_fraction": ne["active_fraction"],
        "scope": {
            "gpu_app": "Exact attached app PID",
            "gpu_nemotron": "Exact app PID and inference command label",
            "gpu_system": "All processes represented in the GPU table",
            "ane": "System-wide; no model attribution",
        },
    }


def toc_info(path, app_pid):
    root = ET.parse(path).getroot()
    runs = root.findall("run")
    if len(runs) != 1:
        raise ValueError("Expected exactly one trace run")
    run = runs[0]
    process = run.find("./info/target/process")
    if process is None or int(process.get("pid", "-1")) != app_pid:
        raise ValueError("Trace target does not match attached app PID")
    summary = run.find("./info/summary")
    duration = float(summary.findtext("duration"))
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("Invalid actual trace duration")
    schemas = {t.get("schema") for t in run.findall("./data/table")}
    if not set(TABLES.values()) <= schemas:
        raise ValueError("Trace is missing a required instrument table")
    return {
        "duration_s": duration,
        "start": summary.findtext("start-date"),
        "end": summary.findtext("end-date"),
        "end_reason": summary.findtext("end-reason"),
        "instruments_version": summary.findtext("instruments-version"),
    }


def samples(path):
    ids = {}
    schema = False
    count = 0
    for _, e in ET.iterparse(path, events=["end"]):
        tag = e.tag
        if tag == "schema":
            if e.get("name") != "time-profile":
                raise ValueError("Wrong CPU schema")
            schema = True
        if e.get("id") and tag in (
            "thread",
            "weight",
            "sample-time",
            "time",
            "timestamp",
            "tagged-backtrace",
            "backtrace",
            "frame",
        ):
            if tag in ("tagged-backtrace", "backtrace"):
                v = tuple(
                    ids.get(x.get("ref"), x.get("name", x.get("fmt", "")))
                    for x in e.findall("frame")
                )
            elif tag == "frame":
                v = e.get("name", e.get("fmt", ""))
            elif tag == "thread":
                v = e.get("fmt", "")
            else:
                v = float(e.text or 0)
            ids[e.get("id")] = v
        if tag != "row":
            continue

        def get(tags, row=e):
            for name in tags:
                x = row.find(name)
                if x is None:
                    continue
                if x.get("ref"):
                    if x.get("ref") not in ids:
                        raise ValueError("Unresolved XML reference")
                    return ids[x.get("ref")]
                if x.get("id") in ids:
                    return ids[x.get("id")]
                if name in ("sample-time", "time", "timestamp", "weight"):
                    return float(x.text or 0)
                if name == "thread":
                    return x.get("fmt", "")
                if name in ("tagged-backtrace", "backtrace"):
                    return tuple(
                        ids.get(f.get("ref"), f.get("name", f.get("fmt", "")))
                        for f in x.findall("frame")
                    )
            return None

        t = get(("sample-time", "time", "timestamp"))
        w = get(("weight",))
        thread = get(("thread",))
        stack = get(("tagged-backtrace", "backtrace"))
        if t is None or w is None:
            raise ValueError("Missing sample timestamp or weight")
        if not all(math.isfinite(x) and x >= 0 for x in (t, w)):
            raise ValueError("Invalid sample value")
        count += 1
        yield t / 1e9, w / 1e6, bool(thread and "Main Thread" in thread), stack or ()
        e.clear()
    if not schema:
        raise ValueError("CPU schema was not validated")


def cpu_metrics(path, duration):
    process_ms = main_ms = 0.0
    frames = Counter()
    bins = defaultdict(lambda: [0.0, 0.0])
    for elapsed, weight, main, stack in samples(path):
        if not 0 <= elapsed < duration:
            continue
        process_ms += weight
        bins[int(elapsed)][0] += weight
        if main:
            main_ms += weight
            bins[int(elapsed)][1] += weight
            frames.update({frame: weight for frame in set(stack) if frame})
    return {
        "process_cpu_ms": process_ms,
        "main_cpu_ms": main_ms,
        "main_inclusive_frames_ms": frames.most_common(80),
        "one_second_bins": [
            {
                "elapsed_s": n,
                "duration_s": min(1, duration - n),
                "process_cpu_ms": bins[n][0],
                "main_cpu_ms": bins[n][1],
            }
            for n in range(math.ceil(duration))
        ],
        "method": "Sampled CPU weights; inclusive frames overlap. 100% CPU means one core.",
    }
