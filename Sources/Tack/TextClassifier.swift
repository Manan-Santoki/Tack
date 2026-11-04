import Foundation

/// What a text clip looks like. This only affects how it's shown, never what gets pasted.
enum TextKind: String, Codable, Sendable {
    case plain, link, email, code

    /// Lets search find clips by type, for example "link" or "code".
    var searchName: String? { self == .plain ? nil : rawValue }
}

enum TextClassifier {
    /// Lines checked against the code patterns. Enough to decide, and fast on huge clips.
    private static let maxLines = 200
    /// Evidence needed before calling text code, so one code-like word in prose doesn't count.
    private static let codeScoreNeeded = 2
    private static let codeLineShareNeeded = 0.4

    /// File names look like web addresses to a link detector: `main.py`, `README.md`.
    private static let fileExtensions: Set<String> = [
        "c", "cpp", "css", "go", "h", "html", "java", "jpg", "js", "json", "lock", "md", "pdf",
        "png", "py", "rb", "rs", "sh", "swift", "toml", "ts", "txt", "yaml", "yml", "zip",
    ]

    /// Each match on a line adds one point.
    private static let codePatterns = [
        #"^\s*(func|def|fn|class|struct|enum|interface|function|public|private|protected|static|async|package|namespace|impl|type)\s+\w"#,
        #"^\s*(let|var|const|val)\s+\w+"#,
        #"^\s*#\s*(include|define|ifdef|ifndef|pragma)\b"#,
        #"^\s*(import\s+[\w.{*"'@]+|from\s+[\w.]+\s+import\s)"#,
        #"^\s*(if|for|while|switch|catch)\s*\(.*\)\s*\{?\s*$"#,
        #"^\s*(return\s+.*;|\}\s*else\s*\{?)\s*$"#,
        #"[;{}]\s*$"#,
        #"\w\(.*\)\s*[;:{]\s*$"#,
        #"(=>|->|===?|!==?|&&|\|\||::|\+=)"#,
        #"\b\w+\s*=\s*[\w"'\[{(]"#,
        #"</?[a-zA-Z][\w-]*(\s[^<>]*)?/?>"#,
        #"(?i)^\s*(select\s.+\sfrom\s|insert\s+into\s|update\s+\w+\s+set\s|delete\s+from\s|create\s+table\s)"#,
    ]

    /// These lines are code on their own, so they score full marks.
    private static let commandPatterns = [
        #"^\s*\$\s+\S"#,
        #"^\s*import\s+[\w.*]+(\s+as\s+\w+)?\s*;?\s*$"#,
        #"^\s*(git|npm|npx|yarn|pnpm|brew|sudo|docker|kubectl|cargo|pip3?)\s+[\w-]+"#,
        #"^\s*(cd|ls|mkdir|chmod|curl|wget)\s+[-./~\w]"#,
    ]

    static func classify(_ text: String) -> TextKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plain }
        return linkKind(of: trimmed) ?? (looksLikeCode(trimmed) ? .code : .plain)
    }

    /// The address to open for a link or email clip.
    static func url(for text: String, kind: TextKind) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .email:
            return URL(string: "mailto:\(trimmed)")
        case .link:
            guard let url = URL(string: trimmed) else { return nil }
            return url.scheme == nil ? URL(string: "https://\(trimmed)") : url
        case .plain, .code:
            return nil
        }
    }

    // MARK: - Links

    private static func linkKind(of text: String) -> TextKind? {
        guard !text.contains(where: \.isWhitespace),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }

        let fullRange = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: fullRange),
              match.range == fullRange,
              let url = match.url
        else { return nil }

        if url.scheme == "mailto" { return .email }

        // Written without a scheme, it might be a file name instead of an address.
        let hasScheme = text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil
        if !hasScheme, !text.contains("/"), !text.lowercased().hasPrefix("www.") {
            let ending = text.split(separator: ".").last.map { $0.lowercased() } ?? ""
            if fileExtensions.contains(ending) { return nil }
        }
        return .link
    }

    // MARK: - Code

    private static func looksLikeCode(_ text: String) -> Bool {
        if isJSONContainer(text) { return true }

        let lines = text.split(whereSeparator: \.isNewline)
            .prefix(maxLines)
            .map(String.init)
            .filter { !$0.allSatisfy(\.isWhitespace) }
        guard !lines.isEmpty else { return false }

        var score = 0
        var codeLines = 0
        for line in lines {
            let lineScore = self.score(line)
            score += lineScore
            if lineScore > 0 { codeLines += 1 }
        }
        return score >= codeScoreNeeded
            && Double(codeLines) / Double(lines.count) >= codeLineShareNeeded
    }

    private static func score(_ line: String) -> Int {
        // Sentences end in punctuation that code lines rarely do.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let last = trimmed.last, ".?!".contains(last) { return 0 }

        if commandPatterns.contains(where: { line.range(of: $0, options: .regularExpression) != nil }) {
            return codeScoreNeeded
        }
        return codePatterns.reduce(0) { total, pattern in
            total + (line.range(of: pattern, options: .regularExpression) == nil ? 0 : 1)
        }
    }

    private static func isJSONContainer(_ text: String) -> Bool {
        guard let first = text.first, "{[".contains(first), let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
