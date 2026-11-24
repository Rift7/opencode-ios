import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeServer

/// A server path resolved into the location and relative path `GET /api/fs/read` expects. This is a
/// remote identifier: nothing here is ever handed to the local file system.
public enum AgentFilePath {
  public static func target(path: String, directory: String?) -> (location: String, relativePath: String)? {
    guard !path.isEmpty else { return nil }
    if path.hasPrefix("~") { return nil }
    if !path.hasPrefix("/") {
      guard let directory, !directory.isEmpty else { return nil }
      let relative = path.replacingOccurrences(of: "\\", with: "/")
      return relative.isEmpty ? nil : (directory, relative)
    }
    let normalizedPath = normalize(path)
    if let directory, !directory.isEmpty {
      let base = normalize(directory)
      if normalizedPath == base { return nil }
      let prefix = base == "/" ? "/" : "\(base)/"
      if normalizedPath.hasPrefix(prefix) {
        let relative = String(normalizedPath.dropFirst(prefix.count))
        return relative.isEmpty ? nil : (base, relative)
      }
    }
    guard normalizedPath.hasPrefix("/") else {
      guard let directory, !directory.isEmpty else { return nil }
      return (directory, normalizedPath)
    }
    let components = normalizedPath.split(separator: "/").map(String.init)
    guard let last = components.last else { return nil }
    let parent = "/" + components.dropLast().joined(separator: "/")
    return (parent == "/" ? "/" : parent, last)
  }

  private static func normalize(_ path: String) -> String {
    let replaced = path.replacingOccurrences(of: "\\", with: "/")
    var components: [String] = []
    for part in replaced.split(separator: "/", omittingEmptySubsequences: true) {
      switch part {
      case ".": continue
      case "..": _ = components.popLast()
      default: components.append(String(part))
      }
    }
    return "/" + components.joined(separator: "/")
  }
}

/// What a file viewer shows.
public enum FileViewerLoad: Equatable, Sendable {
  case idle
  case loading
  case code(CodePreview)
  case image(Data)
  case downloaded(URL)
  case unsupported
  case unavailable
  case failed(MediaAttachmentProblem)
}

@Reducer
public struct FileViewerFeature: Sendable {
  @ObservableState
  public struct State: Equatable, Sendable, Identifiable {
    public var id: String { file.id }
    public var file: TranscriptFile
    public var title: String
    public var detail: String?
    public var kind: MediaPageKind
    public var load: FileViewerLoad
    public var server: OpenCodeServer?
    public var directory: String?

    public init(file: TranscriptFile, server: OpenCodeServer?, directory: String?) {
      self.file = file
      self.server = server
      self.directory = directory
      self.title = file.name ?? "File"
      self.detail = [file.mime, file.byteCount.map { MediaFileType.byteCount(Int64($0)) }]
        .compactMap { $0 }.joined(separator: " · ")
      let mime = (file.mime ?? "").lowercased()
      let name = file.name ?? ""
      if mime.hasPrefix("image/") || MediaFileType.imageExtensions.contains(MediaFileType.fileExtension(name)) {
        self.kind = .image
      } else if mime.hasPrefix("video/") {
        self.kind = .video
      } else if mime.hasPrefix("audio/") {
        self.kind = .audio
      } else if mime == MediaFileType.pdfMime {
        self.kind = .pdf
      } else if mime == "text/plain" || Self.textExtensions.contains(MediaFileType.fileExtension(name)) {
        self.kind = .text
      } else {
        self.kind = .unsupported
      }
      self.load = .idle
    }

    public var canCopyText: Bool {
      if case .code = load { return true }
      return false
    }

    public var text: String? {
      if case .code(let preview) = load { return preview.text }
      return nil
    }

    static let textExtensions: Set<String> = [
      "c", "cjs", "cpp", "cs", "css", "dart", "go", "h", "hpp", "html", "java", "js", "json",
      "jsonc", "jsx", "kt", "kts", "log", "md", "mdx", "mjs", "php", "plist", "py", "rb", "rs",
      "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml", "zsh",
    ]
  }

  public enum Action: Equatable, Sendable {
    case task
    case retryTapped
    case closeTapped
    case loaded(FileViewerLoad)
    case delegate(Delegate)
  }

  public enum Delegate: Equatable, Sendable {
    case dismiss
  }

  enum CancelID: Hashable { case load }

  @Dependency(\.openCodeClient) private var client
  @Dependency(\.mediaScratch) private var scratch

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        guard case .idle = state.load else { return .none }
        return load(state: &state)
      case .retryTapped:
        return load(state: &state)
      case .closeTapped:
        return .send(.delegate(.dismiss))
      case .loaded(let load):
        state.load = load
        return .none
      case .delegate:
        return .none
      }
    }
  }

  private func load(state: inout State) -> Effect<Action> {
    guard let server = state.server, let path = state.file.path, !path.isEmpty else {
      if let hash = state.file.mediaHash {
        return loadMediaHash(hash, state: &state)
      }
      state.load = .failed(.unreadable)
      return .none
    }
    guard let target = AgentFilePath.target(path: path, directory: state.directory) else {
      state.load = .failed(.unreadable)
      return .none
    }
    state.load = .loading
    let client = client
    let scratch = scratch
    let kind = state.kind
    let name = state.title
    return .run { send in
      do {
        let data = try await client.readFile(
          server,
          target.location,
          target.relativePath,
          MediaLimits.maximumMediaBlobBytes
        )
        await send(.loaded(try await transform(data, kind: kind, name: name, scratch: scratch)))
      } catch is CancellationError {
        return
      } catch let problem as MediaAttachmentProblem {
        await send(.loaded(.failed(problem)))
      } catch {
        await send(.loaded(.failed(.couldNotRead)))
      }
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }

  private func loadMediaHash(_ hash: String, state: inout State) -> Effect<Action> {
    guard let server = state.server else {
      state.load = .failed(.unreadable)
      return .none
    }
    state.load = .loading
    let client = client
    let scratch = scratch
    let kind = state.kind
    let name = state.title
    return .run { send in
      do {
        let data = try await client.mediaBlob(server, hash)
        await send(.loaded(try await transform(data, kind: kind, name: name, scratch: scratch)))
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        if case .status(404) = error.failure {
          await send(.loaded(.unavailable))
        } else {
          await send(.loaded(.failed(.couldNotRead)))
        }
      } catch {
        await send(.loaded(.failed(.couldNotRead)))
      }
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }

  private func transform(
    _ data: Data,
    kind: MediaPageKind,
    name: String,
    scratch: MediaScratchFiles
  ) async throws -> FileViewerLoad {
    switch kind {
    case .text:
      guard let preview = CodePreview.make(data: data, fileName: name) else {
        return .unsupported
      }
      return .code(preview)
    case .image:
      guard Int64(data.count) <= MediaLimits.maximumMediaBlobBytes else { return .failed(.tooLarge) }
      return .image(data)
    case .pdf, .video, .audio:
      let url = try await scratch.store.write(data, name: name)
      return .downloaded(url)
    case .unsupported:
      return .unsupported
    }
  }
}
