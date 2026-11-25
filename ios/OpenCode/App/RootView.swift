import ComposableArchitecture
import OpenCodeApp
import OpenCodeCore
import OpenCodeDrawer
import OpenCodeServer
import OpenCodeSession
import OpenCodeSettings
import SwiftUI
#if canImport(UIKit)
  import UIKit
#endif

enum AppCopy {
  static func text(_ key: String) -> String {
    String(localized: String.LocalizationValue(key))
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), arguments: arguments)
  }

  static func count(_ key: String, _ value: Int) -> String {
    format("\(key).\(value == 1 ? "one" : "other")", value)
  }
}

struct RootView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    ZStack(alignment: .top) {
      OpenCodeColors.color(.canvas)
        .ignoresSafeArea()

      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
          VStack(spacing: 0) {
            if let problem = store.pairingProblem, store.connection != nil {
              PairingProblemBanner(problem: problem) { store.send(.pairingProblemDismissed) }
            }
            if store.connection != nil, store.savedData.isUnreadable {
              SavedDataWarningBanner(
                retry: { store.send(.restoreRetried) },
                replace: { store.send(.replaceSavedDataTapped) }
              )
            }
            if let notice = store.notice {
              NoticeBanner(notice: notice) { store.send(.noticeDismissed) }
            }
          }
        }
    }
    .sheet(isPresented: formPresented) {
      if let form = store.form {
        ServerFormView(
          form: form,
          nameChanged: { store.send(.formNameChanged($0)) },
          addressChanged: { store.send(.formAddressChanged($0)) },
          usernameChanged: { store.send(.formUsernameChanged($0)) },
          passwordChanged: { store.send(.formPasswordChanged($0)) },
          submit: { store.send(.formSubmitted) },
          dismiss: { store.send(.formDismissed) }
        )
      }
    }
    .alert(
      Text(pairingTitle),
      isPresented: pairingPresented,
      presenting: store.pendingPairing
    ) { _ in
      Button(AppCopy.text("common.pair")) {
        if let id = store.pendingPairing?.id { store.send(.pairingConfirmed(id)) }
      }
      Button(AppCopy.text("common.cancel"), role: .cancel) { store.send(.pairingCancelled) }
    } message: { pending in
      Text(pairingMessage(pending))
    }
    .alert(
      Text(AppCopy.text("saved_data.confirm.title")),
      isPresented: replaceConfirmationPresented
    ) {
      Button(AppCopy.text("saved_data.confirm.action"), role: .destructive) {
        store.send(.replaceSavedDataConfirmed)
      }
      Button(AppCopy.text("common.cancel"), role: .cancel) {
        store.send(.replaceSavedDataCancelled)
      }
    } message: {
      Text(AppCopy.text("saved_data.confirm.message"))
    }
    .fullScreenCover(isPresented: sessionDestinationPresented) {
      if let sessionStore = store.scope(state: \.session, action: \.session) {
        SessionView(store: sessionStore)
      }
    }
    .fullScreenCover(isPresented: settingsPresented, onDismiss: {
      store.send(.settingsCoverDismissed)
    }) {
      if let settingsStore = store.scope(state: \.settings, action: \.settings) {
        SettingsView(store: settingsStore)
      }
    }
    #if canImport(UIKit)
      .onReceive(
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
      ) { _ in
        store.send(.memoryWarning)
      }
    #endif
  }

  @ViewBuilder
  private var content: some View {
    if store.pairingAttempt != nil {
      LoadingView(
        identifier: "root-phase-pairing",
        label: AppCopy.text("connection.phase.pairing"),
        detail: nil,
        projects: []
      )
    } else if let problem = store.pairingProblem, store.connection == nil {
      PairingFailureView(problem: problem) {
        store.send(.pairingProblemDismissed)
        store.send(.manualEntryTapped)
      }
    } else if let connectionStore = store.scope(state: \.connection, action: \.connection),
      connectionStore.phase == .connected,
      let homeStore = store.scope(state: \.home, action: \.home)
    {
      HomeView(
        store: homeStore,
        savedServers: store.savedServers,
        disconnect: { store.send(.disconnectTapped) },
        openSettings: { store.send(.settingsOpened) }
      )
    } else if let connectionStore = store.scope(state: \.connection, action: \.connection) {
      ConnectionView(
        store: connectionStore,
        edit: { store.send(.manualEntryTapped) },
        disconnect: { store.send(.disconnectTapped) }
      )
    } else if case .storageUnavailable(let failure) = store.restore {
      StorageFailureView(failure: failure) {
        store.send(.restoreRetried)
      } enterManually: {
        store.send(.manualEntryTapped)
      }
    } else if store.restore == .corruptSavedServers {
      CorruptStorageView(
        forget: { store.send(.forgetSavedServersTapped) },
        enterManually: { store.send(.manualEntryTapped) }
      )
    } else {
      DisconnectedView(
        savedServers: store.savedServers,
        savedServer: store.savedServer,
        pasteProblem: store.pasteProblem,
        select: { store.send(.savedServerTapped($0)) },
        enterManually: { store.send(.manualEntryTapped) },
        paste: { store.send(.pastePairingTapped) }
      )
    }
  }

  private var settingsPresented: Binding<Bool> {
    Binding(
      get: { store.settings != nil },
      set: {
        if !$0, store.settings != nil { store.send(.settings(.delegate(.close))) }
      }
    )
  }

  private var formPresented: Binding<Bool> {
    Binding(
      get: { store.form != nil },
      set: { if !$0 { store.send(.formDismissed) } }
    )
  }

  private var pairingPresented: Binding<Bool> {
    Binding(
      get: { store.pendingPairing != nil },
      set: { if !$0 { store.send(.pairingCancelled) } }
    )
  }

  private var pairingTitle: String {
    AppCopy.format("pairing.confirm.title", store.pendingPairing?.hosts.first ?? "")
  }

  private var replaceConfirmationPresented: Binding<Bool> {
    Binding(
      get: { store.showsReplaceSavedDataConfirmation },
      set: { if !$0 { store.send(.replaceSavedDataCancelled) } }
    )
  }

  private func projectName(for selection: SessionSelection?) -> String? {
    guard let selection,
      let session = store.home?.session(selection.sessionID),
      let project = store.home?.projects.first(where: { $0.id == session.projectID })
    else { return nil }
    return project.name
  }

  private var sessionDestinationPresented: Binding<Bool> {
    Binding(
      get: { store.session != nil },
      set: { isPresented in
        if !isPresented { store.send(.sessionDestinationDismissed) }
      }
    )
  }

  private func pairingMessage(_ pending: PairingConfirmation) -> String {
    let hosts = pending.hosts
    let action: String
    if hosts.count <= 1 {
      action = AppCopy.format("pairing.confirm.message_one", hosts.first ?? "")
    } else {
      action = AppCopy.format("pairing.confirm.message_many", hosts.joined(separator: ", "))
    }
    guard !pending.replacedServerNames.isEmpty else { return action }
    return AppCopy.format(
      "pairing.confirm.replaces",
      action,
      pending.replacedServerNames.joined(separator: ", ")
    )
  }
}

