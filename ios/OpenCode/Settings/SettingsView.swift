import ComposableArchitecture
import OpenCodeCore
import OpenCodeServer
import OpenCodeSettings
import SwiftUI
#if canImport(UIKit)
  import UIKit
#endif

struct SettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    NavigationStack(
      path: Binding(
        get: { store.path },
        set: { store.send(.pathReplaced($0)) }
      )
    ) {
      root
        .navigationTitle(AppCopy.text("settings.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button(AppCopy.text("common.done")) { store.send(.closed) }
              .accessibilityIdentifier("settings-done")
          }
        }
        .navigationDestination(for: SettingsPage.self) { page in
          destination(page)
        }
    }
    .fullScreenCover(
      isPresented: Binding(
        get: { store.isScanning },
        set: { if !$0 { store.send(.scanCancelled) } }
      )
    ) {
      PairingCaptureView(
        cancel: { store.send(.scanCancelled) },
        problem: store.scanProblem,
        dismissProblem: { store.send(.scanProblemDismissed) }
      )
    }
    .alert(
      AppCopy.text("settings.remove.title"),
      isPresented: Binding(
        get: { store.pendingRemoval != nil },
        set: { if !$0 { store.send(.serverRemoveCancelled) } }
      )
    ) {
      Button(AppCopy.text("settings.remove.action"), role: .destructive) {
        store.send(.serverRemoveConfirmed)
      }
      Button(AppCopy.text("common.cancel"), role: .cancel) { store.send(.serverRemoveCancelled) }
    } message: {
      Text(AppCopy.text("settings.remove.message"))
    }
    .alert(
      AppCopy.text("settings.onboarding.done.title"),
      isPresented: Binding(
        get: { store.notice == .onboardingFinished },
        set: { if !$0 { store.send(.noticeDismissed) } }
      )
    ) {
      Button(AppCopy.text("common.done")) { store.send(.noticeDismissed) }
    } message: {
      Text(AppCopy.text("settings.onboarding.done.message"))
    }
    .task { store.send(.task) }
    .accessibilityIdentifier("settings-root")
  }

  private var root: some View {
    List {
      Section {
        serverCard
      } header: {
        Text(AppCopy.text("settings.server.section"))
      } footer: {
        if let problem = store.preferencesProblem {
          Text(problemCopy(problem))
            .foregroundStyle(OpenCodeColors.color(.warning))
        }
      }

      Section(AppCopy.text("settings.appearance.section")) {
        Picker(
          AppCopy.text("settings.appearance.style"),
          selection: Binding(
            get: { store.preferences.appearance },
            set: { store.send(.appearanceChanged($0)) }
          )
        ) {
          ForEach(AppearanceChoice.allCases, id: \.self) { choice in
            Text(choice.title).tag(choice)
          }
        }
        .accessibilityIdentifier("settings-appearance")
      }

      Section {
        Toggle(
          AppCopy.text("settings.sessions.return_sends"),
          isOn: Binding(
            get: { store.preferences.returnKeySends },
            set: { store.send(.returnKeySendsChanged($0)) }
          )
        )
        .accessibilityIdentifier("settings-return-sends")
        Toggle(
          AppCopy.text("settings.sessions.wrap_lines"),
          isOn: Binding(
            get: { store.preferences.fileViewerWrapsLines },
            set: { store.send(.fileViewerWrapChanged($0)) }
          )
        )
        .accessibilityIdentifier("settings-wrap-lines")
      } header: {
        Text(AppCopy.text("settings.sessions.section"))
      } footer: {
        Text(AppCopy.text("settings.sessions.return_detail"))
      }

      Section {
        Toggle(
          AppCopy.text("settings.experimental.browser"),
          isOn: Binding(
            get: { store.preferences.inAppBrowser },
            set: { store.send(.inAppBrowserChanged($0)) }
          )
        )
        .accessibilityIdentifier("settings-in-app-browser")
      } header: {
        Text(AppCopy.text("settings.experimental.section"))
      } footer: {
        Text(AppCopy.text("settings.experimental.browser_detail"))
      }

      if let saveProblem = store.saveProblem {
        Section {
          Label(
            AppCopy.text("settings.save.failed"),
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(OpenCodeColors.color(.warning))
          .accessibilityIdentifier("settings-save-problem")
          Button(AppCopy.text("common.dismiss")) { store.send(.saveProblemDismissed) }
        }
      }

      Section(AppCopy.text("settings.support.section")) {
        NavigationLink(value: SettingsPage(kind: .diagnostics)) {
          Label(AppCopy.text("settings.diagnostics.title"), systemImage: "stethoscope")
        }
        NavigationLink(value: SettingsPage(kind: .onboarding)) {
          Label(AppCopy.text("settings.onboarding.title"), systemImage: "hand.wave")
        }
        NavigationLink(value: SettingsPage(kind: .help)) {
          Label(AppCopy.text("settings.help.title"), systemImage: "questionmark.circle")
        }
      }
    }
    .listStyle(.insetGrouped)
  }

  private var serverCard: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s8) {
      if let server = store.server {
        Text(server.displayName)
          .font(OpenCodeFonts.font(.headline))
          .foregroundStyle(OpenCodeColors.color(.textStrong))
        Text(server.host)
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
        HStack(spacing: OpenCodeSpacing.s8) {
          Button(AppCopy.text("settings.server.edit")) { store.send(.serverEditTapped) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("settings-edit-server")
          Button(AppCopy.text("settings.server.scan")) { store.send(.scanTapped) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("settings-scan-server")
        }
        .padding(.top, OpenCodeSpacing.s4)
        Button(AppCopy.text("settings.server.remove"), role: .destructive) {
          store.send(.serverRemoveTapped)
        }
        .font(OpenCodeFonts.font(.footnote))
        .accessibilityIdentifier("settings-remove-server")
        if let problem = store.removalProblem {
          Text(removalCopy(problem))
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.warning))
        }
      } else {
        Text(AppCopy.text("settings.server.none"))
          .font(OpenCodeFonts.font(.body))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
        Button(AppCopy.text("settings.server.scan")) { store.send(.scanTapped) }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("settings-scan-server")
      }
    }
    .padding(.vertical, OpenCodeSpacing.s4)
  }

  @ViewBuilder
  private func destination(_ page: SettingsPage) -> some View {
    switch page.kind {
    case .appearance, .sessions, .experimental, .servers:
      emptyPage
    case .server:
      if let form = store.serverForm {
        ServerEditView(store: store, form: form)
      } else {
        emptyPage
      }
    case .diagnostics:
      diagnosticsPage
    case .onboarding:
      onboardingPage
    case .help:
      helpPage
    }
  }

  private var emptyPage: some View {
    Text(AppCopy.text("settings.empty"))
      .foregroundStyle(OpenCodeColors.color(.textWeak))
  }

  private var diagnosticsPage: some View {
    List {
      Section {
        if let report = store.diagnosticsReport {
          Text(report.text)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .accessibilityIdentifier("settings-diagnostics-report")
        } else {
          Text(AppCopy.text("settings.diagnostics.empty"))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        }
      } footer: {
        Text(AppCopy.text("settings.diagnostics.detail"))
      }
      Section {
        Button(AppCopy.text("settings.diagnostics.collect")) { store.send(.diagnosticsRequested) }
          .accessibilityIdentifier("settings-diagnostics-collect")
        Button(AppCopy.text("settings.diagnostics.copy")) { store.send(.diagnosticsCopyTapped) }
          .disabled(store.diagnosticsFacts == nil && store.diagnosticsReport == nil)
          .accessibilityIdentifier("settings-diagnostics-copy")
        if store.diagnosticsCopied {
          Label(AppCopy.text("settings.diagnostics.copied"), systemImage: "checkmark")
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        }
      }
      if let notice = store.notice, notice == .couldNotCopy {
        Text(AppCopy.text("settings.diagnostics.copy_failed"))
          .foregroundStyle(OpenCodeColors.color(.warning))
      }
    }
    .navigationTitle(AppCopy.text("settings.diagnostics.title"))
    .accessibilityIdentifier("settings-diagnostics-title")
  }

  private var onboardingPage: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s16) {
      Text(AppCopy.text("settings.onboarding.step.\(store.onboardingStep).title"))
        .accessibilityIdentifier("settings-onboarding-title")
        .font(OpenCodeFonts.font(.title2))
        .foregroundStyle(OpenCodeColors.color(.textStrong))
      Text(AppCopy.text("settings.onboarding.step.\(store.onboardingStep).body"))
        .font(OpenCodeFonts.font(.body))
        .foregroundStyle(OpenCodeColors.color(.textBody))
      Spacer()
      HStack(spacing: OpenCodeSpacing.s8) {
        if store.onboardingStep > 0 {
          Button(AppCopy.text("settings.onboarding.back")) { store.send(.onboardingBack) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("settings-onboarding-back")
        }
        Spacer()
        if store.onboardingStep < 2 {
          Button(AppCopy.text("settings.onboarding.next")) { store.send(.onboardingNext) }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("settings-onboarding-next")
        } else {
          Button(AppCopy.text("settings.onboarding.finish")) { store.send(.onboardingFinished) }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("settings-onboarding-finish")
        }
      }
    }
    .padding(OpenCodeSpacing.s24)
    .navigationTitle(AppCopy.text("settings.onboarding.title"))
  }

  private var helpPage: some View {
    List {
      Section(AppCopy.text("settings.help.pair.title")) {
        Text(AppCopy.text("settings.help.pair.body"))
      }
      Section(AppCopy.text("settings.help.browser.title")) {
        Text(AppCopy.text("settings.help.browser.body"))
      }
      Section(AppCopy.text("settings.help.privacy.title")) {
        Text(AppCopy.text("settings.help.privacy.body"))
      }
    }
    .navigationTitle(AppCopy.text("settings.help.title"))
  }

  private func problemCopy(_ problem: PreferencesProblem) -> String {
    switch problem {
    case .storage: AppCopy.text("settings.problem.storage")
    case .corrupt: AppCopy.text("settings.problem.corrupt")
    }
  }

  private func removalCopy(_ problem: ServerRemovalProblem) -> String {
    switch problem {
    case .storage: AppCopy.text("settings.problem.storage")
    case .lastServer: AppCopy.text("settings.problem.last_server")
    }
  }
}

