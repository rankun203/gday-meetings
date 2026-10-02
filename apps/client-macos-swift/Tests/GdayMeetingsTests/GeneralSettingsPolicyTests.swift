import Foundation
import Testing

@testable import GdayMeetings

struct GeneralSettingsPolicyTests {
    @Test func firstManualSelectionEnablesFeatureButLaterSwitchDoesNot() {
        var settings = AppSettings()
        settings.selectProvider(UUID(), for: .transcription)
        #expect(settings.autoTranscribe)
        settings.autoTranscribe = false
        settings.selectProvider(UUID(), for: .transcription)
        #expect(!settings.autoTranscribe)
    }
    @Test func firstHealthyProviderEnablesOnlyRelatedFeatures() {
        var settings = AppSettings()
        let provider = UUID()
        let assigned = settings.assignInitiallyHealthyProvider(provider, capabilities: [.liveDiarization])
        #expect(assigned)
        #expect(settings.liveDiarizationProviderID == provider)
        #expect(settings.showLiveSpeakerLabels)
        #expect(!settings.recognizeLiveSpeakers)
        #expect(!settings.labelRecordedSpeakers)
    }

    @Test func initialAssignmentRespectsIndependentExplicitFeatureChoices() throws {
        var settings = AppSettings()
        settings.recordExplicitFeatureChoice(\.recognizeLiveSpeakers, enabled: false)
        settings.recordExplicitFeatureChoice(\.autoSummarize, enabled: false)
        settings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        let provider = UUID()
        settings.assignInitiallyHealthyProvider(provider, capabilities: [.speakerRecognition, .summarization])
        #expect(settings.speakerRecognitionProviderID == provider)
        #expect(settings.summaryProviderID == provider)
        #expect(!settings.recognizeLiveSpeakers)
        #expect(settings.recognizeSpeakers)
        #expect(!settings.autoSummarize)
        #expect(settings.autoExtractTodos)
    }

    @Test func disablingToDosDoesNotDisableInitialSummarization() {
        var settings = AppSettings()
        settings.autoExtractTodos = false
        settings.recordExplicitFeatureChoice(\.autoExtractTodos, enabled: false)
        settings.assignInitiallyHealthyProvider(UUID(), capabilities: [.summarization])
        #expect(settings.autoSummarize)
        #expect(!settings.autoExtractTodos)
    }

    @Test func recoveryDoesNotOverrideExplicitOffOrClear() throws {
        var settings = AppSettings()
        let provider = UUID()
        settings.assignInitiallyHealthyProvider(provider, capabilities: [.diarization])
        settings.labelRecordedSpeakers = false
        let reassigned = settings.assignInitiallyHealthyProvider(provider, capabilities: [.diarization])
        #expect(!reassigned)
        #expect(!settings.labelRecordedSpeakers)
        settings.selectProvider(nil, for: .diarization)
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        var next = restored
        let restoredAssignment = next.assignInitiallyHealthyProvider(UUID(), capabilities: [.diarization])
        #expect(!restoredAssignment)
        #expect(next.diarizationProviderID == nil)
        #expect(!next.labelRecordedSpeakers)
    }

