import ComposableArchitecture
import OpenCodeCore
import OpenCodeDrawer
import OpenCodeServer
import SwiftUI

/// The connected Home: a session surface with the native drawer over it. Session screens belong to
/// P7, so opening a row hands a stable selection to `RootView` instead of claiming a transcript.
struct HomeView: View {
  let store: StoreOf<HomeFeature>
  let savedServers: [OpenCodeServer]
  let disconnect: () -> Void
  let openSettings: () -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: OpenCodeSpacing.s24) {
          header
          if let notice = store.notice {
            HomeNoticeView(notice: notice) { store.send(.noticeExpired) }
          }
          projectSection
          recentSection
          openSessionsButton
        }
        .padding(OpenCodeSpacing.s24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle(store.server.displayName)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            store.send(.drawerToggled)
          } label: {
            Image(systemName: "list.bullet")
          }
          .accessibilityLabel(AppCopy.text("home.open_sessions"))
          .accessibilityIdentifier("home-drawer-button")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button {
            store.send(.newSessionTapped(directory: nil))
          } label: {
            Image(systemName: "square.and.pencil")
          }
          .accessibilityLabel(AppCopy.text("composer.new_session"))
          .accessibilityIdentifier("home-new-session")
          Button {
            store.send(.serverSwitcherTapped)
          } label: {
            Image(systemName: "server.rack")
          }
          .accessibilityLabel(AppCopy.text("home.server_switcher.title"))
          .accessibilityIdentifier("home-server-button")
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("root-phase-connected")
    .sheet(isPresented: drawerPresented) {
      HomeDrawer(
        store: store,
        openSettings: openSettings
      )
    }
    .sheet(isPresented: serverSwitcherPresented) {
      ServerSwitcherView(
        savedServers: savedServers,
        current: store.server,
        select: { store.send(.savedServerSelected($0)) },
        disconnect: {
          store.send(.serverSwitcherDismissed)
          disconnect()
        },
        dismiss: { store.send(.serverSwitcherDismissed) }
      )
    }
    .alert(
      AppCopy.text("home.delete.title"),
      isPresented: deleteConfirmationPresented,
      presenting: store.pendingDeletion?.session
    ) { _ in
      Button(AppCopy.text("home.delete.action"), role: .destructive) {
        store.send(.deleteConfirmed)
      }
      Button(AppCopy.text("common.cancel"), role: .cancel) {
        store.send(.deleteCancelled)
      }
    } message: { session in
      Text(AppCopy.format("home.delete.message", session.title))
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s4) {
      Text(store.server.displayName)
        .font(OpenCodeFonts.font(.title2))
        .foregroundStyle(OpenCodeColors.color(.textStrong))
      Text(AppCopy.text("home.connected"))
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.success))
        .accessibilityIdentifier("home-connected")
    }
  }

  private var projectSection: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s8) {
      Text(AppCopy.text("home.projects"))
        .font(OpenCodeFonts.font(.headline))
        .foregroundStyle(OpenCodeColors.color(.textStrong))
      if store.projects.isEmpty {
        Text(AppCopy.text("home.no_projects"))
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      } else {
        ForEach(store.projects, id: \.id) { project in
          ProjectRow(project: project) {
            store.send(.newSessionTapped(directory: project.directory))
          }
        }
      }
    }
    .accessibilityIdentifier("home-projects")
  }

  private var recentSection: some View {
    let recents = Array(store.drawerSessions.recents.prefix(5))
    return VStack(alignment: .leading, spacing: OpenCodeSpacing.s8) {
      Text(AppCopy.text("home.recent"))
        .font(OpenCodeFonts.font(.headline))
        .foregroundStyle(OpenCodeColors.color(.textStrong))
      if recents.isEmpty {
        Text(
          store.isLive
            ? AppCopy.text("home.no_sessions")
            : AppCopy.text("home.reconnecting")
        )
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.textWeak))
      } else {
        ForEach(recents, id: \.id) { session in
          HomeSessionRow(
            session: session,
            project: projectName(for: session),
            indicator: store.state.indicator(session),
            isPinned: store.state.isPinned(session.id),
            identifier: "home-session-row-\(session.id)",
            open: { store.send(.sessionTapped(session.id)) },
            pin: { store.send(.pinToggled(session.id)) },
            markRead: { store.send(.markReadTapped(session.id)) },
            markUnread: { store.send(.markUnreadTapped(session.id)) },
            delete: { store.send(.deleteTapped(session.id)) }
          )
        }
      }
    }
    .accessibilityIdentifier("home-recent")
  }

  private var openSessionsButton: some View {
    Button {
      store.send(.drawerToggled)
    } label: {
      Text(AppCopy.text("home.open_sessions"))
        .font(OpenCodeFonts.font(.headline))
        .foregroundStyle(OpenCodeColors.color(.canvas))
        .padding(.vertical, OpenCodeSpacing.s14)
        .frame(maxWidth: .infinity)
        .background(OpenCodeColors.color(.accent), in: .rect(cornerRadius: OpenCodeRadius.control))
        .frame(minHeight: 48)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("home-open-sessions")
  }

  private func projectName(for session: OpenCodeSession) -> String {
    store.projects.first { $0.id == session.projectID }?.name ?? ""
  }

  private var drawerPresented: Binding<Bool> {
    Binding(
      get: { store.isDrawerOpen },
      set: { isOpen in
        if !isOpen { store.send(.drawerDismissed) }
      }
    )
  }

  private var serverSwitcherPresented: Binding<Bool> {
    Binding(
      get: { store.showsServerSwitcher },
      set: { isOpen in
        if !isOpen { store.send(.serverSwitcherDismissed) }
      }
    )
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { store.pendingDeletion != nil },
      set: { isOpen in
        if !isOpen { store.send(.deleteCancelled) }
      }
    )
  }
}

