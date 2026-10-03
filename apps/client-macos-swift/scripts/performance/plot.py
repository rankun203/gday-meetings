#!/usr/bin/env python3
"""Create one SVG with aligned resource and latency comparisons from analyze.py."""

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("data", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--labels",
        type=Path,
        help="Optional JSON mapping build values to concise names",
    )
    parser.add_argument("--time-kib", type=float, default=100)
    args = parser.parse_args()
    if args.output.suffix.lower() != ".svg":
        parser.error("Output must use the .svg extension")
    data = json.loads(args.data.read_text())["runs"]
    labels = json.loads(args.labels.read_text()) if args.labels else {}

    def build_label(build):
        value = labels.get(build, build or "unspecified")
        return value.get("label", build) if isinstance(value, dict) else value

    colors = {"notes": "#B45518", "summary": "#2469A0"}
    builds = list(dict.fromkeys(r["build"] for r in data if not r["profiled"]))
    styles = {
        build: ["--", "-.", "-", ":"][min(i, 3)] for i, build in enumerate(builds)
    }
    if len(builds) == 1:
        styles[builds[0]] = "-"
    for build in builds:
        if isinstance(labels.get(build), dict):
            styles[build] = labels[build].get("linestyle", styles[build])
    plt.rcParams.update(
        {
            "font.family": "DejaVu Sans",
            "font.size": 10.5,
            "svg.fonttype": "path",
            "axes.spines.top": False,
            "axes.spines.right": False,
            "axes.edgecolor": "#ADB5BD",
            "text.color": "#252B32",
        }
    )
    fig, axes = plt.subplots(4, 2, figsize=(14, 15))
    fig.subplots_adjust(
        left=0.085, right=0.97, top=0.87, bottom=0.29, hspace=0.65, wspace=0.28
    )
    fig.suptitle(
        "Notes and Summary: resource use and payload growth",
        x=0.085,
        ha="left",
        fontsize=18,
        y=0.98,
    )
    fig.text(
        0.085,
        0.952,
        "Synthetic release workloads · requested 10 updates/s · 25 seconds of input, then 5 seconds settling",
        fontsize=11,
    )
    axes[0, 0].set_title(
        f"Over time · initial payload near {args.time_kib:g} KiB", loc="left", pad=12
    )
    axes[0, 1].set_title("Over payload size · measured run values", loc="left", pad=12)
    groups = defaultdict(list)
    for run in data:
        if run["profiled"] or not run["actions"]:
            continue
        groups[(run["task"], run["mode"], run["build"])].append(run)
    handles = []
    for (task, mode, build), runs in groups.items():
        color = colors[task]
        style = ":" if mode == "hidden" else styles[build]
        label = (
            task.title()
            + (" hidden" if mode == "hidden" else "")
            + " · "
            + build_label(build)
        )
        handles.append(Line2D([0], [0], color=color, ls=style, label=label))
        for run in runs:
            initial = run["initial_utf8_bytes"] / 1024
            marker = ("s" if mode == "hidden" else "o") if run["completed"] else "^"
            values = [
                run["mean_main_cpu_pct"],
                run["footprint_peak_bytes"] / 2**20,
                run["disk_write_bytes"] / 1024
                if run["disk_write_bytes"] is not None
                else None,
                run["action_p95_ms"],
            ]
            for index, value in enumerate(values):
                if value is not None:
                    axes[index, 1].scatter(
                        initial,
                        value,
                        color=color,
                        marker=marker,
                        facecolors="none" if styles[build] != "-" else color,
                        s=48,
                        linewidths=1.4,
                    )
            if abs(initial - args.time_kib) > max(1, args.time_kib * 0.03):
                continue
            rows = [r for r in run["samples"] if r.get("interval_s", 0) >= 0.5]
            times = [r["elapsed_s"] for r in rows]
            series = [
                [100 * r["main_cpu_ns_delta"] / 1e9 / r["interval_s"] for r in rows],
                [r["physical_footprint_bytes"] / 2**20 for r in rows],
                [
                    r["disk_write_bytes"] / 1024
                    if r["disk_write_bytes"] is not None
                    else float("nan")
                    for r in rows
                ],
            ]
            for index, values in enumerate(series):
                axes[index, 0].plot(times, values, color=color, ls=style, lw=1.6)
            bins = defaultdict(list)
            for row in run["actions"]:
                bins[int(row["elapsed_s"])].append(row["action_duration_s"] * 1000)
            axes[3, 0].plot(
                list(bins),
                [statistics.median(v) for v in bins.values()],
                color=color,
                ls=style,
                lw=1.6,
            )
    units = [
        "Main CPU (% of one core)",
        "Physical footprint (MiB)",
        "Process writes (KiB)",
        "Operation time (ms, log scale)",
    ]
    aggregate_units = [
        "Mean main CPU\n(% of one core)",
        "Peak footprint (MiB)",
        "Total process writes (KiB)",
        "p95 operation time (ms, log scale)",
    ]
    for index, row in enumerate(axes):
        for column, ax in enumerate(row):
            ax.set_ylabel(units[index] if column == 0 else aggregate_units[index])
            ax.grid(axis="y", color="#E6E9EC", linewidth=0.7)
            if index == 3:
                ax.set_yscale("log")
                ax.axhline(16.7, color="#666", ls=":", lw=0.9)
            else:
                ax.set_ylim(bottom=0)
            if column == 0:
                ax.set_xlim(0, 31)
                ax.axvline(25, color="#777", ls=":", lw=0.8)
                ax.set_xlabel("Elapsed seconds")
            else:
                ax.set_xlim(
                    0,
                    max(530, max(r["initial_utf8_bytes"] / 1024 for r in data) * 1.05),
                )
                ax.set_xticks([10, 100, 500])
                ax.set_xlabel("Initial UTF-8 payload (KiB)")
        # Equal row scales make the two dimensions directly comparable.
        low = min(a.get_ylim()[0] for a in row)
        high = max(a.get_ylim()[1] for a in row)
        for ax in row:
            ax.set_ylim(low, high)
    fig.legend(
        handles=handles,
        loc="upper center",
        bbox_to_anchor=(0.53, 0.94),
        ncol=min(3, len(handles)),
        frameon=False,
        fontsize=9,
    )
    devices = []
    for run in data:
        if run.get("devices"):
            device = run["devices"]
            analysis = device["analysis"]
            duration = analysis["duration_s"]
            devices.append(
                [
                    run["task"].title() + " · " + build_label(run["build"]),
                    f"{run['initial_utf8_bytes'] / 1024:.0f} KiB",
                    f"{duration:.2f} s",
                    f"{100 * analysis['gpu_app_union_s'] / duration:.3f}%",
                    f"{100 * analysis['gpu_active_fraction']:.2f}%",
                    f"{100 * analysis['ane_active_fraction']:.2f}%",
                    str(analysis["coreml_rows"]),
                ]
            )
    table_ax = fig.add_axes([0.085, 0.085, 0.885, 0.12])
    table_ax.axis("off")
    if devices:
        table = table_ax.table(
            cellText=devices,
            colLabels=[
                "Device probe",
                "Payload",
                "Captured",
                "App GPU",
                "System GPU",
                "System ANE",
                "Core ML events",
            ],
            loc="center",
            cellLoc="center",
            colWidths=[0.31, 0.10, 0.11, 0.12, 0.12, 0.12, 0.12],
        )
        table.auto_set_font_size(False)
        table.set_fontsize(8.5)
        table.scale(1, 1.35)
        for cell in table.get_celld().values():
            cell.set_edgecolor("#D9DEE3")
            cell.set_linewidth(0.5)
    else:
        table_ax.text(
            0,
            0.5,
            "Accelerator probes unavailable; missing values are not zero.",
            fontsize=10,
        )
    fig.text(
        0.085,
        0.235,
        "Open: before scan fixes. Filled: after. Squares: hidden Summary. Triangles: latency guard; values cover only actual duration.\nTime chart shows per-second median operation time; payload chart shows p95. Dotted reference: 16.7 ms, not measured key-to-photon.",
        fontsize=9,
    )
    fig.text(
        0.085,
        0.025,
        "Device values cover separate instrumented intervals, not the full unprofiled run. GPU/ANE are active wall time, not device-capacity utilization.\nSystem GPU includes the app and unrelated rendering. ANE is system-wide. Empty Core ML events do not rule out another inference backend.",
        fontsize=9,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.output, bbox_inches="tight")
    args.output.write_text(
        "\n".join(line.rstrip() for line in args.output.read_text().splitlines()) + "\n"
    )
    fig.savefig(args.output.with_suffix(".png"), dpi=120, bbox_inches="tight")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