    @Test func legacyExplicitOffSurvivesFirstHealthyProvider() throws {
        var settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(
                """
                {"autoSummarize":false,"autoExtractTodos":false,"recognizeSpeakers":false}
                """.utf8))
        let provider = UUID()
        settings.assignInitiallyHealthyProvider(
            provider, capabilities: [.summarization, .speakerRecognition, .diarization])
        #expect(settings.summaryProviderID == provider)
        #expect(!settings.autoSummarize)
        #expect(!settings.autoExtractTodos)
        #expect(!settings.recognizeSpeakers)
        #expect(!settings.labelRecordedSpeakers)
        #expect(settings.recognizeLiveSpeakers)
    }

    @Test func missingLegacyPreferencesAllowInitialSetup() throws {
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        settings.assignInitiallyHealthyProvider(UUID(), capabilities: [.summarization, .diarization])
        #expect(settings.autoSummarize)
        #expect(settings.labelRecordedSpeakers)
    }

    @Test func legacyAssociationMigratesRecordedLabelingWithoutChangingLiveChoices() throws {
        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(
                """
                {"recognizeSpeakers":true,"showLiveSpeakerLabels":false,"recognizeLiveSpeakers":true}
                """.utf8))
        #expect(settings.labelRecordedSpeakers)
        #expect(settings.recognizeSpeakers)
        #expect(!settings.showLiveSpeakerLabels)
        #expect(settings.recognizeLiveSpeakers)
    }

    @Test func recordedAssociationRequiresAnEmbeddingSource() {
        var settings = AppSettings()
        settings.showLiveSpeakerLabels = true
        #expect(
            settings.recordedAssociationPrerequisite(
                liveLabelingReady: true, liveAssociationReady: true, recordedLabelingReady: false) != nil)
        settings.recognizeLiveSpeakers = true
        #expect(
            settings.recordedAssociationPrerequisite(
                liveLabelingReady: true, liveAssociationReady: true, recordedLabelingReady: false) == nil)
        #expect(
            settings.recordedAssociationPrerequisite(
                liveLabelingReady: true, liveAssociationReady: false, recordedLabelingReady: false) != nil)
        settings.autoTranscribe = true
        settings.autoTranscribeEvenWithLiveTranscript = true
        #expect(
            settings.recordedAssociationPrerequisite(
                liveLabelingReady: true, liveAssociationReady: true, recordedLabelingReady: false) != nil)
        settings.autoTranscribeEvenWithLiveTranscript = false
        settings.showLiveTranscript = false
        #expect(
            settings.recordedAssociationPrerequisite(
                liveLabelingReady: true, liveAssociationReady: true, recordedLabelingReady: false) != nil)
        settings.labelRecordedSpeakers = true
        let remote = ServiceProvider(kind: .runpod)
        settings.serviceProviders = [remote]
        settings.diarizationProviderID = remote.id
        #expect(
            settings.recordedAssociationPrerequisite(
                liveLabelingReady: true, liveAssociationReady: true, recordedLabelingReady: true) != nil)
        let local = ServiceProvider(kind: .community1)
        settings.serviceProviders = [local]
        settings.diarizationProviderID = local.id
        #expect(
            settings.recordedAssociationPrerequisite(
                liveLabelingReady: false, liveAssociationReady: false, recordedLabelingReady: true) == nil)
    }

    @Test func remoteLabelingRequiresDesiredSwitchAndSelectedProvider() {
        var settings = AppSettings()
        let provider = UUID()
        settings.diarizationProviderID = provider
        #expect(!settings.shouldLabelDuringTranscription(providerID: provider))
        settings.labelRecordedSpeakers = true
        #expect(settings.shouldLabelDuringTranscription(providerID: provider))
        #expect(!settings.shouldLabelDuringTranscription(providerID: UUID()))
    }

    @Test func standaloneLabelingPreservesManualPeopleAssignments() {
        let person = UUID()
        var assigned = MeetingSpeaker(label: "Speaker 1", track: "track0", providerName: "Local Provider")
        assigned.personID = person
        var meeting = Meeting(title: "Sample Recording")
        meeting.replaceSpeakers([assigned])
        let replacement = MeetingSpeaker(label: "Speaker 1", track: "track0", providerName: "Local Provider")
        let result = LocalDiarizationResult(modelRevision: "test", ranges: [], speakers: [replacement])
        let updated = LocalDiarizationAssignment.applying(result, to: meeting, fileCount: 1)
        #expect(updated.speakers.count == 2)
        #expect(updated.speakers.first { $0.id == assigned.id }?.personID == person)
        #expect(updated.speakers.first { $0.id == replacement.id }?.personID == nil)
        #expect(updated.personIDs.contains(person))
    }

    @Test func standaloneLabelingPreservesSpeakersWithoutTranscript() {
        let speaker = MeetingSpeaker(label: "Speaker 1", track: "track0", providerName: "Local Provider")
        let result = LocalDiarizationResult(modelRevision: "test", ranges: [], speakers: [speaker])
        let meeting = Meeting(title: "Sample Recording")
        let updated = LocalDiarizationAssignment.applying(result, to: meeting, fileCount: 1)
        #expect(updated.speakers == [speaker])
        #expect(updated.transcript.isEmpty)
    }
}
