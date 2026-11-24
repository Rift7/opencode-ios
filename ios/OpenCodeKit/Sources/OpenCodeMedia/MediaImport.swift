import ComposableArchitecture
import CoreGraphics
import Foundation
import ImageIO
import OpenCodeCore
import UniformTypeIdentifiers

/// What a view hands the importer. A file URL may be security-scoped; the store opens and closes
/// that scope around its copy.
public enum MediaImportSource: Equatable, Sendable {
  case imageData(Data)
  case file(URL, name: String? = nil)
  case pastedText(String)
}

/// One import's result and the type facts the UI needs.
public struct ImportedMedia: Equatable, Sendable {
  public var attachment: MediaAttachment

  public init(attachment: MediaAttachment) {
    self.attachment = attachment
  }
}

/// Imports photos, files and long pastes into app-owned staging. All decoding, re-encoding and
/// copying happens off the main actor.
public struct MediaImportClient: Sendable {
  public var importImage: @Sendable (Data, String, String) async throws -> MediaAttachment
  public var importFile: @Sendable (URL, String?, String, String) async throws -> MediaAttachment
  public var importPastedText: @Sendable (String, String, String) async throws -> MediaAttachment

  public init(
    importImage: @escaping @Sendable (Data, String, String) async throws -> MediaAttachment,
    importFile: @escaping @Sendable (URL, String?, String, String) async throws -> MediaAttachment,
    importPastedText: @escaping @Sendable (String, String, String) async throws -> MediaAttachment
  ) {
    self.importImage = importImage
    self.importFile = importFile
    self.importPastedText = importPastedText
  }

  /// A live importer over an explicit store, used by the app and by isolated tests.
  public static func live(store: MediaFileStore) -> MediaImportClient {
    MediaImportClient(
      importImage: { data, serverID, id in
        guard Int64(data.count) <= MediaLimits.maximumImageSourceBytes else {
          throw MediaAttachmentProblem.tooLarge
        }
        guard let encoded = MediaImageEncoding.jpeg(data) else {
          throw MediaAttachmentProblem.unsupported
        }
        let written = try await store.write(
          encoded.data,
          name: "\(id).jpg",
          serverID: serverID,
          id: id
        )
        return MediaAttachment(
          id: id,
          kind: .image,
          name: "Image.jpg",
          mime: "image/jpeg",
          byteCount: written.byteCount,
          storedName: written.storedName,
          transfer: .inline,
          pixelWidth: encoded.width,
          pixelHeight: encoded.height
        )
      },
      importFile: { url, providedName, serverID, id in
        let name = providedName ?? url.lastPathComponent
        if MediaFileType.isInlineImage(name: name, mime: nil) {
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          let values = try? url.resourceValues(forKeys: [.fileSizeKey])
          if let size = values?.fileSize, Int64(size) > MediaLimits.maximumImageSourceBytes {
            throw MediaAttachmentProblem.tooLarge
          }
          let data: Data
          do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
          } catch {
            throw MediaAttachmentProblem.unreadable
          }
          guard Int64(data.count) <= MediaLimits.maximumImageSourceBytes else {
            throw MediaAttachmentProblem.tooLarge
          }
          guard let encoded = MediaImageEncoding.jpeg(data) else {
            throw MediaAttachmentProblem.unsupported
          }
          let written = try await store.write(
            encoded.data,
            name: "\(id).jpg",
            serverID: serverID,
            id: id
          )
          return MediaAttachment(
            id: id,
            kind: .image,
            name: name.isEmpty ? "Image.jpg" : "\(MediaFileType.sanitizedName(name)).jpg",
            mime: "image/jpeg",
            byteCount: written.byteCount,
            storedName: written.storedName,
            transfer: .inline,
            pixelWidth: encoded.width,
            pixelHeight: encoded.height
          )
        }
        let written = try await store.copyFile(
          at: url,
          name: name,
          serverID: serverID,
          id: id
        )
        return MediaAttachment(
          id: id,
          kind: .file,
          name: MediaFileType.sanitizedName(name),
          mime: MediaFileType.mime(name: name, declared: MediaFileType.declaredMime(name), head: written.head),
          byteCount: written.byteCount,
          storedName: written.storedName,
          transfer: .uploading(sent: 0)
        )
      },
      importPastedText: { text, serverID, id in
        let normalized = text
          .replacingOccurrences(of: "\r\n", with: "\n")
          .replacingOccurrences(of: "\r", with: "\n")
        let data = Data(normalized.utf8)
        guard Int64(data.count) <= MediaLimits.maximumInlineBytes else {
          throw MediaAttachmentProblem.tooLarge
        }
        let written = try await store.write(
          data,
          name: "Pasted Text.txt",
          serverID: serverID,
          id: id
        )
        return MediaAttachment(
          id: id,
          kind: .pastedText,
          name: "Pasted Text",
          mime: "text/plain",
          byteCount: written.byteCount,
          storedName: written.storedName,
          transfer: .inline
        )
      }
    )
  }
}

extension MediaImportClient: DependencyKey {
  public static var liveValue: MediaImportClient {
    .live(store: MediaFiles.liveValue.store)
  }

  public static let testValue = MediaImportClient(
    importImage: { _, _, _ in throw MediaAttachmentProblem.unreadable },
    importFile: { _, _, _, _ in throw MediaAttachmentProblem.unreadable },
    importPastedText: { _, _, _ in throw MediaAttachmentProblem.unreadable }
  )
}

extension DependencyValues {
  public var mediaImporter: MediaImportClient {
    get { self[MediaImportClient.self] }
    set { self[MediaImportClient.self] = newValue }
  }
}

/// Downscale and re-encode imported images so prompts stay small. Re-encoding drops EXIF and GPS;
/// the source's orientation is applied before the pixels are written.
public enum MediaImageEncoding {
  public struct Encoded: Sendable, Equatable {
    public var data: Data
    public var width: Int
    public var height: Int
  }

  /// Decodes at most `maximumPixelSize` on the long edge and writes JPEG at the audited quality.
  /// Never upscales.
  public static func jpeg(_ data: Data, maximumPixelSize: Int = MediaLimits.maximumImageLongEdge) -> Encoded? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else { return nil }
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImageDestinationLossyCompressionQuality: MediaLimits.imageQuality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { return nil }
    return Encoded(data: output as Data, width: image.width, height: image.height)
  }

  /// The image's pixel dimensions without decoding its pixels.
  public static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
  }

  public static func thumbnail(_ data: Data, maximumPixelSize: Int = 1_024) -> CGImage? {
    guard maximumPixelSize > 0,
      let source = CGImageSourceCreateWithData(data as CFData, nil)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}

extension MediaFileType {
  /// The declared type for an extension, for importers that have no provider MIME.
  public static func declaredMime(_ name: String) -> String? {
    let suffix = fileExtension(name)
    guard !suffix.isEmpty else { return nil }
    return UTType(filenameExtension: suffix)?.preferredMIMEType
  }
}