// MARK: - Disconnected

private struct DisconnectedView: View {
  let savedServers: [OpenCodeServer]
  let savedServer: OpenCodeServer?
  let pasteProblem: PairingProblem?
  let select: (OpenCodeServer) -> Void
  let enterManually: () -> Void
  let paste: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s16) {
        Text(AppCopy.text("app.name"))
          .font(OpenCodeFonts.font(.largeTitle))
          .foregroundStyle(OpenCodeColors.color(.textStrong))

        Text(AppCopy.text("connection.disconnected.intro"))
          .font(OpenCodeFonts.font(.body))
          .foregroundStyle(OpenCodeColors.color(.textBody))

        if savedServers.isEmpty {
          Text(AppCopy.text("connection.disconnected.no_saved"))
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        } else {
          Text(AppCopy.text("connection.disconnected.returning"))
            .font(OpenCodeFonts.font(.body))
            .foregroundStyle(OpenCodeColors.color(.textBody))
          Text(AppCopy.text("connection.disconnected.saved"))
            .font(OpenCodeFonts.font(.headline))
            .foregroundStyle(OpenCodeColors.color(.textStrong))
            .padding(.top, OpenCodeSpacing.s8)
          ForEach(savedServers, id: \.persistenceID) { server in
            SavedServerRow(server: server, isLastUsed: server.persistenceID == savedServer?.persistenceID) {
              select(server)
            }
          }
        }

        VStack(spacing: OpenCodeSpacing.s12) {
          PrimaryButton(title: AppCopy.text("connection.disconnected.enter_manually"), action: enterManually)
            .accessibilityIdentifier("connection-enter-manually")
          SecondaryButton(title: AppCopy.text("connection.disconnected.paste"), action: paste)
            .accessibilityIdentifier("connection-paste")
        }
        .padding(.top, OpenCodeSpacing.s8)

        if let pasteProblem {
          Text(pairingProblemText(pasteProblem))
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.danger))
            .accessibilityIdentifier("connection-paste-error")
        }

        Text(AppCopy.text("connection.disconnected.paste_hint"))
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      }
      .padding(OpenCodeSpacing.s24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("root-phase-disconnected")
  }
}

