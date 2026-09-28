import CoreServices
import Darwin
import Foundation

/// One recursive stream for the library. The cursor is acknowledged only after reconciliation succeeds.
final class LibraryFileMonitor: @unchecked Sendable {
    struct Batch: Sendable {
        var paths: [URL]
        var requiresScan: Bool
        var eventID: UInt64
    }
    private let root: URL
    private let queue = DispatchQueue(label: "com.gdaymeetings.library-events", qos: .utility)
    private let receive: @Sendable (Batch) -> Void
    private var stream: FSEventStreamRef?
    private var pending = Set<String>()
    private var scan = false
    private var latest: UInt64 = 0
    private var delivery: DispatchWorkItem?
    private final class CallbackContext {
        weak var owner: LibraryFileMonitor?
    }

    init(root: URL, since: UInt64?, receive: @escaping @Sendable (Batch) -> Void) {
        self.root = Self.canonicalRoot(root)
        self.receive = receive
        latest = FSEventsGetCurrentEventId()
        let callbackContext = CallbackContext()
        callbackContext.owner = self
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(callbackContext).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<CallbackContext>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                if let pointer { Unmanaged<CallbackContext>.fromOpaque(pointer).release() }
            }, copyDescription: nil
        )
        stream = FSEventStreamCreate(
            nil,
            { _, info, count, paths, flags, ids in
                guard let info else { return }
                guard let owner = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue().owner else {
                    return
                }
                let values = unsafeBitCast(paths, to: NSArray.self) as! [String]
                for index in 0..<count {
                    owner.accept(path: values[index], flags: flags[index], id: ids[index])
                }
            }, &context, [self.root.path] as CFArray, since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) { scan = true }
        }
        if since == nil || (since ?? 0) > latest || stream == nil || scan {
            queue.async { [weak self] in self?.scheduleScan() }
        }
    }

    func flush() {
        queue.async { [weak self] in
            if let stream = self?.stream { FSEventStreamFlushAsync(stream) }
        }
    }

    /// Foundation standardization can shorten /private/tmp back to /tmp, while
    /// FSEvents reports the physical /private path. Keep the POSIX canonical spelling.
    static func canonicalRoot(_ root: URL) -> URL {
        guard
            let resolved = root.withUnsafeFileSystemRepresentation({ path in
                path.flatMap { realpath($0, nil) }
            })
        else { return root.absoluteURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    static func isRelevant(relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/")
        guard let first = parts.first else { return true }
        if first.hasPrefix("index.db") || first.hasPrefix(".index") || first == "cache" || first == "caches"
            || first == "staging"
        {
            return false
        }
        return !parts.contains(where: { $0.hasPrefix(".") })
    }

    private func accept(path: String, flags: FSEventStreamEventFlags, id: UInt64) {
        latest = max(latest, id)
        let failureFlags =
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagEventIdsWrapped
        if flags & UInt32(failureFlags) != 0 { scan = true }
        if path == root.path {
            pending.insert(path)
        }
        else if path.hasPrefix(root.path + "/") {
            let relative = String(path.dropFirst(root.path.count + 1))
            if Self.isRelevant(relativePath: relative) { pending.insert(path) }
        }
        if pending.count > 4096 {
            pending.removeAll()
            scan = true
        }
        if scan || !pending.isEmpty { scheduleDelivery() }
    }

    private func scheduleScan() {
        scan = true
        scheduleDelivery()
    }

    private func scheduleDelivery() {
        guard delivery == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = Batch(
                paths: self.pending.map { URL(fileURLWithPath: $0) }, requiresScan: self.scan, eventID: self.latest)
            self.pending.removeAll()
            self.scan = false
            self.delivery = nil
            self.receive(batch)
        }
        delivery = item
        queue.asyncAfter(deadline: .now() + 1, execute: item)
    }

    deinit {
        delivery?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
