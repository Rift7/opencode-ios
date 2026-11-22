import ComposableArchitecture
import Foundation
#if canImport(UIKit)
  import UIKit
#endif

/// Opening an external link is an explicit action, never a side effect of drawing server content.
/// A link tap stores the URL, and only a confirmed Open reaches this client.
public struct OpenURLClient: Sendable {
  public var open: @Sendable (URL) async -> Bool

  public init(open: @escaping @Sendable (URL) async -> Bool) {
    self.open = open
  }
}

extension OpenURLClient: DependencyKey {
  public static var liveValue: OpenURLClient {
    #if canImport(UIKit)
      OpenURLClient { url in
        await MainActor.run {
          UIApplication.shared.open(url)
          return true
        }
      }
    #else
      OpenURLClient { _ in false }
    #endif
  }

  public static let testValue = OpenURLClient { _ in false }
}

extension DependencyValues {
  public var linkOpener: OpenURLClient {
    get { self[OpenURLClient.self] }
    set { self[OpenURLClient.self] = newValue }
  }
}
