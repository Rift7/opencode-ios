import Foundation
import OpenCodeServer

/// What a composer attachment is. Images and long pastes travel inline in the prompt; other files
/// upload and travel as a server path reference.
public enum MediaAttachmentKind: String, Codable, Equatable, Sendable {
  case image
  case file
  case pastedText

  public var isInline: Bool { self != .file }
}

/// Why an import, upload or local read failed. Typed facts only; copy is chosen at the view edge.
public enum MediaAttachmentProblem: String, Codable, Equatable, Sendable, Error {
  case tooLarge
  case unreadable
  case unsupported
  case couldNotWrite
  case couldNotRead
  case cameraUnavailable
  case cameraDenied
  case uploadUnsupported
  case uploadFailed
  case uploadInterrupted
  case notFound
  case denied
}

/// A staged attachment's transfer state. A record with no upload yet is `.inline` for images and
/// pastes; files start `.uploading` and end `.uploaded` with the server's absolute path.
public enum MediaTransfer: Equatable, Sendable {
  case inline
  case uploading(sent: Int64)
  case uploaded(path: String)
  case failed(MediaAttachmentProblem)
}

extension MediaTransfer: Codable {
  private enum CodingKeys: String, CodingKey {
    case state, sent, path, problem
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .state) {
    case "inline": self = .inline
    case "uploading": self = .uploading(sent: try container.decode(Int64.self, forKey: .sent))
    case "uploaded": self = .uploaded(path: try container.decode(String.self, forKey: .path))
    case "failed": self = .failed(try container.decode(MediaAttachmentProblem.self, forKey: .problem))
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .state,
        in: container,
        debugDescription: "Unknown media transfer state \(other)"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .inline:
      try container.encode("inline", forKey: .state)
    case .uploading(let sent):
      try container.encode("uploading", forKey: .state)
      try container.encode(sent, forKey: .sent)
    case .uploaded(let path):
      try container.encode("uploaded", forKey: .state)
      try container.encode(path, forKey: .path)
    case .failed(let problem):
      try container.encode("failed", forKey: .state)
      try container.encode(problem, forKey: .problem)
    }
  }
}

/// One durable composer attachment. `storedName` is a path relative to this server's app-owned
/// staging directory, never a picker or security-scoped URL.
public struct MediaAttachment: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var kind: MediaAttachmentKind
  public var name: String
  public var mime: String
  public var byteCount: Int64
  public var storedName: String
  public var transfer: MediaTransfer
  public var pixelWidth: Int?
  public var pixelHeight: Int?

  public init(
    id: String,
    kind: MediaAttachmentKind,
    name: String,
    mime: String,
    byteCount: Int64,
    storedName: String,
    transfer: MediaTransfer,
    pixelWidth: Int? = nil,
    pixelHeight: Int? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.mime = mime
    self.byteCount = byteCount
    self.storedName = storedName
    self.transfer = transfer
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }

  public var isImage: Bool { kind == .image }

  public var isReady: Bool {
    switch transfer {
    case .inline, .uploaded: true
    case .uploading, .failed: false
    }
  }

  public var isUploading: Bool {
    if case .uploading = transfer { return true }
    return false
  }

  /// Upload completion fraction, 0…1. An inline attachment with a size is complete.
  public var progress: Double {
    switch transfer {
    case .inline: 1
    case .uploading(let sent):
      byteCount > 0 ? min(1, Double(sent) / Double(byteCount)) : 0
    case .uploaded: 1
    case .failed: 0
    }
  }

  /// The path reference the prompt carries once the file has uploaded.
  public var fileReference: PromptBody.Metadata.Attachment? {
    guard case .uploaded(let path) = transfer else { return nil }
    return PromptBody.Metadata.Attachment(name: name, mime: mime, path: path)
  }

  /// A send-ready copy with the staging path retained. A failed upload is not send-ready.
  public func sendReady() -> MediaAttachment? {
    isReady || kind.isInline ? self : nil
  }
}

/// Hard bounds shared by the importer and the composer. Values come from the audited attachment
/// contract: 20 MB source images re-encoded to 1568 px JPEG 0.8, 8 photos per pick, and four pastes
/// per import.
public enum MediaLimits {
  public static let maximumImageSourceBytes: Int64 = 20_000_000
  public static let maximumImageLongEdge = 1568
  public static let imageQuality = 0.8
  public static let maximumFileBytes: Int64 = 100 * 1024 * 1024
  public static let maximumPhotos = 8
  public static let maximumImagePastes = 4
  public static let maximumAttachments = 16
  public static let maximumInlineBytes: Int64 = 20 * 1024 * 1024
  public static let maximumPreviewBytes: Int64 = 2 * 1024 * 1024
  public static let maximumMediaBlobBytes: Int64 = 25 * 1024 * 1024

  /// A pasted string longer than this becomes a Pasted Text attachment instead of ordinary typing.
  public static func isLongPaste(_ text: String) -> Bool {
    if text.count > 1_000 { return true }
    let newlines = text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
    return newlines > 12 || (newlines == 12 && !text.hasSuffix("\n"))
  }
}