private struct ServerEditView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let form: ServerEditForm

  var body: some View {
    List {
      Section {
        TextField(AppCopy.text("settings.server.name"), text: Binding(
          get: { store.serverForm?.name ?? "" },
          set: { store.send(.serverFormNameChanged($0)) }
        ))
        .accessibilityIdentifier("settings-server-name")
        TextField(AppCopy.text("settings.server.address"), text: Binding(
          get: { store.serverForm?.address ?? "" },
          set: { store.send(.serverFormAddressChanged($0)) }
        ))
        .accessibilityIdentifier("settings-server-address")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        TextField(AppCopy.text("settings.server.username"), text: Binding(
          get: { store.serverForm?.username ?? "" },
          set: { store.send(.serverFormUsernameChanged($0)) }
        ))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        SecureField(AppCopy.text("settings.server.password"), text: Binding(
          get: { store.serverForm?.password ?? "" },
          set: { store.send(.serverFormPasswordChanged($0)) }
        ))
      }

      Section {
        ForEach(Array((store.serverForm?.headers ?? []).enumerated()), id: \.offset) { index, header in
          VStack(alignment: .leading, spacing: OpenCodeSpacing.s4) {
            TextField(AppCopy.text("settings.server.header_name"), text: Binding(
              get: { header.name },
              set: { store.send(.serverHeaderNameChanged(index: index, name: $0)) }
            ))
            .accessibilityIdentifier("settings-header-name-\(index)")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            TextField(AppCopy.text("settings.server.header_value"), text: Binding(
              get: { header.value },
              set: { store.send(.serverHeaderValueChanged(index: index, value: $0)) }
            ))
            .accessibilityIdentifier("settings-header-value-\(index)")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          }
          .swipeActions {
            Button(AppCopy.text("common.remove"), role: .destructive) {
              store.send(.serverHeaderRemoved(index: index))
            }
          }
        }
        Button(AppCopy.text("settings.server.add_header")) { store.send(.serverHeaderAdded) }
          .disabled((store.serverForm?.headers.count ?? 0) >= 16)
          .accessibilityIdentifier("settings-header-add")
      } header: {
        Text(AppCopy.text("settings.server.headers"))
      } footer: {
        if let problem = store.serverForm?.headerProblem {
          Text(headerProblemCopy(problem))
            .foregroundStyle(OpenCodeColors.color(.warning))
        } else {
          Text(AppCopy.text("settings.server.headers_detail"))
        }
      }

      if let problem = store.serverForm?.problem {
        Section {
          Text(problemCopy(problem))
            .foregroundStyle(OpenCodeColors.color(.warning))
        }
      }
      if let problem = store.serverFormSaveProblem {
        Section {
          Text(saveProblemCopy(problem))
            .foregroundStyle(OpenCodeColors.color(.warning))
            .accessibilityIdentifier("settings-server-save-problem")
        }
      }

      Section {
        Button(AppCopy.text("settings.server.save")) { store.send(.serverFormSubmitted) }
          .disabled(store.serverForm == nil)
          .accessibilityIdentifier("settings-server-save")
        Button(AppCopy.text("common.cancel"), role: .cancel) { store.send(.serverFormDismissed) }
      }
    }
    .navigationTitle(AppCopy.text("settings.server.edit"))
  }

  private func headerProblemCopy(_ problem: ServerEditForm.HeaderProblem) -> String {
    switch problem {
    case .emptyName: AppCopy.text("settings.server.header_empty")
    case .invalidName(_, let name): AppCopy.format("settings.server.header_invalid_name", name)
    case .invalidValue(_, let name): AppCopy.format("settings.server.header_invalid_value", name)
    case .forbidden(_, let name): AppCopy.format("settings.server.header_forbidden", name)
    }
  }

  private func problemCopy(_ problem: ServerEditForm.Problem) -> String {
    switch problem {
    case .emptyAddress: AppCopy.text("settings.server.empty_address")
    case .invalidAddress(let reason): AppCopy.format("settings.server.invalid_address", addressReason(reason))
    case .noChanges: AppCopy.text("settings.server.no_changes")
    }
  }

  private func addressReason(_ problem: ServerOrigin.Problem) -> String {
    switch problem {
    case .notAWebAddress: AppCopy.text("settings.address.not_web")
    case .badScheme: AppCopy.text("settings.address.scheme")
    case .noHost: AppCopy.text("settings.address.host")
    case .credentials: AppCopy.text("settings.address.credentials")
    case .query: AppCopy.text("settings.address.query")
    case .port: AppCopy.text("settings.address.port")
    case .path: AppCopy.text("settings.address.path")
    }
  }

  private func saveProblemCopy(_ problem: PreferencesProblem) -> String {
    switch problem {
    case .storage: AppCopy.text("settings.problem.storage")
    case .corrupt: AppCopy.text("settings.problem.corrupt")
    }
  }
}

