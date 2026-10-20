import AppKit

struct CaptureItem: Identifiable, Hashable {
    enum Kind { case image, video }

    let url: URL
    let date: Date
    var id: URL { url }

    /// GIFs are treated like videos: opened and shared as files rather than edited.
    var kind: Kind { ["mp4", "mov", "gif"].contains(url.pathExtension.lowercased()) ? .video : .image }

    func loadImage() -> (CGImage, CGFloat)? { ImageIOHelper.load(url) }

    /// Copies the capture into the user's save folder and returns the new location.
    @discardableResult
    func export(to directory: URL = Settings.saveDirectory) throws -> URL {
        let dest = HistoryStore.uniqueURL(in: directory, name: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}

/// Every capture is written here first. With history disabled the files go to a temp folder,
/// so overlays still have a file to drag and copy.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    var directory: URL {
        let fm = FileManager.default
        let dir: URL
        if Settings.historyEnabled {
            dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Skreener/History", isDirectory: true)
        } else {
            dir = fm.temporaryDirectory.appendingPathComponent("Skreener", isDirectory: true)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func uniqueURL(in dir: URL, name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    func newURL(ext: String) -> URL {
        Self.uniqueURL(in: directory, name: Settings.fileName(ext: ext))
    }

    func add(image: CGImage, pixelScale: CGFloat) throws -> CaptureItem {
        guard let data = ImageIOHelper.pngData(image, pixelScale: pixelScale) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = newURL(ext: "png")
        try data.write(to: url)
        prune()
        return CaptureItem(url: url, date: Date())
    }

    func items() -> [CaptureItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { ["png", "mp4", "mov", "gif"].contains($0.pathExtension.lowercased()) }
            .map { CaptureItem(url: $0, date: (try? $0.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast) }
            .sorted { $0.date > $1.date }
    }

    func delete(_ item: CaptureItem) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        NotificationCenter.default.post(name: .historyChanged, object: nil)
    }

    private func prune() {
        defer { NotificationCenter.default.post(name: .historyChanged, object: nil) }
        guard Settings.historyEnabled else { return }
        for item in items().dropFirst(Settings.historyLimit) {
            try? FileManager.default.removeItem(at: item.url)
        }
    }
}

extension Notification.Name {
    static let historyChanged = Notification.Name("SkreenerHistoryChanged")
}
