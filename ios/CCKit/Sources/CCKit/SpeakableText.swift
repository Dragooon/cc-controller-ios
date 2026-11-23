import Foundation

/// Turns an agent's markdown into what the voice reads. Every word is kept: only markdown's symbols go. A fenced
/// code block is the one exception, read as "Code on screen.", and a table as "Table on screen.": the voice note
/// tells the agent anything meant only for the screen goes in one.
public enum SpeakableText {
    /// The whole reply an agent gives when what it heard wasn't meant for it. Never spoken.
    public static let skipReply = "(skip)"

    public static let codeOnScreen = "Code on screen."
    public static let tableOnScreen = "Table on screen."

    /// Whether a reply is the agent's "not for me" answer.
    public static func isSkip(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == skipReply || trimmed == "(skip)."
    }

    /// Markdown in, plain spoken prose out.
    public static func speakable(_ markdown: String) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        var insideFence = false
        var insideTable = false

        func endParagraph() {
            let joined = current.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { paragraphs.append(endWithPunctuation(joined)) }
            current = []
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if insideFence {
                    insideFence = false
                } else {
                    endParagraph()
                    paragraphs.append(codeOnScreen)
                    insideFence = true
                }
                continue
            }
            if insideFence { continue }

            if isTableLine(line) {
                if !insideTable {
                    endParagraph()
                    paragraphs.append(tableOnScreen)
                    insideTable = true
                }
                continue
            }
            insideTable = false

            if line.isEmpty || isRule(line) {
                endParagraph()
                continue
            }

            let cleaned = cleanInline(stripBlockMarkers(line))
            if cleaned.isEmpty { continue }
            if isBlockItem(line) {
                // A heading, list item or quote is its own sentence.
                endParagraph()
                paragraphs.append(endWithPunctuation(cleaned))
            } else {
                current.append(cleaned)
            }
        }
        endParagraph()
        return collapseSpaces(paragraphs.joined(separator: " "))
    }

    /// Splits speakable text into the pieces the voice asks the host for, in order. A fragment under three words
    /// joins the next one (short clips come out garbled), and a long first sentence is cut at a comma so the first
    /// audio arrives sooner.
    public static func sentences(_ text: String, firstChunkLimit: Int = 120, longSentenceLimit: Int = 300) -> [String] {
        let trimmed = collapseSpaces(text)
        guard !trimmed.isEmpty else { return [] }

        var pieces: [String] = []
        var buffer = ""
        let characters = Array(trimmed)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            buffer.append(character)
            if ".!?…".contains(character) {
                // Swallow closing quotes and brackets that belong to the sentence.
                while index + 1 < characters.count, "\"')]”’".contains(characters[index + 1]) {
                    index += 1
                    buffer.append(characters[index])
                }
                let nextIsSpace = index + 1 >= characters.count || characters[index + 1] == " "
                if nextIsSpace && !endsWithAbbreviationOrNumber(buffer, next: index + 2 < characters.count ? characters[index + 2] : nil) {
                    pieces.append(buffer.trimmingCharacters(in: .whitespaces))
                    buffer = ""
                }
            }
            index += 1
        }
        let rest = buffer.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { pieces.append(rest) }

        var merged: [String] = []
        var carry = ""
        for piece in pieces {
            let candidate = carry.isEmpty ? piece : carry + " " + piece
            if wordCount(candidate) < 3 {
                carry = candidate
            } else {
                merged.append(candidate)
                carry = ""
            }
        }
        if !carry.isEmpty {
            if let last = merged.popLast() { merged.append(last + " " + carry) } else { merged.append(carry) }
        }

        var result: [String] = []
        for (position, sentence) in merged.enumerated() {
            let limit = position == 0 ? firstChunkLimit : longSentenceLimit
            result.append(contentsOf: splitAtCommas(sentence, limit: limit))
        }
        return result
    }

    // MARK: - Pieces

    private static func isTableLine(_ line: String) -> Bool {
        line.hasPrefix("|") && line.dropFirst().contains("|")
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isBlockItem(_ line: String) -> Bool {
        line.hasPrefix("#") || line.hasPrefix(">") || listMarkerLength(line) > 0
    }

    private static func listMarkerLength(_ line: String) -> Int {
        for marker in ["- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return marker.count
        }
        // "1. " or "12) "
        var digits = 0
        for character in line {
            if character.isNumber { digits += 1 } else { break }
        }
        if digits > 0, digits < 4 {
            let after = line.dropFirst(digits)
            if after.hasPrefix(". ") || after.hasPrefix(") ") { return digits + 2 }
        }
        return 0
    }

    private static func stripBlockMarkers(_ line: String) -> String {
        var text = line
        while text.hasPrefix(">") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if text.hasPrefix("#") {
            text = String(text.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
        }
        let marker = listMarkerLength(text)
        if marker > 0 {
            let isNumbered = text.first?.isNumber == true
            if isNumbered {
                // Keep the number so "1." is read; drop only the bracket form's ")".
                let digits = text.prefix(while: { $0.isNumber })
                text = String(digits) + ". " + String(text.dropFirst(marker))
            } else {
                text = String(text.dropFirst(marker))
            }
        }
        return text
    }

    private static func cleanInline(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),          // images: alt text
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),           // links: their words
            (#"\[([^\]]+)\]\[[^\]]*\]"#, "$1"),          // reference links
            (#"`+([^`]+)`+"#, "$1"),                     // inline code
            (#"\*\*([^*]+)\*\*"#, "$1"),                 // bold
            (#"__([^_]+)__"#, "$1"),
            (#"~~([^~]+)~~"#, "$1"),                     // strikethrough
            (#"(?<![\w*])\*(?!\s)([^*]+?)(?<!\s)\*(?![\w*])"#, "$1"),  // italic
            (#"(?<![\w_])_(?!\s)([^_]+?)(?<!\s)_(?![\w_])"#, "$1"),
            (#"<br\s*/?>"#, " "),
            (#"</?[a-zA-Z][^>]*>"#, ""),                 // other HTML tags
        ]
        for (pattern, template) in replacements {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return collapseSpaces(result)
    }

    private static func endWithPunctuation(_ text: String) -> String {
        guard let last = text.last else { return text }
        if ".!?…:;".contains(last) { return last == ":" || last == ";" ? String(text.dropLast()) + "." : text }
        if "\"')]”’".contains(last) { return text }
        return text + "."
    }

    private static func collapseSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static let abbreviations: Set<String> = ["e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "ms.", "dr.", "st.", "approx.", "no."]

    private static func endsWithAbbreviationOrNumber(_ buffer: String, next: Character?) -> Bool {
        let lastWord = buffer.split(separator: " ").last.map { String($0).lowercased() } ?? ""
        if abbreviations.contains(lastWord) {
            // "etc." can still end a sentence when a capital follows.
            if lastWord == "etc.", let next, next.isUppercase { return false }
            return true
        }
        return false
    }

    private static func splitAtCommas(_ sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var pieces: [String] = []
        var remaining = Substring(sentence)
        while remaining.count > limit {
            let window = remaining.prefix(limit)
            guard let cut = window.lastIndex(where: { $0 == "," || $0 == ";" }), remaining.distance(from: remaining.startIndex, to: cut) > 20 else { break }
            let head = remaining[...cut].trimmingCharacters(in: .whitespaces)
            pieces.append(head)
            remaining = remaining[remaining.index(after: cut)...].drop(while: { $0 == " " })
        }
        let tail = remaining.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}