private struct SavedServerRow: View {
  let server: OpenCodeServer
  let isLastUsed: Bool
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      HStack(spacing: OpenCodeSpacing.s12) {
        Image(systemName: "server.rack")
          .foregroundStyle(OpenCodeColors.color(.textWeak))
        VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
          Text(server.displayName)
            .font(OpenCodeFonts.font(.body))
            .foregroundStyle(OpenCodeColors.color(.textStrong))
          Text(server.host)
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        }
        Spacer()
        if isLastUsed {
          Text(AppCopy.text("connection.disconnected.last_used"))
            .font(OpenCodeFonts.font(.caption))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        }
      }
      .padding(OpenCodeSpacing.s12)
      .background(OpenCodeColors.color(.surfaceStrong), in: .rect(cornerRadius: OpenCodeRadius.card))
      .overlay {
        RoundedRectangle(cornerRadius: OpenCodeRadius.card)
          .strokeBorder(OpenCodeColors.color(.border), lineWidth: 0.5)
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("saved-server-\(server.persistenceID)")
  }
}

// MARK: - Form

private struct ServerFormView: View {
  let form: ServerForm
  let nameChanged: @MainActor @Sendable (String) -> Void
  let addressChanged: @MainActor @Sendable (String) -> Void
  let usernameChanged: @MainActor @Sendable (String) -> Void
  let passwordChanged: @MainActor @Sendable (String) -> Void
  let submit: () -> Void
  let dismiss: () -> Void

  @State private var showsPassword = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(
            AppCopy.text("form.name"),
            text: Binding(get: { form.name }, set: nameChanged),
            prompt: Text(AppCopy.text("form.name_placeholder"))
          )
            .textContentType(.name)
            .accessibilityIdentifier("server-form-name")
          TextField(AppCopy.text("form.address"), text: Binding(get: { form.address }, set: addressChanged))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .accessibilityIdentifier("server-form-address")
          TextField(AppCopy.text("form.username"), text: Binding(get: { form.username }, set: usernameChanged))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("server-form-username")
          HStack {
            if showsPassword {
              TextField(AppCopy.text("form.password"), text: Binding(get: { form.password }, set: passwordChanged))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } else {
              SecureField(AppCopy.text("form.password"), text: Binding(get: { form.password }, set: passwordChanged))
            }
            Button {
              showsPassword.toggle()
            } label: {
              Image(systemName: showsPassword ? "eye.slash" : "eye")
                .foregroundStyle(OpenCodeColors.color(.textWeak))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
              showsPassword
                ? AppCopy.text("form.hide_password")
                : AppCopy.text("form.show_password")
            )
          }
          .accessibilityIdentifier("server-form-password")
        } footer: {
          Text(AppCopy.text("form.hint"))
        }

        if let problem = form.problem {
          Section {
            Text(formProblemText(problem))
              .foregroundStyle(OpenCodeColors.color(.danger))
              .accessibilityIdentifier("server-form-error")
          }
        }

        Section {
          Button(action: submit) {
            HStack {
              Text(AppCopy.text("form.connect"))
              Spacer()
              Image(systemName: "arrow.right")
            }
            .font(OpenCodeFonts.font(.headline))
          }
          .accessibilityIdentifier("server-form-connect")
        }
      }
      .navigationTitle(
        AppCopy.text(form.isEditingSaved ? "form.title.edit" : "form.title.new")
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppCopy.text("common.cancel"), action: dismiss)
        }
      }
    }
    .accessibilityIdentifier("server-form")
  }
}

