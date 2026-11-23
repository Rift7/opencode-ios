import ComposableArchitecture
import OpenCodeCore
import OpenCodeServer
import OpenCodeSession
import OpenCodeTranscript
import SwiftUI

/// The transcript stack. A standard SwiftUI scroll view owns following, restoration and lazy row
/// rendering; the reducer owns grouping, loaded pages and disclosure state.
struct TranscriptView: View {
  let store: StoreOf<SessionFeature>
  let transcript: TranscriptState
  let isRunning: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var position: String?
  @State private var isFollowing: Bool
  @State private var pendingEarlierAnchor: String?
  @State private var restoreTask: Task<Void, Never>?
  @State private var readerIsScrolling = false
  @State private var quoteSelection: QuoteSelection?
  @State private var frameProbe = ScrollFrameProbe()

  init(store: StoreOf<SessionFeature>, transcript: TranscriptState, isRunning: Bool) {
    self.store = store
    self.transcript = transcript
    self.isRunning = isRunning
    _isFollowing = State(initialValue: transcript.isFollowing)
  }

  private var entries: [TranscriptEntry] { transcript.entries(isRunning: isRunning) }
  private var lastEntryID: String? { entries.last?.id }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: OpenCodeSpacing.s12) {
          if transcript.hasEarlierItems || transcript.isLoadingEarlier || transcript.earlierProblem != nil {
            earlierHistoryRow
          }
          if transcript.showsEmptyState {
            emptyState
          }
          ForEach(entries) { entry in
            TranscriptEntryRow(
              entry: entry,
              isRunning: isRunning,
              expanded: transcript.expandedIDs.contains(entry.id),
              store: store,
              onQuote: { quoteSelection = QuoteSelection(text: $0) }
            )
            .id(entry.id)
          }
          if isRunning {
            workingRow
          }
          #if DEBUG
          Text("tail")
            .font(.caption2)
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("transcript-tail")
          #endif
        }
        .scrollTargetLayout()
        .padding(.horizontal, OpenCodeSpacing.screenHorizontal)
        .padding(.vertical, OpenCodeSpacing.s16)
      }
      .scrollPosition(id: $position)
      .accessibilityIdentifier("transcript-list")
      .scrollDismissesKeyboard(.interactively)
      .defaultScrollAnchor(.bottom)
      .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
        TranscriptScrollMetrics(geometry)
      } action: { old, new in
        handleScroll(from: old, to: new, proxy: proxy)
      }
      .onChange(of: transcript.items.count) { _, _ in
        if let pendingEarlierAnchor, entries.contains(where: { $0.id == pendingEarlierAnchor }) {
          let anchor = pendingEarlierAnchor
          self.pendingEarlierAnchor = nil
          withAnimation(nil) { proxy.scrollTo(anchor, anchor: .top) }
          return
        }
        guard isFollowing, !readerIsScrolling, let lastEntryID else { return }
        withAnimation(nil) { proxy.scrollTo(lastEntryID, anchor: .bottom) }
      }
      .onChange(of: lastEntryID) { _, _ in
        guard isFollowing, !readerIsScrolling, let lastEntryID else { return }
        withAnimation(nil) { proxy.scrollTo(lastEntryID, anchor: .bottom) }
      }
      .overlay(alignment: .bottomTrailing) {
        if !isFollowing {
          jumpButton(proxy: proxy)
            .padding(OpenCodeSpacing.s16)
        }
      }
      .task {
        restoreTask?.cancel()
        restoreTask = Task { @MainActor in
          // One layout turn before restoring a covered page's anchor.
          try? await Task.sleep(for: .milliseconds(60))
          guard !Task.isCancelled else { return }
          if !transcript.isFollowing, let anchor = transcript.scrollAnchorID,
            entries.contains(where: { $0.id == anchor })
          {
            proxy.scrollTo(anchor, anchor: .top)
          } else if let lastEntryID {
            proxy.scrollTo(lastEntryID, anchor: .bottom)
          }
        }
      }
      .onScrollPhaseChange { _, phase in
        readerIsScrolling =
          phase == .tracking || phase == .interacting || phase == .decelerating
        #if DEBUG
        frameProbe.isScrolling = phase != .idle
        #endif
        if phase == .idle, !isFollowing {
          sendFollowChanged(false)
        }
      }
      .onDisappear {
        sendFollowChanged(isFollowing)
      }
      .environment(\.openURL, OpenURLAction { url in
        store.send(.transcriptLinkTapped(url.absoluteString))
        return .handled
      })
      #if DEBUG
      .overlay(alignment: .topLeading) {
        Text(frameProbe.summary)
          .font(.caption2)
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .accessibilityIdentifier("transcript-frame-probe")
      }
      .overlay(alignment: .topLeading) {
        Text(isFollowing ? "following" : "browsing")
          .font(.caption2)
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .accessibilityIdentifier("transcript-follow-state")
      }
      .overlay(alignment: .topLeading) {
        Text("\(MarkdownDebugCounters.parseRequests)")
          .font(.caption2)
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .accessibilityIdentifier("markdown-parse-count")
      }
      .overlay(alignment: .topLeading) {
        Text("\(entries.count)")
          .font(.caption2)
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .accessibilityIdentifier("transcript-entry-count")
      }
      #endif
    }
    .sheet(item: $quoteSelection) { selection in
      QuoteSelectionSheet(text: selection.text) { text in
        store.send(.transcriptQuoteTapped(text))
      }
    }
  }

  private func handleScroll(
    from old: TranscriptScrollMetrics,
    to new: TranscriptScrollMetrics,
    proxy: ScrollViewProxy
  ) {
    let atEnd = new.distanceToEnd < 96
    if atEnd {
      if !isFollowing, readerIsScrolling || new.offsetY > old.offsetY + 0.5 {
        setFollowing(true)
      }
      return
    }
    // While browsing, content growth must never pull the reader back to the end.
    guard isFollowing else { return }
    if readerIsScrolling {
      setFollowing(false)
      return
    }
    if new.contentHeight > old.contentHeight + 0.5 {
      // Text, tool output and async Markdown layout can grow the tail without a row identity
      // change. Re-pin only when the person was already following.
      pinToLatest(proxy)
      return
    }
    if new.offsetY < old.offsetY - 0.5 {
      setFollowing(false)
    }
  }

  private func pinToLatest(_ proxy: ScrollViewProxy) {
    guard let lastEntryID else { return }
    withAnimation(nil) { proxy.scrollTo(lastEntryID, anchor: .bottom) }
  }

  private func setFollowing(_ value: Bool) {
    guard isFollowing != value else { return }
    isFollowing = value
    sendFollowChanged(value)
  }

  private func sendFollowChanged(_ value: Bool) {
    store.send(
      .transcriptFollowChanged(
        sessionID: transcript.sessionID,
        isFollowing: value,
        anchorID: position ?? transcript.scrollAnchorID
      )
    )
  }

  private var earlierHistoryRow: some View {
    HStack(spacing: OpenCodeSpacing.s8) {
      if transcript.isLoadingEarlier {
        ProgressView()
          .controlSize(.small)
        Text(AppCopy.text("transcript.loading_earlier"))
          .font(OpenCodeFonts.font(.caption))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      } else if let problem = transcript.earlierProblem {
        Text(TranscriptCopy.problem(problem, earlier: true))
          .font(OpenCodeFonts.font(.caption))
          .foregroundStyle(OpenCodeColors.color(.danger))
        Button(AppCopy.text("common.try_again")) {
          store.send(.transcriptEarlierTapped)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("transcript-earlier-retry")
      } else if transcript.hasEarlierItems {
        Button {
          pendingEarlierAnchor = position ?? entries.first?.id
          store.send(.transcriptEarlierTapped)
        } label: {
          Label(AppCopy.text("transcript.load_earlier"), systemImage: "arrow.up")
            .font(OpenCodeFonts.font(.footnote))
        }
        .buttonStyle(.plain)
        .foregroundStyle(OpenCodeColors.color(.link))
        .accessibilityIdentifier("transcript-earlier")
      }
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s6) {
      Text(AppCopy.text("transcript.empty_title"))
        .font(OpenCodeFonts.font(.headline))
        .foregroundStyle(OpenCodeColors.color(.textStrong))
      Text(AppCopy.text("transcript.empty_detail"))
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.textWeak))
    }
    .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
    .multilineTextAlignment(.center)
    .accessibilityIdentifier("transcript-empty")
  }

  private var workingRow: some View {
    HStack(spacing: OpenCodeSpacing.s8) {
      ProgressView()
        .controlSize(.small)
      Text(AppCopy.text("transcript.working"))
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.textWeak))
    }
    .accessibilityIdentifier("transcript-working")
  }

  private func jumpButton(proxy: ScrollViewProxy) -> some View {
    Button {
      guard let lastEntryID else { return }
      isFollowing = true
      store.send(.transcriptJumpTapped)
      let curve = OpenCodeMotionRole.microIn.curve(phase: .enter, reduceMotion: reduceMotion)
      withAnimation(curve.animation) {
        proxy.scrollTo(lastEntryID, anchor: .bottom)
      }
    } label: {
      Label(AppCopy.text("transcript.jump_latest"), systemImage: "arrow.down")
        .font(OpenCodeFonts.font(.footnote))
        .padding(.horizontal, OpenCodeSpacing.s12)
        .padding(.vertical, OpenCodeSpacing.s8)
        .background(OpenCodeColors.color(.surfaceStrong), in: .capsule)
        .overlay {
          Capsule().strokeBorder(OpenCodeColors.color(.border), lineWidth: 0.5)
        }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("transcript-jump")
  }
}

