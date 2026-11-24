import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeServer

/// Browsing the connected server's folders for a new session. Every route is read on demand with
/// `GET /api/fs/list`; a path is never passed to the local file system. Selecting a folder changes
/// the new session's project without touching the composer draft.
@Reducer
public struct FolderBrowserFeature: Sendable {
  @ObservableState
  public struct State: Equatable, Sendable {
    public struct Route: Hashable, Sendable {
      /// nil is where browsing starts: the server's default directory.
      public var path: String?

      public init(path: String?) {
        self.path = path
      }
    }

    public enum Listing: Equatable, Sendable {
      case loading
      case loaded(ServerDirectoryListing)
      case failed(OpenCodeClientError)
    }

    public var server: OpenCodeServer
    public var routes: [Route]
    public var listings: [Route: Listing]

    public init(server: OpenCodeServer, routes: [Route] = [], listings: [Route: Listing] = [:]) {
      self.server = server
      self.routes = routes
      self.listings = listings
    }

    public var route: Route { routes.last ?? Route(path: nil) }

    public func directory(_ route: Route) -> String? {
      if let path = route.path { return path }
      if case .loaded(let listing) = listings[route] { return listing.directory }
      return nil
    }

    public var canSelect: Bool {
      if case .loaded = listings[route] { return true }
      return false
    }
  }

  public enum Action: Equatable, Sendable {
    case appeared
    case retryTapped
    case folderTapped(String)
    case ancestorTapped(String)
    case backTapped
    case listed(State.Route, Result<ServerDirectoryListing, OpenCodeClientError>)
    case selectTapped
    case delegate(Delegate)
  }

  public enum Delegate: Equatable, Sendable {
    case selected(String)
  }

  @Dependency(\.openCodeClient) private var client

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .appeared:
        if state.routes.isEmpty { state.routes = [State.Route(path: nil)] }
        return load(state.route, state: &state)
      case .retryTapped:
        return load(state.route, state: &state)
      case .folderTapped(let path):
        let route = State.Route(path: path)
        state.routes.append(route)
        return load(route, state: &state)
      case .ancestorTapped(let path):
        if let index = state.routes.lastIndex(where: { state.directory($0) == path }) {
          state.routes = Array(state.routes.prefix(index + 1))
          return .none
        }
        let route = State.Route(path: path)
        state.routes = [route]
        return load(route, state: &state)
      case .backTapped:
        if state.routes.count > 1 {
          state.routes.removeLast()
        }
        return .none
      case .listed(let route, let result):
        switch result {
        case .success(let listing):
          state.listings[route] = .loaded(listing)
        case .failure(let error):
          state.listings[route] = .failed(error)
        }
        return .none
      case .selectTapped:
        guard let directory = state.directory(state.route), state.canSelect else { return .none }
        return .send(.delegate(.selected(directory)))
      case .delegate:
        return .none
      }
    }
  }

  private func load(_ route: State.Route, state: inout State) -> Effect<Action> {
    switch state.listings[route] {
    case .loaded, .loading:
      return .none
    case .failed, .none:
      break
    }
    state.listings[route] = .loading
    let server = state.server
    let path = route.path
    let client = client
    return .run { send in
      do {
        let listing = try await client.listDirectory(server, path).asServerDirectoryListing
        await send(.listed(route, .success(listing)))
      } catch let error as OpenCodeClientError {
        await send(.listed(route, .failure(error)))
      } catch {
        await send(.listed(route, .failure(.init(.unreachable))))
      }
    }
    .cancellable(id: CancelID(route), cancelInFlight: true)
  }

  private struct CancelID: Hashable {
    var route: State.Route

    init(_ route: State.Route) {
      self.route = route
    }
  }

  /// Folders above `path`, nearest last.
  public static func ancestors(path: String) -> [String] {
    var result: [String] = []
    var current = deletingLastPathComponent(path)
    while !current.isEmpty, current != path, !result.contains(current) {
      result.insert(current, at: 0)
      if current == "/" { break }
      current = deletingLastPathComponent(current)
    }
    return result
  }

  public static func name(path: String) -> String {
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    if trimmed.isEmpty { return "/" }
    return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
  }

  private static func deletingLastPathComponent(_ path: String) -> String {
    if path.isEmpty { return "" }
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    if trimmed.isEmpty { return "/" }
    guard let slash = trimmed.lastIndex(of: "/") else { return "" }
    if slash == trimmed.startIndex { return "/" }
    return String(trimmed[..<slash])
  }
}

/// The folder listing shape the client decodes, kept here so the reducer does not depend on the
/// media module's file viewer types.
public struct ServerDirectoryListing: Equatable, Sendable {
  public var directory: String
  public var folders: [String]

  public init(directory: String, folders: [String]) {
    self.directory = directory
    self.folders = folders
  }
}

extension DirectoryListing {
  public var asServerDirectoryListing: ServerDirectoryListing {
    ServerDirectoryListing(
      directory: directory,
      folders: entries.filter(\.isDirectory).map(\.path).sorted()
    )
  }
}
