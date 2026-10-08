"""Build a bounded, local comparison of voice embedding projections and exact scores."""

import argparse
import base64
import hashlib
import importlib.metadata
import json
import re
from pathlib import Path
from urllib.parse import urlsplit

import numpy as np
from export import atomic_directory
from scipy.spatial.distance import pdist, squareform
from scipy.stats import spearmanr

MAX_SAMPLES = 1000
HERE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fidelity(distances, coordinates):
    """Compare unique unordered pairs, excluding diagonal; fit one global scale."""
    original = squareform(distances, checks=True)
    projected = pdist(np.asarray(coordinates, dtype=np.float64))
    if len(original) != len(projected) or not np.isfinite(projected).all():
        raise ValueError("Invalid projection coordinates")
    original_energy, projected_energy = original @ original, projected @ projected
    if original_energy == 0 or projected_energy == 0:
        return {
            "pairCount": len(original),
            "spearman": None,
            "scaledStress": None,
            "scale": None,
            "undefinedReason": "All original or projected distances are zero",
        }
    scale = float((original @ projected) / projected_energy)
    stress = float(
        np.sqrt(np.sum((original - scale * projected) ** 2) / original_energy)
    )
    correlation = (
        None
        if np.ptp(original) == 0 or np.ptp(projected) == 0
        else float(spearmanr(original, projected).statistic)
    )
    return {
        "pairCount": len(original),
        "spearman": correlation,
        "scaledStress": stress,
        "scale": scale,
        "undefinedReason": None
        if correlation is not None
        else "Pair distances are constant",
    }


def aligned_rows(canonical, viewer):
    ids = [row["id"] for row in canonical]
    by_id = {row["id"]: row for row in viewer}
    if len(ids) != len(set(ids)) or len(by_id) != len(viewer) or set(ids) != set(by_id):
        raise ValueError("Canonical and viewer sample identities differ")
    output = []
    cluster_names, name_clusters = {}, {}
    for i, row in enumerate(canonical):
        display = by_id[row["id"]]
        if display["sampleID"] != row["sampleID"] or any(
            display[k] != row[k] for k in ("start", "end")
        ):
            raise ValueError("Viewer excerpt identity differs")
        if (
            display["source_id"] != row["source"]
            or display["cluster_id"] != row["cluster"]
        ):
            raise ValueError("Viewer source or cluster differs")
        cluster_key = (row["role"], row["cluster"])
        name = display["Cluster"]
        if (cluster_key in cluster_names and cluster_names[cluster_key] != name) or (
            name in name_clusters and name_clusters[name] != cluster_key
        ):
            raise ValueError("Viewer display labels split or merge canonical clusters")
        cluster_names[cluster_key] = name
        name_clusters[name] = cluster_key
        output.append(
            {
                "row": i,
                "id": row["id"],
                "sampleID": row["sampleID"],
                "source": row["source"],
                "start": row["start"],
                "end": row["end"],
                "role": row["role"],
                "clusterID": row["cluster"],
                "cluster": display["Cluster"],
                "trust": row["trustReason"],
                "representativeRank": row["representativeRank"],
                "referenceName": row["reviewConfirmedPerson"],
                "audio": display["audio"],
                "label": f"{i + 1:03d} · {display['Cluster']} · {row['source']} · {row['start'] / 60:.2f} min",
            }
        )
    return output


def verify_audio(canonical, row, receipt, site):
    base = urlsplit(receipt["audioBaseURL"])
    if (
        base.scheme != "http"
        or base.hostname not in {"localhost", "127.0.0.1", "::1"}
        or base.username
        or base.password
        or base.query
        or base.fragment
    ):
        raise ValueError("Comparison audio must use an approved loopback URL")
    prefix = "data:audio/wav;base64,"
    value = canonical["audio"]
    if not value.startswith(prefix):
        raise ValueError("Canonical sample lacks WAV payload")
    expected = hashlib.sha256(
        base64.b64decode(value[len(prefix) :], validate=True)
    ).hexdigest()
    filename = expected + ".wav"
    if (
        row["audio"] != receipt["audioBaseURL"] + filename
        or receipt["audioSHA256"].get(filename) != expected
        or sha(site / "projector/audio" / filename) != expected
    ):
        raise ValueError("Sample playback differs from its canonical audio")


