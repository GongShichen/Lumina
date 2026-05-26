import Foundation

struct ArithmeticParser {
    private let characters: [Character]
    private var index = 0

    init(_ expression: String) {
        self.characters = Array(expression.filter { !$0.isWhitespace })
    }

    mutating func parse() throws -> Double {
        let value = try parseExpression()
        guard index == characters.count else { throw NSError(domain: "LuminaCalculator", code: 1) }
        return value
    }

    private mutating func parseExpression() throws -> Double {
        var value = try parseTerm()
        while index < characters.count {
            if characters[index] == "+" {
                index += 1
                value += try parseTerm()
            } else if characters[index] == "-" {
                index += 1
                value -= try parseTerm()
            } else {
                break
            }
        }
        return value
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parseFactor()
        while index < characters.count {
            if characters[index] == "*" {
                index += 1
                value *= try parseFactor()
            } else if characters[index] == "/" {
                index += 1
                value /= try parseFactor()
            } else {
                break
            }
        }
        return value
    }

    private mutating func parseFactor() throws -> Double {
        if index < characters.count, characters[index] == "(" {
            index += 1
            let value = try parseExpression()
            guard index < characters.count, characters[index] == ")" else { throw NSError(domain: "LuminaCalculator", code: 2) }
            index += 1
            return value
        }
        let start = index
        if index < characters.count, characters[index] == "-" {
            index += 1
        }
        while index < characters.count, characters[index].isNumber || characters[index] == "." {
            index += 1
        }
        guard start < index, let value = Double(String(characters[start..<index])) else {
            throw NSError(domain: "LuminaCalculator", code: 3)
        }
        return value
    }
}
