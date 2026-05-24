import Foundation
import PersonalMemory

#if canImport(CoreML)
import CoreML

public struct LuminaBGEWordPieceTokenizer: Sendable {
    public struct Encoded: Sendable {
        public var inputIDs: [Int32]
        public var attentionMask: [Int32]
    }

    private let vocabulary: [String: Int32]
    private let unknownID: Int32
    private let classificationID: Int32
    private let separatorID: Int32
    private let paddingID: Int32
    private let maximumWordCharacters = 100

    public init(tokenizerURL: URL) throws {
        let data = try Data(contentsOf: tokenizerURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let rawVocabulary = model["vocab"] as? [String: Any] else {
            throw LuminaCoreMLEmbeddingError.invalidTokenizer("missing WordPiece vocabulary")
        }

        var parsed: [String: Int32] = [:]
        parsed.reserveCapacity(rawVocabulary.count)
        for (token, rawID) in rawVocabulary {
            if let id = rawID as? Int {
                parsed[token] = Int32(id)
            }
        }

        guard let unknownID = parsed["[UNK]"],
              let classificationID = parsed["[CLS]"],
              let separatorID = parsed["[SEP]"],
              let paddingID = parsed["[PAD]"] else {
            throw LuminaCoreMLEmbeddingError.invalidTokenizer("missing required special tokens")
        }

        self.vocabulary = parsed
        self.unknownID = unknownID
        self.classificationID = classificationID
        self.separatorID = separatorID
        self.paddingID = paddingID
    }

    public func encode(_ text: String, maxLength: Int = 512) -> Encoded {
        let payloadLimit = max(0, maxLength - 2)
        let tokenIDs = tokenize(text).prefix(payloadLimit)
        var inputIDs = [classificationID]
        inputIDs.append(contentsOf: tokenIDs)
        inputIDs.append(separatorID)

        if inputIDs.count > maxLength {
            inputIDs = Array(inputIDs.prefix(maxLength))
            inputIDs[maxLength - 1] = separatorID
        }

        var attentionMask = Array(repeating: Int32(1), count: inputIDs.count)
        if inputIDs.count < maxLength {
            let paddingCount = maxLength - inputIDs.count
            inputIDs.append(contentsOf: Array(repeating: paddingID, count: paddingCount))
            attentionMask.append(contentsOf: Array(repeating: Int32(0), count: paddingCount))
        }

        return Encoded(inputIDs: inputIDs, attentionMask: attentionMask)
    }

    private func tokenize(_ text: String) -> [Int32] {
        basicTokens(text).flatMap { wordPieceIDs(for: $0) }
    }

    private func basicTokens(_ text: String) -> [String] {
        var normalized = ""
        normalized.reserveCapacity(text.count * 2)

        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || Self.isControl(scalar) {
                normalized.append(" ")
            } else if Self.isChineseCharacter(scalar) {
                normalized.append(" ")
                normalized.append(Character(scalar))
                normalized.append(" ")
            } else {
                normalized.append(Character(scalar))
            }
        }

        var tokens: [String] = []
        var current = ""
        for scalar in normalized.unicodeScalars {
            if scalar.properties.isWhitespace {
                appendCurrent(&current, to: &tokens)
            } else if Self.isPunctuation(scalar) {
                appendCurrent(&current, to: &tokens)
                tokens.append(String(scalar))
            } else {
                current.append(Character(scalar))
            }
        }
        appendCurrent(&current, to: &tokens)
        return tokens
    }

    private func appendCurrent(_ current: inout String, to tokens: inout [String]) {
        guard !current.isEmpty else { return }
        tokens.append(current)
        current.removeAll(keepingCapacity: true)
    }

    private func wordPieceIDs(for token: String) -> [Int32] {
        if let direct = vocabulary[token] {
            return [direct]
        }
        if token.count > maximumWordCharacters {
            return [unknownID]
        }

        let characters = Array(token)
        var start = 0
        var subTokens: [Int32] = []
        while start < characters.count {
            var end = characters.count
            var currentID: Int32?
            while start < end {
                let piece = String(characters[start..<end])
                let candidate = start == 0 ? piece : "##\(piece)"
                if let id = vocabulary[candidate] {
                    currentID = id
                    break
                }
                end -= 1
            }

            guard let id = currentID else {
                return [unknownID]
            }
            subTokens.append(id)
            start = end
        }
        return subTokens
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned:
            return true
        default:
            return false
        }
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private static func isChineseCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F, 0x2B820...0x2CEAF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}

#endif
