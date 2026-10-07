"""Instrument an isolated replay copy with unpublished bootstrap activity callbacks."""

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE.parent / "diarization-benchmark"))
from private_paths import private_output

REVISION = "bootstrap-context-v1-experiment"
ADAPTER = "Sources/GdayMeetings/Services/LocalLiveDiarization.swift"
COLLECTOR = "Tests/GdayMeetingsTests/SpeakerConsolidationReplayTests.swift"
CONTEXT_TYPE = '''/// Experimental replay context; never submitted to the published speaker timeline.
struct LiveSpeakerBootstrapContext: Codable, Sendable {
    var source: LiveAudioSource
    var generation: UUID
    var speakers: [LiveSpeakerIdentity]
    var intervals: [LiveSpeakerInterval]
    var start: Double
    var end: Double
    var contextOrigin: Double
    var handoff: Double
    var capacityReachedAt: Double?
    var policyRevision: String

    static func clipping(
        _ event: LiveSpeakerEvent, contextOrigin: Double, handoff: Double
    ) -> Self? {
        let start = max(event.start, contextOrigin)
        let end = min(event.end, handoff)
        guard end > start, let window = event.continuity else { return nil }
        return .init(
            source: event.source, generation: event.generation, speakers: event.speakers,
            intervals: event.intervals.compactMap { interval in
                let lower = max(interval.start, start)
                let upper = min(interval.end, end)
                return upper > lower
                    ? LiveSpeakerInterval(speakerID: interval.speakerID, start: lower, end: upper) : nil
            }, start: start, end: end, contextOrigin: contextOrigin, handoff: handoff,
            capacityReachedAt: window.capacityReachedAt, policyRevision: window.policyRevision)
    }
}

'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("The expected source anchor is absent or ambiguous: " + old[:80])
    return text.replace(old, new, 1)


def adapter_patch(text):
    text = replace_once(text, "/// One actor serializes shared model scratch buffers.",
        CONTEXT_TYPE + "/// One actor serializes shared model scratch buffers.")
    text = replace_once(text,
        "    private var sample: (@Sendable (LiveSpeakerAudioSample) async -> Void)?\n",
        "    private var sample: (@Sendable (LiveSpeakerAudioSample) async -> Void)?\n"
        "    private var bootstrapContext: (@Sendable (LiveSpeakerBootstrapContext) async -> Void)?\n")
    text = replace_once(text,
        "        sample: @escaping @Sendable (LiveSpeakerAudioSample) async -> Void\n",
        "        sample: @escaping @Sendable (LiveSpeakerAudioSample) async -> Void,\n"
        "        bootstrapContext: (@Sendable (LiveSpeakerBootstrapContext) async -> Void)? = nil\n")
    text = replace_once(text, "        self.sample = sample\n",
        "        self.sample = sample\n        self.bootstrapContext = bootstrapContext\n")
    text = replace_once(text,
        "            if let publication = Self.publication(candidate, from: session.publicationStart) {\n",
        "            if let context = LiveSpeakerBootstrapContext.clipping(\n"
        "                candidate, contextOrigin: origin, handoff: session.publicationStart)\n"
        "            {\n"
        "                await bootstrapContext?(context)\n"
        "            }\n"
        "            if let publication = Self.publication(candidate, from: session.publicationStart) {\n")
    return text


def collector_patch(text):
    text = replace_once(text,
        "        enum Kind: String, Codable { case speakerEvent, embeddingReady }",
        "        enum Kind: String, Codable { case speakerEvent, embeddingReady, bootstrapContext }")
    text = replace_once(text, "        var sampleID: String?\n",
        "        var sampleID: String?\n        var bootstrapContext: LiveSpeakerBootstrapContext?\n")
    text = replace_once(text, "    var schemaVersion = 1\n",
        '    var schemaVersion = 2\n    var contextPolicyRevision = "' + REVISION + '"\n')
    text = replace_once(text, "    func receive(_ event: LiveSpeakerEvent) {\n",
        "    func receive(_ context: LiveSpeakerBootstrapContext) {\n"
        "        availability.entries.append(\n"
        "            .init(\n"
        "                ordinal: availability.entries.count, audioSubmittedThrough: audioSubmittedThrough,\n"
        "                kind: .bootstrapContext, bootstrapContext: context))\n"
        "    }\n\n"
        "    func receive(_ event: LiveSpeakerEvent) {\n")
    text = replace_once(text,
        "            sample: { await collector.receive($0, extractor: extractor) })",
        "            sample: { await collector.receive($0, extractor: extractor) },\n"
        "            bootstrapContext: { await collector.receive($0) })")
    tests = '''    @Test func bootstrapContextPreservesOnePublicationBoundary() async throws {
        let generation = UUID()
        let speaker = LiveSpeakerIdentity(
            id: UUID(), source: .microphone, generation: generation, slot: 0,
            model: "synthetic", revision: "synthetic")
        let window = SpeakerEvidenceWindow(
            generation: generation.uuidString, source: "microphone", localSpeakerIDs: [speaker.id.uuidString],
            publicationStart: 10, observedEnd: 12, capacityReachedAt: 8,
            policyRevision: SpeakerEvidenceWindow.protectedPolicy)
        let event = LiveSpeakerEvent(
            source: .microphone, generation: generation, sequence: 1, speakers: [speaker],
            intervals: [.init(speakerID: speaker.id, start: 5, end: 12)], start: 5, end: 12, continuity: window)
        let context = try #require(LiveSpeakerBootstrapContext.clipping(event, contextOrigin: 5, handoff: 10))
        let publication = try #require(LocalLiveDiarization.publication(event, from: 10))
        #expect(context.start == 5 && context.end == 10)
        #expect(context.intervals == [.init(speakerID: speaker.id, start: 5, end: 10)])
        #expect(publication.intervals == [.init(speakerID: speaker.id, start: 10, end: 12)])
        #expect(context.capacityReachedAt == 8)
        #expect(context.handoff == 10 && context.contextOrigin == 5)
        #expect(LiveSpeakerBootstrapContext.clipping(publication, contextOrigin: 5, handoff: 10) == nil)
        let collector = ConsolidationReplayCollector()
        try await collector.submittedAudio(through: 12)
        await collector.receive(context)
        #expect(await collector.document.activity.isEmpty)
        #expect(await collector.document.samples.isEmpty)
        #expect(await collector.document.windows == nil)
        await collector.receive(publication)
        let document = await collector.document
        #expect(document.activity.count == 1)
        #expect(document.activity[0].start == 10 && document.activity[0].end == 12)
        let encoded = try JSONEncoder().encode(await collector.availability)
        let trace = try JSONDecoder().decode(ConsolidationReplayAvailability.self, from: encoded)
        #expect(trace.schemaVersion == 2)
        #expect(trace.entries.map(\\.kind) == [.bootstrapContext, .speakerEvent])
        #expect(trace.entries.map(\\.ordinal) == [0, 1])
        #expect(trace.entries[0].bootstrapContext?.capacityReachedAt == 8)
        #expect(trace.entries[0].event == nil && trace.entries[0].sampleID == nil)
    }

