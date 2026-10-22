import Foundation
import Testing

@testable import GdayMeetings

struct PeopleScanPresentationTests {
    private func job(discover: Bool = true, state: VoicePreparationState, date: Double) -> VoicePreparationJob {
        VoicePreparationJob(
            providerID: UUID(), providerName: "Local Voices", type: .community1, discover: discover,
            exampleIDs: [], state: state, createdAt: Date(timeIntervalSince1970: date))
    }

    @Test func summarySeparatesScanFromPreparationAndPrioritizesRunningWork() {
        let scan = job(state: .running, date: 1)
        let completed = job(state: .completed, date: 2)
        let preparation = job(discover: false, state: .completed, date: 3)
        #expect(PeopleScanPresentation.prepare(jobs: [scan, completed, preparation])?.jobID == scan.id)
        #expect(PeopleScanPresentation.prepare(jobs: [preparation]) == nil)
        #expect(PeopleScanPresentation.prepare(jobs: [completed, preparation])?.jobID == completed.id)
    }

    @Test func completedFreshScanReplacesOldPausedHistory() {
        let paused = job(state: .paused, date: 1)
        let completed = job(state: .completed, date: 2)
        #expect(PeopleScanPresentation.prepare(jobs: [paused, completed])?.jobID == completed.id)
    }

    @Test func errorsAreBoundedAndPartialCompletionIsExplicit() {
        var scan = job(state: .completed, date: 1)
        scan.failures = Dictionary(
            uniqueKeysWithValues: (0..<5000).map { ("item-\($0)", "Couldn’t prepare example \($0).") })
        let summary = PeopleScanPresentation.prepare(jobs: [scan])!
        #expect(summary.failureCount == 5000)
        #expect(summary.failures.count == 3)
        #expect(summary.failures.map(\.id) == ["item-0", "item-1", "item-10"])
        #expect(summary.status == "Completed with Errors")
    }

    @Test func previewPrioritizesBlockersAndCombinesRepeatedMessages() {
        let preview = PeopleScanPresentation.errorPreview([
            "configuration": "Check the selected model.",
            "recording-z": "Couldn’t read this recording.",
            "example-a": "Couldn’t read this recording.",
            "example-b": "Couldn’t prepare this voice.",
            "example-c": "Couldn’t prepare this voice.",
        ])
        #expect(preview.map(\.id) == ["configuration", "recording-z", "example-b"])
        #expect(preview.map(\.count) == [1, 2, 2])
    }

    @MainActor @Test func activationReusesHealthCacheAndUnsupportedProviderReplacesPreviousReason() async {
        let provider = ServiceProvider(kind: .speakerLabeling)
        var settings = AppSettings()
        settings.serviceProviders = [provider]
        settings.diarizationProviderID = provider.id
        var calls = 0
        let health = ProviderHealthStore { _, _, _ in
            calls += 1
            return .ready
        }
        let readiness = DiarizationReadiness()
        await readiness.refresh(provider: provider, settings: settings, health: health)
        #expect(readiness.isReady(for: provider))
        await readiness.refresh(provider: provider, settings: settings, health: health)
        #expect(calls == 1)
        #expect(readiness.isReady(for: provider))

        let unavailable = ServiceProvider(kind: .runpod)
        await readiness.refresh(provider: unavailable, settings: settings, health: health)
        #expect(!readiness.isReady(for: provider))
        #expect(readiness.result.reason?.contains("RunPod") == true)
        #expect(calls == 1)

        let failureHealth = ProviderHealthStore { _, _, _ in .notReady("Download the selected model.") }
        await readiness.refresh(provider: provider, settings: settings, health: failureHealth)
        #expect(readiness.result.reason != nil)
        await readiness.refresh(provider: unavailable, settings: settings, health: failureHealth)
        #expect(readiness.result.reason?.contains("RunPod") == true)
    }

