"""Export a local Atlas application and an interval timeline from reviewed evidence."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
from urllib.parse import urlsplit


def external_audio(values, directory, base_url):
    """Keep audio bytes outside the query table; serve only through loopback."""
    parsed = urlsplit(base_url)
    if (
        parsed.scheme != "http"
        or parsed.hostname not in {"localhost", "127.0.0.1", "::1"}
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or not base_url.endswith("/")
    ):
        raise ValueError("Audio base URL must be an HTTP loopback directory URL")
    urls, hashes = [], {}
    for value in values:
        prefix = "data:audio/wav;base64,"
        if not isinstance(value, str) or not value.startswith(prefix):
            raise ValueError("Expected canonical WAV data URL")
        data = base64.b64decode(value[len(prefix) :], validate=True)
        if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
            raise ValueError("Expected WAV bytes")
        digest = hashlib.sha256(data).hexdigest()
        name = digest + ".wav"
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / name
        if target.exists():
            if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                raise ValueError("Existing audio excerpt differs")
        else:
            target.write_bytes(data)
        urls.append(base_url + name)
        hashes[name] = digest
    return urls, hashes


def main():
    import embedding_atlas
    import numpy as np
    import pandas as pd
    import plotly.graph_objects as go
    from embedding_atlas.data_source import DataSource
    from embedding_atlas.options import make_embedding_atlas_props
    from plotly.subplots import make_subplots

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--export", type=Path, required=True)
    parser.add_argument("--analysis", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--historical-intervals", type=Path, required=True)
    parser.add_argument("--historical-examples", type=Path, required=True)
    parser.add_argument("--site", type=Path, required=True)
    parser.add_argument(
        "--audio-base-url", default="http://127.0.0.1:8765/projector/audio/"
    )
    args = parser.parse_args()

    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    bound_paths = [
        args.analysis,
        args.evidence,
        args.result,
        args.historical_intervals,
        args.historical_examples,
        args.export / "samples.parquet",
        args.export / "summary.json",
        Path(__file__),
    ]
    initial_hashes = {str(path): digest(path) for path in bound_paths}
    summary = json.loads((args.export / "summary.json").read_text())
    for name in ("evidence", "result", "historical_intervals", "historical_examples"):
        if digest(getattr(args, name)) != summary["sourceSHA256"][name]:
            raise ValueError("Input differs from projector provenance: " + name)
    if (
        digest(args.export / "samples.parquet")
        != summary["outputSHA256"]["samples.parquet"]
    ):
        raise ValueError("Projector rows differ from export receipt")
    df = pd.read_parquet(args.export / "samples.parquet")
    evidence = json.loads(args.evidence.read_text())
    analysis = json.loads(args.analysis.read_text())
    if analysis["result"] != json.loads(args.result.read_text()):
        raise ValueError("Timeline and projector use different cluster results")
    source_hashes = {
        name: digest(getattr(args, name))
        for name in (
            "analysis",
            "evidence",
            "result",
            "historical_intervals",
            "historical_examples",
        )
    }
    first = {
        c["id"]: min(
            s["start"] for s in evidence["samples"] if s["id"] in set(c["sampleIDs"])
        )
        for c in analysis["result"]["clusters"]
    }
    labels = {
        key: f"Cluster {i + 1:02d}"
        for i, key in enumerate(sorted(first, key=lambda k: (first[k], k)))
    }
    windows = sorted(
        evidence["windows"], key=lambda w: (w["source"], w["publicationStart"])
    )
    window_labels = {
        w["generation"]: f"{w['source']} / window {i + 1}"
        for i, w in enumerate(windows)
    }
    df["Cluster"] = df["cluster"].map(labels).fillna("Unresolved")
    df.loc[df["role"] == "historical_reference", "Cluster"] = "Saved reference"
    df["Window"] = df["window"].map(window_labels).fillna("Saved reference")
    df["Source"] = df["source"]
    df["Cosine to label mean"] = np.nan
    accepted = df[(df["role"] == "replay_sample") & df["cluster"].notna()]
    for _, members in accepted.groupby(["source", "localLabel"]):
        vectors = np.stack(members["embedding"].to_list())
        mean = vectors.mean(axis=0)
        mean /= np.linalg.norm(mean)
        df.loc[members.index, "Cosine to label mean"] = vectors @ mean
    df["Role"] = df["role"].map(
        {
            "replay_sample": "Fresh replay",
            "historical_reference": "Saved reference, re-extracted",
        }
    )
    df["Time (minutes)"] = df["start"] / 60
    df["Review example"] = [
        "Selected " + str(int(v)) if pd.notna(v) else "Other evidence"
        for v in df["representativeRank"]
    ]
    df["Trust"] = df["trustReason"].str.replace("_", " ")
    df["Confirmed reference name"] = df["reviewConfirmedPerson"].fillna("Unassigned")
    df["Closest reference (diagnostic)"] = df["diagnosticReferenceName"].fillna(
        "None available"
    )
    df["Cosine similarity"] = df["diagnosticReferenceCosine"]
    df["Margin"] = df["diagnosticReferenceMargin"]
    df["Score gate (diagnostic)"] = [
        "Passes 0.85 / 0.08"
        if pd.notna(score) and pd.notna(margin) and score >= 0.85 and margin >= 0.08
        else "Needs review"
        for score, margin in zip(df["Cosine similarity"], df["Margin"], strict=True)
    ]
    df["Historical label"] = df["historicalContext"].map(
        lambda raw: (
            ", ".join(
                sorted(
                    {
                        x["speakerLabel"]
                        for x in json.loads(raw)
                        if x.get("speakerLabel")
                    }
                )
            )
            or "No transcript context"
        )
    )
    df["Historical name (context only)"] = df["historicalContext"].map(
        lambda raw: (
            ", ".join(
                sorted(
                    {x["personName"] for x in json.loads(raw) if x.get("personName")}
                )
            )
            or "Unassigned"
        )
    )
    df["Description"] = [
        f"{r['Cluster']} · {r['Source']} · {r['Time (minutes)']:.2f} min · {r['Review example']} · {r['Trust']}"
        for _, r in df.iterrows()
    ]
    # The exporter preserves row order, so these IDs match exact-vector neighbors.
    df["row_index"] = range(len(df))
    props = make_embedding_atlas_props(
        row_id="row_index",
        x="projection_x",
        y="projection_y",
        text="Description",
        neighbors="neighbors",
        labels=[],
        point_size=5,
    )
    props["embeddingViewLabels"] = []
    props["defaultChartsConfig"] = {
        "include": [
            "Cluster",
            "Review example",
            "Trust",
            "Role",
            "Window",
            "Historical label",
            "Closest reference (diagnostic)",
            "Score gate (diagnostic)",
            "Cosine to label mean",
            "Time (minutes)",
        ],
        "embedding": {
            "data": {
                "x": "projection_x",
                "y": "projection_y",
                "text": "Description",
                "neighbors": "neighbors",
                "category": "Cluster",
            }
        },
        "table": {
            "columns": [
                "Cluster",
                "Time (minutes)",
                "Review example",
                "audio",
                "Historical label",
                "Historical name (context only)",
                "Confirmed reference name",
                "Closest reference (diagnostic)",
                "Cosine similarity",
                "Margin",
                "Score gate (diagnostic)",
                "Cosine to label mean",
                "Trust",
                "Window",
                "Role",
            ],
            "pageSize": 25,
            "columnStyles": {"audio": {"renderer": "audio"}},
        },
    }
    props["initialState"] = {
        "columnStyles": {
            "audio": {"renderer": "audio"},
            "embedding": {"display": "hidden"},
        }
    }
    destination = args.site / "projector"
    if destination.exists():
        raise ValueError("Use a fresh site output directory")
    df["audio"], audio_hashes = external_audio(
        df["audio"], destination / "audio", args.audio_base_url
    )
    identifier = hashlib.sha256(
        (args.export / "samples.parquet").read_bytes()
        + Path(__file__).read_bytes()
        + json.dumps(props, sort_keys=True).encode()
        + args.audio_base_url.encode()
    ).hexdigest()
    # DuckDB treats column names as case-insensitive. Preserve raw IDs under
    # distinct names so readable columns resolve to the intended values.
    view_df = df.rename(
        columns={
            "cluster": "cluster_id",
            "window": "window_id",
            "source": "source_id",
            "role": "evidence_role",
        }
    )
    visible = props["defaultChartsConfig"]["table"]["columns"]
    view_df = view_df[
        visible + [name for name in view_df.columns if name not in visible]
    ]
    ds = DataSource(identifier, view_df, {"props": props})
    ds.export_to_folder(
        str(Path(embedding_atlas.__file__).parent / "static"), str(destination)
    )
    (args.site / "cluster-labels.json").write_text(json.dumps(labels, indent=2))

    fig = make_subplots(
        rows=3,
        cols=1,
        shared_xaxes=True,
        vertical_spacing=0.09,
        subplot_titles=[
            "Original saved transcript labels (historical context)",
            "Fresh local activity and window boundaries",
            "Consolidated speaker activity and selected examples",
        ],
    )
    history = json.loads(args.historical_intervals.read_text())["intervals"]
    historical = json.loads(args.historical_examples.read_text())
    saved_labels = {
        speaker["id"]: speaker["label"] for speaker in historical["speakers"]
    }
    local_names = {}
    for wi, window in enumerate(windows):
        for slot, local in enumerate(window["localSpeakerIDs"]):
            local_names[(window["source"], local)] = (
                f"{window['source']} W{wi + 1} / channel {slot + 1}"
            )
    groups = {}
    for row_index, intervals in [
        (1, history),
        (2, evidence["activity"]),
        (3, analysis["result"]["intervals"]),
    ]:
        for item in intervals:
            if row_index == 1:
                label = saved_labels.get(item.get("speakerID"), "Unknown")
            elif row_index == 2:
                label = local_names.get(
                    (item["source"], item["localSpeakerID"]), "Unknown local label"
                )
            else:
                label = (
                    labels.get(item.get("clusterID"), "Unresolved")
                    + " / "
                    + item["source"]
                )
            groups.setdefault((row_index, label), []).append(item)
    for (row_index, label), spans in groups.items():
        xs, ys = [], []
        merged = []
        for span in sorted(spans, key=lambda s: (s["start"], s["end"])):
            if merged and span["start"] <= merged[-1]["end"]:
                merged[-1]["end"] = max(merged[-1]["end"], span["end"])
            else:
                merged.append(dict(span))
        for span in merged:
            xs.extend([span["start"] / 60, span["end"] / 60, None])
            ys.extend([label, label, None])
        fig.add_trace(
            go.Scatter(
                x=xs,
                y=ys,
                mode="lines",
                line={
                    "width": 5,
                    "simplify": False,
                    **({"color": "#2563eb"} if row_index == 2 else {}),
                },
                name=label,
                hovertemplate="%{y}<br>%{x:.2f} min<extra></extra>",
                showlegend=False,
            ),
            row=row_index,
            col=1,
        )
    selected = df[(df["role"] == "replay_sample") & df["representativeRank"].notna()]
    fig.add_trace(
        go.Scatter(
            x=selected["start"] / 60,
            y=selected["Cluster"] + " / " + selected["source"],
            mode="markers",
            marker={
                "symbol": "diamond",
                "size": 10,
                "color": "#111827",
                "line": {"color": "white", "width": 1},
            },
            text=selected["Review example"],
            name="Selected examples",
            hovertemplate="%{y}<br>%{x:.2f} min<br>%{text}<extra></extra>",
        ),
        row=3,
        col=1,
    )
    for window in windows:
        if window["publicationStart"] > 0:
            fig.add_vline(
                x=window["publicationStart"] / 60,
                line_dash="dot",
                line_color="#6b7280",
                row=2,
                col=1,
            )
    fig.update_layout(
        template="plotly_white",
        height=max(1000, len(local_names) * 12 + len(labels) * 15 + 400),
        title="Speaker timeline · minutes from recording start",
        margin={"l": 200, "r": 35, "t": 90, "b": 60},
    )
    fig.update_xaxes(
        title_text="Recording time (minutes)", row=3, col=1, rangeslider_visible=True
    )
    fig.write_html(args.site / "timeline.html", include_plotlyjs=True, full_html=True)
    if initial_hashes != {str(path): digest(path) for path in bound_paths}:
        raise ValueError("An input changed during export; discard this site")
    (args.site / "receipt.json").write_text(
        json.dumps(
            {
                "sourceSHA256": source_hashes,
                "boundInputsSHA256": initial_hashes,
                "audioBaseURL": args.audio_base_url,
                "audioSHA256": audio_hashes,
                "exportSummarySHA256": digest(args.export / "summary.json"),
                "scriptSHA256": digest(Path(__file__)),
            },
            indent=2,
        )
    )
    print(
        json.dumps(
            {
                "points": len(df),
                "clusters": len(labels),
                "selected": len(selected),
                "site": str(args.site),
            }
        )
    )


if __name__ == "__main__":
    main()
