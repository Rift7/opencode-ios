import Foundation
import SwiftUI

/// A Markdown block the transcript can draw without a web view. Unsupported constructs stay as
/// plain paragraphs; a malformed stream never loses text.
public enum MarkdownBlock: Equatable, Sendable {
  case heading(level: Int, text: String)
  case paragraph(String)
  case list(ordered: Bool, items: [MarkdownListItem])
  case quote(String)
  case code(language: String?, text: String)
  case table(header: [String], rows: [[String]])
  case rule
  case math(String)
  /// Remote images are links, not fetches: P8 never retrieves a resource on its own.
  case image(alt: String?, url: String)
}

public struct MarkdownListItem: Equatable, Sendable {
  public var text: String
  public var checked: Bool?

  public init(text: String, checked: Bool? = nil) {
    self.text = text
    self.checked = checked
  }
}

public enum MarkdownParser {
  public static func parse(_ source: String, limit: Int = 2_000_000) -> [MarkdownBlock] {
    let text = source.utf8.count > limit ? String(source.prefix(limit)) : source
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var blocks: [MarkdownBlock] = []
    var index = 0

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.isEmpty {
        index += 1
        continue
      }

      if let fence = fenceStart(trimmed) {
        var body: [String] = []
        index += 1
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          if candidate.hasPrefix(fence.marker), candidate.count >= fence.marker.count {
            index += 1
            break
          }
          body.append(lines[index])
          index += 1
        }
        blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
        continue
      }

      if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
        let closing = trimmed.hasPrefix("$$") ? "$$" : "\\]"
        let opening = trimmed.hasPrefix("$$") ? "$$" : "\\["
        var body = String(trimmed.dropFirst(opening.count))
        if body.hasSuffix(closing) {
          body = String(body.dropLast(closing.count))
          index += 1
        } else {
          var collected = [body]
          index += 1
          while index < lines.count {
            let candidate = lines[index].trimmingCharacters(in: .whitespaces)
            if candidate.hasSuffix(closing) {
              collected.append(String(candidate.dropLast(closing.count)))
              index += 1
              break
            }
            collected.append(lines[index])
            index += 1
          }
          body = collected.joined(separator: "\n")
        }
        blocks.append(.math(body.trimmingCharacters(in: .whitespacesAndNewlines)))
        continue
      }

      if let heading = heading(trimmed) {
        blocks.append(.heading(level: heading.level, text: heading.text))
        index += 1
        continue
      }

      if isRule(trimmed) {
        blocks.append(.rule)
        index += 1
        continue
      }

      if trimmed.hasPrefix(">") {
        var quoted: [String] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          guard candidate.hasPrefix(">") else { break }
          var body = String(candidate.dropFirst())
          if body.hasPrefix(" ") { body.removeFirst() }
          quoted.append(body)
          index += 1
        }
        blocks.append(.quote(quoted.joined(separator: "\n")))
        continue
      }

      if let table = table(at: index, lines: lines) {
        blocks.append(table.block)
        index = table.next
        continue
      }

      if let item = listItem(trimmed) {
        var ordered = item.ordered
        var items: [MarkdownListItem] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          if candidate.isEmpty { break }
          guard let next = listItem(candidate), next.ordered == ordered else { break }
          items.append(MarkdownListItem(text: next.text, checked: next.checked))
          index += 1
        }
        if items.isEmpty {
          // The shape changed on the first row; let the paragraph path draw it.
          let nextOrdered = !ordered
          ordered = nextOrdered
        }
        blocks.append(.list(ordered: ordered, items: items))
        continue
      }

      if let image = image(trimmed) {
        blocks.append(image)
        index += 1
        continue
      }

      var paragraph: [String] = []
      while index < lines.count {
        let candidate = lines[index].trimmingCharacters(in: .whitespaces)
        if candidate.isEmpty || startsBlock(candidate) { break }
        paragraph.append(candidate)
        index += 1
      }
      if paragraph.isEmpty {
        paragraph.append(trimmed)
        index += 1
      }
      blocks.append(.paragraph(paragraph.joined(separator: " ")))
    }
    return blocks
  }

  /// Inline Markdown as the system reads it; malformed content is the literal text.
  public static func inline(_ text: String) -> AttributedString {
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .inlineOnlyPreservingWhitespace
    options.failurePolicy = .returnPartiallyParsedIfPossible
    if let attributed = try? AttributedString(markdown: text, options: options) {
      return attributed
    }
    return AttributedString(text)
  }

  /// The Markdown a Copy action should place on the pasteboard.
  public static func markdown(from blocks: [MarkdownBlock]) -> String {
    blocks.map { block in
      switch block {
      case .heading(let level, let text): return String(repeating: "#", count: level) + " " + text
      case .paragraph(let text): return text
      case .list(_, let items):
        return items.map { item in
          let mark: String
          switch item.checked {
          case true: mark = "- [x] "
          case false: mark = "- [ ] "
          case nil: mark = "- "
          }
          return mark + item.text
        }.joined(separator: "\n")
      case .quote(let text): return text.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
      case .code(let language, let text):
        return "```\(language ?? "")\n\(text)\n```"
      case .table(let header, let rows):
        let head = "| " + header.joined(separator: " | ") + " |"
        let divider = "| " + header.map { _ in "---" }.joined(separator: " | ") + " |"
        return ([head, divider] + rows.map { "| " + $0.joined(separator: " | ") + " |" })
          .joined(separator: "\n")
      case .rule: return "---"
      case .math(let text): return "$$\n\(text)\n$$"
      case .image(let alt, let url): return "![\(alt ?? "")](\(url))"
      }
    }.joined(separator: "\n\n")
  }

  private static func fenceStart(_ line: String) -> (marker: String, language: String?)? {
    guard line.hasPrefix("```") || line.hasPrefix("~~~") else { return nil }
    let marker = String(line.prefix(3))
    let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    return (marker, language.isEmpty ? nil : language)
  }

  private static func heading(_ line: String) -> (level: Int, text: String)? {
    let hashes = line.prefix { $0 == "#" }
    guard (1...6).contains(hashes.count) else { return nil }
    let rest = line.dropFirst(hashes.count)
    guard rest.first == " " else { return nil }
    return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
  }

  private static func isRule(_ line: String) -> Bool {
    let stripped = line.filter { !$0.isWhitespace }
    guard stripped.count >= 3, let first = stripped.first, "-*_".contains(first) else { return false }
    return stripped.allSatisfy { $0 == first }
  }

  private static func listItem(_ line: String) -> (ordered: Bool, text: String, checked: Bool?)? {
    if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
      return (false, taskText(String(line.dropFirst(2))).text, taskText(String(line.dropFirst(2))).checked)
    }
    guard let dot = line.firstIndex(of: ".") else { return nil }
    let number = line[..<dot]
    guard !number.isEmpty, number.allSatisfy(\.isNumber), line.index(after: dot) < line.endIndex else {
      return nil
    }
    let after = line[line.index(after: dot)...]
    guard after.first == " " else { return nil }
    return (true, String(after.dropFirst()), nil)
  }

  private static func taskText(_ text: String) -> (text: String, checked: Bool?) {
    if text.hasPrefix("[ ] ") { return (String(text.dropFirst(4)), false) }
    if text.lowercased().hasPrefix("[x] ") { return (String(text.dropFirst(4)), true) }
    return (text, nil)
  }

  private static func image(_ line: String) -> MarkdownBlock? {
    guard line.hasPrefix("!["), let close = line.firstIndex(of: "]"),
      line.index(after: close) < line.endIndex, line[line.index(after: close)] == "(",
      line.hasSuffix(")")
    else { return nil }
    let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close])
    let url = String(line[line.index(close, offsetBy: 2)..<line.index(before: line.endIndex)])
    guard !url.isEmpty else { return nil }
    return .image(alt: alt.isEmpty ? nil : alt, url: url)
  }

  private static func table(at index: Int, lines: [String]) -> (block: MarkdownBlock, next: Int)? {
    guard index + 1 < lines.count else { return nil }
    let header = tableCells(lines[index])
    let divider = tableCells(lines[index + 1])
    guard !header.isEmpty, header.count == divider.count,
      divider.allSatisfy({ cell in
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == "-" || $0 == ":" }
      })
    else { return nil }
    var rows: [[String]] = []
    var cursor = index + 2
    while cursor < lines.count {
      let line = lines[cursor].trimmingCharacters(in: .whitespaces)
      guard line.contains("|") else { break }
      let cells = tableCells(lines[cursor])
      guard !cells.isEmpty else { break }
      rows.append(normalize(cells, count: header.count))
      cursor += 1
    }
    return (.table(header: header, rows: rows), cursor)
  }

  private static func tableCells(_ line: String) -> [String] {
    var text = line.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("|") { text.removeFirst() }
    if text.hasSuffix("|") { text.removeLast() }
    return text.split(separator: "|", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }

  private static func normalize(_ cells: [String], count: Int) -> [String] {
    if cells.count == count { return cells }
    if cells.count > count { return Array(cells.prefix(count)) }
    return cells + Array(repeating: "", count: count - cells.count)
  }

  private static func startsBlock(_ line: String) -> Bool {
    if fenceStart(line) != nil || heading(line) != nil || isRule(line) { return true }
    if line.hasPrefix(">") || listItem(line) != nil || image(line) != nil { return true }
    if line.hasPrefix("$$") || line.hasPrefix("\\[") { return true }
    return false
  }
}

