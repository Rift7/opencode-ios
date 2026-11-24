import ComposableArchitecture
import CoreGraphics
import CryptoKit
import Foundation
import OpenCodeCore
import OpenCodeServer

/// Authentication scope for authenticated media. It hashes the saved-server identity with the
/// credential value, so changing a token or password invalidates the scope without putting a raw
/// credential in a filename, memory key or log.
public enum MediaCacheScope {
  public static func token(for server: OpenCodeServer) -> String {
    let material = server.authenticationScopeMaterial
    let digest = SHA256.hash(data: Data(material.utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(24).description
  }
}

/// Content-addressed media blobs by hash, partitioned by authentication scope, with an in-memory
/// LRU and a bounded disk tier. A 404 is remembered per scope in memory only. Concurrent reads of
/// one blob coalesce into one request, and fetched or disk-loaded bytes must match their hash.
public actor MediaReferenceCache {
  public enum Load: Equatable, Sendable {
    case loaded(Data)
    case unavailable
    case failed(MediaAttachmentProblem)
    case cancelled
  }

  public struct Bounds: Sendable, Equatable {
    public var memoryBytes: Int
    public var memoryEntries: Int
    public var diskBytes: Int64
    public var blobBytes: Int64

    public init(
      memoryBytes: Int = 48 * 1024 * 1024,
      memoryEntries: Int = 64,
      diskBytes: Int64 = Int64(256) * 1024 * 1024,
      blobBytes: Int64 = MediaLimits.maximumMediaBlobBytes
    ) {
      self.memoryBytes = memoryBytes
      self.memoryEntries = memoryEntries
      self.diskBytes = diskBytes
      self.blobBytes = blobBytes
    }
  }

  private struct MemoryEntry {
    var data: Data
    var lastUsed: UInt64
  }

  private let directory: URL
  private let bounds: Bounds
  private let fetch: @Sendable (OpenCodeServer, String) async throws -> Data
  private let fileManager: FileManager
  private var memory: [String: MemoryEntry] = [:]
  private var memoryBytes = 0
  private var useCounter: UInt64 = 0
  private var unavailable: Set<String> = []
  private var inFlight: [String: Task<Load, Never>] = [:]

  public init(
    directory: URL,
    bounds: Bounds = Bounds(),
    fileManager: FileManager = .default,
    fetch: @escaping @Sendable (OpenCodeServer, String) async throws -> Data
  ) {
    self.directory = directory
    self.bounds = bounds
    self.fileManager = fileManager
    self.fetch = fetch
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  public func cachedData(server: OpenCodeServer, hash: String) -> Data? {
    let normalized = hash.lowercased()
    let scope = MediaCacheScope.token(for: server)
    let entryKey = key(scope: scope, hash: normalized)
    guard MediaReference.isValidHash(normalized), var entry = memory[entryKey] else { return nil }
    guard Self.matchesHash(entry.data, hash: normalized) else {
      memory.removeValue(forKey: entryKey)
      memoryBytes -= entry.data.count
      return nil
    }
    useCounter += 1
    entry.lastUsed = useCounter
    memory[entryKey] = entry
    return entry.data
  }

  public func isUnavailable(server: OpenCodeServer, hash: String) -> Bool {
    unavailable.contains(key(server: server, hash: hash))
  }

  public func load(server: OpenCodeServer, hash: String) async -> Load {
    let normalized = hash.lowercased()
    guard MediaReference.isValidHash(normalized) else { return .failed(.unreadable) }
    let scope = MediaCacheScope.token(for: server)
    let entryKey = key(scope: scope, hash: normalized)
    if let entry = memory[entryKey] {
      guard Self.matchesHash(entry.data, hash: normalized) else {
        memory.removeValue(forKey: entryKey)
        memoryBytes -= entry.data.count
        return .failed(.unreadable)
      }
      var touched = entry
      useCounter += 1
      touched.lastUsed = useCounter
      memory[entryKey] = touched
      return .loaded(entry.data)
    }
    if unavailable.contains(key(server: server, hash: normalized)) {
      return .unavailable
    }
    if let disk = readDisk(scope: scope, hash: normalized) {
      storeMemory(key: entryKey, data: disk)
      return .loaded(disk)
    }
    let coalescingKey = "\(scope)|\(normalized)"
    if let task = inFlight[coalescingKey] {
      return await task.value
    }
    let task = Task<Load, Never> { [fetch, bounds] in
      do {
        let data = try await fetch(server, normalized)
        if Int64(data.count) > bounds.blobBytes {
          return .failed(.tooLarge)
        }
        guard MediaReferenceCache.matchesHash(data, hash: normalized) else {
          return .failed(.unreadable)
        }
        return .loaded(data)
      } catch is CancellationError {
        return .cancelled
      } catch let error as OpenCodeClientError {
        if case .status(404) = error.failure { return .unavailable }
        return .failed(.uploadFailed)
      } catch {
        return .failed(.uploadFailed)
      }
    }
    inFlight[coalescingKey] = task
    let result = await task.value
    inFlight[coalescingKey] = nil
    switch result {
    case .loaded(let data):
      storeMemory(key: entryKey, data: data)
      writeDisk(scope: scope, hash: normalized, data: data)
    case .unavailable:
      unavailable.insert(key(server: server, hash: normalized))
    case .failed:
      break
    case .cancelled:
      break
    }
    return result
  }

  public func purgeMemory() {
    memory.removeAll()
    memoryBytes = 0
  }

  /// Deletes the memory tier and trims the disk tier to its bound. Called on a memory warning.
  public func trim() {
    purgeMemory()
    trimDisk(keeping: nil)
  }

  private func key(scope: String, hash: String) -> String {
    "\(scope)|\(hash.lowercased())"
  }

  private func key(server: OpenCodeServer, hash: String) -> String {
    key(scope: MediaCacheScope.token(for: server), hash: hash)
  }

  static func matchesHash(_ data: Data, hash: String) -> Bool {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return digest == hash.lowercased()
  }

  private func storeMemory(key: String, data: Data) {
    let bytes = data.count
    guard bytes <= bounds.memoryBytes else { return }
    useCounter += 1
    if let previous = memory[key] { memoryBytes -= previous.data.count }
    memory[key] = MemoryEntry(data: data, lastUsed: useCounter)
    memoryBytes += bytes
    while memoryBytes > bounds.memoryBytes || memory.count > bounds.memoryEntries {
      guard let oldest = memory.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { break }
      memory.removeValue(forKey: oldest.key)
      memoryBytes -= oldest.value.data.count
    }
  }

  private func blobURL(scope: String, hash: String) -> URL {
    directory.appendingPathComponent(scope, isDirectory: true)
      .appendingPathComponent("\(hash).blob")
  }

  private func readDisk(scope: String, hash: String) -> Data? {
    let url = blobURL(scope: scope, hash: hash)
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true, let size = values?.fileSize,
      Int64(size) <= bounds.blobBytes
    else { return nil }
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
      Int64(data.count) <= bounds.blobBytes
    else { return nil }
    guard Self.matchesHash(data, hash: hash) else {
      try? fileManager.removeItem(at: url)
      return nil
    }
    return data
  }

  private func writeDisk(scope: String, hash: String, data: Data) {
    let folder = directory.appendingPathComponent(scope, isDirectory: true)
    let partial = folder.appendingPathComponent("\(hash).partial")
    let destination = blobURL(scope: scope, hash: hash)
    do {
      try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: partial, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
      try fileManager.moveItem(at: partial, to: destination)
      trimDisk(keeping: destination)
    } catch {
      try? fileManager.removeItem(at: partial)
    }
  }

  /// Counts only finished `.blob` files across every scope, so a partial is never charged or
  /// deleted before its rename. The globally bounded disk tier is shared by all scopes.
  private func trimDisk(keeping current: URL?) {
    guard let enumerator = fileManager.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    var blobs: [(url: URL, size: Int64, date: Date)] = []
    var total: Int64 = 0
    for case let url as URL in enumerator where url.pathExtension == "blob" {
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
        let size = values.fileSize
      else { continue }
      blobs.append((url, Int64(size), values.contentModificationDate ?? .distantPast))
      total += Int64(size)
    }
    guard total > bounds.diskBytes else { return }
    blobs.sort { $0.date < $1.date }
    for blob in blobs where total > bounds.diskBytes {
      if blob.url == current { continue }
      try? fileManager.removeItem(at: blob.url)
      total -= blob.size
    }
  }
}

/// The live cache built over the client's authenticated media read. The dependency captures one
/// actor so the session, transcript tiles and the viewer share the same memory and disk tiers.
public struct MediaReferences: Sendable {
  public var load: @Sendable (OpenCodeServer, String) async -> MediaReferenceCache.Load
  public var cachedData: @Sendable (OpenCodeServer, String) async -> Data?
  public var isUnavailable: @Sendable (OpenCodeServer, String) async -> Bool
  public var purgeMemory: @Sendable () async -> Void
  public var trim: @Sendable () async -> Void

  public init(
    load: @escaping @Sendable (OpenCodeServer, String) async -> MediaReferenceCache.Load,
    cachedData: @escaping @Sendable (OpenCodeServer, String) async -> Data?,
    isUnavailable: @escaping @Sendable (OpenCodeServer, String) async -> Bool,
    purgeMemory: @escaping @Sendable () async -> Void,
    trim: @escaping @Sendable () async -> Void
  ) {
    self.load = load
    self.cachedData = cachedData
    self.isUnavailable = isUnavailable
    self.purgeMemory = purgeMemory
    self.trim = trim
  }

  public static func live(client: OpenCodeClient = .liveValue) -> MediaReferences {
    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return make(cache: MediaReferenceCache(
      directory: root.appendingPathComponent("media-references", isDirectory: true),
      fetch: { server, hash in try await client.mediaBlob(server, hash) }
    ))
  }

  public static func make(cache: MediaReferenceCache) -> MediaReferences {
    MediaReferences(
      load: { server, hash in await cache.load(server: server, hash: hash) },
      cachedData: { server, hash in await cache.cachedData(server: server, hash: hash) },
      isUnavailable: { server, hash in await cache.isUnavailable(server: server, hash: hash) },
      purgeMemory: { await cache.purgeMemory() },
      trim: { await cache.trim() }
    )
  }

  public static func testing(cache: MediaReferenceCache) -> MediaReferences {
    make(cache: cache)
  }
}

extension MediaReferences: DependencyKey {
  public static let liveValue = MediaReferences.live()
  public static let testValue = MediaReferences(
    load: { _, _ in .failed(.uploadFailed) },
    cachedData: { _, _ in nil },
    isUnavailable: { _, _ in false },
    purgeMemory: {},
    trim: {}
  )
}

extension DependencyValues {
  public var mediaReferences: MediaReferences {
    get { self[MediaReferences.self] }
    set { self[MediaReferences.self] = newValue }
  }
}

/// Decoded images are bounded separately from their encoded bytes: thumbnail decoding happens off
/// the main actor and a view only receives finished `CGImage`s.
public actor DecodedImageCache {
  private let capacityBytes: Int
  private var entries: [String: (image: CGImage, bytes: Int, used: UInt64)] = [:]
  private var totalBytes = 0
  private var counter: UInt64 = 0

  public init(capacityBytes: Int = 64 * 1024 * 1024) {
    self.capacityBytes = capacityBytes
  }

  public func image(key: String) -> CGImage? {
    guard var entry = entries[key] else { return nil }
    counter += 1
    entry.used = counter
    entries[key] = entry
    return entry.image
  }

  public func decode(key: String, data: Data, maximumPixelSize: Int) -> CGImage? {
    if let cached = image(key: key) { return cached }
    guard let image = MediaImageEncoding.thumbnail(data, maximumPixelSize: maximumPixelSize) else {
      return nil
    }
    let bytes = image.bytesPerRow * image.height
    counter += 1
    if let old = entries[key] { totalBytes -= old.bytes }
    entries[key] = (image, max(bytes, 1), counter)
    totalBytes += max(bytes, 1)
    while totalBytes > capacityBytes || entries.count > 96 {
      guard let oldest = entries.min(by: { $0.value.used < $1.value.used }) else { break }
      entries.removeValue(forKey: oldest.key)
      totalBytes -= oldest.value.bytes
    }
    return image
  }

  public func purge() {
    entries.removeAll()
    totalBytes = 0
  }
}
