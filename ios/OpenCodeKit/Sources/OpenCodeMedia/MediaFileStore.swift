import ComposableArchitecture
import CryptoKit
import Foundation
import OpenCodeCore

/// App-owned staging for composer attachments. Records keep a path relative to this server's
/// directory; a picker URL, bookmark or security-scoped URL is never persisted.
public actor MediaFileStore {
  public struct Written: Sendable, Equatable {
    public var storedName: String
    public var byteCount: Int64
    public var head: Data
  }

  private let root: URL
  private let fileManager: FileManager

  public init(root: URL, fileManager: FileManager = .default) {
    self.root = root
    self.fileManager = fileManager
  }

  /// Application Support, not Caches: a draft's files are not disposable cache entries.
  public static func liveRoot() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return support.appendingPathComponent("ComposerAttachments", isDirectory: true)
  }

  public nonisolated func serverDirectory(_ serverID: String) -> URL {
    let token = SHA256.hash(data: Data(serverID.utf8)).map { String(format: "%02x", $0) }.joined()
    return root.appendingPathComponent(String(token.prefix(24)), isDirectory: true)
  }

  public func url(serverID: String, storedName: String) -> URL {
    serverDirectory(serverID).appendingPathComponent(storedName)
  }

  /// Copies bytes into a fresh per-attachment directory. Writes are atomic; a failure removes only
  /// the new directory.
  @discardableResult
  public func write(
    _ data: Data,
    name: String,
    serverID: String,
    id: String
  ) throws -> Written {
    try Task.checkCancellation()
    guard Int64(data.count) <= MediaLimits.maximumInlineBytes else {
      throw MediaAttachmentProblem.tooLarge
    }
    let cleanName = MediaFileType.sanitizedName(name)
    let storedName = "\(id)/\(cleanName)"
    let directory = serverDirectory(serverID).appendingPathComponent(id, isDirectory: true)
    let destination = directory.appendingPathComponent(cleanName)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      try excludeFromBackup(directory)
      try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      try? fileManager.removeItem(at: directory)
      throw MediaAttachmentProblem.couldNotWrite
    }
    return Written(
      storedName: storedName,
      byteCount: Int64(data.count),
      head: Data(data.prefix(4_096))
    )
  }

  /// Copies a file from a picker or a security-scoped URL. The scope is opened here and always
  /// closed, including on cancellation or failure.
  @discardableResult
  public func copyFile(
    at source: URL,
    name: String,
    serverID: String,
    id: String,
    maximumBytes: Int64 = MediaLimits.maximumFileBytes
  ) throws -> Written {
    try Task.checkCancellation()
    let scoped = source.startAccessingSecurityScopedResource()
    defer {
      if scoped { source.stopAccessingSecurityScopedResource() }
    }
    let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
      throw MediaAttachmentProblem.unreadable
    }
    if let size = values?.fileSize, Int64(size) > maximumBytes {
      throw MediaAttachmentProblem.tooLarge
    }
    let cleanName = MediaFileType.sanitizedName(name)
    let storedName = "\(id)/\(cleanName)"
    let directory = serverDirectory(serverID).appendingPathComponent(id, isDirectory: true)
    let destination = directory.appendingPathComponent(cleanName)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      try excludeFromBackup(directory)
      guard let input = try? FileHandle(forReadingFrom: source) else {
        throw MediaAttachmentProblem.unreadable
      }
      defer { try? input.close() }
      guard fileManager.createFile(
        atPath: destination.path,
        contents: nil,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
      ) else {
        throw MediaAttachmentProblem.couldNotWrite
      }
      let output = try FileHandle(forWritingTo: destination)
      defer { try? output.close() }
      var written: Int64 = 0
      while true {
        try Task.checkCancellation()
        let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
        if chunk.isEmpty { break }
        written += Int64(chunk.count)
        if written > maximumBytes {
          throw MediaAttachmentProblem.tooLarge
        }
        try output.write(contentsOf: chunk)
      }
      let head = try readPrefix(destination, count: 4_096)
      return Written(storedName: storedName, byteCount: written, head: head)
    } catch let problem as MediaAttachmentProblem {
      try? fileManager.removeItem(at: directory)
      throw problem
    } catch is CancellationError {
      try? fileManager.removeItem(at: directory)
      throw CancellationError()
    } catch {
      try? fileManager.removeItem(at: directory)
      throw MediaAttachmentProblem.couldNotWrite
    }
  }

  public func read(serverID: String, storedName: String, maximumBytes: Int64) throws -> Data {
    let url = url(serverID: serverID, storedName: storedName)
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true else { throw MediaAttachmentProblem.notFound }
    if let size = values?.fileSize, Int64(size) > maximumBytes {
      throw MediaAttachmentProblem.tooLarge
    }
    do {
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      guard Int64(data.count) <= maximumBytes else { throw MediaAttachmentProblem.tooLarge }
      return data
    } catch let problem as MediaAttachmentProblem {
      throw problem
    } catch {
      throw MediaAttachmentProblem.couldNotRead
    }
  }

  public func remove(serverID: String, storedName: String) {
    let url = url(serverID: serverID, storedName: storedName)
    try? fileManager.removeItem(at: url)
    try? fileManager.removeItem(at: url.deletingLastPathComponent())
  }

  /// Deletes partial or temporary writes left by a terminated import. A draft's own files are never
  /// touched here; they are released only with their record.
  public func cleanupTemporaryArtifacts() {
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    for case let url as URL in enumerator {
      let name = url.lastPathComponent
      if name.hasSuffix(".partial") || name.hasSuffix(".tmp") {
        try? fileManager.removeItem(at: url)
      }
    }
  }

  /// Removes every staged file not named by a live record. Callers pass the union of draft,
  /// failed-send and outbound references, scoped per server persistence ID.
  public func cleanupAbandonedFiles(serverID: String, keeping storedNames: Set<String>) {
    let directory = serverDirectory(serverID)
    guard let folders = try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey]
    ) else { return }
    for folder in folders {
      let id = folder.lastPathComponent
      let kept = storedNames.contains { $0 == id || $0.hasPrefix("\(id)/") }
      if !kept {
        try? fileManager.removeItem(at: folder)
      }
    }
  }

  private func readPrefix(_ url: URL, count: Int) throws -> Data {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
    defer { try? handle.close() }
    return try handle.read(upToCount: count) ?? Data()
  }

  private func excludeFromBackup(_ url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var copy = url
    try copy.setResourceValues(values)
  }
}