// MARK: - Drawer

private struct HomeDrawer: View {
  let store: StoreOf<HomeFeature>
  let openSettings: () -> Void
  #if DEBUG
  @State private var frameProbe = ScrollFrameProbe()
  #endif

  var body: some View {
    NavigationStack {
      drawerList
        .navigationDestination(isPresented: catchUpPresented) {
          CatchUpView(store: store)
        }
    }
    .presentationDragIndicator(.visible)
    .accessibilityIdentifier("drawer")
  }

  private var drawerList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: OpenCodeSpacing.s4) {
        searchField

        Button {
          store.send(.catchUpTapped)
        } label: {
          DrawerActionRow(
            icon: store.catchUpFinished ? "checkmark.circle" : "arrow.uturn.backward.circle",
            title: store.catchUpFinished
              ? AppCopy.text("home.all_caught_up")
              : AppCopy.text("home.catch_up"),
            detail: catchUpDetail
          )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(store.catchUpFinished ? "drawer-all-caught-up" : "drawer-catch-up")
        .disabled(store.catchUpSessions.isEmpty && !store.canMarkAllRead)
        .contextMenu {
          if store.canMarkAllRead {
            Button(AppCopy.text("home.mark_all_read")) {
              store.send(.markAllReadTapped)
            }
          }
        }
        .accessibilityAction(named: Text(AppCopy.text("home.mark_all_read"))) {
          store.send(.markAllReadTapped)
        }

        if store.showsWhatsNewRow {
          Button {
            store.send(.whatsNewTapped)
          } label: {
            DrawerActionRow(
              icon: "sparkles",
              title: AppCopy.text("home.whats_new"),
              detail: nil
            )
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("drawer-whats-new")
        }

        if !store.drawerSessions.pinned.isEmpty {
          sectionHeader(AppCopy.text("home.pinned"))
          ForEach(store.drawerSessions.pinned, id: \.id) { session in
            row(session)
          }
        }

        if !store.drawerSessions.recents.isEmpty {
          sectionHeader(AppCopy.text("home.recents"))
          ForEach(store.drawerSessions.recents, id: \.id) { session in
            row(session)
          }
        }

        if store.drawerSessions.pinned.isEmpty, store.drawerSessions.recents.isEmpty {
          Text(
            store.searchText.isEmpty
              ? AppCopy.text("home.no_sessions")
              : AppCopy.text("home.no_matches")
          )
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, OpenCodeSpacing.s24)
          .accessibilityIdentifier("drawer-empty")
        }

        footer
      }
      .padding(OpenCodeSpacing.s16)
    }
    #if DEBUG
    .onScrollPhaseChange { _, phase in
      frameProbe.isScrolling = phase != .idle
    }
    .overlay(alignment: .topLeading) {
      Text(frameProbe.summary)
        .font(.caption2)
        .foregroundStyle(.clear)
        .frame(width: 1, height: 1)
        .accessibilityIdentifier("scroll-frame-probe")
    }
    #endif
    .navigationTitle(AppCopy.text("home.sessions"))
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Menu {
          Button(AppCopy.text("home.mark_all_read")) {
            store.send(.markAllReadTapped)
          }
          .disabled(!store.canMarkAllRead)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(AppCopy.text("home.sessions"))
        .accessibilityIdentifier("drawer-more")
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          store.send(.drawerDismissed)
          openSettings()
        } label: {
          Image(systemName: "gearshape")
        }
        .accessibilityLabel(AppCopy.text("settings.title"))
        .accessibilityIdentifier("drawer-settings")
        Button(AppCopy.text("common.done")) {
          store.send(.drawerDismissed)
        }
        .accessibilityIdentifier("drawer-done")
      }
    }
    .navigationDestination(isPresented: whatsNewPresented) {
      WhatsNewView(store: store)
    }
    #if DEBUG
    .onDisappear {
      frameProbe.invalidate()
    }
    #endif
  }

  private var catchUpPresented: Binding<Bool> {
    Binding(
      get: { store.catchUp != nil },
      set: { isPresented in
        if !isPresented { store.send(.catchUpExitTapped) }
      }
    )
  }

  private var searchField: some View {
    HStack(spacing: OpenCodeSpacing.s8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(OpenCodeColors.color(.textWeak))
      TextField(
        AppCopy.text("home.search"),
        text: Binding(
          get: { store.searchText },
          set: { store.send(.searchChanged($0)) }
        )
      )
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .submitLabel(.search)
      .accessibilityIdentifier("drawer-search")
      if !store.searchText.isEmpty {
        Button {
          store.send(.searchChanged(""))
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppCopy.text("home.clear_search"))
      }
    }
    .padding(OpenCodeSpacing.s12)
    .background(OpenCodeColors.color(.surfaceStrong), in: .rect(cornerRadius: OpenCodeRadius.control))
    .overlay {
      RoundedRectangle(cornerRadius: OpenCodeRadius.control)
        .strokeBorder(OpenCodeColors.color(.border), lineWidth: 0.5)
    }
    .padding(.bottom, OpenCodeSpacing.s8)
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(OpenCodeFonts.font(.footnote))
      .foregroundStyle(OpenCodeColors.color(.textWeak))
      .textCase(.uppercase)
      .padding(.top, OpenCodeSpacing.s12)
      .padding(.bottom, OpenCodeSpacing.s2)
  }

  private func row(_ session: OpenCodeSession) -> some View {
    HomeSessionRow(
      session: session,
      project: projectName(for: session),
      indicator: store.state.indicator(session),
      isPinned: store.state.isPinned(session.id),
      identifier: "drawer-session-row-\(session.id)",
      open: { store.send(.sessionTapped(session.id)) },
      pin: { store.send(.pinToggled(session.id)) },
      markRead: { store.send(.markReadTapped(session.id)) },
      markUnread: { store.send(.markUnreadTapped(session.id)) },
      delete: { store.send(.deleteTapped(session.id)) }
    )
  }

  private func projectName(for session: OpenCodeSession) -> String {
    store.projects.first { $0.id == session.projectID }?.name ?? ""
  }

  private var catchUpDetail: String? {
    let count = store.catchUpSessions.count
    guard count > 0 else { return nil }
    return AppCopy.format("home.catch_up_count", count)
  }

  @ViewBuilder
  private var footer: some View {
    if store.searchText.isEmpty {
      if store.page.failed {
        Button(AppCopy.text("common.try_again")) {
          store.send(.loadMoreTapped)
        }
        .font(OpenCodeFonts.font(.footnote))
        .accessibilityIdentifier("drawer-load-more-retry")
      } else if store.page.canLoad {
        Button {
          store.send(.loadMoreTapped)
        } label: {
          ProgressView()
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppCopy.text("home.load_more"))
        .accessibilityIdentifier("drawer-load-more")
        .onAppear {
          store.send(.loadMoreTapped)
        }
      }
    } else if let search = store.search {
      if search.failed {
        Button(AppCopy.text("common.try_again")) {
          store.send(.loadMoreTapped)
        }
        .font(OpenCodeFonts.font(.footnote))
        .accessibilityIdentifier("drawer-search-retry")
      } else if search.canLoad {
        Button {
          store.send(.loadMoreTapped)
        } label: {
          ProgressView()
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppCopy.text("home.load_more"))
        .accessibilityIdentifier("drawer-search-more")
        .onAppear {
          store.send(.loadMoreTapped)
        }
      }
    }
  }

  private var whatsNewPresented: Binding<Bool> {
    Binding(
      get: { store.whatsNew.isPresented },
      set: { isPresented in
        if !isPresented { store.send(.whatsNewDismissed) }
      }
    )
  }
}