/// Parsed blocks keyed by a row's identity and text length. The cache is bounded and cleared on a
/// memory warning; parsing itself runs off the main actor at the view's request.
public actor MarkdownBlockCache {
  public static let shared = MarkdownBlockCache()

  private struct Entry {
    var blocks: [MarkdownBlock]
    var characters: Int
    var tick: Int
  }

  private var entries: [String: Entry] = [:]
  private var tick = 0
  private var totalCharacters = 0
  private let maximumEntries: Int
  private let maximumCharacters: Int

  public init(maximumEntries: Int = 256, maximumCharacters: Int = 4 * 1024 * 1024) {
    self.maximumEntries = maximumEntries
    self.maximumCharacters = maximumCharacters
  }

  public func blocks(for key: String, text: String, parse: @Sendable (String) -> [MarkdownBlock] = { MarkdownParser.parse($0) }) -> [MarkdownBlock] {
    tick += 1
    if var entry = entries[key] {
      entry.tick = tick
      entries[key] = entry
      return entry.blocks
    }
    let blocks = parse(text)
    let characters = text.utf8.count
    entries[key] = Entry(blocks: blocks, characters: characters, tick: tick)
    totalCharacters += characters
    evictIfNeeded()
    return blocks
  }

  public func cached(_ key: String) -> [MarkdownBlock]? {
    guard var entry = entries[key] else { return nil }
    tick += 1
    entry.tick = tick
    entries[key] = entry
    return entry.blocks
  }

  public func clear() {
    entries.removeAll()
    totalCharacters = 0
    tick = 0
  }

  public var count: Int { entries.count }
  public var characterCount: Int { totalCharacters }

  private func evictIfNeeded() {
    while entries.count > maximumEntries || totalCharacters > maximumCharacters {
      guard let oldest = entries.min(by: { $0.value.tick < $1.value.tick })?.key,
        let entry = entries.removeValue(forKey: oldest)
      else { return }
      totalCharacters -= entry.characters
    }
  }
}
