import ComposableArchitecture
import OpenCodeCore
import OpenCodeServer
import OpenCodeSession
import OpenCodeTranscript
import SwiftUI

struct TranscriptEntryRow: View {
  let entry: TranscriptEntry
  let isRunning: Bool
  let expanded: Bool
  let store: StoreOf<SessionFeature>

  var body: some View {
    switch entry {
    case .single(let item):
      TranscriptItemRow(item: item, expanded: expanded, store: store)
    case .userGroup(_, let items, let startsTurn):
      VStack(alignment: .trailing, spacing: OpenCodeSpacing.s8) {
        ForEach(items) { item in
          TranscriptItemRow(item: item, expanded: expanded, store: store)
        }
      }
      .padding(.top, startsTurn ? OpenCodeSpacing.s12 : 0)
      .frame(maxWidth: .infinity, alignment: .trailing)
    case .toolGroup(_, let tools):
      ToolGroupRow(id: entry.id, tools: tools, expanded: expanded, store: store)
    case .replyEnd(let id, let texts):
      HStack {
        Button {
          store.send(.transcriptCopyTapped(texts.joined(separator: "\n\n")))
        } label: {
          Label(AppCopy.text("transcript.copy_reply"), systemImage: "doc.on.doc")
            .font(OpenCodeFonts.font(.caption))
        }
        .buttonStyle(.plain)
        .foregroundStyle(OpenCodeColors.color(.textWeak))
        .accessibilityIdentifier("transcript-copy-\(id)")
        Spacer()
        if !isRunning {
          Text(AppCopy.text("transcript.reply_end"))
            .font(OpenCodeFonts.font(.caption2))
            .foregroundStyle(OpenCodeColors.color(.textTertiary))
        }
      }
      .padding(.top, OpenCodeSpacing.s2)
    }
  }
}

private struct TranscriptItemRow: View {
  let item: TranscriptItem
  let expanded: Bool
  let store: StoreOf<SessionFeature>

  var body: some View {
    switch item {
    case .userText(_, let text, let source, let quotes):
      UserTextRow(
        text: text,
        source: source,
        quotes: quotes,
        onLink: { store.send(.transcriptLinkTapped($0)) }
      )
    case .userImages(_, let images):
      UserImagesRow(images: images)
    case .userFiles(_, let files):
      UserFilesRow(files: files) { store.send(.transcriptFileTapped($0)) }
    case .assistantMarkdown(_, let text, _):
      MarkdownBlocksView(
        itemID: item.id,
        text: text,
        isSecondary: false,
        onLink: { store.send(.transcriptLinkTapped($0)) },
        onCopy: { store.send(.transcriptCopyTapped($0)) }
      )
    case .tool(_, let call):
      ToolRow(id: item.id, call: call, expanded: expanded, store: store)
    case .compaction(_, let info):
      CompactionRow(id: item.id, info: info, expanded: expanded, store: store)
    case .info(_, let text):
      Text(text)
        .font(OpenCodeFonts.font(.caption))
        .foregroundStyle(OpenCodeColors.color(.textTertiary))
        .frame(maxWidth: .infinity, alignment: .center)
    case .modelSwitch(_, let model, let previous, let name):
      HStack(spacing: OpenCodeSpacing.s6) {
        Image(systemName: "arrow.triangle.2.circlepath")
        Text(
          previous == nil
            ? AppCopy.format("transcript.model_switched_to", name ?? model.displayID)
            : AppCopy.format(
              "transcript.model_switched_from",
              name ?? model.displayID,
              previous?.displayID ?? ""
            )
        )
      }
      .font(OpenCodeFonts.font(.caption))
      .foregroundStyle(OpenCodeColors.color(.textWeak))
      .frame(maxWidth: .infinity, alignment: .center)
    case .notice(_, let text, let isError, let kind, let agent):
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
        if let kind {
          Text(TranscriptCopy.noticeHeading(kind, agent: agent))
            .font(OpenCodeFonts.font(.caption))
            .foregroundStyle(OpenCodeColors.color(isError ? .danger : .textWeak))
        }
        Text(text)
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(isError ? .danger : .textBody))
          .textSelection(.enabled)
      }
      .padding(OpenCodeSpacing.s10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        OpenCodeColors.color(isError ? .canvasWeak : .canvasWeak),
        in: .rect(cornerRadius: OpenCodeRadius.control)
      )
    case .sendFailure(_, let message):
      TranscriptProblemRow(
        title: AppCopy.text("transcript.send_failed"),
        detail: message,
        retry: nil
      )
    case .runError(_, let error):
      RunErrorRow(error: error)
    case .runRetry(_, let retry):
      HStack(spacing: OpenCodeSpacing.s6) {
        ProgressView().controlSize(.small)
        Text(
          AppCopy.format(
            "transcript.retrying",
            TranscriptCopy.runError(retry.error),
            retry.attempt
          )
        )
      }
      .font(OpenCodeFonts.font(.footnote))
      .foregroundStyle(OpenCodeColors.color(.textWeak))
      .padding(OpenCodeSpacing.s10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        OpenCodeColors.color(.canvasWeak),
        in: .rect(cornerRadius: OpenCodeRadius.control)
      )
    case .undone(_, let messages):
      Text(AppCopy.count("transcript.messages_undone", messages))
        .font(OpenCodeFonts.font(.caption))
        .foregroundStyle(OpenCodeColors.color(.textWeak))
        .frame(maxWidth: .infinity, alignment: .center)
    }
  }
}

