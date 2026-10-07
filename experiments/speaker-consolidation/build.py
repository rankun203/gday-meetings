"""Compile reproducible experiment drivers against the shared production types."""

import argparse
from pathlib import Path
import subprocess

from score import private_output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", choices=["excerpt", "channel", "trusted", "reextract", "audit"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = private_output(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    experiment = Path(__file__).resolve().parent
    core = experiment.parents[1]/"apps/client-macos-swift/Sources/GdayMeetings/Core"
    sources = [core/"LocalModels/TypedVoiceEmbedding.swift", core/"SpeakerEvidence.swift",
               core/"VoiceEmbeddingMath.swift", core/"VoiceProfileSelection.swift", core/"SpeakerConsolidation.swift"]
    drivers = dict(excerpt="Consolidate.swift",channel="ChannelConsolidate.swift",trusted="TrustedChannelConsolidate.swift",
                   reextract="Reextract.swift",audit="EmbeddingAudit.swift")
    if args.tool == "excerpt":
        sources.append(experiment/"ExcerptSpeakerConsolidation.swift")
    if args.tool in ("reextract","audit"):
        sources.append(core/"CommunityVoiceEmbeddingExtractor.swift")
    sources.append(experiment/drivers[args.tool])
    subprocess.run(["xcrun","swiftc","-module-cache-path",str(output.parent/"module-cache"),"-O",
                    *(str(p) for p in sources),"-o",str(output)],check=True)


if __name__ == "__main__":
    main()
