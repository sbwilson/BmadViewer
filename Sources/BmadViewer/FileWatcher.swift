import CoreServices
import Foundation

/// FSEvents over a few directories, reporting only changes to the text files a
/// BMAD project is made of, coalesced by the stream's latency.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void
    private static let extensions: Set<String> = ["md", "yaml", "yml", "toml"]

    init?(directories: [URL], latency: TimeInterval = 0.4, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let paths = directories.map { $0.path(percentEncoded: false) } as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            if paths.prefix(count).contains(where: { FileWatcher.extensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
                watcher.onChange()
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