enum TranscriptCopy {
  static func problem(_ problem: SessionProblem, earlier: Bool) -> String {
    switch problem {
    case .offline: return AppCopy.text("transcript.error.offline")
    case .unreachable: return AppCopy.text("transcript.error.unreachable")
    case .timedOut: return AppCopy.text("transcript.error.timed_out")
    case .credentialsRejected: return AppCopy.text("transcript.error.credentials")
    case .incompatibleAPI: return AppCopy.text("transcript.error.incompatible")
    case .malformed: return AppCopy.text(earlier ? "transcript.error.earlier" : "transcript.error.malformed")
    case .serverStatus(let status): return AppCopy.format("transcript.error.status", status)
    case .unsupported, .notFound, .unknown:
      return AppCopy.text(earlier ? "transcript.error.earlier" : "transcript.error.generic")
    }
  }

  static func runError(_ error: TranscriptRunError) -> String {
    if error.isStop { return AppCopy.text("transcript.run_error.stopped") }
    switch error.type {
    case "provider.content-filter": return AppCopy.text("transcript.run_error.content_filter")
    case "provider.rate-limit": return AppCopy.text("transcript.run_error.rate_limit")
    case "provider.quota": return AppCopy.text("transcript.run_error.quota")
    case "provider.auth": return AppCopy.text("transcript.run_error.auth")
    case "provider.invalid-request":
      return AppCopy.text(
        error.isContextOverflow
          ? "transcript.run_error.context_overflow"
          : "transcript.run_error.invalid_request"
      )
    case "provider.internal":
      return AppCopy.text(
        error.isOverloaded ? "transcript.run_error.overloaded" : "transcript.run_error.internal"
      )
    case "provider.transport": return AppCopy.text("transcript.run_error.transport")
    case "provider.timeout": return AppCopy.text("transcript.run_error.timeout")
    case "provider.invalid-output": return AppCopy.text("transcript.run_error.invalid_output")
    case "provider.no-route", "provider.unknown": return AppCopy.text("transcript.run_error.unavailable")
    case "provider.unsupported-operation":
      return AppCopy.text("transcript.run_error.unsupported")
    case "tool.execution": return AppCopy.text("transcript.run_error.tool")
    default: return AppCopy.text("transcript.run_error.other")
    }
  }

  static func noticeHeading(_ kind: TranscriptNoticeKind, agent: String?) -> String {
    let actor: String
    switch kind.source {
    case .shell: actor = AppCopy.text("transcript.notice.shell")
    case .subagent:
      if let agent, !agent.isEmpty {
        actor = agent.prefix(1).uppercased() + agent.dropFirst()
      } else {
        actor = AppCopy.text("transcript.notice.subagent")
      }
    }
    switch kind.outcome {
    case .finished: return AppCopy.format("transcript.notice.finished", actor)
    case .failed: return AppCopy.format("transcript.notice.failed", actor)
    case .cancelled: return AppCopy.format("transcript.notice.interrupted", actor)
    }
  }

  static func fileSize(_ bytes: Int?) -> String? {
    guard let bytes, bytes > 0 else { return nil }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }
}

private struct TranscriptScrollMetrics: Equatable {
  var offsetY: CGFloat
  var contentHeight: CGFloat
  var containerHeight: CGFloat

  init(_ geometry: ScrollGeometry) {
    offsetY = geometry.contentOffset.y
    contentHeight = geometry.contentSize.height
    containerHeight = geometry.containerSize.height
  }

  var distanceToEnd: CGFloat {
    contentHeight - offsetY - containerHeight
  }
}
