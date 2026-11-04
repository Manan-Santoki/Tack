import Foundation

/// Scores text against a search. Works on folded UTF-16 so comparing is fast and ignores case and accents.
enum FuzzySearch {
    /// Exact matches are found anywhere in a clip. Looser matching stops here,
    /// because in long text almost any short search would match by accident.
    static let fuzzyWindow = 20_000
    private static let minFuzzyLength = 3
    private static let minTypoLength = 4

    static func fold(_ text: String) -> [UInt16] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf16)
    }

    /// Each word of the search has to match somewhere in the text.
    static func tokens(in query: String) -> [[UInt16]] {
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    /// The longest token decides whether typo matching is worth trying.
    static func canMatchTypos(_ tokens: [[UInt16]]) -> Bool {
        tokens.contains { $0.count >= minTypoLength }
    }

    /// Higher is better. Nil when any token doesn't match.
    static func score(tokens: [[UInt16]], in text: [UInt16], allowTypos: Bool = false) -> Int? {
        var total = 0
        for token in tokens {
            guard let score = score(token: token, in: text, allowTypos: allowTypos) else { return nil }
            total += score
        }
        return total
    }

    private static func score(token: [UInt16], in text: [UInt16], allowTypos: Bool) -> Int? {
        text.withUnsafeBufferPointer { text in
            token.withUnsafeBufferPointer { token in
                exactScore(token, text)
                    ?? subsequenceScore(token, text)
                    ?? (allowTypos ? typoScore(token, text) : nil)
            }
        }
    }

    // MARK: - Exact

    private static func exactScore(_ token: UnsafeBufferPointer<UInt16>, _ text: UnsafeBufferPointer<UInt16>) -> Int? {
        guard token.count <= text.count else { return nil }
        var first: Int?
        var index = 0
        let last = text.count - token.count
        while index <= last {
            if text[index] == token[0], matches(token, text, at: index) {
                if isWordStart(text, index) {
                    return 1200 + (index == 0 ? 100 : 0)
                }
                if first == nil { first = index }
            }
            index += 1
        }
        return first == nil ? nil : 1000
    }

    private static func matches(_ token: UnsafeBufferPointer<UInt16>, _ text: UnsafeBufferPointer<UInt16>, at start: Int) -> Bool {
        for offset in 0..<token.count where text[start + offset] != token[offset] {
            return false
        }
        return true
    }

    // MARK: - Letters in order

    /// The letters must appear in order and close together, so `gtst` finds `git status`.
    private static func subsequenceScore(_ token: UnsafeBufferPointer<UInt16>, _ text: UnsafeBufferPointer<UInt16>) -> Int? {
        guard token.count >= minFuzzyLength else { return nil }
        let end = min(text.count, fuzzyWindow)
        let maxSpan = token.count * 2 + 1
        var best: Int?

        var start = 0
        while start < end {
            defer { start += 1 }
            guard text[start] == token[0] else { continue }

            var matched = 1
            var position = start + 1
            let limit = min(end, start + maxSpan)
            var wordStarts = isWordStart(text, start) ? 1 : 0
            while position < limit, matched < token.count {
                if text[position] == token[matched] {
                    if isWordStart(text, position) { wordStarts += 1 }
                    matched += 1
                }
                position += 1
            }
            guard matched == token.count else { continue }

            let gaps = position - start - token.count
            let score = 500 - gaps * 20 + wordStarts * 40
            if score > (best ?? .min) { best = score }
        }
        return best
    }

    // MARK: - Typos

    /// Finds a word within one or two edits, counting swapped neighbours as one edit.
    private static func typoScore(_ token: UnsafeBufferPointer<UInt16>, _ text: UnsafeBufferPointer<UInt16>) -> Int? {
        guard token.count >= minTypoLength else { return nil }
        let maxEdits = token.count >= 8 ? 2 : 1
        let end = min(text.count, fuzzyWindow)
        var best: Int?

        var index = 0
        while index < end {
            guard isWordCharacter(text[index]) else {
                index += 1
                continue
            }
            var wordEnd = index
            while wordEnd < end, isWordCharacter(text[wordEnd]) { wordEnd += 1 }

            if abs(wordEnd - index - token.count) <= maxEdits {
                let word = UnsafeBufferPointer(rebasing: text[index..<wordEnd])
                if sharesEnoughLetters(token, word, maxEdits: maxEdits),
                   let edits = editDistance(token, word, limit: maxEdits) {
                    let score = 300 - edits * 50
                    if score > (best ?? .min) { best = score }
                }
            }
            index = wordEnd
        }
        return best
    }

    /// A quick check that rules out most words before the costly comparison.
    private static func sharesEnoughLetters(_ token: UnsafeBufferPointer<UInt16>, _ word: UnsafeBufferPointer<UInt16>, maxEdits: Int) -> Bool {
        var missing = 0
        for letter in token where !word.contains(letter) {
            missing += 1
            if missing > maxEdits { return false }
        }
        return true
    }

    private static func editDistance(_ a: UnsafeBufferPointer<UInt16>, _ b: UnsafeBufferPointer<UInt16>, limit: Int) -> Int? {
        var older = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            var rowBest = i
            if b.count > 0 {
                for j in 1...b.count {
                    let cost = a[i - 1] == b[j - 1] ? 0 : 1
                    var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                    if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                        value = min(value, older[j - 2] + 1)
                    }
                    current[j] = value
                    rowBest = min(rowBest, value)
                }
            }
            if rowBest > limit { return nil }
            swap(&older, &previous)
            swap(&previous, &current)
        }
        return previous[b.count] <= limit ? previous[b.count] : nil
    }

    // MARK: - Words

    private static func isWordCharacter(_ unit: UInt16) -> Bool {
        switch unit {
        case 48...57, 65...90, 97...122: true   // ASCII digits and letters
        case 128...: true                       // Anything else non-ASCII counts as a letter
        default: false
        }
    }

    private static func isWordStart(_ text: UnsafeBufferPointer<UInt16>, _ index: Int) -> Bool {
        index == 0 || !isWordCharacter(text[index - 1])
    }
}