def geometry(vectors, umap_coordinates):
    vectors = np.asarray(vectors, dtype=np.float64)
    if (
        vectors.ndim != 2
        or vectors.shape[1] != 256
        or not 3 <= len(vectors) <= MAX_SAMPLES
    ):
        raise ValueError(
            f"Expected 3–{MAX_SAMPLES} samples with 256 dimensions; larger quadratic comparisons require an explicit sampling study"
        )
    if not np.isfinite(vectors).all():
        raise ValueError("Nonfinite embedding")
    norms = np.linalg.norm(vectors, axis=1)
    if np.any(norms == 0):
        raise ValueError("Zero embedding")
    normalized = vectors / norms[:, None]
    if np.allclose(normalized, normalized[0], rtol=0, atol=1e-12):
        raise ValueError(
            "All embeddings are identical; no distance projection is defined"
        )
    cosine = np.clip(normalized @ normalized.T, -1, 1)
    np.fill_diagonal(cosine, 1)
    distance = np.sqrt(np.maximum(0, 2 - 2 * cosine))
    if np.max(distance) == 0:
        raise ValueError(
            "All embeddings are identical; no distance projection is defined"
        )
    from sklearn.manifold import MDS

    mds = MDS(
        n_components=2,
        metric_mds=True,
        metric="precomputed",
        init="random",
        n_init=4,
        max_iter=600,
        eps=1e-6,
        random_state=42,
        n_jobs=1,
        normalized_stress=False,
    ).fit_transform(distance)
    return (
        cosine,
        mds,
        {"umap": fidelity(distance, umap_coordinates), "mds": fidelity(distance, mds)},
    )