// MARK: - Rows

struct HomeSessionRow: View {
  let session: OpenCodeSession
  let project: String
  let indicator: DrawerIndicator
  let isPinned: Bool
  let identifier: String
  let open: () -> Void
  let pin: () -> Void
  let markRead: () -> Void
  let markUnread: () -> Void
  let delete: () -> Void

  var body: some View {
    Button(action: open) {
      HStack(alignment: .center, spacing: OpenCodeSpacing.s12) {
        indicatorView
        VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
          Text(session.title)
            .font(OpenCodeFonts.font(.body))
            .foregroundStyle(OpenCodeColors.color(.textStrong))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          HStack(spacing: OpenCodeSpacing.s6) {
            if !project.isEmpty {
              Text(project)
                .font(OpenCodeFonts.font(.caption))
                .foregroundStyle(OpenCodeColors.color(.textWeak))
                .lineLimit(1)
            }
            Text(session.updatedAt, style: .relative)
              .font(OpenCodeFonts.font(.caption))
              .foregroundStyle(OpenCodeColors.color(.textTertiary))
          }
        }
        Spacer(minLength: 0)
        if isPinned {
          Image(systemName: "pin.fill")
            .font(.caption)
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        }
      }
      .padding(.vertical, OpenCodeSpacing.s10)
      .padding(.horizontal, OpenCodeSpacing.s8)
      .frame(minHeight: 48)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(identifier)
    .contextMenu {
      Button(isPinned ? AppCopy.text("home.unpin") : AppCopy.text("home.pin"), action: pin)
      Button(AppCopy.text("home.mark_read_action"), action: markRead)
      Button(AppCopy.text("home.mark_unread_action"), action: markUnread)
      Button(AppCopy.text("home.delete.action"), role: .destructive, action: delete)
    }
  }

