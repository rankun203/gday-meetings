import Darwin
import Foundation

/// Watches the parent directory so atomic saves do not detach the observation.
/// Events are coalesced on the main actor; only the open meeting is observed.
@MainActor
final class NotesFileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start(directory: URL, changed: @escaping @MainActor () -> Void) async throws {
        stop()
        let generation = generation
        let descriptor = try await Task.detached(priority: .utility) {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return descriptor
        }.value
        guard generation == self.generation, !Task.isCancelled else {
            close(descriptor)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.task?.cancel()
                self?.task = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(120)) }
                    catch { return }
                    changed()
                }
            }
        }
        self.source = source
        source.resume()
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }
}
