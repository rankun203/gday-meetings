"""Export aggregate HNSW grid cells without private vectors or passage IDs."""

import argparse
import json
from pathlib import Path

from summarize_diskann import aggregate

p = argparse.ArgumentParser()
p.add_argument("runs", type=Path)
p.add_argument("output", type=Path)
a = p.parse_args()
result = {"dimensions": 384, "precisions": []}
for dtype in ["f32", "f16", "i8"]:
    folder = a.runs / f"hnsw-{dtype}"
    stages = []
    for scale in range(1, 11):
        cell = {"scale": scale, "windows": 39066 * scale}
        for operation in ["build", "search", "hybrid", "mutations"]:
            path = folder / f"hnsw-{operation}-{scale}.json"
            cell[operation] = (
                aggregate(json.loads(path.read_text()))
                if path.exists()
                else {"status": "pending"}
            )
        stages.append(cell)
    result["precisions"].append({"dtype": dtype, "stages": stages})
quality = a.runs / "quantization-quality.json"
if quality.exists():
    result["labeledQuality"] = json.loads(quality.read_text())
a.output.write_text(json.dumps(result, indent=2) + "\n")
