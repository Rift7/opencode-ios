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

  private struct Lease: Sendable, Hashable {
    var token: UUID
    var serverID: String
    var storedName: String
  }

  private let root: URL
  private let fileManager: FileManager
  private var leases: [UUID: Lease] = [:]

  public init(root: URL, fileManager: FileManager = .default) {
    self.root = root
    self.fileManager = fileManager
  }

  /// App-controlled scratch. Only files this store put here are disposable on launch; a user's
  /// `report.tmp` lives under the final attachment path and is never inferred disposable.
  public nonisolated var scratchDirectory: URL {
    root.appendingPathComponent(".staging", isDirectory: true)
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
    let temp = scratchDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).part")
    do {
      try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
      try data.write(to: temp, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      let storedName = try finalize(
        temp: temp,
        name: cleanName,
        serverID: serverID,
        id: id
      )
      return Written(
        storedName: storedName,
        byteCount: Int64(data.count),
        head: Data(data.prefix(4_096))
      )
    } catch {
      try? fileManager.removeItem(at: temp)
      throw MediaAttachmentProblem.couldNotWrite
    }
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
    let temp = scratchDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).part")
    do {
      try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
      guard let input = try? FileHandle(forReadingFrom: source) else {
        throw MediaAttachmentProblem.unreadable
      }
      defer { try? input.close() }
      guard fileManager.createFile(
        atPath: temp.path,
        contents: nil,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
      ) else {
        throw MediaAttachmentProblem.couldNotWrite
      }
      let output = try FileHandle(forWritingTo: temp)
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
      try? output.close()
      let head = try readPrefix(temp, count: 4_096)
      let storedName = try finalize(
        temp: temp,
        name: cleanName,
        serverID: serverID,
        id: id
      )
      return Written(storedName: storedName, byteCount: written, head: head)
    } catch let problem as MediaAttachmentProblem {
      try? fileManager.removeItem(at: temp)
      throw problem
    } catch is CancellationError {
      try? fileManager.removeItem(at: temp)
      throw CancellationError()
    } catch {
      try? fileManager.removeItem(at: temp)
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

  /// A viewer, preview or annotation can pin a staged file for the duration of its read. Cleanup
  /// refuses to delete a leased file; the lease is process-local and deliberately not persisted.
  @discardableResult
  public func lease(serverID: String, storedName: String) -> UUID {
    let token = UUID()
    leases[token] = Lease(token: token, serverID: serverID, storedName: storedName)
    return token
  }

  public func release(_ token: UUID) {
    leases.removeValue(forKey: token)
  }

  public func isLeased(serverID: String, storedName: String) -> Bool {
    leases.values.contains { $0.serverID == serverID && $0.storedName == storedName }
  }

  /// Deletes one staged attachment only when no lease still holds its bytes.
  @discardableResult
  public func removeIfUnleased(serverID: String, storedName: String) -> Bool {
    guard !isLeased(serverID: serverID, storedName: storedName) else { return false }
    remove(serverID: serverID, storedName: storedName)
    return true
  }

  /// Deletes only this store's app-controlled scratch. Imported names ending in `.tmp` or
  /// `.partial` are final attachments and are never inferred disposable.
  public func cleanupTemporaryArtifacts() {
    guard let entries = try? fileManager.contentsOfDirectory(
      at: scratchDirectory,
      includingPropertiesForKeys: nil
    ) else { return }
    for entry in entries {
      try? fileManager.removeItem(at: entry)
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
      let leased = leases.values.contains {
        $0.serverID == serverID && ($0.storedName == id || $0.storedName.hasPrefix("\(id)/"))
      }
      if !kept, !leased {
        try? fileManager.removeItem(at: folder)
      }
    }
  }

  private func finalize(
    temp: URL,
    name: String,
    serverID: String,
    id: String
  ) throws -> String {
    let directory = serverDirectory(serverID).appendingPathComponent(id, isDirectory: true)
    let destination = directory.appendingPathComponent(name)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      try excludeFromBackup(directory)
      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
      try fileManager.moveItem(at: temp, to: destination)
      return "\(id)/\(name)"
    } catch {
      try? fileManager.removeItem(at: temp)
      try? fileManager.removeItem(at: directory)
      throw MediaAttachmentProblem.couldNotWrite
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

  public var lease: @Sendable (String, String) async -> UUID {
    let store = store
    return { serverID, storedName in
      await store.lease(serverID: serverID, storedName: storedName)
    }
  }

  public var release: @Sendable (UUID) async -> Void {
    let store = store
    return { token in
      await store.release(token)
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
