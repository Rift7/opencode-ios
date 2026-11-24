import ComposableArchitecture
import Foundation
import OpenCodeCore

/// Temporary copies used for playback and Quick Look. They live in Caches, are written atomically,
/// and are removed when a viewer closes or on the next launch.
public actor MediaScratch {
  private let directory: URL
  private let fileManager: FileManager

  public init(directory: URL, fileManager: FileManager = .default) {
    self.directory = directory
    self.fileManager = fileManager
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  public static func live() -> MediaScratch {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return MediaScratch(directory: caches.appendingPathComponent("MediaViewer", isDirectory: true))
  }

  public func write(_ data: Data, name: String) throws -> URL {
    let safe = MediaFileType.sanitizedName(name)
    let url = directory.appendingPathComponent("\(UUID().uuidString.lowercased())-\(safe)")
    do {
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      return url
    } catch {
      throw MediaAttachmentProblem.couldNotWrite
    }
  }

  public func remove(_ url: URL) {
    guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
      return
    }
    try? fileManager.removeItem(at: url)
  }

  public func cleanup() {
    try? fileManager.removeItem(at: directory)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  }
}

/// The scratch store as a dependency.
public struct MediaScratchFiles: Sendable {
  public var store: MediaScratch

  public init(store: MediaScratch) {
    self.store = store
  }

  public static var liveValue: MediaScratchFiles { MediaScratchFiles(store: .live()) }
  public static let testValue = MediaScratchFiles(
    store: MediaScratch(directory: FileManager.default.temporaryDirectory.appendingPathComponent("open-code-scratch-test"))
  )
}

extension MediaScratchFiles: DependencyKey {}
extension DependencyValues {
  public var mediaScratch: MediaScratchFiles {
    get { self[MediaScratchFiles.self] }
    set { self[MediaScratchFiles.self] = newValue }
  }
}
