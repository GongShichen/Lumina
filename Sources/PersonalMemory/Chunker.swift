import Foundation

public struct MemoryChunker: Sendable {
    public var targetCharacters: Int
    public var overlapCharacters: Int

    public init(targetCharacters: Int = 900, overlapCharacters: Int = 120) {
        self.targetCharacters = targetCharacters
        self.overlapCharacters = overlapCharacters
    }

    public func chunks(for document: MemoryDocument) -> [MemoryChunk] {
        let text = document.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var results: [MemoryChunk] = []
        var start = text.startIndex

        while start < text.endIndex {
            let targetEnd = text.index(start, offsetBy: targetCharacters, limitedBy: text.endIndex) ?? text.endIndex
            let end = sentenceBoundary(in: text, from: start, proposedEnd: targetEnd)
            let chunkText = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)

            if !chunkText.isEmpty {
                results.append(MemoryChunk(
                    documentID: document.id,
                    source: document.source,
                    title: document.title,
                    text: chunkText,
                    summary: summarize(chunkText),
                    createdAt: document.createdAt,
                    sensitivity: document.sensitivity,
                    metadata: document.metadata
                ))
            }

            guard end < text.endIndex else { break }
            start = text.index(end, offsetBy: -min(overlapCharacters, text.distance(from: text.startIndex, to: end)), limitedBy: text.startIndex) ?? end
            if start == end {
                start = text.index(after: end)
            }
        }

        return results
    }

    private func sentenceBoundary(in text: String, from start: String.Index, proposedEnd: String.Index) -> String.Index {
        guard proposedEnd < text.endIndex else { return text.endIndex }
        let searchRange = start..<proposedEnd
        let punctuation: Set<Character> = [".", "?", "!", "。", "？", "！", "\n"]
        if let boundary = text[searchRange].lastIndex(where: { punctuation.contains($0) }) {
            return text.index(after: boundary)
        }
        return proposedEnd
    }

    private func summarize(_ text: String) -> String {
        let maxLength = 220
        if text.count <= maxLength { return text }
        let end = text.index(text.startIndex, offsetBy: maxLength, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[..<end]) + "..."
    }
}