def atlas_navigation(html):
    if 'id="speaker-comparison-nav"' in html:
        if html.count('id="speaker-comparison-nav"') != 1:
            raise ValueError("Repeated comparison navigation")
        html = re.sub(
            r'<nav id="speaker-comparison-nav".*?</nav>', "", html, flags=re.DOTALL
        )
        html = re.sub(
            r'<style id="speaker-comparison-style".*?</style>',
            "",
            html,
            flags=re.DOTALL,
        )
    if html.count('<div id="app"') != 1 or html.count("<body>") != 1:
        raise ValueError("Unexpected Atlas HTML structure")
    style = '<style id="speaker-comparison-style">body{margin:0;display:grid;grid-template-rows:44px minmax(0,1fr);height:100dvh;overflow:hidden}#speaker-comparison-nav{box-sizing:border-box;height:44px;display:flex;align-items:center;gap:24px;padding:0 18px;font:14px system-ui;background:#f8fafc;border-bottom:1px solid #cbd5e1}#speaker-comparison-nav a{color:#174fa8}#app{min-height:0;height:calc(100dvh - 44px)!important;overflow:auto}#app>div{top:44px!important;bottom:0!important;height:calc(100dvh - 44px)!important}</style>'
    nav = '<nav id="speaker-comparison-nav" aria-label="Speaker evidence"><strong>Embedding Atlas</strong><a href="../comparison.html">Compare Distances</a><a href="../timeline.html">Speaker Timeline</a></nav>'
    return html.replace("</head>", style + "</head>").replace("<body>", "<body>" + nav)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--export", type=Path, required=True)
    parser.add_argument("--site", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = HERE.parents[1] / "tmp"
    if not args.output.resolve().is_relative_to(root):
        raise ValueError("Comparison output must remain inside ignored tmp")
    paths = {
        "canonical": args.export / "samples.parquet",
        "summary": args.export / "summary.json",
        "viewer": args.site / "projector/data/dataset.parquet",
        "atlasIndex": args.site / "projector/index.html",
        "atlasReceipt": args.site / "receipt.json",
        "script": Path(__file__),
        "html": HERE / "comparison.html",
        "javascript": HERE / "comparison.js",
    }
    hashes = {k: sha(p) for k, p in paths.items()}
    summary = json.loads(paths["summary"].read_text())
    if hashes["canonical"] != summary["outputSHA256"]["samples.parquet"]:
        raise ValueError("Canonical export differs from receipt")
    atlas_receipt = json.loads(paths["atlasReceipt"].read_text())
    if atlas_receipt["exportSummarySHA256"] != hashes["summary"]:
        raise ValueError("Atlas uses a different canonical export")
    import pyarrow.parquet as pq
    from plotly.offline import get_plotlyjs

    canonical = pq.read_table(paths["canonical"]).to_pylist()
    viewer = pq.read_table(paths["viewer"]).to_pylist()
    if len(canonical) > MAX_SAMPLES:
        raise ValueError(f"At most {MAX_SAMPLES} samples are supported")
    rows = aligned_rows(canonical, viewer)
    # Each playback URL must represent that exact canonical sample, not just a valid WAV.
    for canonical_row, row in zip(canonical, rows, strict=True):
        verify_audio(canonical_row, row, atlas_receipt, args.site)
    umap = [[r["projection_x"], r["projection_y"]] for r in canonical]
    cosine, mds, metrics = geometry([r["embedding"] for r in canonical], umap)
    order = sorted(
        range(len(rows)),
        key=lambda i: (rows[i]["cluster"], rows[i]["source"], rows[i]["start"], i),
    )
    payload = {
        "schemaVersion": 1,
        "rows": rows,
        "coordinates": {"umap": umap, "mds": mds.tolist()},
        "cosine": cosine.tolist(),
        "heatmapOrder": order,
        "metrics": metrics,
    }
    receipt = {
        "schemaVersion": 1,
        "sourceSHA256": hashes,
        "sampleCount": len(rows),
        "metrics": metrics,
        "mds": {
            "distance": "Euclidean chord distance sqrt(2-2cosine) on normalized 256D vectors",
            "seed": 42,
            "nInit": 4,
            "maxIter": 600,
            "eps": 1e-6,
        },
        "scope": "All samples including references; unique unordered off-diagonal pairs; projection fidelity is not speaker accuracy",
        "packages": {
            name: importlib.metadata.version(name)
            for name in ("numpy", "scipy", "scikit-learn", "pyarrow", "plotly")
        },
    }

    def write(staging):
        (staging / "comparison-data.json").write_text(
            json.dumps(payload, allow_nan=False, separators=(",", ":"))
        )
        (staging / "comparison.html").write_bytes(paths["html"].read_bytes())
        (staging / "comparison.js").write_bytes(paths["javascript"].read_bytes())
        (staging / "comparison-plotly.min.js").write_text(get_plotlyjs())
        (staging / "atlas-index.html").write_text(
            atlas_navigation(paths["atlasIndex"].read_text())
        )
        if hashes != {k: sha(p) for k, p in paths.items()}:
            raise ValueError("Comparison input changed during calculation")
        for filename, expected in atlas_receipt["audioSHA256"].items():
            if sha(args.site / "projector/audio" / filename) != expected:
                raise ValueError("Audio changed during calculation")
        receipt["outputSHA256"] = {p.name: sha(p) for p in staging.iterdir()}
        (staging / "comparison-receipt.json").write_text(
            json.dumps(receipt, indent=2) + "\n"
        )

    atomic_directory(args.output.resolve(), write)
    print(
        json.dumps(
            {"output": str(args.output), "samples": len(rows), "metrics": metrics}
        )
    )


if __name__ == "__main__":
    main()