private struct UserTextRow: View {
  let text: String
  let source: TranscriptPromptSource?
  let quotes: [TranscriptQuote]
  let onLink: (String) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: OpenCodeSpacing.s12) {
      Spacer(minLength: OpenCodeSpacing.s24)
      VStack(alignment: .trailing, spacing: OpenCodeSpacing.s6) {
        if let source {
          Text(sourceLabel(source))
            .font(OpenCodeFonts.font(.caption2))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        }
        ForEach(Array(quotes.enumerated()), id: \.offset) { _, quote in
          QuoteCard(quote: quote)
        }
        if !text.isEmpty {
          MarkdownBlocksView(
            itemID: "user-\(text.hashValue)-\(text.utf8.count)",
            text: text,
            isSecondary: false,
            onLink: onLink,
            onCopy: { _ in }
          )
          .padding(.horizontal, OpenCodeSpacing.s12)
          .padding(.vertical, OpenCodeSpacing.s10)
          .background(
            OpenCodeColors.color(.userBubble),
            in: .rect(cornerRadius: OpenCodeRadius.card)
          )
        }
      }
    }
  }

  private func sourceLabel(_ source: TranscriptPromptSource) -> String {
    switch source {
    case .session: return AppCopy.text("transcript.from_subagent")
    case .parentAgent: return AppCopy.text("transcript.from_parent")
    }
  }
}

private struct QuoteCard: View {
  let quote: TranscriptQuote

  var body: some View {
    VStack(alignment: .trailing, spacing: OpenCodeSpacing.s4) {
      Text(quote.text)
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.textBody))
        .lineLimit(4)
        .multilineTextAlignment(.trailing)
      if let comment = quote.comment {
        Text(comment)
          .font(OpenCodeFonts.font(.caption))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
          .multilineTextAlignment(.trailing)
      }
      Text(AppCopy.text("transcript.quote"))
        .font(OpenCodeFonts.font(.caption2))
        .foregroundStyle(OpenCodeColors.color(.textTertiary))
    }
    .padding(OpenCodeSpacing.s10)
    .frame(maxWidth: .infinity, alignment: .trailing)
    .background(
      OpenCodeColors.color(.canvasWeak),
      in: .rect(cornerRadius: OpenCodeRadius.control)
    )
    .overlay {
      RoundedRectangle(cornerRadius: OpenCodeRadius.control)
        .strokeBorder(OpenCodeColors.color(.border), lineWidth: 0.5)
    }
  }
}

private struct UserImagesRow: View {
  let images: [TranscriptImage]

