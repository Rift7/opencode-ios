import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeServer

/// What one viewer page shows.
public enum MediaPageKind: String, Equatable, Sendable {
  case image
  case video
  case audio
  case pdf
  case text
  case unsupported
}

/// Where the page's bytes come from. Every remote source is read through the authenticated client
/// or the media cache; a page never hands a server credential to AVPlayer, PDFKit or WebKit.
public enum MediaPageSource: Equatable, Sendable {
  case inline(Data)
  case mediaHash(String)
  case localFile(URL)
  case serverFile(location: String?, path: String)

  /// Inline bytes compare by length, not content: the viewer state is compared on every session
  /// action, and hashing megabytes of image data there would cost more than it can reveal.
  public static func == (lhs: MediaPageSource, rhs: MediaPageSource) -> Bool {
    switch (lhs, rhs) {
    case (.inline(let left), .inline(let right)): left.count == right.count
    case (.mediaHash(let left), .mediaHash(let right)): left == right
    case (.localFile(let left), .localFile(let right)): left == right
    case (.serverFile(let ll, let lp), .serverFile(let rl, let rp)): ll == rl && lp == rp
    default: false
    }
  }
}

public struct MediaViewerPage: Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var detail: String?
  public var kind: MediaPageKind
  public var source: MediaPageSource
  public var byteCount: Int64?
  public var canAnnotate: Bool
  public var pixelWidth: Int?
  public var pixelHeight: Int?

  public init(
    id: String,
    title: String,
    detail: String? = nil,
    kind: MediaPageKind,
    source: MediaPageSource,
    byteCount: Int64? = nil,
    canAnnotate: Bool = false,
    pixelWidth: Int? = nil,
    pixelHeight: Int? = nil
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.kind = kind
    self.source = source
    self.byteCount = byteCount
    self.canAnnotate = canAnnotate
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }

  public var imageSource: MediaImageSource? {
    guard kind == .image else { return nil }
    switch source {
    case .inline(let data): return .data(data)
    case .mediaHash(let hash): return .hash(hash)
    case .localFile(let url): return .localFile(url)
    case .serverFile:
      return nil
    }
  }
}

/// One page's non-pixel load (playback, PDF or text). Images are decoded by the view through
/// `MediaImages`, which keeps large decodes off the main actor.
public enum MediaPageLoad: Equatable, Sendable {
  case idle
  case loading
  case downloaded(URL)
  case text(String)
  case failed(MediaAttachmentProblem)
  case unavailable
}

/// A full-screen gallery for transcript images, tool mosaics and file pages. It owns selection,
/// page loads and dismissal; the image decoding and the authenticated fetch live below it.
@Reducer
public struct MediaViewerFeature: Sendable {
  @ObservableState
  public struct State: Equatable, Sendable, Identifiable {
    public var id: String
    public var pages: [MediaViewerPage]
    public var index: Int
    public var chromeVisible: Bool
    public var loads: [String: MediaPageLoad]
    /// Incremented per page to retry an image decode without replacing the page.
    public var imageReloads: [String: Int]
    public var server: OpenCodeServer?
    public var annotation: AnnotationState?

    public init(
      pages: [MediaViewerPage],
      index: Int = 0,
      server: OpenCodeServer?
    ) {
      self.id = pages.first?.id ?? UUID().uuidString
      self.pages = pages
      self.index = min(max(0, index), max(0, pages.count - 1))
      self.chromeVisible = true
      self.loads = [:]
      self.imageReloads = [:]
      self.server = server
      self.annotation = nil
    }

    public var page: MediaViewerPage? {
      pages.indices.contains(index) ? pages[index] : nil
    }

    public var title: String { page?.title ?? "" }

    public var canPage: Bool { pages.count > 1 }
  }

  public struct AnnotationState: Equatable, Sendable {
    public var pageID: String
    public var strokes: [AnnotationStroke]

    public init(pageID: String, strokes: [AnnotationStroke] = []) {
      self.pageID = pageID
      self.strokes = strokes
    }
  }

  public enum Action: Equatable, Sendable {
    case task
    case pageSelected(Int)
    case previousTapped
    case nextTapped
    case chromeToggled
    case closeTapped
    case retryTapped(String)
    case imageUnavailable(String)
    case loaded(pageID: String, load: MediaPageLoad)
    case annotateTapped
    case annotationChanged([AnnotationStroke])
    case annotationCancelled
    case annotationSaved(Data)
    case delegate(Delegate)
  }

  public enum Delegate: Equatable, Sendable {
    case dismiss
    case annotate(Data)
  }

  enum CancelID: Hashable {
    case load(String)
  }

  @Dependency(\.openCodeClient) private var client
  @Dependency(\.mediaReferences) private var references
  @Dependency(\.mediaScratch) private var scratch

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        return loadCurrent(state: &state)

