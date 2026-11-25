import AVKit
import ComposableArchitecture
import OpenCodeCore
import OpenCodeMedia
import OpenCodeServer
import PDFKit
import SwiftUI

/// A server file opened from a reply, a tool row or an attachment card. Content is read through the
/// authenticated client; the local file system is never asked for a server path.
struct FileViewerView: View {
  @Bindable var store: StoreOf<FileViewerFeature>
  let onClose: () -> Void

  var body: some View {
    NavigationStack {
      Group {
        switch store.load {
        case .idle, .loading:
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .code(let preview):
          if store.wrapsLines {
            ScrollView(.vertical) {
              CodePreviewText(preview: preview, wrapsLines: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .accessibilityIdentifier("file-viewer-code-wrapped")
          } else {
            ScrollView([.vertical, .horizontal]) {
              CodePreviewText(preview: preview, wrapsLines: false)
                .padding()
            }
            .accessibilityIdentifier("file-viewer-code-unwrapped")
          }
        case .image(let data):
          ScrollView([.vertical, .horizontal]) {
            MediaThumbnail(
              source: .data(data),
              server: store.server,
              maximumPixelSize: 2_560,
              aspectRatio: nil,
              label: store.title
            )
            .frame(maxWidth: 2_560)
          }
        case .downloaded(let url):
          if store.kind == .pdf {
            PDFKitFileView(url: url)
          } else {
            VideoPlayer(player: AVPlayer(url: url))
          }
        case .unsupported:
          unavailable(AppCopy.text("media.file_unsupported"))
        case .unavailable:
          unavailable(AppCopy.text("media.viewer_unavailable"))
        case .failed:
          VStack(spacing: OpenCodeSpacing.s12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(AppCopy.text("media.file_unsupported"))
            Button(AppCopy.text("media.viewer_retry")) { store.send(.retryTapped) }
              .buttonStyle(.bordered)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .alert(
        AppCopy.text("media.file_wrap_failed"),
        isPresented: Binding(
          get: { store.wrapLinesProblem },
          set: { if !$0 { store.send(.wrapLinesProblemDismissed) } }
        )
      ) {
        Button(AppCopy.text("common.done")) {}
      }
      .navigationTitle(store.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppCopy.text("media.viewer_close")) { onClose() }
            .accessibilityIdentifier("file-viewer-close")
        }
        ToolbarItemGroup(placement: .primaryAction) {
          if store.text != nil {
            Button {
              store.send(.wrapLinesToggled)
            } label: {
              Image(systemName: store.wrapsLines ? "text.alignleft" : "arrow.left.and.right")
            }
            .accessibilityLabel(AppCopy.text("media.file_wrap_lines"))
            .accessibilityValue(store.wrapsLines ? "wrapped" : "scrolls")
            .accessibilityIdentifier("file-viewer-wrap-lines")
            if let text = store.text {
              ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up")
              }
              .accessibilityLabel(AppCopy.text("media.file_share"))
            }
          }
        }
      }
    }
    .accessibilityIdentifier("file-viewer")
  }

  private func unavailable(_ text: String) -> some View {
    VStack(spacing: OpenCodeSpacing.s12) {
      Image(systemName: "doc").font(.largeTitle)
      Text(text)
        .foregroundStyle(OpenCodeColors.color(.textWeak))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct CodePreviewText: View {
  let preview: CodePreview
  var wrapsLines: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if preview.isTruncated {
        Text(AppCopy.text("media.file_truncated"))
          .font(OpenCodeFonts.font(.caption2))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
          .padding(.bottom, OpenCodeSpacing.s6)
      }
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
            .fixedSize(horizontal: !wrapsLines, vertical: true)
            .frame(maxWidth: wrapsLines ? .infinity : nil, alignment: .leading)
        }
        .padding(.vertical, 1)
        .background(
          line.number == preview.focusedLine
            ? OpenCodeColors.color(.canvasWeak)
            : Color.clear
        )
      }
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

private struct PDFKitFileView: UIViewRepresentable {
  let url: URL

  func makeUIView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.document = PDFDocument(url: url)
    return view
  }

  func updateUIView(_ view: PDFView, context: Context) {
    if view.document == nil { view.document = PDFDocument(url: url) }
  }
}
