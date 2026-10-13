import Foundation

struct TextSnippet: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let text: String
    let updatedAt: Date

    var entry: HistoryEntry { HistoryEntry(id: id, text: text, copiedAt: updatedAt) }
    func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedStandardContains(query) || text.localizedStandardContains(query)
    }
}

enum SnippetError: LocalizedError {
    case emptyText, oversizedText, oversizedTitle, capacity, missing
    var errorDescription: String? {
        switch self {
        case .emptyText: return "请输入文本内容。"
        case .oversizedText: return "单条常用文本最多 100 KiB。"
        case .oversizedTitle: return "名称最多 120 个字符。"
        case .capacity: return "常用文本最多 1000 条，总量最多 20 MiB。"
        case .missing: return "这条常用文本已不存在，请重新选择。"
        }
    }
}

final class SnippetStore {
    let url: URL
    private(set) var snippets: [TextSnippet] = []

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let loaded = try JSONDecoder().decode([TextSnippet].self, from: Data(contentsOf: url))
            guard Set(loaded.map(\.id)).count == loaded.count else { throw CocoaError(.fileReadCorruptFile) }
            try Self.validateCapacity(loaded)
            for snippet in loaded { _ = try Self.validatedTitle(snippet.title, text: snippet.text) }
            snippets = loaded
        }
    }

    static func validatedTitle(_ title: String, text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SnippetError.emptyText }
        guard text.utf8.count <= History.maximumTextBytes else { throw SnippetError.oversizedText }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 120 else { throw SnippetError.oversizedTitle }
        return trimmed.isEmpty ? String(text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")[0].prefix(40)) : trimmed
    }

    @discardableResult
    func save(id: UUID? = nil, title: String, text: String) throws -> TextSnippet {
        let snippet = TextSnippet(id: id ?? UUID(), title: try Self.validatedTitle(title, text: text), text: text, updatedAt: Date())
        var next = snippets
        if let id {
            guard let index = next.firstIndex(where: { $0.id == id }) else { throw SnippetError.missing }
            next[index] = snippet
        } else { next.insert(snippet, at: 0) }
        try commit(next)
        return snippet
    }

    func delete(id: UUID) throws {
        guard snippets.contains(where: { $0.id == id }) else { throw SnippetError.missing }
        try commit(snippets.filter { $0.id != id })
    }

    private static func validateCapacity(_ snippets: [TextSnippet]) throws {
        guard snippets.count <= 1000,
              snippets.reduce(0, { $0 + $1.text.utf8.count + $1.title.utf8.count }) <= History.maximumTotalBytes else { throw SnippetError.capacity }
    }

    private func commit(_ next: [TextSnippet]) throws {
        try Self.validateCapacity(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        snippets = next
    }
}
