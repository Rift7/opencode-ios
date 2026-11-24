import AVKit
import ComposableArchitecture
import OpenCodeCore
import OpenCodeMedia
import OpenCodeServer
import PDFKit
import SwiftUI
import UIKit

/// A bounded, authenticated image tile. The loader owns decoding off the main actor; the task is
/// cancelled when the tile leaves the screen.
struct MediaThumbnail: View {
  let source: MediaImageSource
  let server: OpenCodeServer?
  var maximumPixelSize: Int = 1_024
  var aspectRatio: Double?
  var label: String

  @Dependency(\.mediaImages) private var images
  @State private var loaded: MediaLoadedImage?
  @State private var failed = false
  @State private var attempts = 0

  var body: some View {
    ZStack {
      if let loaded {
        Image(decorative: loaded.image, scale: 1)
          .resizable()
          .scaledToFill()
      } else if failed {
        Image(systemName: "photo")
          .font(.title3)
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .aspectRatio(aspectRatio ?? 1, contentMode: .fit)
    .clipped()
    .background(OpenCodeColors.color(.canvasWeak))
    .accessibilityLabel(label)
    .task(id: "\(sourceKey)-\(attempts)") {
      failed = false
      loaded = await images.load(source, server, maximumPixelSize)
      failed = loaded == nil
    }
  }

  private var sourceKey: String {
    switch source {
    case .data: "data"
    case .hash(let hash): hash
    case .localFile(let url): url.path
    }
  }
}

/// Full-screen gallery for transcript images, tool mosaics and file pages.
struct MediaViewerView: View {
  @Bindable var store: StoreOf<MediaViewerFeature>
  let onClose: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dragOffset: CGSize = .zero

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement()
        .accessibilityIdentifier("media-viewer")
      if let page = store.page {
        TabView(
          selection: Binding(
            get: { store.index },
            set: { store.send(.pageSelected($0)) }
          )
        ) {
          ForEach(Array(store.pages.enumerated()), id: \.element.id) { index, page in
            mediaPage(page)
              .tag(index)
          }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .offset(y: dragOffset.height)
        .scaleEffect(dragOffset.height > 0 ? max(0.82, 1 - dragOffset.height / 1_200) : 1)
        .gesture(dismissDrag)
        .onTapGesture {
          store.send(.chromeToggled)
        }
        .overlay(alignment: .top) {
          if store.chromeVisible {
            viewerBar(page)
          }
        }
        .overlay(alignment: .bottom) {
          if store.chromeVisible, store.canPage {
            pageDots
          }
        }
        .fullScreenCover(item: Binding(
          get: { store.annotation.map(AnnotationSheetItem.init) },
          set: { if $0 == nil { store.send(.annotationCancelled) } }
        )) { _ in
          if let source = page.imageSource {
            AnnotationEditor(
              source: source,
              server: store.server,
              imageLoaded: nil,
              initialStrokes: store.annotation?.strokes ?? []
            ) { strokes in
              store.send(.annotationChanged(strokes))
            } onSave: { data in
              store.send(.annotationSaved(data))
            } onCancel: {
              store.send(.annotationCancelled)
            }
            .ignoresSafeArea()
          }
        }
      }
    }
    .preferredColorScheme(.dark)
  }

  @ViewBuilder private func mediaPage(_ page: MediaViewerPage) -> some View {
    switch page.kind {
    case .image:
      if let source = page.imageSource {
        ZoomableMediaImage(
          source: source,
          server: store.server,
          aspectRatio: page.imageSourceAspect,
          retry: store.imageReloads[page.id] ?? 0
        ) {
          store.send(.imageUnavailable(page.id))
        }
      }
    case .video, .audio:
      switch store.loads[page.id] ?? .idle {
      case .downloaded(let url):
        VideoPlayer(player: AVPlayer(url: url))
      case .failed, .unavailable:
        unavailable(page)
      default:
        ProgressView().tint(.white)
      }
    case .pdf:
      switch store.loads[page.id] ?? .idle {
      case .downloaded(let url):
        PDFKitView(url: url)
      case .failed, .unavailable:
        unavailable(page)
      default:
        ProgressView().tint(.white)
      }
    case .text:
      switch store.loads[page.id] ?? .idle {
      case .text(let text):
        ScrollView {
          CodeText(text: text, fileName: page.title)
            .padding()
        }
      case .failed, .unavailable:
        unavailable(page)
      default:
        ProgressView().tint(.white)
      }
    case .unsupported:
      unavailable(page)
    }
  }

  private func unavailable(_ page: MediaViewerPage) -> some View {
    VStack(spacing: OpenCodeSpacing.s12) {
      Image(systemName: "photo.badge.exclamationmark")
        .font(.largeTitle)
      Text(AppCopy.text("media.viewer_unavailable"))
      Button(AppCopy.text("media.viewer_retry")) {
        store.send(.retryTapped(page.id))
      }
      .buttonStyle(.bordered)
    }
    .foregroundStyle(.white)
  }

  private func viewerBar(_ page: MediaViewerPage) -> some View {
    HStack(spacing: OpenCodeSpacing.s12) {
      Button {
        onClose()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel(AppCopy.text("media.viewer_close"))
      .accessibilityIdentifier("media-viewer-close")
      VStack(alignment: .leading, spacing: 2) {
        Text(page.title)
          .font(OpenCodeFonts.font(.headline))
          .lineLimit(1)
        if let detail = page.detail, !detail.isEmpty {
          Text(detail)
            .font(OpenCodeFonts.font(.caption2))
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      if page.canAnnotate {
        Button {
          store.send(.annotateTapped)
        } label: {
          Image(systemName: "pencil.tip.crop.circle")
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel(AppCopy.text("media.viewer_annotate"))
      }
    }
    .foregroundStyle(.white)
    .padding(.horizontal, OpenCodeSpacing.s8)
    .padding(.top, OpenCodeSpacing.s4)
    .background(
      LinearGradient(
        colors: [.black.opacity(0.7), .black.opacity(0)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea(edges: .top)
    )
  }

  private var pageDots: some View {
    HStack(spacing: OpenCodeSpacing.s6) {
      ForEach(store.pages.indices, id: \.self) { index in
        Circle()
          .fill(index == store.index ? .white : .white.opacity(0.35))
          .frame(width: 6, height: 6)
      }
    }
    .padding(.bottom, OpenCodeSpacing.s20)
    .accessibilityLabel(AppCopy.format("media.page_of", store.index + 1, store.pages.count))
  }

  private var dismissDrag: some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { value in
        guard abs(value.translation.height) > abs(value.translation.width) else { return }
        dragOffset = value.translation
      }
      .onEnded { value in
        if value.translation.height > 120 || value.predictedEndTranslation.height > 260 {
          onClose()
        }
        withAnimation(
          OpenCodeMotionRole.microOut.curve(phase: .exit, reduceMotion: reduceMotion).animation
        ) { dragOffset = .zero }
      }
  }
}

private struct AnnotationSheetItem: Identifiable {
  var id: String

  init(_ state: MediaViewerFeature.AnnotationState) {
    id = state.pageID
  }
}

/// UIScrollView zoom and pan, with a double-tap reset. At minimum zoom the parent's swipe-down
/// dismissal can take the gesture; zoomed in, the scroll view keeps it.
private struct ZoomableMediaImage: View {
  let source: MediaImageSource
  let server: OpenCodeServer?
  let aspectRatio: Double?
  let retry: Int
  let onFailure: () -> Void

  @Dependency(\.mediaImages) private var images
  @State private var image: UIImage?
  @State private var failed = false

  var body: some View {
    Group {
      if let image {
        ZoomScrollView(image: image)
      } else if failed {
        VStack(spacing: OpenCodeSpacing.s12) {
          Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
          Text(AppCopy.text("media.viewer_unavailable"))
        }
        .foregroundStyle(.white)
      } else {
        ProgressView().tint(.white)
      }
    }
    .task(id: "\(retry)-\(sourceKey)") {
      failed = false
      let loaded = await images.load(source, server, 2_560)
      if let loaded {
        image = UIImage(cgImage: loaded.image)
      } else {
        failed = true
        onFailure()
      }
    }
  }

  private var sourceKey: String {
    switch source {
    case .data(let data): "\(data.count)-\(data.hashValue)"
    case .hash(let hash): hash
    case .localFile(let url): url.path
    }
  }
}

private struct ZoomScrollView: UIViewRepresentable {
  let image: UIImage

  func makeUIView(context: Context) -> UIScrollView {
    let scroll = UIScrollView()
    scroll.delegate = context.coordinator
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = 5
    scroll.bouncesZoom = true
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    let view = UIImageView(image: image)
    view.contentMode = .scaleAspectFit
    view.frame = scroll.bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.isUserInteractionEnabled = true
    scroll.addSubview(view)
    context.coordinator.imageView = view
    let doubleTap = UITapGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.doubleTapped(_:))
    )
    doubleTap.numberOfTapsRequired = 2
    scroll.addGestureRecognizer(doubleTap)
    return scroll
  }

  func updateUIView(_ scroll: UIScrollView, context: Context) {
    context.coordinator.imageView?.image = image
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, UIScrollViewDelegate {
    weak var imageView: UIImageView?

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
      guard let scroll = gesture.view as? UIScrollView else { return }
      if scroll.zoomScale > 1 {
        scroll.setZoomScale(1, animated: true)
      } else {
        let point = gesture.location(in: imageView)
        let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
        scroll.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
      }
    }
  }
}

private struct PDFKitView: UIViewRepresentable {
  let url: URL

  func makeUIView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.backgroundColor = .black
    view.document = PDFDocument(url: url)
    return view
  }

  func updateUIView(_ view: PDFView, context: Context) {
    if view.document == nil { view.document = PDFDocument(url: url) }
  }
}

struct CodeText: View {
  let text: String
  let fileName: String
  var focusedLine: Int?

  private var preview: CodePreview? {
    CodePreview.make(data: Data(text.utf8), fileName: fileName, focusedLine: focusedLine)
  }

  var body: some View {
    if let preview {
      VStack(alignment: .leading, spacing: 0) {
        if preview.isTruncated {
          Text(AppCopy.text("media.file_truncated"))
            .font(OpenCodeFonts.font(.caption2))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
            .padding(.bottom, OpenCodeSpacing.s6)
        }
        ScrollView(.horizontal, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(preview.lines) { line in
              HStack(alignment: .top, spacing: OpenCodeSpacing.s10) {
                Text("\(line.number)")
                  .font(OpenCodeFonts.font(.codeSmall))
                  .foregroundStyle(OpenCodeColors.color(.textTertiary))
                  .frame(minWidth: 36, alignment: .trailing)
                Text(attributed(line))
                  .font(OpenCodeFonts.font(.codeSmall))
                  .foregroundStyle(OpenCodeColors.color(.textBody))
                  .textSelection(.enabled)
              }
              .padding(.vertical, 1)
              .background(
                line.number == focusedLine
                  ? OpenCodeColors.color(.canvasWeak)
                  : Color.clear
              )
            }
          }
        }
      }
    } else {
      Text(text)
        .font(OpenCodeFonts.font(.codeSmall))
        .textSelection(.enabled)
    }
  }

  private func attributed(_ line: CodePreview.Line) -> AttributedString {
    var value = AttributedString(line.text)
    for token in line.tokens {
      guard token.start >= 0, token.end <= line.text.utf16.count, token.start < token.end else { continue }
      let start = String.Index(utf16Offset: token.start, in: line.text)
      let end = String.Index(utf16Offset: token.end, in: line.text)
      guard let range = Range(start..<end, in: value) else { continue }
      switch token.kind {
      case .keyword: value[range].foregroundColor = OpenCodeColors.color(.accent)
      case .string: value[range].foregroundColor = OpenCodeColors.color(.success)
      case .comment: value[range].foregroundColor = OpenCodeColors.color(.textTertiary)
      case .number: value[range].foregroundColor = OpenCodeColors.color(.warning)
      }
    }
    return value
  }
}

private extension MediaViewerPage {
  var imageSourceAspect: Double? {
    guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
    return Double(pixelWidth) / Double(pixelHeight)
  }
}
