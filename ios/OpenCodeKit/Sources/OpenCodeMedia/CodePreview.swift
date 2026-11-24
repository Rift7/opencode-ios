import Foundation

/// One bounded code page. Small files keep syntax tokens; large or long-line files render as plain
/// lines so one megabyte line can never lay out at once.
public struct CodePreview: Equatable, Sendable {
  public enum TokenKind: String, Equatable, Sendable {
    case keyword
    case string
    case comment
    case number
  }

  public struct Token: Equatable, Sendable {
    /// UTF-16 offsets into `text`.
    public var start: Int
    public var end: Int
    public var kind: TokenKind
  }

  public struct Line: Identifiable, Equatable, Sendable {
    public var id: Int
    public var number: Int
    public var text: String
    public var tokens: [Token]

    public init(id: Int, number: Int, text: String, tokens: [Token]) {
      self.id = id
      self.number = number
      self.text = text
      self.tokens = tokens
    }
  }

  public var text: String
  public var lines: [Line]
  public var isTruncated: Bool
  /// A `path:42` reference, when the link named one and the line exists.
  public var focusedLine: Int?

  public static let maximumHighlightBytes = 64 * 1024
  public static let maximumHighlightLines = 1_500
  public static let maximumLineBytes = 4_096
  public static let maximumLines = 20_000

  public static func make(
    data: Data,
    fileName: String,
    focusedLine: Int? = nil,
    maximumBytes: Int64 = MediaLimits.maximumPreviewBytes
  ) -> CodePreview? {
    guard Int64(data.count) <= maximumBytes else { return nil }
    let clipped = data.prefix(Int(maximumBytes))
    guard var text = String(data: clipped, encoding: .utf8) else { return nil }
    let truncated = Int64(data.count) > maximumBytes
    text = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let limited = Array(rawLines.prefix(maximumLines))
    let language = MediaFileType.fileExtension(fileName)
    let prose = ["md", "markdown", "mdx", "txt", "log", "csv", "tsv"].contains(language)
    let highlight = !prose
      && clipped.count <= maximumHighlightBytes
      && limited.count <= maximumHighlightLines
      && limited.allSatisfy { $0.utf8.count <= maximumLineBytes }
    var lines: [Line] = []
    lines.reserveCapacity(limited.count)
    for (offset, raw) in limited.enumerated() {
      let lineText = String(raw)
      lines.append(
        Line(
          id: offset,
          number: offset + 1,
          text: lineText,
          tokens: highlight ? CodeHighlighter.tokens(in: lineText, language: language) : []
        )
      )
    }
    let focus = focusedLine.flatMap { $0 >= 1 && $0 <= lines.count ? $0 : nil }
    return CodePreview(
      text: text,
      lines: lines,
      isTruncated: truncated || rawLines.count > maximumLines,
      focusedLine: focus
    )
  }
}

/// A small, bounded tokenizer: enough colour to read code, never a promise of full syntax support.
/// It walks one line at a time and stops at the line bound, so a pathological file cannot stall the
/// UI. Strings, comments, numbers and a per-language keyword set are recognised.
public enum CodeHighlighter {
  public static func tokens(in line: String, language: String) -> [CodePreview.Token] {
    guard !line.isEmpty else { return [] }
    let keywords = keywordSets[language] ?? keywordSets["default"]!
    let scalars = Array(line.utf16)
    var tokens: [CodePreview.Token] = []
    var index = 0
    let lineComment: String? = ["swift", "kt", "kts", "js", "ts", "jsx", "tsx", "c", "cpp", "h", "hpp", "java", "go", "rs", "cs", "dart"].contains(language) ? "//" : nil
    let hashComment = ["py", "rb", "sh", "zsh", "yaml", "yml", "toml", "plist"].contains(language) ? "#" : nil
    while index < scalars.count {
      if let lineComment, matches(lineComment, scalars, at: index) {
        tokens.append(.init(start: index, end: scalars.count, kind: .comment))
        break
      }
      if let hashComment, matches(hashComment, scalars, at: index) {
        tokens.append(.init(start: index, end: scalars.count, kind: .comment))
        break
      }
      let unit = scalars[index]
      if unit == 34 || unit == 39 {
        let quote = unit
        var end = index + 1
        while end < scalars.count {
          if scalars[end] == 92 { end += 2; continue }
          if scalars[end] == quote { end += 1; break }
          end += 1
        }
        tokens.append(.init(start: index, end: min(end, scalars.count), kind: .string))
        index = end
        continue
      }
      if isDigit(unit) {
        var end = index + 1
        while end < scalars.count, isNumberPart(scalars[end]) { end += 1 }
        tokens.append(.init(start: index, end: end, kind: .number))
        index = end
        continue
      }
      if isIdentifierStart(unit) {
        var end = index + 1
        while end < scalars.count, isIdentifierPart(scalars[end]) { end += 1 }
        let word = String(decoding: scalars[index..<end], as: UTF16.self)
        if keywords.contains(word) {
          tokens.append(.init(start: index, end: end, kind: .keyword))
        }
        index = end
        continue
      }
      index += 1
    }
    return tokens
  }