/// The staging store as a dependency. Its test value writes to a fresh temporary directory so an
/// isolated test can still exercise the real copy path.
public struct MediaFiles: Sendable {
  public var store: MediaFileStore

  public init(store: MediaFileStore) {
    self.store = store
  }

  public static func live() -> MediaFiles {
    MediaFiles(store: MediaFileStore(root: MediaFileStore.liveRoot()))
  }

  public static func testing(root: URL) -> MediaFiles {
    MediaFiles(store: MediaFileStore(root: root))
  }

  public var read: @Sendable (String, String, Int64) async throws -> Data {
    let store = store
    return { serverID, storedName, maximum in
      try await store.read(serverID: serverID, storedName: storedName, maximumBytes: maximum)
    }
  }

  public var url: @Sendable (String, String) async -> URL {
    let store = store
    return { serverID, storedName in
      await store.url(serverID: serverID, storedName: storedName)
    }
  }
}

extension MediaFiles: DependencyKey {
  public static let liveValue = MediaFiles.live()
  public static let testValue = MediaFiles(
    store: MediaFileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("open-code-media-test"))
  )
}

extension DependencyValues {
  public var mediaFiles: MediaFiles {
    get { self[MediaFiles.self] }
    set { self[MediaFiles.self] = newValue }
  }
}