'''
    return replace_once(text, "struct SpeakerConsolidationReplayTests {\n",
        "struct SpeakerConsolidationReplayTests {\n" + tests)


def install(package_path):
    package = private_output(package_path)
    production = ROOT / "apps/client-macos-swift"
    names = (ADAPTER, COLLECTOR)
    paths = {name: package / name for name in names}
    for path in paths.values():
        if path.is_symlink() or package not in path.resolve().parents or not path.is_file():
            raise ValueError("Instrumentation destinations must be regular files inside the isolated package")
    before = {name: path.read_bytes() for name, path in paths.items()}
    if any(data != (production / name).read_bytes() for name, data in before.items()):
        raise ValueError("Copied adapter or replay collector differs from the production baseline")
    after = {ADAPTER: adapter_patch(before[ADAPTER].decode()).encode(),
        COLLECTOR: collector_patch(before[COLLECTOR].decode()).encode()}
    evidence_path = package / "Sources/GdayMeetings/Core/SpeakerEvidence.swift"
    capacity_path = package / "Sources/GdayMeetings/Core/LiveSpeakerCapacity.swift"
    revision = re.search(r'static let protectedPolicy = "([^"]+)"', evidence_path.read_text())
    if revision is None:
        raise ValueError("The copied evidence has no explicit policy revision")
    record = package / "bootstrap-context-install.json"
    backup = package / "bootstrap-context-before"
    if record.exists() or backup.exists():
        raise ValueError("This checkout already contains bootstrap instrumentation or its backup")
    backup.mkdir(mode=0o700)
    for name, data in before.items():
        target = backup / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    receipt = dict(contextPolicyRevision=REVISION, availabilitySchemaVersion=2,
        capacityPolicyRevision=revision[1],
        unchangedSourceSHA256={"SpeakerEvidence.swift": sha(evidence_path.read_bytes()),
            "LiveSpeakerCapacity.swift": sha(capacity_path.read_bytes())},
        beforeSHA256={name: sha(data) for name, data in before.items()},
        afterSHA256={name: sha(data) for name, data in after.items()},
        installerSHA256=sha(Path(__file__).read_bytes()))
    try:
        for name, path in paths.items():
            if path.read_bytes() != before[name]:
                raise ValueError("Copied source changed during installation")
        for name, data in after.items():
            paths[name].write_bytes(data)
        with record.open("x") as stream:
            json.dump(receipt, stream, indent=2)
            stream.write("\n")
    except BaseException:
        for name, data in before.items():
            paths[name].write_bytes(data)
        raise
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-path", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    print(json.dumps(install(args.package_path), indent=2))
