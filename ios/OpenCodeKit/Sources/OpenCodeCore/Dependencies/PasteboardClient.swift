import ComposableArchitecture
import Foundation
#if canImport(UIKit)
  import UIKit
#endif

/// Clipboard access behind a dependency so reducers, not views, decide when text is read.
public struct PasteboardClient: Sendable {
  public var string: @Sendable () -> String?
  public var setString: @Sendable (String) -> Void
  /// Image data the person copied, as JPEG re-encodable sources. Empty when the clipboard holds text.
  public var images: @Sendable () -> [Data]
  /// File URLs the person copied. A URL is only read after an explicit paste action.
  public var fileURLs: @Sendable () -> [URL]

  public init(
    string: @escaping @Sendable () -> String?,
    setString: @escaping @Sendable (String) -> Void = { _ in },
    images: @escaping @Sendable () -> [Data] = { [] },
    fileURLs: @escaping @Sendable () -> [URL] = { [] }
  ) {
    self.string = string
    self.setString = setString
    self.images = images
    self.fileURLs = fileURLs
  }
}

extension PasteboardClient: DependencyKey {
  public static var liveValue: PasteboardClient {
    #if canImport(UIKit)
      PasteboardClient(
        string: { UIPasteboard.general.string },
        setString: { UIPasteboard.general.string = $0 },
        images: {
          guard UIPasteboard.general.hasImages else { return [] }
          return (UIPasteboard.general.images ?? []).compactMap {
            $0.jpegData(compressionQuality: 0.9)
          }
        },
        fileURLs: {
          (UIPasteboard.general.urls ?? []).filter(\.isFileURL)
        }
      )
    #else
      .empty
    #endif
  }

  /// No clipboard in a test unless the test installs its own text.
  public static let testValue = PasteboardClient(string: { nil })

  public static let empty = PasteboardClient(string: { nil })
}

extension DependencyValues {
  public var pasteboard: PasteboardClient {
    get { self[PasteboardClient.self] }
    set { self[PasteboardClient.self] = newValue }
  }
}
