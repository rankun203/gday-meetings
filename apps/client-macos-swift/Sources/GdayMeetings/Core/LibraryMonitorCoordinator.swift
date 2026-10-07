import Combine
import Foundation

@MainActor
final class LibraryDataStatus: ObservableObject {
    @Published var meetingCount = 0
    @Published var indexBytes: Int64 = 0
    @Published var isBuilding = false
    @Published var processed = 0
    @Published var isDiscovering = false
    @Published var discoveredFolders = 0
    @Published var error: String?
}

/// Disk work is serialized off the main thread. Acknowledged event IDs are disposable index state.
final class LibraryMonitorCoordinator: @unchecked Sendable {
    private let root: URL
    private let indexDirectory: URL
    private var stopped = false
    private let queue = DispatchQueue(label: "com.gdaymeetings.library-reconcile", qos: .utility)
    private var monitor: LibraryFileMonitor?
    private var wakeObserver: ManagedTaskWakeObserver?
    private let pendingLock = NSLock()
    private var queued: LibraryFileMonitor.Batch?
    private var isScheduled = false
    private var pendingImports = Set<URL>()
    private var importSamples: [URL: [LibraryFolderImport.AudioFingerprint]] = [:]
    private var needsRecoveryScan = false
    private var unsettledOverflow = false
    private var importRetryScheduled = false
    private let report: @Sendable (Int?, Int64?, Bool, Int, String?) -> Void
    private let changed: @Sendable (Bool) -> Void
    private let directoryChanged: @Sendable ([URL], Bool) -> Void
    private let documentsChanged: @Sendable ([URL], Bool) -> Void
    private let discoveryProgress: @Sendable (Int) -> Void
    private var cursor: URL { indexDirectory.appendingPathComponent(".index-events.json") }

    init(
        root: URL, indexDirectory: URL? = nil, forceRebuild: Bool = false,
        report: @escaping @Sendable (Int?, Int64?, Bool, Int, String?) -> Void,
        changed: @escaping @Sendable (Bool) -> Void,
        directoryChanged: @escaping @Sendable ([URL], Bool) -> Void = { _, _ in },
        documentsChanged: @escaping @Sendable ([URL], Bool) -> Void = { _, _ in },
        discoveryProgress: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.root = LibraryFileMonitor.canonicalRoot(root)
        self.indexDirectory = indexDirectory ?? root
        self.report = report
        self.changed = changed
        self.directoryChanged = directoryChanged
        self.documentsChanged = documentsChanged
        self.discoveryProgress = discoveryProgress
        let saved =
            forceRebuild
            ? nil : (try? Data(contentsOf: cursor)).flatMap { try? JSONDecoder().decode(UInt64.self, from: $0) }
        monitor = LibraryFileMonitor(root: self.root, since: saved) { [weak self] batch in self?.process(batch) }
        if saved != nil { queue.async { [weak self] in self?.refreshCounts() } }
    }