  private var indicatorView: some View {
    Group {
      switch indicator {
      case .attention:
        Circle()
          .fill(OpenCodeColors.color(.warning))
          .frame(width: 8, height: 8)
      case .running:
        Circle()
          .strokeBorder(OpenCodeColors.color(.accent), lineWidth: 2)
          .frame(width: 8, height: 8)
      case .unread:
        Circle()
          .fill(OpenCodeColors.color(.accent))
          .frame(width: 8, height: 8)
      case .none:
        Color.clear.frame(width: 8, height: 8)
      }
    }
    .frame(width: 12, height: 16)
  }

  private var accessibilityLabel: String {
    var parts = [session.title]
    if !project.isEmpty { parts.append(project) }
    switch indicator {
    case .attention: parts.append(AppCopy.text("home.needs_attention"))
    case .running: parts.append(AppCopy.text("home.running"))
    case .unread: parts.append(AppCopy.text("home.unread"))
    case .none: break
    }
    if isPinned { parts.append(AppCopy.text("home.pinned_label")) }
    return parts.joined(separator: ", ")
  }
}

private struct ProjectRow: View {
  let project: ServerProject
  let newSession: () -> Void

  var body: some View {
    Button(action: newSession) {
    HStack(spacing: OpenCodeSpacing.s12) {
      Text(project.initial)
        .font(OpenCodeFonts.font(.headline))
        .foregroundStyle(OpenCodeColors.color(.textBody))
        .frame(width: 32, height: 32)
        .background(OpenCodeColors.color(.codeBand), in: .rect(cornerRadius: OpenCodeRadius.sm))
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
        Text(project.name)
          .font(OpenCodeFonts.font(.body))
          .foregroundStyle(OpenCodeColors.color(.textStrong))
        Text(project.directory)
          .font(OpenCodeFonts.font(.codeSmall))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Image(systemName: "square.and.pencil")
        .font(.footnote)
        .foregroundStyle(OpenCodeColors.color(.textWeak))
    }
    .contentShape(Rectangle())
    .padding(.vertical, OpenCodeSpacing.s4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(project.name)
    .accessibilityHint(AppCopy.text("composer.new_session_hint"))
    .accessibilityIdentifier("home-project-\(project.id)")
    }
    .buttonStyle(.plain)
  }
}

private struct DrawerActionRow: View {
  let icon: String
  let title: String
  let detail: String?