// MARK: - Connection states

private struct ConnectionView: View {
  let store: StoreOf<ConnectionFeature>
  let edit: () -> Void
  let disconnect: () -> Void

  var body: some View {
    let phase = store.phase
    let projects = store.projects
    let server = store.server
    let info = store.info
    let failure = store.failure
    let isOffline = store.isOffline
    let state = ConnectionFeature.State(
      id: store.id,
      server: server,
      phase: phase,
      info: info,
      projects: projects,
      failure: failure,
      isOffline: isOffline
    )

    switch phase {
    case .connected:
      ConnectedView(state: state, disconnect: disconnect)
    case .connecting:
      LoadingView(
        identifier: "root-phase-loading",
        label: AppCopy.text("connection.phase.connecting"),
        detail: server.displayName,
        projects: projects
      )
    case .loading:
      LoadingView(
        identifier: "root-phase-loading",
        label: AppCopy.text("connection.phase.loading"),
        detail: server.displayName,
        projects: projects
      )
    case .reconnecting:
      ReconnectingView(state: state, retry: { store.send(.retryTapped) }, disconnect: disconnect)
    case .failed:
      FailureView(
        failure: failure ?? .unknown,
        isOffline: isOffline,
        retry: { store.send(.retryTapped) },
        edit: edit,
        disconnect: disconnect
      )
    }
  }
}

private struct ConnectedView: View {
  let state: ConnectionFeature.State
  let disconnect: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s16) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: OpenCodeSpacing.s4) {
            Text(state.server.displayName)
              .font(OpenCodeFonts.font(.title2))
              .foregroundStyle(OpenCodeColors.color(.textStrong))
            Text(AppCopy.text("connection.connected.title"))
              .font(OpenCodeFonts.font(.footnote))
              .foregroundStyle(OpenCodeColors.color(.success))
          }
          Spacer()
        }

        if let version = state.info?.version {
          Text(version)
            .font(OpenCodeFonts.font(.codeSmall))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        }

        ProjectList(projects: state.projects)

        Text(AppCopy.text("connection.connected.later"))
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textWeak))

        SecondaryButton(title: AppCopy.text("connection.connected.disconnect"), action: disconnect)
          .padding(.top, OpenCodeSpacing.s8)
      }
      .padding(OpenCodeSpacing.s24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("root-phase-connected")
  }
}

private struct ReconnectingView: View {
  let state: ConnectionFeature.State
  let retry: () -> Void
  let disconnect: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s16) {
        HStack(spacing: OpenCodeSpacing.s12) {
          ProgressView()
          VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
            Text(state.server.displayName)
              .font(OpenCodeFonts.font(.title3))
              .foregroundStyle(OpenCodeColors.color(.textStrong))
            Text(
              state.isOffline
                ? AppCopy.text("connection.reconnecting.offline")
                : AppCopy.text("connection.phase.reconnecting")
            )
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.textBody))
          }
        }

        if !state.projects.isEmpty {
          Text(AppCopy.text("connection.reconnecting.cached"))
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
          ProjectList(projects: state.projects)
        }

        HStack(spacing: OpenCodeSpacing.s12) {
          PrimaryButton(title: AppCopy.text("common.try_again"), action: retry)
          SecondaryButton(title: AppCopy.text("connection.connected.disconnect"), action: disconnect)
        }
      }
      .padding(OpenCodeSpacing.s24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("root-phase-reconnecting")
  }
}

private struct LoadingView: View {
  let identifier: String
  let label: String
  let detail: String?
  let projects: [ServerProject]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s16) {
        HStack(spacing: OpenCodeSpacing.s12) {
          ProgressView()
          VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
            Text(label)
              .font(OpenCodeFonts.font(.body))
              .foregroundStyle(OpenCodeColors.color(.textStrong))
            if let detail {
              Text(detail)
                .font(OpenCodeFonts.font(.footnote))
                .foregroundStyle(OpenCodeColors.color(.textWeak))
            }
          }
        }
        if !projects.isEmpty {
          ProjectList(projects: projects)
        }
      }
      .padding(OpenCodeSpacing.s24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }
}

