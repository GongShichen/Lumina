import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

enum LuminaKnowledgeImportError: LocalizedError {
    case unsupportedType(String)
    case fileTooLarge(String)
    case unreadableText(String)
    case invalidPDF(String)
    case encryptedPDF(String)
    case pdfPageLimit(String)
    case emptyDocument(String)
    case documentLimit
    case chunkLimit
    case invalidManifest(String)
    case bundledDocumentMissing(String)
    case baseNotFound
    case bundledBaseCannotBeDeleted

    var errorDescription: String? {
        switch self {
        case let .unsupportedType(name): "不支持的知识文件类型：\(name)"
        case let .fileTooLarge(name): "文件超过 25 MiB 限制：\(name)"
        case let .unreadableText(name): "无法解码文本文件：\(name)"
        case let .invalidPDF(name): "PDF 已损坏或无法读取：\(name)"
        case let .encryptedPDF(name): "PDF 已加密，无法建立索引：\(name)"
        case let .pdfPageLimit(name): "PDF 超过页数限制：\(name)"
        case let .emptyDocument(name): "文件没有可检索文本：\(name)"
        case .documentLimit: "单个知识库最多包含 200 个文件。"
        case .chunkLimit: "启用的知识库总量超过 50,000 个 chunks。"
        case let .invalidManifest(reason): "知识库 manifest 无效：\(reason)"
        case let .bundledDocumentMissing(path): "内置知识文件不存在：\(path)"
        case .baseNotFound: "知识库不存在。"
        case .bundledBaseCannotBeDeleted: "内置知识库只能禁用，不能删除。"
        }
    }
}

struct LuminaExtractedKnowledgeSection: Sendable {
    var text: String
    var heading: String?
    var pageNumber: Int?
}

struct LuminaExtractedKnowledgeDocument: Sendable {
    var title: String
    var fileName: String
    var mediaType: String
    var data: Data
    var sections: [LuminaExtractedKnowledgeSection]
    var metadata: [String: String]
    var pageCount: Int?

    var characterCount: Int {
        sections.reduce(0) { $0 + $1.text.count }
    }
}

enum LuminaKnowledgeTextExtractor {
    static func extract(
        url: URL,
        configuration: LuminaKnowledgeStoreConfiguration
    ) throws -> LuminaExtractedKnowledgeDocument {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try extract(
            data: data,
            fileName: url.lastPathComponent,
            configuration: configuration
        )
    }

    static func extract(
        data: Data,
        fileName: String,
        configuration: LuminaKnowledgeStoreConfiguration
    ) throws -> LuminaExtractedKnowledgeDocument {
        guard data.count <= configuration.maximumFileBytes else {
            throw LuminaKnowledgeImportError.fileTooLarge(fileName)
        }
        let extensionName = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch extensionName {
        case "md", "markdown":
            let text = try decodeText(data, fileName: fileName)
            let parsed = markdownContent(text)
            let sections = parsed.sections
            guard sections.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw LuminaKnowledgeImportError.emptyDocument(fileName)
            }
            return LuminaExtractedKnowledgeDocument(
                title: URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent,
                fileName: fileName,
                mediaType: "text/markdown",
                data: data,
                sections: sections,
                metadata: parsed.metadata,
                pageCount: nil
            )
        case "txt", "text":
            let text = try decodeText(data, fileName: fileName)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LuminaKnowledgeImportError.emptyDocument(fileName)
            }
            return LuminaExtractedKnowledgeDocument(
                title: URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent,
                fileName: fileName,
                mediaType: "text/plain",
                data: data,
                sections: [LuminaExtractedKnowledgeSection(text: text, heading: nil, pageNumber: nil)],
                metadata: [:],
                pageCount: nil
            )
        case "pdf":
            #if canImport(PDFKit)
            guard let pdf = PDFDocument(data: data) else {
                throw LuminaKnowledgeImportError.invalidPDF(fileName)
            }
            guard !pdf.isEncrypted || !pdf.isLocked else {
                throw LuminaKnowledgeImportError.encryptedPDF(fileName)
            }
            guard pdf.pageCount <= configuration.maximumPDFPages else {
                throw LuminaKnowledgeImportError.pdfPageLimit(fileName)
            }
            let sections = (0..<pdf.pageCount).compactMap { index -> LuminaExtractedKnowledgeSection? in
                guard let rawText = pdf.page(at: index)?.string else { return nil }
                let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return LuminaExtractedKnowledgeSection(text: text, heading: nil, pageNumber: index + 1)
            }
            guard !sections.isEmpty else {
                throw LuminaKnowledgeImportError.emptyDocument(fileName)
            }
            return LuminaExtractedKnowledgeDocument(
                title: URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent,
                fileName: fileName,
                mediaType: "application/pdf",
                data: data,
                sections: sections,
                metadata: [:],
                pageCount: pdf.pageCount
            )
            #else
            throw LuminaKnowledgeImportError.unsupportedType(fileName)
            #endif
        default:
            throw LuminaKnowledgeImportError.unsupportedType(fileName)
        }
    }

    private static func decodeText(_ data: Data, fileName: String) throws -> String {
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian] {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        throw LuminaKnowledgeImportError.unreadableText(fileName)
    }

    private static func markdownContent(
        _ input: String
    ) -> (sections: [LuminaExtractedKnowledgeSection], metadata: [String: String]) {
        let lines = input.components(separatedBy: .newlines)
        var sections: [LuminaExtractedKnowledgeSection] = []
        var heading: String?
        var headingPath: [Int: String] = [:]
        var buffer: [String] = []
        var metadata: [String: String] = [:]
        var isFrontMatter = lines.first?.trimmingCharacters(in: .whitespaces) == "---"
        var isCodeFence = false

        func flush() {
            let text = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                sections.append(LuminaExtractedKnowledgeSection(text: text, heading: heading, pageNumber: nil))
            }
            buffer.removeAll(keepingCapacity: true)
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isFrontMatter {
                if index > 0 && trimmed == "---" {
                    isFrontMatter = false
                } else if index > 0, let separator = trimmed.firstIndex(of: ":") {
                    let key = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = trimmed[trimmed.index(after: separator)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !key.isEmpty {
                        metadata[key] = value
                    }
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                isCodeFence.toggle()
                buffer.append(line)
                continue
            }
            if !isCodeFence, trimmed.hasPrefix("#") {
                let prefixCount = trimmed.prefix { $0 == "#" }.count
                if prefixCount <= 6,
                   trimmed.dropFirst(prefixCount).first?.isWhitespace == true {
                    flush()
                    let value = trimmed.dropFirst(prefixCount)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    headingPath = headingPath.filter { $0.key < prefixCount }
                    headingPath[prefixCount] = value
                    heading = headingPath.keys.sorted().compactMap { headingPath[$0] }
                        .joined(separator: " › ")
                    continue
                }
            }
            buffer.append(line)
        }
        flush()
        return (sections, metadata)
    }
}