  var body: some View {
    HStack(spacing: OpenCodeSpacing.s12) {
      Image(systemName: icon)
        .foregroundStyle(OpenCodeColors.color(.accent))
        .frame(width: 24)
      Text(title)
        .font(OpenCodeFonts.font(.body))
        .foregroundStyle(OpenCodeColors.color(.textStrong))
      Spacer(minLength: 0)
      if let detail {
        Text(detail)
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      }
      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(OpenCodeColors.color(.textTertiary))
    }
    .padding(.vertical, OpenCodeSpacing.s12)
    .frame(minHeight: 48)
    .contentShape(Rectangle())
  }
}

// MARK: - Catch Up

private struct CatchUpView: View {
  let store: StoreOf<HomeFeature>

  var body: some View {
    Group {
      if let card = store.catchUpCard {
        cardView(card)
      } else {
        caughtUpView
      }
    }
    .navigationTitle(AppCopy.text("home.catch_up"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button(AppCopy.text("common.done")) {
          store.send(.catchUpExitTapped)
        }
        .accessibilityIdentifier("catch-up-done")
      }
      ToolbarItem(placement: .topBarTrailing) {
        if store.catchUp?.lastUndo != nil {
          Button(AppCopy.text("home.undo")) {
            store.send(.catchUpUndoTapped)
          }
          .accessibilityIdentifier("catch-up-undo")
        }
      }
    }
    .accessibilityIdentifier("catch-up")
  }