  var body: some View {
    HStack {
      Spacer(minLength: OpenCodeSpacing.s24)
      LazyVGrid(
        columns: Array(repeating: GridItem(.fixed(72), spacing: OpenCodeSpacing.s6), count: min(3, images.count)),
        spacing: OpenCodeSpacing.s6
      ) {
        ForEach(images) { image in
          VStack(spacing: OpenCodeSpacing.s2) {
            Image(systemName: "photo")
              .font(.title3)
              .foregroundStyle(OpenCodeColors.color(.textWeak))
            Text(image.name ?? AppCopy.text("transcript.image"))
              .font(OpenCodeFonts.font(.caption2))
              .lineLimit(1)
          }
          .frame(width: 72, height: 72)
          .background(
            OpenCodeColors.color(.canvasWeak),
            in: .rect(cornerRadius: OpenCodeRadius.tile)
          )
          .overlay {
            RoundedRectangle(cornerRadius: OpenCodeRadius.tile)
              .strokeBorder(OpenCodeColors.color(.border), lineWidth: 0.5)
          }
          .accessibilityLabel(AppCopy.text("transcript.attached_image"))
        }
      }
    }
  }
}

private struct UserFilesRow: View {
  let files: [TranscriptFile]
  let onTap: (TranscriptFile) -> Void

  var body: some View {
    HStack {
      Spacer(minLength: OpenCodeSpacing.s24)
      VStack(alignment: .trailing, spacing: OpenCodeSpacing.s6) {
        ForEach(files) { file in
          Button {
            onTap(file)
          } label: {
            HStack(spacing: OpenCodeSpacing.s8) {
              Image(systemName: file.isUnavailable ? "exclamationmark.triangle" : "doc")
                .foregroundStyle(OpenCodeColors.color(file.isUnavailable ? .warning : .textWeak))
              VStack(alignment: .leading, spacing: OpenCodeSpacing.s1) {
                Text(file.name ?? AppCopy.text("transcript.file"))
                  .font(OpenCodeFonts.font(.footnote))
                  .foregroundStyle(OpenCodeColors.color(.textStrong))
                  .lineLimit(1)
                if let size = TranscriptCopy.fileSize(file.byteCount) {
                  Text(size)
                    .font(OpenCodeFonts.font(.caption2))
                    .foregroundStyle(OpenCodeColors.color(.textWeak))
                }
              }
            }
            .padding(.horizontal, OpenCodeSpacing.s10)
            .padding(.vertical, OpenCodeSpacing.s6)
            .background(
              OpenCodeColors.color(.canvasWeak),
              in: .rect(cornerRadius: OpenCodeRadius.control)
            )
            .overlay {
              RoundedRectangle(cornerRadius: OpenCodeRadius.control)
                .strokeBorder(OpenCodeColors.color(.border), lineWidth: 0.5)
            }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("transcript-file-\(file.id)")
        }
      }
    }
  }
}

private struct ToolGroupRow: View {
  let id: String
  let tools: [TranscriptItem]
  let expanded: Bool
  let store: StoreOf<SessionFeature>