  private static func matches(_ needle: String, _ line: [UInt16], at index: Int) -> Bool {
    let units = Array(needle.utf16)
    guard index + units.count <= line.count else { return false }
    return Array(line[index..<(index + units.count)]) == units
  }

  private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
  private static func isNumberPart(_ unit: UInt16) -> Bool {
    isDigit(unit) || unit == 46 || unit == 95 || unit == 120 || (unit >= 65 && unit <= 70)
      || (unit >= 97 && unit <= 102)
  }
  private static func isIdentifierStart(_ unit: UInt16) -> Bool {
    (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit > 127
  }
  private static func isIdentifierPart(_ unit: UInt16) -> Bool {
    isIdentifierStart(unit) || isDigit(unit)
  }

  private static let keywordSets: [String: Set<String>] = {
    var sets: [String: Set<String>] = [
      "default": [
      "if", "else", "for", "while", "return", "true", "false", "nil", "null", "let", "var",
      "func", "class", "struct", "enum", "import", "public", "private", "switch", "case",
    ],
    "swift": [
      "actor", "any", "as", "async", "await", "break", "case", "catch", "class", "deinit", "do",
      "else", "enum", "extension", "false", "fileprivate", "for", "func", "guard", "if", "import",
      "in", "init", "internal", "is", "let", "nil", "open", "private", "protocol", "public",
      "repeat", "return", "self", "static", "struct", "subscript", "super", "switch", "throw",
      "throws", "true", "try", "typealias", "var", "where", "while",
    ],
    "kt": [
      "as", "break", "class", "companion", "const", "continue", "data", "do", "else", "enum",
      "false", "for", "fun", "if", "in", "interface", "internal", "is", "null", "object",
      "override", "package", "private", "protected", "public", "return", "sealed", "super",
      "this", "throw", "true", "try", "typealias", "val", "var", "when", "while",
    ],
    "js": [
      "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "else",
      "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in",
      "instanceof", "let", "new", "null", "return", "static", "switch", "this", "throw", "true",
      "try", "typeof", "undefined", "var", "while", "yield",
    ],
    "py": [
      "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
      "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is",
      "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try",
      "while", "with", "yield",
    ],
    "json": ["true", "false", "null"],
    "go": [
      "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
      "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
      "return", "select", "struct", "switch", "type", "var",
    ],
    "rs": [
      "as", "async", "await", "break", "const", "continue", "crate", "else", "enum", "extern",
      "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut",
      "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true", "type",
      "unsafe", "use", "where", "while",
    ],
    "c": [
      "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else",
      "enum", "extern", "float", "for", "goto", "if", "int", "long", "register", "return",
      "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned",
      "void", "volatile", "while",
    ],
    ]
    sets["kts"] = sets["kt"]
    sets["cpp"] = sets["c"]
    sets["h"] = sets["c"]
    sets["hpp"] = sets["c"]
    sets["java"] = sets["c"]
    sets["cs"] = sets["c"]
    sets["ts"] = sets["js"]
    sets["tsx"] = sets["js"]
    sets["jsx"] = sets["js"]
    sets["sh"] = sets["default"]
    sets["zsh"] = sets["default"]
    sets["yaml"] = sets["default"]
    sets["yml"] = sets["default"]
    sets["toml"] = sets["default"]
    sets["html"] = sets["default"]
    sets["xml"] = sets["default"]
    return sets
  }()
}
