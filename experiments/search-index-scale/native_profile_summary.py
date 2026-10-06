"""Summarize exported Instruments CPU stacks without paths or process identifiers."""
import argparse
import json
import xml.etree.ElementTree as ET
from collections import Counter

p = argparse.ArgumentParser()
p.add_argument("input")
p.add_argument("output")
a = p.parse_args()
root = ET.parse(a.input).getroot()
ids = {x.attrib["id"]: x for x in root.iter() if "id" in x.attrib}


def resolve(element):
    return ids[element.attrib["ref"]] if "ref" in element.attrib else element


inclusive = Counter()
categories = Counter()
total = 0
for row in root.findall(".//row"):
    stack = resolve(row.find("tagged-backtrace"))
    weight = int(resolve(row.find("weight")).text)
    names = [resolve(frame).get("name", "") for frame in stack.findall("frame")]
    total += weight
    for name in set(names):
        inclusive[name] += weight
    joined = "\n".join(names)
    if "SemanticSource.fingerprint" in joined:
        category = "Source fingerprint validation"
    elif "JSONDecoder" in joined:
        category = "JSON decoding"
    elif "vDSP" in joined:
        category = "Accelerate vector kernels"
    elif "sqlite3" in joined:
        category = "SQLite calls"
    elif "SemanticSearchIndex.search" in joined:
        category = "Other retrieval work"
    else:
        category = "Outside retrieval"
    categories[category] += weight
report = {
    "method": "15-second Time Profiler-only attachment; inclusive CPU stack samples, not wall-time stage instrumentation",
    "scale": 10,
    "sampleWeightMilliseconds": total / 1e6,
    "exclusiveCategoriesPercent": {k: v / total * 100 for k, v in categories.most_common()},
    "inclusiveFrames": [{"symbol": k, "percent": v / total * 100}
                        for k, v in inclusive.most_common(50) if not k.startswith("0x")],
    "limitations": "One short capture. Inlined vector-loop work can fall under Other retrieval work; CPU shares are approximate. Profiled queries are excluded from latency measurements.",
}
with open(a.output, "w") as f:
    json.dump(report, f, indent=2)
    f.write("\n")
print(json.dumps(report["exclusiveCategoriesPercent"], indent=2))