private struct ProjectList: View {
  let projects: [ServerProject]

  var body: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s8) {
      Text(AppCopy.text("connection.connected.projects"))
        .font(OpenCodeFonts.font(.headline))
        .foregroundStyle(OpenCodeColors.color(.textStrong))
      if projects.isEmpty {
        Text(AppCopy.text("connection.connected.no_projects"))
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      } else {
        ForEach(projects, id: \.id) { project in
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
            Spacer()
          }
          .padding(.vertical, OpenCodeSpacing.s4)
        }
      }
    }
  }
}

// MARK: - Failures

private struct FailureView: View {
  let failure: ConnectionFailure
  let isOffline: Bool
  let retry: () -> Void
  let edit: () -> Void
  let disconnect: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s16) {
        Text(AppCopy.text("failure.connect.title"))
          .font(OpenCodeFonts.font(.title2))
          .foregroundStyle(OpenCodeColors.color(.textStrong))

        Text(failureText(failure, isOffline: isOffline))
          .font(OpenCodeFonts.font(.body))
          .foregroundStyle(OpenCodeColors.color(.textBody))

        if showsLocalNetworkHint {
          Text(AppCopy.text("failure.local_network_hint"))
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        }

        VStack(spacing: OpenCodeSpacing.s12) {
          if needsEditFirst {
            PrimaryButton(title: AppCopy.text("failure.edit_server"), action: edit)
            SecondaryButton(title: AppCopy.text("common.try_again"), action: retry)
          } else {
            PrimaryButton(title: AppCopy.text("common.try_again"), action: retry)
            SecondaryButton(title: AppCopy.text("failure.edit_server"), action: edit)
          }
          SecondaryButton(title: AppCopy.text("connection.connected.disconnect"), action: disconnect)
        }
        .padding(.top, OpenCodeSpacing.s8)
      }
      .padding(OpenCodeSpacing.s24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("root-phase-failed")
  }

  private var needsEditFirst: Bool {
    switch failure {
    case .credentialsRejected, .incompatibleAPI, .malformed, .invalidAddress:
      return true
    default:
      return false
    }
  }

  private var showsLocalNetworkHint: Bool {
    switch failure {
    case .unreachable, .offline, .timedOut:
      return true
    default:
      return false
    }
  }
}

private struct StorageFailureView: View {
  let failure: StorageFailure
  let retry: () -> Void
  let enterManually: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s16) {
        Text(AppCopy.text("failure.storage.title"))
          .font(OpenCodeFonts.font(.title2))
          .foregroundStyle(OpenCodeColors.color(.textStrong))
        Text(storageFailureText(failure))
          .font(OpenCodeFonts.font(.body))
          .foregroundStyle(OpenCodeColors.color(.textBody))
        PrimaryButton(title: AppCopy.text("common.try_again"), action: retry)
          .padding(.top, OpenCodeSpacing.s8)
        SecondaryButton(title: AppCopy.text("failure.enter_manually"), action: enterManually)
      }
      .padding(OpenCodeSpacing.s24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("root-phase-storage")
  }
}

private struct CorruptStorageView: View {
  let forget: () -> Void
  let enterManually: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s16) {
        Text(AppCopy.text("failure.corrupt.title"))
          .font(OpenCodeFonts.font(.title2))
          .foregroundStyle(OpenCodeColors.color(.textStrong))
        Text(AppCopy.text("failure.corrupt.body"))
          .font(OpenCodeFonts.font(.body))
          .foregroundStyle(OpenCodeColors.color(.textBody))
        PrimaryButton(title: AppCopy.text("failure.enter_manually"), action: enterManually)
          .padding(.top, OpenCodeSpacing.s8)
        Button(role: .destructive, action: forget) {
          Text(AppCopy.text("failure.forget"))
            .font(OpenCodeFonts.font(.headline))
        }
      }
      .padding(OpenCodeSpacing.s24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("root-phase-corrupt")
  }
}

