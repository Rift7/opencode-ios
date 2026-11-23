import OpenCodeCore
import OpenCodeServer
import OpenCodeTranscript
import SwiftUI

/// Draws parsed Markdown without a web view. Remote images and links are cards; nothing is
/// fetched or opened until the person asks.
struct MarkdownBlocksView: View {
  let itemID: String
  let text: String
  let isSecondary: Bool
  let onLink: (String) -> Void
  let onCopy: (String) -> Void

  @State private var presenter = MarkdownBlockPresenter()

  var body: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s10) {
      if let blocks = presenter.blocks {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
          MarkdownBlockView(block: block, isSecondary: isSecondary, onLink: onLink, onCopy: onCopy)
        }
      } else {
        Text(text)
          .font(OpenCodeFonts.font(.body))
          .foregroundStyle(OpenCodeColors.color(isSecondary ? .textWeak : .textBody))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .task(id: cacheKey) {
      presenter.load(key: cacheKey, text: text)
    }
    .onDisappear {
      presenter.clear()
    }
  }

  private var cacheKey: String { "\(itemID)#\(text.utf8.count)#\(text.hashValue)" }
}

private struct MarkdownBlockView: View {
  let block: MarkdownBlock
  let isSecondary: Bool
  let onLink: (String) -> Void
  let onCopy: (String) -> Void

  var body: some View {
    switch block {
    case .heading(let level, let text):
      Text(MarkdownParser.inline(text))
        .font(headingFont(level))
        .foregroundStyle(
          OpenCodeColors.color(isSecondary ? .textWeak : .textStrong)
        )
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

    case .paragraph(let text):
      Text(MarkdownParser.inline(text))
        .font(OpenCodeFonts.font(.body))
        .foregroundStyle(OpenCodeColors.color(isSecondary ? .textWeak : .textBody))
        .lineSpacing(2)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

    case .list(let ordered, let items):
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s4) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: OpenCodeSpacing.s8) {
            Text(marker(ordered: ordered, index: index, item: item))
              .font(OpenCodeFonts.font(.body))
              .foregroundStyle(OpenCodeColors.color(.textTertiary))
              .frame(minWidth: 18, alignment: .trailing)
            Text(MarkdownParser.inline(item.text))
              .font(OpenCodeFonts.font(.body))
              .foregroundStyle(OpenCodeColors.color(isSecondary ? .textWeak : .textBody))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }

    case .quote(let text):
      HStack(alignment: .top, spacing: OpenCodeSpacing.s10) {
        Rectangle()
          .fill(OpenCodeColors.color(.borderStrong))
          .frame(width: 2)
        Text(MarkdownParser.inline(text))
          .font(OpenCodeFonts.font(.body))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
          .textSelection(.enabled)
      }
      .fixedSize(horizontal: false, vertical: true)

    case .code(let language, let text):
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text(language?.uppercased() ?? AppCopy.text("transcript.code"))
            .font(OpenCodeFonts.font(.codeSmall))
            .foregroundStyle(OpenCodeColors.color(.textTertiary))
          Spacer()
          Button {
            onCopy(text)
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.plain)
          .accessibilityLabel(AppCopy.text("transcript.copy_code"))
          .accessibilityIdentifier("transcript-copy-code")
        }
        .padding(.horizontal, OpenCodeSpacing.s10)
        .padding(.vertical, OpenCodeSpacing.s6)
        Text(text)
          .font(OpenCodeFonts.font(.code))
          .foregroundStyle(OpenCodeColors.color(.textBody))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(OpenCodeSpacing.s10)
      }
      .background(
        OpenCodeColors.color(.codeBand),
        in: .rect(cornerRadius: OpenCodeRadius.control)
      )
      .overlay {
        RoundedRectangle(cornerRadius: OpenCodeRadius.control)
          .strokeBorder(OpenCodeColors.color(.border), lineWidth: 0.5)
      }

    case .table(let header, let rows):
      ScrollView(.horizontal) {
        Grid(alignment: .leading, horizontalSpacing: OpenCodeSpacing.s12, verticalSpacing: OpenCodeSpacing.s6) {
          GridRow {
            ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
              Text(MarkdownParser.inline(cell))
                .font(OpenCodeFonts.font(.subheadline))
                .foregroundStyle(OpenCodeColors.color(.textStrong))
            }
          }
          Divider().overlay(OpenCodeColors.color(.border))
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            GridRow {
              ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                Text(MarkdownParser.inline(cell))
                  .font(OpenCodeFonts.font(.subheadline))
                  .foregroundStyle(OpenCodeColors.color(.textBody))
              }
            }
          }
        }
        .padding(OpenCodeSpacing.s10)
      }
      .background(
        OpenCodeColors.color(.codeBand),
        in: .rect(cornerRadius: OpenCodeRadius.control)
      )

    case .rule:
      Divider().overlay(OpenCodeColors.color(.border))

    case .math(let source):
      Text(source)
        .font(OpenCodeFonts.font(.code))
        .foregroundStyle(OpenCodeColors.color(.textBody))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(OpenCodeSpacing.s10)
        .background(
          OpenCodeColors.color(.codeBand),
          in: .rect(cornerRadius: OpenCodeRadius.control)
        )
        .accessibilityLabel(AppCopy.text("transcript.math"))

    case .image(let alt, let url):
      Button {
        onLink(url)
      } label: {
        HStack(spacing: OpenCodeSpacing.s10) {
          Image(systemName: "photo")
            .foregroundStyle(OpenCodeColors.color(.textWeak))
          VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
            Text(alt ?? AppCopy.text("transcript.image"))
              .font(OpenCodeFonts.font(.subheadline))
              .foregroundStyle(OpenCodeColors.color(.textStrong))
            Text(url)
              .font(OpenCodeFonts.font(.caption))
              .foregroundStyle(OpenCodeColors.color(.textWeak))
              .lineLimit(1)
          }
          Spacer()
        }
        .padding(OpenCodeSpacing.s10)
        .background(
          OpenCodeColors.color(.canvasWeak),
          in: .rect(cornerRadius: OpenCodeRadius.control)
        )
      }
      .buttonStyle(.plain)
    }
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: OpenCodeFonts.font(.title2)
    case 2: OpenCodeFonts.font(.title3)
    case 3: OpenCodeFonts.font(.headline)
    default: OpenCodeFonts.font(.subheadline)
    }
  }

  private func marker(ordered: Bool, index: Int, item: MarkdownListItem) -> String {
    if let checked = item.checked { return checked ? "☑" : "☐" }
    return ordered ? "\(index + 1)." : "•"
  }
}
