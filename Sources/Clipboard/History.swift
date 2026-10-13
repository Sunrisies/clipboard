import Foundation

struct HistoryEntry: Equatable, Identifiable {
    let id: UUID
    let text: String
    let image: ClipboardImage?
    var copiedAt: Date
    init(id: UUID, text: String, copiedAt: Date) {
        self.id = id; self.text = text; self.copiedAt = copiedAt; image = nil
    }
    init(id: UUID, content: ClipboardContent, copiedAt: Date) {
        self.id = id; self.copiedAt = copiedAt
        switch content {
        case .text(let text): self.text = text; image = nil
        case .image(let image): text = ""; self.image = image
        }
    }
    var content: ClipboardContent { image.map(ClipboardContent.image) ?? .text(text) }
    var title: String { image?.title ?? text }
    func matches(_ query: String) -> Bool {
        query.isEmpty || (image == nil ? text : "图片 image PNG \(image!.width) × \(image!.height)")
            .localizedStandardContains(query)
    }
}

struct History {
    private(set) var entries: [HistoryEntry]
    static let maximumTextBytes = 100 * 1024
    static let maximumTotalBytes = 20 * 1024 * 1024
    init(entries: [HistoryEntry] = []) { self.entries = entries }

    @discardableResult
    mutating func record(_ text: String, limit: Int, now: Date = Date()) -> Bool {
        record(.text(text), limit: limit, now: now)
    }
    @discardableResult
    mutating func record(_ content: ClipboardContent, limit: Int, now: Date = Date()) -> Bool {
        if case .text(let text) = content {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= Self.maximumTextBytes else { return false }
        }
        let previous = entries.first { $0.content == content }
        entries.removeAll { $0.content == content }
        entries.insert(HistoryEntry(id: previous?.id ?? UUID(), content: content, copiedAt: now), at: 0)
        trim(limit: limit)
        return true
    }
    mutating func trim(limit: Int) {
        var seen = Set<ClipboardContent>()
        var bytes = 0
        entries = Array(entries.filter {
            if $0.image == nil && ($0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || $0.text.utf8.count > Self.maximumTextBytes) { return false }
            guard seen.insert($0.content).inserted else { return false }
            bytes += $0.content.byteCount
            return bytes <= Self.maximumTotalBytes
        }.prefix(max(1, min(limit, 1000))))
    }
    mutating func clear() { entries.removeAll() }
    func matching(_ query: String) -> [HistoryEntry] { entries.filter { $0.matches(query) } }
}

// The index keeps the original text-history shape; old files decode without migration.
private struct DiskHistory: Codable { let entries: [DiskEntry] }
private struct DiskEntry: Codable {
    let id: UUID
    let text: String
    let copiedAt: Date
    let image: DiskImage?
}
private struct DiskImage: Codable {
    let digest: String
    let width: Int
    let height: Int
    var isValid: Bool {
        digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

final class HistoryStore {
    let url: URL
    private(set) var history: History
    private var imagesURL: URL { url.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true) }
    init(url: URL, limit: Int) throws {
        self.url = url
        history = History()
        if FileManager.default.fileExists(atPath: url.path) {
            let disk = try JSONDecoder().decode(DiskHistory.self, from: Data(contentsOf: url))
            history = History(entries: try disk.entries.map { entry in
                let content: ClipboardContent
                if let image = entry.image {
                    guard image.isValid else { throw CocoaError(.fileReadCorruptFile) }
                    let data = try Data(contentsOf: imagesURL.appendingPathComponent(image.digest + ".png"))
                    guard let decoded = ClipboardImage(storedPNG: data, width: image.width, height: image.height, digest: image.digest)
                    else { throw CocoaError(.fileReadCorruptFile) }
                    content = .image(decoded)
                } else { content = .text(entry.text) }
                return HistoryEntry(id: entry.id, content: content, copiedAt: entry.copiedAt)
            })
        }
        history.trim(limit: limit)
    }
    func record(_ text: String, limit: Int) throws { try record(.text(text), limit: limit) }
    func record(_ content: ClipboardContent, limit: Int) throws {
        var next = history
        guard next.record(content, limit: limit) else { return }
        try commit(next)
    }
    func trim(limit: Int) throws {
        var next = history; next.trim(limit: limit); try commit(next)
    }
    func clear() throws { try commit(History()) }
    private func commit(_ next: History) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if next.entries.contains(where: { $0.image != nil }) {
            try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let disk = DiskHistory(entries: try next.entries.map { entry in
            var metadata: DiskImage?
            if let image = entry.image {
                let path = imagesURL.appendingPathComponent(image.digest + ".png")
                if !FileManager.default.fileExists(atPath: path.path) {
                    try image.pngData.write(to: path, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                }
                metadata = DiskImage(digest: image.digest, width: image.width, height: image.height)
            }
            return DiskEntry(id: entry.id, text: entry.text, copiedAt: entry.copiedAt, image: metadata)
        })
        // Commit the index after image files exist, then remove evicted assets.
        try JSONEncoder().encode(disk).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        history = next
        let retained = Set(next.entries.compactMap { $0.image.map { $0.digest + ".png" } })
        if let files = try? FileManager.default.contentsOfDirectory(at: imagesURL, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "png" && !retained.contains(file.lastPathComponent) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
