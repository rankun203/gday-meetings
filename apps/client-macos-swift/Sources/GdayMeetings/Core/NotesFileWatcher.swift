import Darwin
import Foundation

/// Watches the parent directory so atomic saves do not detach the observation.
/// Events are coalesced on the main actor; only the open meeting is observed.
@MainActor
final class NotesFileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var task: Task<Void, Never>?

    func start(directory: URL, changed: @escaping @MainActor () -> Void) throws {
        stop()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
        task?.cancel()
        task = nil
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }
}