private struct PairingFailureView: View {
  let problem: PairingProblem
  let enterManually: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s16) {
        Text(AppCopy.text("failure.pair.title"))
          .font(OpenCodeFonts.font(.title2))
          .foregroundStyle(OpenCodeColors.color(.textStrong))
        Text(pairingProblemText(problem))
          .font(OpenCodeFonts.font(.body))
          .foregroundStyle(OpenCodeColors.color(.textBody))
        PrimaryButton(title: AppCopy.text("failure.enter_manually"), action: enterManually)
          .padding(.top, OpenCodeSpacing.s8)
      }
      .padding(OpenCodeSpacing.s24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("root-phase-pairing-failed")
  }
}

// MARK: - Shared controls

private struct PrimaryButton: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(OpenCodeFonts.font(.headline))
        .foregroundStyle(OpenCodeColors.color(.canvas))
        .padding(.vertical, OpenCodeSpacing.s14)
        .frame(maxWidth: .infinity)
        .background(OpenCodeColors.color(.accent), in: .rect(cornerRadius: OpenCodeRadius.control))
    }
    .buttonStyle(.plain)
  }
}

private struct SecondaryButton: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(OpenCodeFonts.font(.headline))
        .foregroundStyle(OpenCodeColors.color(.textBody))
        .padding(.vertical, OpenCodeSpacing.s14)
        .frame(maxWidth: .infinity)
        .background(OpenCodeColors.color(.surfaceStrong), in: .rect(cornerRadius: OpenCodeRadius.control))
        .overlay {
          RoundedRectangle(cornerRadius: OpenCodeRadius.control)
            .strokeBorder(OpenCodeColors.color(.border), lineWidth: 0.5)
        }
    }
    .buttonStyle(.plain)
  }
}

private struct NoticeBanner: View {
  let notice: AppNotice
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: OpenCodeSpacing.s8) {
      Text(noticeText(notice))
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.textBody))
      Spacer()
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.caption)
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(AppCopy.text("common.dismiss"))
    }
    .padding(OpenCodeSpacing.s12)
    .background(OpenCodeColors.color(.surfaceStrong))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(OpenCodeColors.color(.border))
        .frame(height: 0.5)
    }
    .accessibilityIdentifier("app-notice")
  }
}

private struct SavedDataWarningBanner: View {
  let retry: () -> Void
  let replace: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s8) {
      Text(AppCopy.text("saved_data.warning"))
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.warning))
      HStack(spacing: OpenCodeSpacing.s16) {
        Button(action: retry) {
          Text(AppCopy.text("common.try_again"))
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.link))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("saved-data-retry")
        Button(action: replace) {
          Text(AppCopy.text("saved_data.replace"))
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.link))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("saved-data-replace")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(OpenCodeSpacing.s12)
    .background(OpenCodeColors.color(.surfaceStrong))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(OpenCodeColors.color(.border))
        .frame(height: 0.5)
    }
    .accessibilityIdentifier("saved-data-warning")
  }
}

private struct PairingProblemBanner: View {
  let problem: PairingProblem
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: OpenCodeSpacing.s8) {
      Text(pairingProblemText(problem))
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.danger))
      Spacer()
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.caption)
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(AppCopy.text("common.dismiss"))
    }
    .padding(OpenCodeSpacing.s12)
    .background(OpenCodeColors.color(.surfaceStrong))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(OpenCodeColors.color(.border))
        .frame(height: 0.5)
    }
    .accessibilityIdentifier("pairing-problem")
  }
}

// MARK: - Copy mapping

private func failureText(_ failure: ConnectionFailure, isOffline: Bool) -> String {
  switch failure {
  case .invalidAddress:
    return AppCopy.text("form.problem.invalid")
  case .unreachable:
    return AppCopy.text("failure.unreachable")
  case .offline:
    return AppCopy.text("failure.offline")
  case .timedOut:
    return AppCopy.text("failure.timed_out")
  case .credentialsRejected:
    return AppCopy.text("failure.credentials")
  case .incompatibleAPI:
    return AppCopy.text("failure.incompatible")
  case .malformed:
    return AppCopy.text("failure.malformed")
  case .serverStatus(let status):
    return AppCopy.format("failure.http", status)
  case .pairingExpired:
    return AppCopy.text("pairing.error.expired")
  case .pairingUnsupported:
    return AppCopy.text("pairing.error.unsupported")
  case .streamEnded:
    return AppCopy.text("failure.stream_ended")
  case .streamOverflow:
    return AppCopy.text("failure.stream_overflow")
  case .unsupported:
    return AppCopy.text("failure.unsupported")
  case .unknown:
    return isOffline ? AppCopy.text("failure.offline") : AppCopy.text("failure.unreachable")
  }
}