  private func cardView(_ session: OpenCodeSession) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s20) {
        Text(AppCopy.text("home.catch_up_hint"))
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textWeak))

        VStack(alignment: .leading, spacing: OpenCodeSpacing.s12) {
          statusLabel(session)
          Text(session.title)
            .font(OpenCodeFonts.font(.title2))
            .foregroundStyle(OpenCodeColors.color(.textStrong))
          HStack(spacing: OpenCodeSpacing.s8) {
            if let project = store.projects.first(where: { $0.id == session.projectID }) {
              Text(project.name)
                .font(OpenCodeFonts.font(.footnote))
                .foregroundStyle(OpenCodeColors.color(.textWeak))
            }
            Text(session.updatedAt, style: .relative)
              .font(OpenCodeFonts.font(.footnote))
              .foregroundStyle(OpenCodeColors.color(.textTertiary))
          }
        }
        .padding(OpenCodeSpacing.s24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenCodeColors.color(.surfaceStrong), in: .rect(cornerRadius: OpenCodeRadius.card))
        .overlay {
          RoundedRectangle(cornerRadius: OpenCodeRadius.card)
            .strokeBorder(OpenCodeColors.color(.border), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("catch-up-card")
        .gesture(
          DragGesture(minimumDistance: 40)
            .onEnded { value in
              if value.translation.width < -80 {
                store.send(.catchUpCardDismissed(sessionID: session.id, disposition: .markRead))
              } else if value.translation.width > 80 {
                store.send(.catchUpCardDismissed(sessionID: session.id, disposition: .keepUnread))
              }
            }
        )

        if let problem = store.catchUp?.problem {
          Text(AppCopy.format("home.catch_up_error", problem))
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.danger))
            .accessibilityIdentifier("catch-up-error")
        }

        VStack(spacing: OpenCodeSpacing.s12) {
          Button {
            store.send(.catchUpCardDismissed(sessionID: session.id, disposition: .markRead))
          } label: {
            actionLabel(AppCopy.text("home.mark_read"), foreground: OpenCodeColors.color(.canvas), background: OpenCodeColors.color(.accent))
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("catch-up-mark-read")

          Button {
            store.send(.catchUpCardDismissed(sessionID: session.id, disposition: .keepUnread))
          } label: {
            actionLabel(AppCopy.text("home.keep_unread"), foreground: OpenCodeColors.color(.textBody), background: OpenCodeColors.color(.surfaceStrong))
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("catch-up-keep-unread")

          Button {
            store.send(.catchUpOpenTapped)
          } label: {
            actionLabel(AppCopy.text("home.open"), foreground: OpenCodeColors.color(.textBody), background: OpenCodeColors.color(.canvasWeak))
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("catch-up-open")
        }
      }
      .padding(OpenCodeSpacing.s24)
    }
  }

  private var caughtUpView: some View {
    VStack(spacing: OpenCodeSpacing.s16) {
      Image(systemName: "checkmark.circle")
        .font(.system(size: 44, weight: .regular))
        .foregroundStyle(OpenCodeColors.color(.success))
      Text(AppCopy.text("home.all_caught_up"))
        .font(OpenCodeFonts.font(.title3))
        .foregroundStyle(OpenCodeColors.color(.textStrong))
      Text(AppCopy.text("home.all_caught_up_detail"))
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.textWeak))
        .multilineTextAlignment(.center)
    }
    .padding(OpenCodeSpacing.s32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("catch-up-empty")
  }

  private func statusLabel(_ session: OpenCodeSession) -> some View {
    let text: String
    let color: Color
    switch store.state.indicator(session) {
    case .attention:
      text = AppCopy.text("home.needs_attention")
      color = OpenCodeColors.color(.warning)
    case .running:
      text = AppCopy.text("home.running")
      color = OpenCodeColors.color(.accent)
    default:
      text = AppCopy.text("home.unread")
      color = OpenCodeColors.color(.accent)
    }
    return Text(text)
      .font(OpenCodeFonts.font(.caption))
      .foregroundStyle(color)
      .textCase(.uppercase)
  }

  private func actionLabel(_ title: String, foreground: Color, background: Color) -> some View {
    Text(title)
      .font(OpenCodeFonts.font(.headline))
      .foregroundStyle(foreground)
      .padding(.vertical, OpenCodeSpacing.s14)
      .frame(maxWidth: .infinity)
      .background(background, in: .rect(cornerRadius: OpenCodeRadius.control))
      .overlay {
        RoundedRectangle(cornerRadius: OpenCodeRadius.control)
          .strokeBorder(OpenCodeColors.color(.border), lineWidth: 0.5)
      }
      .frame(minHeight: 48)
  }
}

// MARK: - What's New

private struct WhatsNewView: View {
  let store: StoreOf<HomeFeature>

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: OpenCodeSpacing.s16) {
        Text(AppCopy.text("whats_new.intro"))
          .font(OpenCodeFonts.font(.body))
          .foregroundStyle(OpenCodeColors.color(.textBody))
        ForEach(store.whatsNewEntries) { entry in
          WhatsNewCard(entry: entry) {
            if let destination = entry.destination {
              store.send(.whatsNewTryTapped(destination))
            }
          }
        }
      }
      .padding(OpenCodeSpacing.s24)
    }
    .navigationTitle(AppCopy.text("home.whats_new"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(AppCopy.text("common.done")) {
          store.send(.whatsNewDismissed)
        }
        .accessibilityIdentifier("whats-new-done")
      }
    }
    .onAppear {
      store.send(.whatsNewViewed)
    }
    .accessibilityIdentifier("whats-new-list")
  }
}