    @MainActor @Test func downloadedModelRecoversOnActivationThenReadyChecksStayCached() async {
        let provider = ServiceProvider(kind: .speakerLabeling)
        var settings = AppSettings()
        settings.serviceProviders = [provider]
        settings.diarizationProviderID = provider.id
        var modelAvailable = false
        var calls = 0
        let health = ProviderHealthStore { _, _, _ in
            calls += 1
            return modelAvailable ? .ready : .notReady("Download the selected model.")
        }
        let readiness = DiarizationReadiness()
        await readiness.refresh(provider: provider, settings: settings, health: health)
        #expect(readiness.result.reason != nil)
        #expect(calls == 1)
        modelAvailable = true
        await readiness.refresh(provider: provider, settings: settings, health: health)
        #expect(readiness.isReady(for: provider))
        #expect(calls == 2)
        await readiness.refresh(provider: provider, settings: settings, health: health)
        #expect(readiness.isReady(for: provider))
        #expect(calls == 2)
    }

    @MainActor @Test func lateReadyCheckCannotEnableChangedProvider() async {
        var pending: CheckedContinuation<ProviderHealth, Never>?
        let provider = ServiceProvider(kind: .speakerLabeling)
        var settings = AppSettings()
        settings.serviceProviders = [provider]
        let original = settings
        let health = ProviderHealthStore { _, _, captured in
            if captured.serviceProviders.first?.isEnabled == false { return .notReady("Provider is turned off.") }
            return await withCheckedContinuation { pending = $0 }
        }
        let readiness = DiarizationReadiness()
        let old = Task { await readiness.refresh(provider: provider, settings: original, health: health) }
        while pending == nil { await Task.yield() }
        var disabled = provider
        disabled.isEnabled = false
        settings.serviceProviders = [disabled]
        await readiness.refresh(provider: disabled, settings: settings, health: health)
        pending?.resume(returning: .ready)
        await old.value
        #expect(!readiness.isReady(for: disabled))
        #expect(readiness.result == .notReady("Provider is turned off."))
    }

    @MainActor @Test func cancelledReadinessDoesNotPublishLateResult() async {
        var pending: CheckedContinuation<ProviderHealth, Never>?
        let provider = ServiceProvider(kind: .speakerLabeling)
        var settings = AppSettings()
        settings.serviceProviders = [provider]
        let health = ProviderHealthStore { _, _, _ in
            await withCheckedContinuation { pending = $0 }
        }
        let readiness = DiarizationReadiness()
        let task = Task { await readiness.refresh(provider: provider, settings: settings, health: health) }
        while pending == nil { await Task.yield() }
        task.cancel()
        pending?.resume(returning: .ready)
        await task.value
        #expect(!readiness.isReady(for: provider))
        // A new appearance can use the completed shared health estimate.
        await readiness.refresh(provider: provider, settings: settings, health: health)
        #expect(readiness.isReady(for: provider))
    }

    @MainActor @Test func resumePolicyRequiresCurrentProviderAndCompatibleExtraction() {
        let provider = ServiceProvider(kind: .speakerLabeling)
        var scan = job(state: .paused, date: 1)
        scan.providerID = provider.id
        scan.type = .community1SpeechSpan
        #expect(PeopleScanPresentation.resumeUnavailableReason(for: scan, provider: provider) == nil)
        #expect(PeopleScanPresentation.resumeUnavailableReason(for: scan, provider: nil) != nil)
        #expect(
            PeopleScanPresentation.resumeUnavailableReason(for: scan, provider: ServiceProvider(kind: .speakerLabeling))
                != nil)
        scan.type = .community1
        #expect(PeopleScanPresentation.resumeUnavailableReason(for: scan, provider: provider) != nil)
    }

    @Test func latestTransitionDeterminesRelevantHistory() {
        var resumed = job(state: .cancelled, date: 1)
        resumed.timeline = [.init(kind: .ended, date: Date(timeIntervalSince1970: 10), reason: nil)]
        let completed = job(state: .completed, date: 2)
        #expect(PeopleScanPresentation.prepare(jobs: [resumed, completed])?.jobID == resumed.id)
    }
}
