import ComposableArchitecture
import Foundation
#if canImport(UIKit)
  import UIKit
#endif

/// Clipboard access behind a dependency so reducers, not views, decide when text is read.
public struct PasteboardClient: Sendable {
  public var string: @Sendable () -> String?
  public var setString: @Sendable (String) -> Void

  public init(
    string: @escaping @Sendable () -> String?,
    setString: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.string = string
    self.setString = setString
  }
}

extension PasteboardClient: DependencyKey {
  public static var liveValue: PasteboardClient {
    #if canImport(UIKit)
      PasteboardClient(
        string: { UIPasteboard.general.string },
        setString: { UIPasteboard.general.string = $0 }
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