struct LuminaKnowledgeChunker: Sendable {
    var targetCharacters: Int
    var overlapCharacters: Int

    func chunks(
        extracted: LuminaExtractedKnowledgeDocument,
        document: LuminaKnowledgeDocument
    ) -> [LuminaKnowledgeChunk] {
        var chunks: [LuminaKnowledgeChunk] = []
        for section in extracted.sections {
            let text = section.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var startOffset = 0
            while startOffset < text.count {
                let proposedEnd = min(text.count, startOffset + targetCharacters)
                let endOffset = boundary(in: text, start: startOffset, proposedEnd: proposedEnd)
                let value = substring(text, start: startOffset, end: endOffset)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    let ordinal = chunks.count
                    let chunkHash = LuminaKnowledgeStableHash.string(
                        "\(document.knowledgeBaseID)|\(document.id)|\(document.contentHash)|\(ordinal)"
                    )
                    chunks.append(LuminaKnowledgeChunk(
                        id: chunkHash,
                        knowledgeBaseID: document.knowledgeBaseID,
                        documentID: document.id,
                        ordinal: ordinal,
                        title: section.heading ?? document.title,
                        text: value,
                        summary: summarize(value),
                        locator: LuminaKnowledgeLocator(
                            fileName: document.fileName,
                            heading: section.heading,
                            pageNumber: section.pageNumber,
                            characterStart: startOffset,
                            characterEnd: endOffset
                        ),
                        tags: document.tags,
                        contentHash: LuminaKnowledgeStableHash.string(value),
                        metadata: document.metadata
                    ))
                }
                guard endOffset < text.count else { break }
                let next = max(startOffset + 1, endOffset - min(overlapCharacters, endOffset))
                startOffset = next
            }
        }
        return chunks
    }

    private func boundary(in text: String, start: Int, proposedEnd: Int) -> Int {
        guard proposedEnd < text.count else { return text.count }
        let candidate = substring(text, start: start, end: proposedEnd)
        let punctuation: Set<Character> = [".", "?", "!", "。", "？", "！", "\n"]
        guard let last = candidate.lastIndex(where: { punctuation.contains($0) }) else {
            return proposedEnd
        }
        let distance = candidate.distance(from: candidate.startIndex, to: candidate.index(after: last))
        return max(start + 1, start + distance)
    }

    private func substring(_ text: String, start: Int, end: Int) -> String {
        let startIndex = text.index(text.startIndex, offsetBy: start)
        let endIndex = text.index(text.startIndex, offsetBy: end)
        return String(text[startIndex..<endIndex])
    }

    private func summarize(_ text: String) -> String {
        guard text.count > 240 else { return text }
        let end = text.index(text.startIndex, offsetBy: 240)
        return String(text[..<end]) + "…"
    }
}

enum LuminaKnowledgeStableHash {
    static func data(_ data: Data) -> String {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in data {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte &+ 31)) &* 0x100000001b3
        }
        return String(format: "%016llx%016llx", first, second)
    }

    static func string(_ value: String) -> String {
        data(Data(value.utf8))
    }
}