      case .pageSelected(let index):
        guard state.pages.indices.contains(index) else { return .none }
        state.index = index
        state.chromeVisible = true
        return loadCurrent(state: &state)

      case .previousTapped:
        guard state.index > 0 else { return .none }
        state.index -= 1
        return loadCurrent(state: &state)

      case .nextTapped:
        guard state.index + 1 < state.pages.count else { return .none }
        state.index += 1
        return loadCurrent(state: &state)

      case .chromeToggled:
        guard state.page?.kind != .text else { return .none }
        state.chromeVisible.toggle()
        return .none

      case .closeTapped:
        return .send(.delegate(.dismiss))

      case .retryTapped(let pageID):
        guard let page = state.pages.first(where: { $0.id == pageID }) else { return .none }
        state.loads[pageID] = .loading
        state.imageReloads[pageID, default: 0] += 1
        return load(page, state: state)

      case .imageUnavailable(let pageID):
        state.loads[pageID] = .unavailable
        return .none

      case .loaded(let pageID, let load):
        state.loads[pageID] = load
        return .none

      case .annotateTapped:
        guard let page = state.page, page.kind == .image else { return .none }
        state.annotation = AnnotationState(pageID: page.id)
        return .none

      case .annotationChanged(let strokes):
        state.annotation?.strokes = strokes
        return .none

      case .annotationCancelled:
        state.annotation = nil
        return .none

      case .annotationSaved(let data):
        state.annotation = nil
        return .send(.delegate(.annotate(data)))

      case .delegate:
        return .none
      }
    }
  }

  private func loadCurrent(state: inout State) -> Effect<Action> {
    guard let page = state.page else { return .none }
    if page.kind == .image {
      if state.loads[page.id] == nil { state.loads[page.id] = .loading }
      return .none
    }
    state.loads[page.id] = .loading
    return load(page, state: state)
  }

  private func load(_ page: MediaViewerPage, state: State) -> Effect<Action> {
    let client = client
    let references = references
    let scratch = scratch
    let server = state.server
    return .run { send in
      do {
        let data: Data
        switch page.source {
        case .inline(let inline):
          data = inline
        case .localFile(let url):
          data = try await MediaLocalRead.data(at: url, maximumBytes: MediaLimits.maximumMediaBlobBytes)
        case .mediaHash(let hash):
          guard let server else {
            await send(.loaded(pageID: page.id, load: .failed(.unreadable)))
            return
          }
          switch await references.load(server, hash) {
          case .loaded(let loaded):
            data = loaded
          case .unavailable:
            await send(.loaded(pageID: page.id, load: .unavailable))
            return
          case .failed(let problem):
            await send(.loaded(pageID: page.id, load: .failed(problem)))
            return
          case .cancelled:
            return
          }
        case .serverFile(let location, let path):
          guard let server, let location else {
            await send(.loaded(pageID: page.id, load: .failed(.unreadable)))
            return
          }
          data = try await client.readFile(
            server,
            location,
            path,
            MediaLimits.maximumMediaBlobBytes
          )
        }
        switch page.kind {
        case .text:
          let clipped = data.prefix(Int(MediaLimits.maximumPreviewBytes))
          guard let text = String(data: clipped, encoding: .utf8) else {
            await send(.loaded(pageID: page.id, load: .failed(.unsupported)))
            return
          }
          await send(.loaded(pageID: page.id, load: .text(text)))
        case .video, .audio, .pdf:
          let name = page.title.isEmpty ? "media" : page.title
          let url = try await scratch.store.write(data, name: name)
          await send(.loaded(pageID: page.id, load: .downloaded(url)))
        case .image:
          return
        case .unsupported:
          await send(.loaded(pageID: page.id, load: .unavailable))
        }
      } catch is CancellationError {
        return
      } catch let problem as MediaAttachmentProblem {
        await send(.loaded(pageID: page.id, load: .failed(problem)))
      } catch {
        await send(.loaded(pageID: page.id, load: .failed(.uploadFailed)))
      }
    }
    .cancellable(id: CancelID.load(page.id), cancelInFlight: true)
  }
}

enum MediaLocalRead {
  static func data(at url: URL, maximumBytes: Int64) async throws -> Data {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values?.isRegularFile == true else { throw MediaAttachmentProblem.notFound }
    if let size = values?.fileSize, Int64(size) > maximumBytes {
      throw MediaAttachmentProblem.tooLarge
    }
    do {
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      guard Int64(data.count) <= maximumBytes else { throw MediaAttachmentProblem.tooLarge }
      return data
    } catch let problem as MediaAttachmentProblem {
      throw problem
    } catch {
      throw MediaAttachmentProblem.couldNotRead
    }
  }
}