private struct WhatsNewCard: View {
  let entry: WhatsNewEntry
  let tryIt: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s6) {
      HStack(spacing: OpenCodeSpacing.s8) {
        Image(systemName: entry.symbol)
          .foregroundStyle(tint)
        Text(entry.title)
          .font(OpenCodeFonts.font(.headline))
          .foregroundStyle(OpenCodeColors.color(.textStrong))
        Spacer(minLength: 0)
        Text(entry.day)
          .font(OpenCodeFonts.font(.caption2))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      }
      Text(entry.summary)
        .font(OpenCodeFonts.font(.body))
        .foregroundStyle(OpenCodeColors.color(.textBody))
      ForEach(entry.details, id: \.self) { detail in
        Text(detail)
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textBody))
      }
      if let example = entry.example {
        Text(example)
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      }
      if let destination = entry.destination {
        switch destination {
        case .unavailable:
          Text(AppCopy.text("whats_new.try_unavailable"))
            .font(OpenCodeFonts.font(.caption))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        default:
          Button(AppCopy.text("whats_new.try")) { tryIt() }
            .font(OpenCodeFonts.font(.footnote))
            .buttonStyle(.bordered)
            .accessibilityIdentifier("whats-new-try-\(entry.id)")
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(OpenCodeSpacing.s16)
    .background(OpenCodeColors.color(.surfaceStrong), in: .rect(cornerRadius: OpenCodeRadius.card))
    .overlay {
      RoundedRectangle(cornerRadius: OpenCodeRadius.card)
        .strokeBorder(OpenCodeColors.color(.border), lineWidth: 0.5)
    }
    .accessibilityIdentifier("whats-new-entry-\(entry.id)")
  }

  private var tint: Color {
    switch entry.tint {
    case "red": OpenCodeColors.color(.danger)
    case "orange", "brown": OpenCodeColors.color(.warning)
    case "green", "mint", "teal": OpenCodeColors.color(.success)
    case "gray": OpenCodeColors.color(.textWeak)
    default: OpenCodeColors.color(.accent)
    }
  }
}

// MARK: - Server switcher

private struct ServerSwitcherView: View {
  let savedServers: [OpenCodeServer]
  let current: OpenCodeServer
  let select: (OpenCodeServer) -> Void
  let disconnect: () -> Void
  let dismiss: () -> Void

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(savedServers, id: \.persistenceID) { server in
            Button {
              select(server)
            } label: {
              HStack(spacing: OpenCodeSpacing.s12) {
                VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
                  Text(server.displayName)
                    .font(OpenCodeFonts.font(.body))
                    .foregroundStyle(OpenCodeColors.color(.textStrong))
                  Text(server.host)
                    .font(OpenCodeFonts.font(.footnote))
                    .foregroundStyle(OpenCodeColors.color(.textWeak))
                }
                Spacer(minLength: 0)
                if server.persistenceID == current.persistenceID {
                  Image(systemName: "checkmark")
                    .foregroundStyle(OpenCodeColors.color(.success))
                }
              }
              .frame(minHeight: 48)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("server-switch-\(server.displayName)")
          }
        } header: {
          Text(AppCopy.text("home.server_switcher.saved"))
        }
        Section {
          Button(AppCopy.text("connection.connected.disconnect"), role: .destructive, action: disconnect)
            .accessibilityIdentifier("server-switcher-disconnect")
        }
      }
      .navigationTitle(AppCopy.text("home.server_switcher.title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppCopy.text("common.cancel"), action: dismiss)
        }
      }
    }
    .accessibilityIdentifier("server-switcher")
  }
}

// MARK: - Notice

private struct HomeNoticeView: View {
  let notice: HomeNotice
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: OpenCodeSpacing.s8) {
      Text(noticeText(notice))
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.warning))
      Spacer(minLength: 0)
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.caption)
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(AppCopy.text("common.dismiss"))
    }
    .padding(OpenCodeSpacing.s12)
    .background(OpenCodeColors.color(.surfaceStrong), in: .rect(cornerRadius: OpenCodeRadius.control))
    .accessibilityIdentifier("home-notice")
  }
}

private func noticeText(_ notice: HomeNotice) -> String {
  switch notice {
  case .couldNotRefresh:
    return AppCopy.text("home.refresh_failed")
  case .couldNotReadSnapshot:
    return AppCopy.text("home.snapshot_unreadable")
  case .couldNotSaveSnapshot:
    return AppCopy.text("home.snapshot_save_failed")
  case .couldNotDelete(let title):
    return AppCopy.format("home.delete_failed", title)
  case .couldNotVerifyDeletion(let title):
    return AppCopy.format("home.delete_unverified", title)
  case .couldNotMarkRead(let title):
    return AppCopy.format("home.mark_read_failed", title)
  case .couldNotLoadSearch:
    return AppCopy.text("home.search_failed")
  case .couldNotLoadOlder:
    return AppCopy.text("home.older_failed")
  }
}
