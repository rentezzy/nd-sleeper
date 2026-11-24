import Foundation

public enum TOMLValue: Equatable, Sendable {
    case integer(Int)
    case string(String)
    case boolean(Bool)
}

public struct TOMLError: Error, Equatable, Sendable {
    public let line: Int
    public let message: String
}

public enum TOMLParser {
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return try lines.enumerated().reduce(into: [String: TOMLValue]()) { table, item in
            let lineNumber = item.offset + 1
            let content = stripComment(item.element).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }

            guard !content.hasPrefix("[") else {
                throw TOMLError(line: lineNumber, message: "tables are not supported, use top-level keys only")
            }
            guard let equals = content.firstIndex(of: "=") else {
                throw TOMLError(line: lineNumber, message: "expected key = value")
            }

            let key = content[..<equals].trimmingCharacters(in: .whitespaces)
            let rawValue = content[content.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard isBareKey(key) else {
                throw TOMLError(line: lineNumber, message: "invalid key \"\(key)\"")
            }
            guard table[key] == nil else {
                throw TOMLError(line: lineNumber, message: "\(key) is set twice")
            }
            table[key] = try value(rawValue, line: lineNumber)
        }
    }

    private static func stripComment(_ line: String) -> String {
        let state = line.reduce(into: (text: "", inString: false, escaped: false, done: false)) { state, character in
            guard !state.done else { return }
            if character == "#", !state.inString {
                state.done = true
                return
            }
            state.text.append(character)
            if state.inString, character == "\\", !state.escaped {
                state.escaped = true
                return
            }
            if character == "\"", !state.escaped {
                state.inString.toggle()
            }
            state.escaped = false
        }
        return state.text
    }

    private static func isBareKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func value(_ text: String, line: Int) throws -> TOMLValue {
        if text.hasPrefix("\"") {
            return .string(try string(text, line: line))
        }
        if text == "true" || text == "false" {
            return .boolean(text == "true")
        }
        guard let integer = integer(text) else {
            throw TOMLError(line: line, message: "unsupported value \(text.isEmpty ? "(empty)" : text)")
        }
        return .integer(integer)
    }

    private static func integer(_ text: String) -> Int? {
        let digits = text.hasPrefix("+") || text.hasPrefix("-") ? text.dropFirst() : Substring(text)
        guard let first = digits.first, let last = digits.last, first.isNumber, last.isNumber,
              !digits.contains("__"), digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "_") })
        else { return nil }
        return Int(text.replacingOccurrences(of: "_", with: ""))
    }

    private static func string(_ text: String, line: Int) throws -> String {
        guard text.count >= 2, text.hasSuffix("\"") else {
            throw TOMLError(line: line, message: "unterminated string")
        }
        let inner = text.dropFirst().dropLast()
        let state = inner.reduce(into: (text: "", escaped: false, strayQuote: false)) { state, character in
            if state.escaped {
                state.text.append(unescaped(character))
                state.escaped = false
            } else if character == "\\" {
                state.escaped = true
            } else if character == "\"" {
                state.strayQuote = true
            } else {
                state.text.append(character)
            }
        }
        guard !state.escaped else {
            throw TOMLError(line: line, message: "unterminated string")
        }
        guard !state.strayQuote else {
            throw TOMLError(line: line, message: "unexpected quote in string")
        }
        return state.text
    }

    private static func unescaped(_ character: Character) -> Character {
        switch character {
        case "n": "\n"
        case "t": "\t"
        default: character
        }
    }
}