private struct PairingCaptureView: View {
  let cancel: () -> Void
  let problem: PairingScanProblem?
  let dismissProblem: () -> Void

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if problem == nil {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
          CameraPreview(session: QRCameraScanner.shared.captureSession)
        }
        .ignoresSafeArea()
      }
      VStack {
        Spacer()
        VStack(spacing: OpenCodeSpacing.s12) {
          if let problem {
            Text(problemCopy(problem))
              .font(OpenCodeFonts.font(.body))
              .multilineTextAlignment(.center)
            Button(AppCopy.text("common.done")) { dismissProblem() }
              .buttonStyle(.borderedProminent)
          } else {
            Text(AppCopy.text("settings.scan.instruction"))
              .accessibilityIdentifier("settings-scan-instruction")
              .font(OpenCodeFonts.font(.headline))
              .multilineTextAlignment(.center)
          }
          Button(AppCopy.text("common.cancel"), role: .cancel) { cancel() }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("settings-scan-cancel")
        }
        .padding(OpenCodeSpacing.s24)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: OpenCodeRadius.panel))
        .padding(OpenCodeSpacing.s24)
      }
    }
  }

  private func problemCopy(_ problem: PairingScanProblem) -> String {
    switch problem {
    case .cameraDenied: AppCopy.text("settings.scan.denied")
    case .cameraRestricted: AppCopy.text("settings.scan.restricted")
    case .cameraUnavailable: AppCopy.text("settings.scan.unavailable")
    case .cameraFailed: AppCopy.text("settings.scan.failed")
    }
  }
}

#if canImport(UIKit) && canImport(AVFoundation)
  import AVFoundation

  private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession?

    func makeUIView(context: Context) -> PreviewView {
      PreviewView()
    }

    func updateUIView(_ view: PreviewView, context: Context) {
      view.attach(session)
    }

    final class PreviewView: UIView {
      override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

      func attach(_ session: AVCaptureSession?) {
        guard let session, let preview = layer as? AVCaptureVideoPreviewLayer else { return }
        if preview.session !== session { preview.session = session }
        preview.videoGravity = .resizeAspectFill
      }
    }
  }
#else
  private struct CameraPreview: View {
    let session: AnyObject?
    var body: some View { Color.black }
  }
#endif
