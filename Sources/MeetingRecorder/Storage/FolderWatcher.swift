import Foundation
import MeetingCore

/// Fires (debounced) when anything changes inside the watched directories.
@MainActor
final class FolderWatcher {
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var debounce: Task<Void, Never>?
    var onChange: (() -> Void)?

    func watch(_ directories: [URL]) {
        let wanted = Set(directories.map { $0.standardizedFileURL })
        for (url, source) in sources where !wanted.contains(url) {
            source.cancel()
            sources[url] = nil
        }
        for url in wanted where sources[url] == nil {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
            source.setEventHandler { [weak self] in self?.schedule() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[url] = source
        }
    }

    func stop() {
        for (_, s) in sources { s.cancel() }
        sources = [:]
    }

    private func schedule() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}