    @MainActor func watchWake() {
        wakeObserver = ManagedTaskWakeObserver { [weak self] in self?.monitor?.flush() }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                pendingLock.lock()
                stopped = true
                queued = nil
                pendingLock.unlock()
                monitor = nil
                wakeObserver = nil
                continuation.resume()
            }
        }
    }

    func reconcileMissingMeeting(id: UUID) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !stopped else {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    let index = try LibraryIndex(directory: root, indexDirectory: indexDirectory)
                    let removed = try index.reconcileMissingMeeting(id: id)
                    if removed {
                        refreshCounts()
                        changed(false)
                    }
                    continuation.resume(returning: removed)
                }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func rebuild() { process(.init(paths: [], requiresScan: true, eventID: 0)) }

    func process(_ batch: LibraryFileMonitor.Batch) {
        pendingLock.lock()
        guard !stopped else {
            pendingLock.unlock()
            return
        }
        if var waiting = queued {
            waiting.eventID = max(waiting.eventID, batch.eventID)
            waiting.requiresScan = waiting.requiresScan || batch.requiresScan
            let paths = Set(waiting.paths + batch.paths)
            waiting.requiresScan = waiting.requiresScan || paths.count > 4096
            waiting.paths = waiting.requiresScan ? [] : Array(paths)
            queued = waiting
        }
        else {
            queued = batch
        }
        let schedule = !isScheduled
        isScheduled = true
        pendingLock.unlock()
        guard schedule else { return }
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            pendingLock.lock()
            let next = queued
            queued = nil
            if next == nil { isScheduled = false }
            pendingLock.unlock()
            guard let batch = next else { return }
            reconcile(batch)
        }
    }

    private func reconcile(_ incoming: LibraryFileMonitor.Batch) {
        var batch = incoming
        let meetingsRoot = root.appendingPathComponent("meetings").standardized.path
        let libraryRoot = root.standardized.path
        let hasAncestorEvent = batch.paths.contains {
            let path = $0.standardized.path
            return path == libraryRoot || path == meetingsRoot
        }
        batch.requiresScan = batch.requiresScan || needsRecoveryScan || hasAncestorEvent
        do {
            let index = try LibraryIndex(directory: self.root, indexDirectory: self.indexDirectory)
            batch.requiresScan = batch.requiresScan || index.requiresRebuild
            let existingCount = try index.count()
            if batch.requiresScan { self.report(existingCount, self.indexSize(), true, 0, nil) }
            var paths = batch.paths
            var importErrors: [String] = []
            var importErrorCount = 0
            let meetings = self.root.appendingPathComponent("meetings", isDirectory: true)
            func adopt(_ folder: URL) throws {
                guard FileManager.default.fileExists(atPath: folder.path) else {
                    pendingImports.remove(folder)
                    return
                }
                do {
                    if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("metadata.json").path) {
                        let sample = try LibraryFolderImport.fingerprints(folder)
                        if !sample.isEmpty && importSamples[folder] != sample {
                            if importSamples.count < 4096 { importSamples[folder] = sample }
                            throw LibraryFolderImport.ImportPending()
                        }
                    }
                    if let adopted = try LibraryFolderImport.adopt(folder, root: self.root) {
                        if !batch.requiresScan { paths.append(adopted.appendingPathComponent("metadata.json")) }
                        try LibraryFolderImport.updateDuration(adopted)
                    }
                    pendingImports.remove(folder)
                    importSamples.removeValue(forKey: folder)
                }
                catch is LibraryFolderImport.ImportPending {
                    if pendingImports.count < 4096 {
                        pendingImports.insert(folder)
                    }
                    else {
                        unsettledOverflow = true
                    }
                }
                catch {
                    importErrorCount += 1
                    if importErrors.count < 5 {
                        importErrors.append("\(folder.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            if batch.requiresScan {
                self.discoveryProgress(0)
                var discovered = 0
                if let folders = FileManager.default.enumerator(
                    at: meetings, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles])
                {
                    while let folder = folders.nextObject() as? URL {
                        try autoreleasepool {
                            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                            if values.isSymbolicLink == true {
                                folders.skipDescendants()
                                return
                            }
                            guard values.isDirectory == true else { return }
                            discovered += 1
                            if discovered % 500 == 0 { self.discoveryProgress(discovered) }
                            let isMeeting = FileManager.default.fileExists(
                                atPath: folder.appendingPathComponent("metadata.json").path)
                            if isMeeting { folders.skipDescendants() }
                            try adopt(folder)
                            if !FileManager.default.fileExists(atPath: folder.path) { folders.skipDescendants() }
                        }
                    }
                }
            }
            else {
                let prefix = meetings.standardizedFileURL.path + "/"
                let candidates = paths.compactMap { path -> URL? in
                    let normalized = path.standardizedFileURL.path
                    guard normalized.hasPrefix(prefix),
                        let component = normalized.dropFirst(prefix.count).split(separator: "/").first
                    else { return nil }
                    // Nested provider artifacts belong to their meeting, not a new import folder.
                    let folder = meetings.appendingPathComponent(String(component), isDirectory: true)
                    if FileManager.default.fileExists(atPath: folder.path),
                        (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                    {
                        return nil
                    }
                    return folder
                }
                for folder in Set(candidates).union(pendingImports) { try adopt(folder) }
            }
            if (!pendingImports.isEmpty || unsettledOverflow) && !importRetryScheduled {
                importRetryScheduled = true
                queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    self.importRetryScheduled = false
                    let scan = self.unsettledOverflow
                    self.unsettledOverflow = false
                    self.process(.init(paths: Array(self.pendingImports), requiresScan: scan, eventID: batch.eventID))
                }
            }
            if batch.requiresScan {
                self.report(nil, self.indexSize(), true, 0, nil)
                try index.rebuild { [weak self] count in
                    guard let self else { return }
                    self.report(index.lastCommittedCount ?? existingCount, self.indexSize(), true, count, nil)
                }
            }
            else if !paths.isEmpty {
                try index.reconcile(paths: paths)
            }
            directoryChanged(paths, batch.requiresScan)
            if batch.eventID > 0 && pendingImports.isEmpty && !unsettledOverflow {
                try JSONEncoder().encode(batch.eventID).write(to: self.cursor, options: .atomic)
            }
            needsRecoveryScan = false
            if index.lastRebuildErrorCount > 0 {
                importErrorCount += index.lastRebuildErrorCount
                importErrors.append("\(index.lastRebuildErrorCount) meeting documents could not be indexed.")
            }
            let importError =
                importErrorCount > 0
                ? "\(importErrorCount) folders need attention. " + importErrors.joined(separator: " ") : nil
            self.refreshCounts(error: importError)
            if batch.requiresScan || !paths.isEmpty {
                self.changed(batch.requiresScan)
                self.documentsChanged(paths, batch.requiresScan)
            }
        }
        catch {
            needsRecoveryScan = true
            self.report(nil, nil, false, 0, error.localizedDescription)
        }
    }

    private func indexSize() -> Int64 {
        ["index.db", "index.db-wal", "index.db-shm"].reduce(Int64(0)) { total, name in
            total
                + Int64(
                    (try? indexDirectory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        ?? 0)
        }
    }

    private func refreshCounts(error: String? = nil) {
        do {
            let count = try LibraryIndex(directory: root, indexDirectory: indexDirectory).count()
            report(count, indexSize(), false, 0, error)
        }
        catch { report(nil, nil, false, 0, error.localizedDescription) }
    }
}

extension MeetingStore {
    func startLibraryMonitoring() {
        libraryDataStatus.isBuilding = indexNeedsInitialRebuild
        libraryMonitor = LibraryMonitorCoordinator(
            root: dataDirectory, indexDirectory: indexDirectory, forceRebuild: indexNeedsInitialRebuild,
            report: { [weak self] count, bytes, building, processed, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let count {
                        let previous = self.libraryDataStatus.meetingCount
                        self.libraryDataStatus.meetingCount = count
                        if building && count > previous { self.refreshMeetingPageAvailabilityAfterIndexCommit() }
                        if !building && error == nil { self.indexNeedsInitialRebuild = false }
                    }
                    if let bytes { self.libraryDataStatus.indexBytes = bytes }
                    self.libraryDataStatus.isBuilding = building
                    self.libraryDataStatus.isDiscovering = false
                    self.libraryDataStatus.processed = processed
                    self.libraryDataStatus.error = error
                }
            },
            changed: { [weak self] rebuilt in
                Task { @MainActor in
                    guard let self else { return }
                    self.meetingIndexRevision = UUID()
                    self.scheduleSearchIndexing()
                    if rebuilt {
                        do {
                            self.libraryIndex = try LibraryIndex(
                                directory: self.dataDirectory, indexDirectory: self.indexDirectory)
                        }
                        catch {
                            self.libraryDataStatus.error =
                                "Couldn’t open the rebuilt index. \(error.localizedDescription)"
                            return
                        }
                    }
                }
            },
            directoryChanged: { [weak self] paths, rebuild in
                Task { @MainActor in self?.refreshDirectoryIndex(paths: paths, rebuild: rebuild) }
            },
            documentsChanged: { [weak self] paths, rebuild in
                Task { @MainActor in self?.requestExternalLibraryReload(paths: paths, rebuild: rebuild) }
            },
            discoveryProgress: { [weak self] count in
                Task { @MainActor in
                    self?.libraryDataStatus.isDiscovering = true
                    self?.libraryDataStatus.discoveredFolders = count
                }
            })
        libraryMonitor?.watchWake()
    }
}