/// The image formats the composer treats as inline images.
public enum MediaFileType {
  public static let imageMimes: Set<String> = [
    "image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/heif",
  ]
  public static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif",
  ]
  public static let textMimes: Set<String> = [
    "application/json", "application/ld+json", "application/toml", "application/x-toml",
    "application/x-yaml", "application/xml", "application/yaml",
  ]
  public static let pdfMime = "application/pdf"

  public static func fileExtension(_ name: String) -> String {
    let base = name.split(separator: "/").last.map(String.init) ?? name
    guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
    return base[base.index(after: dot)...].lowercased()
  }

  public static func isInlineImage(name: String, mime: String?) -> Bool {
    if let mime, imageMimes.contains(mime.lowercased()) { return true }
    return imageExtensions.contains(fileExtension(name))
  }

  public static func sanitizedName(_ name: String) -> String {
    let cleaned = name
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .drop(while: { $0 == "." })
    return cleaned.isEmpty ? "file" : String(cleaned)
  }

  /// A file name the server can use as the last path component. Bytes with no useful extension
  /// keep their name; a leading path is removed.
  public static func mime(name: String, declared: String?, head: Data) -> String {
    let declaredType = (declared ?? "").split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    if imageMimes.contains(declaredType) || declaredType == pdfMime { return declaredType }
    let suffix = fileExtension(name)
    let fallback: String? = imageMimes.first { $0.hasSuffix("/\(suffix == "jpg" ? "jpeg" : suffix)") }
      ?? (suffix == "pdf" ? pdfMime : nil)
    if (declaredType.isEmpty || declaredType == "application/octet-stream"), let fallback {
      return fallback
    }
    if declaredType.hasPrefix("text/") || textMimes.contains(declaredType)
      || declaredType.hasSuffix("+json") || declaredType.hasSuffix("+xml")
    {
      return "text/plain"
    }
    let binary = declaredType.isEmpty ? "application/octet-stream" : declaredType
    let count = min(head.count, 4_096)
    guard count > 0 else { return binary }
    var control = 0
    for byte in head.prefix(count) {
      if byte == 0 { return binary }
      if byte < 9 || (14...31).contains(byte) { control += 1 }
    }
    return Double(control) / Double(count) > 0.3 ? binary : "text/plain"
  }

  /// "PDF", a language name, or the extension in capitals.
  public static func label(name: String, mime: String) -> String {
    if mime == pdfMime { return "PDF" }
    let suffix = fileExtension(name)
    guard !suffix.isEmpty else { return MediaCopy.text(.file) }
    return languageNames[suffix] ?? suffix.uppercased()
  }

  public static func symbolName(name: String, mime: String) -> String {
    if mime == pdfMime { return "doc.richtext" }
    if mime.hasPrefix("image/") { return "photo" }
    if mime.hasPrefix("video/") { return "film" }
    if mime.hasPrefix("audio/") { return "waveform" }
    if mime == "text/plain" { return "doc.text" }
    if mime.contains("zip") || mime.contains("archive") { return "doc.zipper" }
    return "doc"
  }

  public static func byteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private static let languageNames: [String: String] = [
    "c": "C", "cjs": "JavaScript", "cpp": "C++", "cs": "C#", "css": "CSS", "dart": "Dart",
    "go": "Go", "html": "HTML", "java": "Java", "js": "JavaScript", "json": "JSON",
    "jsx": "JSX", "kt": "Kotlin", "md": "Markdown", "php": "PHP", "py": "Python", "rb": "Ruby",
    "rs": "Rust", "sh": "Shell", "sql": "SQL", "swift": "Swift", "toml": "TOML", "ts": "TypeScript",
    "tsx": "TSX", "xml": "XML", "yaml": "YAML", "yml": "YAML", "zsh": "Zsh",
  ]
}

/// A media blob address. The hash is the server's content identity; the name is display only.
public struct MediaReference: Equatable, Sendable, Identifiable, Codable {
  public var hash: String
  public var name: String?
  public var mime: String?
  public var byteCount: Int64?
  public var isUnavailable: Bool

  public var id: String { hash }

  public init(
    hash: String,
    name: String? = nil,
    mime: String? = nil,
    byteCount: Int64? = nil,
    isUnavailable: Bool = false
  ) {
    self.hash = hash
    self.name = name
    self.mime = mime
    self.byteCount = byteCount
    self.isUnavailable = isUnavailable
  }

  /// The audited `media:<sha256>` identity.
  public static func isValidHash(_ hash: String) -> Bool {
    hash.count == 64 && hash.allSatisfy { $0.isHexDigit }
  }

  public static func uri(_ hash: String) -> String { "media:\(hash)" }

  public static func hash(_ uri: String?) -> String? {
    guard let uri, uri.hasPrefix("media:") else { return nil }
    let value = String(uri.dropFirst("media:".count)).lowercased()
    return isValidHash(value) ? value : nil
  }
}