  private var calls: [TranscriptToolCall] {
    tools.compactMap {
      if case .tool(_, let call) = $0 { return call }
      return nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s6) {
      Button {
        store.send(.transcriptDisclosureToggled(id))
      } label: {
        HStack(spacing: OpenCodeSpacing.s8) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
            .foregroundStyle(OpenCodeColors.color(.textTertiary))
          Text(AppCopy.count("transcript.used_tools", calls.count))
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
          if let failed = calls.first(where: { $0.status == .error }) {
            Circle()
              .fill(OpenCodeColors.color(.danger))
              .frame(width: 6, height: 6)
              .accessibilityLabel(AppCopy.text("transcript.tool_failed"))
              .accessibilityValue(failed.name)
          } else if calls.contains(where: { $0.status == .running }) {
            ProgressView().controlSize(.mini)
          }
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier(id)

      if expanded {
        VStack(alignment: .leading, spacing: OpenCodeSpacing.s8) {
          ForEach(Array(tools.enumerated()), id: \.offset) { _, item in
            TranscriptItemRow(item: item, expanded: true, store: store)
          }
        }
        .padding(.leading, OpenCodeSpacing.s12)
      }
    }
  }
}

private struct ToolRow: View {
  let id: String
  let call: TranscriptToolCall
  let expanded: Bool
  let store: StoreOf<SessionFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s6) {
      Button {
        store.send(.transcriptDisclosureToggled(id))
      } label: {
        HStack(alignment: .firstTextBaseline, spacing: OpenCodeSpacing.s8) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
            .foregroundStyle(OpenCodeColors.color(.textTertiary))
          statusMark
          VStack(alignment: .leading, spacing: OpenCodeSpacing.s1) {
            Text(call.displayName)
              .font(OpenCodeFonts.font(.footnote))
              .foregroundStyle(OpenCodeColors.color(.textStrong))
            if let subtitle = call.subtitle {
              Text(subtitle)
                .font(OpenCodeFonts.font(.caption))
                .foregroundStyle(OpenCodeColors.color(.textWeak))
                .lineLimit(expanded ? 6 : 1)
                .truncationMode(.middle)
            }
          }
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("tool-\(id)")

      if expanded {
        VStack(alignment: .leading, spacing: OpenCodeSpacing.s8) {
          if !call.inputText.isEmpty, call.input == .null {
            codeBand(call.inputText)
          }
          if !call.arguments.isEmpty {
            VStack(alignment: .leading, spacing: OpenCodeSpacing.s4) {
              ForEach(Array(call.arguments.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .firstTextBaseline, spacing: OpenCodeSpacing.s6) {
                  Text(pair.0)
                    .font(OpenCodeFonts.font(.codeSmall))
                    .foregroundStyle(OpenCodeColors.color(.textTertiary))
                  Text(pair.1)
                    .font(OpenCodeFonts.font(.codeSmall))
                    .foregroundStyle(OpenCodeColors.color(.textBody))
                    .lineLimit(12)
                    .textSelection(.enabled)
                }
              }
            }
          }
          if !call.outputText.isEmpty {
            codeBand(call.outputText)
          }
          if let error = call.error, !error.isEmpty {
            Text(error)
              .font(OpenCodeFonts.font(.footnote))
              .foregroundStyle(OpenCodeColors.color(.danger))
              .textSelection(.enabled)
          }
          if let exit = call.shellExit, exit != 0 {
            Text(AppCopy.format("transcript.shell_exit", exit))
              .font(OpenCodeFonts.font(.caption))
              .foregroundStyle(OpenCodeColors.color(.danger))
          }
          if !call.images.isEmpty {
            Text(
              AppCopy.count("transcript.tool_image", call.images.count)
            )
            .font(OpenCodeFonts.font(.caption))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
            .accessibilityIdentifier("tool-image-mosaic")
          }
          if !call.videos.isEmpty {
            ForEach(call.videos) { video in
              Button {
                store.send(.transcriptFileTapped(video))
              } label: {
                Label(video.name ?? AppCopy.text("transcript.video"), systemImage: "film")
                  .font(OpenCodeFonts.font(.caption))
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("transcript-tool-video-\(video.id)")
            }
          }
        }
        .padding(OpenCodeSpacing.s10)
        .background(
          OpenCodeColors.color(.canvasWeak),
          in: .rect(cornerRadius: OpenCodeRadius.control)
        )
      }
    }
    .padding(.vertical, OpenCodeSpacing.s2)
  }

  @ViewBuilder private var statusMark: some View {
    switch call.status {
    case .running, .streaming:
      ProgressView().controlSize(.mini)
    case .error:
      Circle().fill(OpenCodeColors.color(.danger)).frame(width: 6, height: 6)
    case .completed:
      Image(systemName: "checkmark")
        .font(.caption2)
        .foregroundStyle(OpenCodeColors.color(.textTertiary))
    }
  }

  private func codeBand(_ text: String) -> some View {
    ScrollView(.horizontal) {
      Text(text)
        .font(OpenCodeFonts.font(.codeSmall))
        .foregroundStyle(OpenCodeColors.color(.textBody))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: 260)
    .padding(OpenCodeSpacing.s8)
    .background(
      OpenCodeColors.color(.codeBand),
      in: .rect(cornerRadius: OpenCodeRadius.xs)
    )
  }
}

private struct CompactionRow: View {
  let id: String
  let info: TranscriptCompaction?
  let expanded: Bool
  let store: StoreOf<SessionFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s6) {
      Button {
        guard info?.status == .completed, let info, !info.summary.isEmpty else { return }
        store.send(.transcriptDisclosureToggled(id))
      } label: {
        HStack(spacing: OpenCodeSpacing.s8) {
          Image(systemName: "rectangle.compress.vertical")
            .foregroundStyle(OpenCodeColors.color(.textWeak))
          Text(title)
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
          if info?.status == .running { ProgressView().controlSize(.mini) }
          Spacer()
          if info?.status == .completed, info?.summary.isEmpty == false {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.caption2)
              .foregroundStyle(OpenCodeColors.color(.textTertiary))
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("compaction-\(id)")

      if expanded, info?.status == .completed, let summary = info?.summary, !summary.isEmpty {
        MarkdownBlocksView(
          itemID: "\(id)-summary",
          text: summary,
          isSecondary: true,
          onLink: { store.send(.transcriptLinkTapped($0)) },
          onCopy: { store.send(.transcriptCopyTapped($0)) }
        )
        .padding(OpenCodeSpacing.s10)
        .background(
          OpenCodeColors.color(.canvasWeak),
          in: .rect(cornerRadius: OpenCodeRadius.control)
        )
      }
      if info?.status == .failed, let message = info?.errorMessage {
        Text(message)
          .font(OpenCodeFonts.font(.caption))
          .foregroundStyle(OpenCodeColors.color(.danger))
      }
      if let info, let input = info.inputTokens, let output = info.outputTokens {
        Text(AppCopy.format("transcript.compaction_usage", input, output))
          .font(OpenCodeFonts.font(.caption2))
          .foregroundStyle(OpenCodeColors.color(.textTertiary))
      }
    }
    .padding(.vertical, OpenCodeSpacing.s4)
  }

  private var title: String {
    guard let info else { return AppCopy.text("transcript.compaction.completed") }
    switch info.status {
    case .running: return AppCopy.text("transcript.compaction.running")
    case .failed: return AppCopy.text("transcript.compaction.failed")
    case .cancelled: return AppCopy.text("transcript.compaction.cancelled")
    case .completed:
      return info.isProvider
        ? AppCopy.text("transcript.compaction.provider")
        : AppCopy.text("transcript.compaction.completed")
    }
  }
}

private struct RunErrorRow: View {
  let error: TranscriptRunError

