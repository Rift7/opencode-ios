import Dependencies
import Foundation

public enum TransportError: Error, Equatable, Sendable {
  /// The live transport is not wired yet; the networking phase replaces it.
  case notConfigured
  /// A test tried to reach the network through a dependency that was never given a fixture.
  case blocked
}

/// The single seam through which the app may perform HTTP work. Features resolve this dependency;
/// they never create a `URLSession` themselves, so a test that forgets an override still cannot
/// reach the network.
public struct HTTPTransport: Sendable {
  public var perform: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  public init(perform: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
    self.perform = perform
  }
}

extension HTTPTransport: DependencyKey {
  /// Inert on purpose: no `URLSession` exists in the app yet. The networking phase supplies the
  /// live value in one place, and it must stop being inert here rather than in a feature.
  public static let liveValue = HTTPTransport { _ in
    throw TransportError.notConfigured
  }

  public static let testValue = HTTPTransport { _ in
    throw TransportError.blocked
  }
}

extension DependencyValues {
  public var httpTransport: HTTPTransport {
    get { self[HTTPTransport.self] }
    set { self[HTTPTransport.self] = newValue }
  }
}