private func pairingProblemText(_ problem: PairingProblem) -> String {
  switch problem {
  case .emptyClipboard:
    return AppCopy.text("clipboard.empty")
  case .notPairingText:
    return AppCopy.text("pairing.error.not_a_link")
  case .invalidCode:
    return AppCopy.text("pairing.error.invalid_code")
  case .unusableAddress(let address, let reason):
    return AppCopy.format("pairing.error.unusable", address, addressReasonText(reason))
  case .loopback:
    return AppCopy.text("pairing.error.loopback")
  case .expired:
    return AppCopy.text("pairing.error.expired")
  case .unsupported:
    return AppCopy.text("pairing.error.unsupported")
  case .connection(let failure):
    return failureText(failure, isOffline: failure == .offline)
  }
}

private func addressReasonText(_ reason: PairingAddressProblem) -> String {
  switch reason {
  case .notAWebAddress: return AppCopy.text("pairing.address.not_a_web_address")
  case .badScheme: return AppCopy.text("pairing.address.bad_scheme")
  case .noHost: return AppCopy.text("pairing.address.no_host")
  case .credentials: return AppCopy.text("pairing.address.credentials")
  case .query: return AppCopy.text("pairing.address.query")
  case .port: return AppCopy.text("pairing.address.port")
  case .path: return AppCopy.text("pairing.address.path")
  }
}

private func formProblemText(_ problem: ServerFormProblem) -> String {
  switch problem {
  case .emptyAddress:
    return AppCopy.text("form.problem.empty")
  case .invalidAddress(let reason):
    switch reason {
    case .notAWebAddress:
      return AppCopy.text("form.problem.invalid")
    case .badScheme:
      return AppCopy.text("form.problem.scheme")
    case .noHost:
      return AppCopy.text("form.problem.host")
    case .credentials:
      return AppCopy.text("form.problem.credentials")
    case .query:
      return AppCopy.text("form.problem.query")
    case .port:
      return AppCopy.text("form.problem.port")
    case .path:
      return AppCopy.text("form.problem.path")
    }
  }
}

private func storageFailureText(_ failure: StorageFailure) -> String {
  switch failure {
  case .unavailable:
    return AppCopy.text("failure.storage.unavailable")
  case .denied:
    return AppCopy.text("failure.storage.denied")
  case .encoding, .other:
    return AppCopy.text("failure.storage.other")
  }
}

private func noticeText(_ notice: AppNotice) -> String {
  switch notice {
  case .couldNotSaveServer:
    return AppCopy.text("notice.save_failed")
  case .couldNotReadSavedServers:
    return AppCopy.text("notice.saved_list_unreadable")
  case .couldNotReadCache:
    return AppCopy.text("notice.cache_unreadable")
  case .couldNotReplaceSavedData:
    return AppCopy.text("notice.replace_failed")
  case .couldNotSaveDraft:
    return AppCopy.text("notice.draft_save_failed")
  case .draftKept:
    return AppCopy.text("notice.draft_kept")
  }
}

#Preview("Disconnected") {
  RootView(
    store: Store(initialState: AppFeature.State(isPinnedForUITest: true)) { AppFeature() }
  )
}

#Preview("Failure") {
  RootView(
    store: Store(
      initialState: AppFeature.State(
        restore: .ready,
        connection: ConnectionFeature.State(
          id: 1,
          server: OpenCodeServer(url: "https://studio.invalid", name: "Studio"),
          phase: .failed,
          failure: .unreachable,
          isPinned: true
        ),
        isPinnedForUITest: true
      )
    ) { AppFeature() }
  )
}