  var body: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s4) {
      Label(TranscriptCopy.runError(error), systemImage: "exclamationmark.triangle")
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(error.isStop ? .textWeak : .danger))
      Text(error.type)
        .font(OpenCodeFonts.font(.caption2))
        .foregroundStyle(OpenCodeColors.color(.textTertiary))
        .textSelection(.enabled)
    }
    .padding(OpenCodeSpacing.s10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      OpenCodeColors.color(.canvasWeak),
      in: .rect(cornerRadius: OpenCodeRadius.control)
    )
    .accessibilityIdentifier("transcript-run-error")
  }
}

private struct TranscriptProblemRow: View {
  let title: String
  let detail: String
  let retry: (() -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: OpenCodeSpacing.s8) {
      Image(systemName: "exclamationmark.circle")
        .foregroundStyle(OpenCodeColors.color(.danger))
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
        Text(title)
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.danger))
        if !detail.isEmpty {
          Text(detail)
            .font(OpenCodeFonts.font(.caption))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
            .textSelection(.enabled)
        }
        if let retry {
          Button(AppCopy.text("common.try_again"), action: retry)
            .font(OpenCodeFonts.font(.caption))
        }
      }
      Spacer()
    }
    .padding(OpenCodeSpacing.s10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      OpenCodeColors.color(.canvasWeak),
      in: .rect(cornerRadius: OpenCodeRadius.control)
    )
  }
}
