import ComposableArchitecture
import CoreGraphics
import Foundation
import OpenCodeServer

/// Where a media image's bytes come from. A composer attachment reads its app-owned staged file; a
/// transcript image prefers its inline bytes and falls back to the server blob.
public enum MediaImageSource: Equatable, Sendable {
  case data(Data)
  case hash(String)
  case localFile(URL)

  public static func transcript(data: Data, hash: String?) -> MediaImageSource {
    if !data.isEmpty { return .data(data) }
    if let hash, !hash.isEmpty { return .hash(hash) }
    return .data(Data())
  }
}

/// One decoded image and the facts a view needs to reserve its box before pixels arrive.
public struct MediaLoadedImage: Sendable {
  public var image: CGImage
  public var pixelWidth: Int
  public var pixelHeight: Int

  public init(image: CGImage, pixelWidth: Int, pixelHeight: Int) {
    self.image = image
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }

  public var aspectRatio: Double {
    guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
    return Double(pixelWidth) / Double(pixelHeight)
  }
}

/// Read-only image loading for views. It owns no presentation state; a caller cancels its task when
/// the tile or page disappears. Authenticated blobs always pass through `MediaReferences`.
public struct MediaImages: Sendable {
  public var load: @Sendable (MediaImageSource, OpenCodeServer?, Int) async -> MediaLoadedImage?
  public var purged: @Sendable () async -> Void

  public init(
    load: @escaping @Sendable (MediaImageSource, OpenCodeServer?, Int) async -> MediaLoadedImage?,
    purged: @escaping @Sendable () async -> Void
  ) {
    self.load = load
    self.purged = purged
  }

  public static func make(
    references: MediaReferences,
    cache: DecodedImageCache,
    files: MediaFileStore = MediaFileStore(root: MediaFileStore.liveRoot())
  ) -> MediaImages {
    MediaImages(
      load: { source, server, maximumPixelSize in
        switch source {
        case .data(let data):
          guard !data.isEmpty else { return nil }
          return await decode(key: "data:\(data.hashValue)", data: data, maximum: maximumPixelSize, cache: cache)
        case .hash(let hash):
          guard let server else { return nil }
          switch await references.load(server, hash) {
          case .loaded(let data):
            return await decode(
              key: "\(server.persistenceID)|\(hash)",
              data: data,
              maximum: maximumPixelSize,
              cache: cache
            )
          case .unavailable, .failed, .cancelled:
            return nil
          }
        case .localFile(let url):
          let values = try? url.resourceValues(forKeys: [.fileSizeKey])
          guard values?.isFileSizeWithin(MediaLimits.maximumMediaBlobBytes) != false else { return nil }
          guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
          return await decode(key: "file:\(url.path)", data: data, maximum: maximumPixelSize, cache: cache)
        }
      },
      purged: { await cache.purge() }
    )
  }

  private static func decode(
    key: String,
    data: Data,
    maximum: Int,
    cache: DecodedImageCache
  ) async -> MediaLoadedImage? {
    if let cached = await cache.image(key: key) {
      return MediaLoadedImage(image: cached, pixelWidth: cached.width, pixelHeight: cached.height)
    }
    guard let image = await cache.decode(key: key, data: data, maximumPixelSize: maximum) else {
      return nil
    }
    return MediaLoadedImage(image: image, pixelWidth: image.width, pixelHeight: image.height)
  }
}

extension URLResourceValues {
  fileprivate func isFileSizeWithin(_ maximum: Int64) -> Bool {
    guard let fileSize else { return true }
    return Int64(fileSize) <= maximum
  }
}

extension MediaImages: DependencyKey {
  public static var liveValue: MediaImages {
    MediaImages.make(references: MediaReferences.liveValue, cache: MediaRuntime.decodedImages)
  }

  public static let testValue = MediaImages(
    load: { _, _, _ in nil },
    purged: {}
  )
}

extension DependencyValues {
  public var mediaImages: MediaImages {
    get { self[MediaImages.self] }
    set { self[MediaImages.self] = newValue }
  }
}

enum MediaRuntime {
  static let decodedImages = DecodedImageCache()
}
