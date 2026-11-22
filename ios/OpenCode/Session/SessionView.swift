import ComposableArchitecture
import OpenCodeCore
import OpenCodeServer
import OpenCodeSession
import SwiftUI

/// The session screen: the run's Stop, the subagent family, pending requests and background work.
/// Transcript rows and composer editing stay with P8/P9; the placeholder says so.
struct SessionView: View {
  let store: StoreOf<SessionFeature>

  @State private var showsSubagents = false
  @State private var showsRequests = false
  @State private var showsBackground = false
  @State private var denyReason = ""
  @State private var isConfirmingShellStop = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: OpenCodeSpacing.s16) {
          if !store.isAtRoot {
            pageBackRow
          }
          header
          if let notice = store.notice {
            NoticeRow(text: noticeText(notice)) { store.send(.noticeDismissed) }
          }
          if store.requests.hasPending {
            requestBar
          }
          if !store.pendingInputs.isEmpty {
            pendingInputs
          }
          transcriptBoundary
          backgroundButton
        }
        .padding(OpenCodeSpacing.s20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle(store.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(AppCopy.text("common.done")) { store.send(.delegate(.dismiss)) }
            .accessibilityIdentifier("session-done")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          if !store.subagents.isEmpty {
            Button {
              showsSubagents = true
            } label: {
              Image(systemName: "person.2")
            }
            .accessibilityLabel(AppCopy.text("session.subagents"))
            .accessibilityIdentifier("session-subagents")
          }
          Button {
            showsBackground = true
          } label: {
            Image(systemName: "terminal")
          }
          .accessibilityLabel(AppCopy.text("session.background"))
          .accessibilityIdentifier("session-background")
        }
      }
    }
    .accessibilityIdentifier("root-phase-session")
    .tint(OpenCodeColors.color(.accent))
    .sheet(isPresented: $showsSubagents) {
      SubagentList(store: store) { showsSubagents = false }
    }
    .sheet(isPresented: $showsRequests) {
      RequestReviewSheet(store: store, denyReason: $denyReason)
    }
    .sheet(isPresented: $showsBackground) {
      BackgroundWorkSheet(store: store) { showsBackground = false }
    }
    .sheet(isPresented: shellOutputPresented) {
      if let output = store.background.output {
        ShellOutputSheet(
          store: store,
          output: output,
          confirmStop: { isConfirmingShellStop = true }
        )
      }
    }
    .alert(
      AppCopy.text("session.shell.stop_title"),
      isPresented: $isConfirmingShellStop
    ) {
      Button(AppCopy.text("session.shell.stop"), role: .destructive) {
        store.send(.shellStopConfirmed)
      }
      Button(AppCopy.text("common.cancel"), role: .cancel) {}
    } message: {
      Text(AppCopy.text("session.shell.stop_message"))
    }
  }

  private var pageBackRow: some View {
    HStack {
      Button {
        store.send(.popPage)
      } label: {
        Label(AppCopy.text("session.back"), systemImage: "chevron.left")
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("session-page-back")
      Spacer()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s8) {
      HStack(alignment: .firstTextBaseline) {
        Text(store.title)
          .font(OpenCodeFonts.font(.title2))
          .foregroundStyle(OpenCodeColors.color(.textStrong))
          .accessibilityIdentifier("session-title")
        Spacer()
        if store.isRunning {
          HStack(spacing: OpenCodeSpacing.s8) {
            Text(
              store.run.isInterrupting
                ? AppCopy.text("session.stopping")
                : AppCopy.text("session.working")
            )
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
            .accessibilityIdentifier("session-working")
            Button {
              store.send(.interruptTapped)
            } label: {
              Image(systemName: "stop.circle")
                .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!store.canInterrupt)
            .accessibilityLabel(AppCopy.text("session.stop"))
            .accessibilityIdentifier("session-stop")
          }
        }
      }
      if let session = store.activeSession {
        HStack(spacing: OpenCodeSpacing.s12) {
          if let agent = session.agent {
            Text(agent)
          }
          if let model = session.model {
            Text(model.id)
          }
          if !store.subagents.isEmpty {
            Text(AppCopy.count("session.subagent_count", store.subagents.count))
          }
        }
        .font(OpenCodeFonts.font(.caption))
        .foregroundStyle(OpenCodeColors.color(.textWeak))
      }
    }
  }

  private var requestBar: some View {
    Button {
      showsRequests = true
    } label: {
      HStack(spacing: OpenCodeSpacing.s12) {
        Image(systemName: "hand.raised")
        VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
          Text(AppCopy.text("session.requests.pending"))
            .font(OpenCodeFonts.font(.headline))
          Text(AppCopy.count("session.requests.count", store.requests.reviewIDs.count))
            .font(OpenCodeFonts.font(.caption))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        }
        Spacer()
        Text(AppCopy.text("session.requests.review"))
          .font(OpenCodeFonts.font(.footnote))
      }
      .foregroundStyle(OpenCodeColors.color(.textStrong))
      .padding(OpenCodeSpacing.s12)
      .background(OpenCodeColors.color(.surfaceStrong), in: .rect(cornerRadius: OpenCodeRadius.control))
      .overlay {
        RoundedRectangle(cornerRadius: OpenCodeRadius.control)
          .strokeBorder(OpenCodeColors.color(.border), lineWidth: 0.5)
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("session-review-requests")
  }

  private var pendingInputs: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s8) {
      Text(AppCopy.text("session.inputs.title"))
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.textWeak))
      ForEach(store.pendingInputs) { input in
        HStack(alignment: .firstTextBaseline, spacing: OpenCodeSpacing.s8) {
          Text(
            input.delivery == .steer
              ? AppCopy.text("session.inputs.steering")
              : AppCopy.text("session.inputs.queued")
          )
          .font(OpenCodeFonts.font(.caption))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
          Text(input.text.isEmpty ? input.id : input.text)
            .font(OpenCodeFonts.font(.body))
            .lineLimit(2)
          Spacer()
          if !store.isRunning, !input.isCompaction {
            Button(AppCopy.text("session.inputs.send_now")) {
              store.send(.strandedSteerTapped(inputID: input.id))
            }
            .font(OpenCodeFonts.font(.footnote))
            .accessibilityIdentifier("session-send-now-\(input.id)")
          }
        }
        .padding(OpenCodeSpacing.s10)
        .background(OpenCodeColors.color(.canvasWeak), in: .rect(cornerRadius: OpenCodeRadius.control))
      }
    }
    .accessibilityIdentifier("session-pending-inputs")
  }

  private var transcriptBoundary: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s6) {
      Text(AppCopy.text("session.transcript_later"))
        .font(OpenCodeFonts.font(.headline))
        .foregroundStyle(OpenCodeColors.color(.textStrong))
      Text(AppCopy.text("session.transcript_later_detail"))
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.textWeak))
    }
    .padding(.vertical, OpenCodeSpacing.s24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("session-transcript-boundary")
  }

  private var backgroundButton: some View {
    let summary = store.backgroundSummary
    return Button {
      showsBackground = true
    } label: {
      HStack {
        Image(systemName: "terminal")
        Text(AppCopy.text("session.background"))
          .font(OpenCodeFonts.font(.headline))
        Spacer()
        Text(
          AppCopy.format(
            "session.background_summary",
            AppCopy.count("session.background.shell", summary.shells) as NSString,
            AppCopy.count("session.background.job", summary.jobs) as NSString
          )
        )
          .font(OpenCodeFonts.font(.caption))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      }
      .padding(OpenCodeSpacing.s12)
      .background(OpenCodeColors.color(.surfaceStrong), in: .rect(cornerRadius: OpenCodeRadius.control))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("background-activity")
  }

  private var shellOutputPresented: Binding<Bool> {
    Binding(
      get: { store.background.output != nil },
      set: { presented in
        if !presented { store.send(.backgroundDismissed) }
      }
    )
  }

  private func noticeText(_ notice: SessionNotice) -> String {
    switch notice {
    case .couldNotRefresh: AppCopy.text("session.notice.refresh")
    case .couldNotLoadFamily: AppCopy.text("session.notice.family")
    case .couldNotLoadRequests: AppCopy.text("session.notice.requests")
    case .couldNotInterrupt: AppCopy.text("session.notice.interrupt")
    case .couldNotStopShell: AppCopy.text("session.notice.shell")
    case .couldNotLoadOutput: AppCopy.text("session.notice.output")
    case .couldNotCancelJob: AppCopy.text("session.notice.job")
    case .couldNotWakeInput: AppCopy.text("session.notice.wake")
    case .sessionGone: AppCopy.text("session.notice.gone")
    }
  }
}

// MARK: - Subagents

private struct SubagentList: View {
  let store: StoreOf<SessionFeature>
  let close: () -> Void

  var body: some View {
    NavigationStack {
      List(store.subagents, id: \.id) { session in
        Button {
          store.send(.openSubagent(session.id))
          close()
        } label: {
          VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
            Text(session.title)
              .font(OpenCodeFonts.font(.body))
            if let agent = session.agent {
              Text(agent)
                .font(OpenCodeFonts.font(.caption))
                .foregroundStyle(OpenCodeColors.color(.textWeak))
            }
          }
        }
        .accessibilityIdentifier("subagent-\(session.id)")
      }
      .navigationTitle(AppCopy.text("session.subagents"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(AppCopy.text("common.done"), action: close)
        }
      }
      .overlay {
        if store.subagents.isEmpty {
          Text(AppCopy.text("session.background.none"))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        }
      }
    }
    .accessibilityIdentifier("subagent-list")
    .tint(OpenCodeColors.color(.accent))
    .presentationBackground(OpenCodeColors.color(.canvas))
  }
}

// MARK: - Requests

private struct RequestReviewSheet: View {
  let store: StoreOf<SessionFeature>
  @Binding var denyReason: String
  @Environment(\.dismiss) private var dismiss
  @State private var numberDrafts: [String: String] = [:]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: OpenCodeSpacing.s16) {
          if let problem = store.requests.loadProblem {
            RequestLoadError(problem: problem) { store.send(.requestLoadRetried) }
          }
          if store.requests.reviewIDs.count > 1 {
            requestPicker
          }
          if let failure = selectedFailure {
            Text(failureText(failure))
              .font(OpenCodeFonts.font(.footnote))
              .foregroundStyle(OpenCodeColors.color(.danger))
              .accessibilityIdentifier("request-error")
          }
          if let permission = store.requests.selectedPermission {
            permissionReview(permission)
          } else if let form = store.requests.selectedForm {
            formReview(form)
          } else {
            Text(AppCopy.text("session.requests.settled"))
              .font(OpenCodeFonts.font(.body))
              .foregroundStyle(OpenCodeColors.color(.textWeak))
          }
        }
        .padding(OpenCodeSpacing.s20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle(AppCopy.text("session.requests.pending"))
      .navigationBarTitleDisplayMode(.inline)
      .onChange(of: store.requests.reviewIDs) { _, ids in
        if ids.isEmpty { dismiss() }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel(AppCopy.text("common.dismiss"))
          .accessibilityIdentifier("request-review-close")
        }
      }
    }
    .accessibilityIdentifier("request-review")
    .tint(OpenCodeColors.color(.accent))
    .presentationBackground(OpenCodeColors.color(.canvas))
  }

  private var requestPicker: some View {
    Picker(
      AppCopy.text("session.requests.pending"),
      selection: Binding(
        get: { store.requests.selectedRequestID ?? "" },
        set: { store.send(.requestSelected($0)) }
      )
    ) {
      ForEach(store.requests.reviewIDs, id: \.self) { id in
        Text(requestTitle(id)).tag(id)
      }
    }
    .pickerStyle(.menu)
  }

  private func requestTitle(_ id: String) -> String {
    if let form = store.requests.form(id) { return form.title }
    if let permission = store.requests.permission(id) { return permission.action }
    return id
  }

  private var selectedFailure: RequestFailure? {
    guard let id = store.requests.selectedRequestID else { return nil }
    return store.requests.failures[id]
  }

  private func permissionReview(_ permission: PermissionRequest) -> some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s12) {
      Text(AppCopy.text("session.requests.run_command"))
        .font(OpenCodeFonts.font(.title3))
        .foregroundStyle(OpenCodeColors.color(.textStrong))
      if !permission.resources.isEmpty {
        VStack(alignment: .leading, spacing: OpenCodeSpacing.s4) {
          ForEach(permission.resources, id: \.self) { resource in
            Text(resource)
              .font(OpenCodeFonts.font(.codeSmall))
              .foregroundStyle(OpenCodeColors.color(.textBody))
              .textSelection(.enabled)
          }
        }
        .padding(OpenCodeSpacing.s10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenCodeColors.color(.codeBand), in: .rect(cornerRadius: OpenCodeRadius.control))
      }
      TextField(AppCopy.text("session.requests.deny_reason"), text: $denyReason, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("request-deny-reason")
      HStack(spacing: OpenCodeSpacing.s8) {
        Button(AppCopy.text("session.requests.deny")) {
          store.send(.permissionReplyTapped(id: permission.id, decision: .reject, message: denyReason))
          denyReason = ""
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("request-permission-deny")
        Spacer()
        if !(permission.save?.isEmpty ?? true) {
          Button(AppCopy.text("session.requests.always")) {
            store.send(.permissionReplyTapped(id: permission.id, decision: .always, message: nil))
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("request-permission-always")
        }
        Button(AppCopy.text("session.requests.allow_once")) {
          store.send(.permissionReplyTapped(id: permission.id, decision: .once, message: nil))
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("request-permission-allow-once")
      }
      .font(OpenCodeFonts.font(.body))
      .disabled(store.requests.respondingIDs.contains(permission.id))
    }
  }

  private func formReview(_ form: FormRequest) -> some View {
    let answers = store.requests.answers[form.id] ?? form.defaultAnswers
    let fields = form.activeFields(answers: answers)
    return VStack(alignment: .leading, spacing: OpenCodeSpacing.s16) {
      Text(form.title)
        .font(OpenCodeFonts.font(.title3))
        .foregroundStyle(OpenCodeColors.color(.textStrong))
      ForEach(Array(fields.enumerated()), id: \.element.key) { _, field in
        fieldView(field, form: form)
      }
      HStack(spacing: OpenCodeSpacing.s12) {
        Button(AppCopy.text("common.dismiss")) {
          store.send(.formCancelTapped(form.id))
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("request-sheet-dismiss")
        Spacer()
        Button {
          store.send(.formSubmitTapped(form.id))
        } label: {
          if store.requests.respondingIDs.contains(form.id) {
            ProgressView()
          } else {
            Text(AppCopy.text("common.send"))
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.requests.respondingIDs.contains(form.id))
        .accessibilityIdentifier("request-send")
      }
    }
  }

  @ViewBuilder
  private func fieldView(_ field: FormField, form: FormRequest) -> some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s6) {
      if let title = field.title, !title.isEmpty {
        Text(title)
          .font(OpenCodeFonts.font(.headline))
      }
      if let description = field.description, !description.isEmpty {
        Text(description)
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      }
      switch field.type {
      case .boolean:
        booleanField(field, form: form)
      case .multiselect:
        Text(AppCopy.text("session.requests.choose_multiple"))
          .font(OpenCodeFonts.font(.caption))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
        optionButtons(field, form: form)
      case .external:
        Toggle(
          AppCopy.text("session.requests.completed"),
          isOn: Binding(
            get: { store.requests.answers[form.id]?[field.key] == .boolean(true) },
            set: { store.send(.requestValueChanged(formID: form.id, key: field.key, value: .boolean($0))) }
          )
        )
        .accessibilityIdentifier("request-field-\(field.key)")
      case .string:
        if let options = field.options, !options.isEmpty {
          optionButtons(field, form: form)
        }
        if field.options?.isEmpty ?? true || field.custom == true {
          TextField(
            AppCopy.text("session.requests.answer_placeholder"),
            text: stringBinding(field, form: form),
            axis: .vertical
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("request-field-\(field.key)")
        }
      case .number, .integer:
        if let options = field.options, !options.isEmpty {
          optionButtons(field, form: form)
        }
        if field.options?.isEmpty ?? true || field.custom == true {
          TextField(
            AppCopy.text("session.requests.answer_placeholder"),
            text: numberBinding(field, form: form)
          )
          .keyboardType(.decimalPad)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("request-field-\(field.key)")
        }
      }
      if let problem = field.validationProblem(store.requests.answers[form.id]?[field.key]) {
        Text(validationText(problem))
          .font(OpenCodeFonts.font(.caption))
          .foregroundStyle(OpenCodeColors.color(.danger))
      }
    }
  }

  private func booleanField(_ field: FormField, form: FormRequest) -> some View {
    let value = store.requests.answers[form.id]?[field.key]
    return HStack(spacing: OpenCodeSpacing.s8) {
      Button(AppCopy.text("session.requests.yes")) {
        store.send(.requestValueChanged(formID: form.id, key: field.key, value: .boolean(true)))
      }
      .buttonStyle(.bordered)
      .tint(value == .boolean(true) ? OpenCodeColors.color(.accent) : nil)
      .accessibilityIdentifier("request-field-\(field.key)-yes")
      Button(AppCopy.text("session.requests.no")) {
        store.send(.requestValueChanged(formID: form.id, key: field.key, value: .boolean(false)))
      }
      .buttonStyle(.bordered)
      .tint(value == .boolean(false) ? OpenCodeColors.color(.accent) : nil)
      .accessibilityIdentifier("request-field-\(field.key)-no")
    }
  }

  private func optionButtons(_ field: FormField, form: FormRequest) -> some View {
    let current = store.requests.answers[form.id]?[field.key]
    return VStack(alignment: .leading, spacing: OpenCodeSpacing.s4) {
      ForEach(field.options ?? [], id: \.value) { option in
        let selected = isSelected(option.value, value: current)
        Button {
          let value = toggled(option.value, field: field, current: current)
          store.send(.requestValueChanged(formID: form.id, key: field.key, value: value))
        } label: {
          HStack {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            VStack(alignment: .leading) {
              Text(option.label)
              if let description = option.description {
                Text(description)
                  .font(OpenCodeFonts.font(.caption))
                  .foregroundStyle(OpenCodeColors.color(.textWeak))
              }
            }
            Spacer()
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("request-option-\(option.value)")
      }
    }
  }

  private func stringBinding(_ field: FormField, form: FormRequest) -> Binding<String> {
    Binding(
      get: {
        if case .string(let value) = store.requests.answers[form.id]?[field.key] { return value }
        return ""
      },
      set: {
        store.send(.requestValueChanged(formID: form.id, key: field.key, value: .string($0)))
      }
    )
  }

  private func numberBinding(_ field: FormField, form: FormRequest) -> Binding<String> {
    Binding(
      get: {
        if case .number(let value) = store.requests.answers[form.id]?[field.key] {
          return String(value)
        }
        return ""
      },
      set: {
        store.send(
          .requestValueChanged(formID: form.id, key: field.key, value: .typedNumber($0))
        )
      }
    )
  }

  private func isSelected(_ option: String, value: FormValue?) -> Bool {
    switch value {
    case .string(let text): text == option
    case .strings(let values): values.contains(option)
    case .boolean(let flag): String(flag) == option
    default: false
    }
  }

  private func toggled(_ option: String, field: FormField, current: FormValue?) -> FormValue {
    switch field.type {
    case .multiselect:
      var values: [String]
      if case .strings(let existing) = current { values = existing } else { values = [] }
      if let index = values.firstIndex(of: option) { values.remove(at: index) } else { values.append(option) }
      return .strings(values)
    case .boolean:
      return .boolean(option == "true")
    default:
      return .string(option)
    }
  }

}

private struct RequestLoadError: View {
  let problem: SessionProblem
  let retry: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: OpenCodeSpacing.s8) {
      Text(AppCopy.text("session.notice.requests"))
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.danger))
      Spacer()
      Button(AppCopy.text("common.try_again"), action: retry)
        .font(OpenCodeFonts.font(.footnote))
    }
    .padding(OpenCodeSpacing.s12)
    .background(OpenCodeColors.color(.surfaceStrong), in: .rect(cornerRadius: OpenCodeRadius.control))
    .accessibilityIdentifier("request-load-error")
  }
}

// MARK: - Background work

private struct BackgroundWorkSheet: View {
  let store: StoreOf<SessionFeature>
  let close: () -> Void

  var body: some View {
    NavigationStack {
      List {
        if !store.background.shells.isEmpty {
          Section(AppCopy.text("session.background.shells")) {
            ForEach(store.background.shells, id: \.id) { shell in
              Button {
                store.send(.shellOutputTapped(shellID: shell.id))
                close()
              } label: {
                VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
                  Text(shell.title)
                    .font(OpenCodeFonts.font(.codeSmall))
                  Text(shell.status.rawValue)
                    .font(OpenCodeFonts.font(.caption))
                    .foregroundStyle(OpenCodeColors.color(.textWeak))
                }
              }
              .accessibilityIdentifier("background-shell-\(shell.id)")
            }
          }
        }
        if !store.background.jobs.isEmpty {
          Section(AppCopy.text("session.background.jobs")) {
            ForEach(store.background.jobs, id: \.id) { job in
              HStack {
                VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
                  Text(job.kind.rawValue)
                    .font(OpenCodeFonts.font(.body))
                  Text(job.id)
                    .font(OpenCodeFonts.font(.caption))
                    .foregroundStyle(OpenCodeColors.color(.textWeak))
                }
                Spacer()
                Button {
                  store.send(.jobCancelTapped(jobID: job.id))
                } label: {
                  Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .disabled(store.background.stoppingIDs.contains(job.id))
                .accessibilityLabel(AppCopy.text("session.notice.job"))
                .accessibilityIdentifier("background-job-stop-\(job.id)")
              }
              .accessibilityIdentifier("background-job-\(job.id)")
            }
          }
        }
        if store.background.shells.isEmpty, store.background.jobs.isEmpty {
          Text(AppCopy.text("session.background.none"))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
        }
        if let problem = store.background.problem {
          Text(AppCopy.text("session.notice.output"))
            .foregroundStyle(OpenCodeColors.color(.danger))
          Button(AppCopy.text("common.try_again")) {
            store.send(.backgroundProblemDismissed)
            store.send(.refreshRequested(.watchdog))
          }
        }
      }
      .navigationTitle(AppCopy.text("session.background"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(AppCopy.text("common.done"), action: close)
        }
      }
    }
    .accessibilityIdentifier("background-work-panel")
    .tint(OpenCodeColors.color(.accent))
    .presentationBackground(OpenCodeColors.color(.canvas))
  }
}

private struct ShellOutputSheet: View {
  let store: StoreOf<SessionFeature>
  let output: ShellOutputState
  let confirmStop: () -> Void

  private var current: ShellOutputState { store.background.output ?? output }

  var body: some View {
    NavigationStack {
      ScrollView {
        if current.isUnavailable {
          Text(AppCopy.text("session.shell.unavailable"))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
            .padding(OpenCodeSpacing.s20)
        } else if !current.isLoaded {
          ProgressView()
            .padding(OpenCodeSpacing.s24)
        } else if current.output.isEmpty {
          Text(AppCopy.text("session.shell.no_output"))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
            .padding(OpenCodeSpacing.s20)
        } else {
          Text(current.output)
            .font(OpenCodeFonts.font(.codeSmall))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(OpenCodeSpacing.s12)
            .accessibilityIdentifier("shell-output")
        }
      }
      .navigationTitle(output.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppCopy.text("common.done")) { store.send(.backgroundDismissed) }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          if current.canLoadEarlier {
            Button(AppCopy.text("session.shell.load_earlier")) {
              store.send(.shellEarlierTapped)
            }
            .accessibilityIdentifier("shell-output-load-earlier")
          }
          if !current.isUnavailable, current.isRunning {
            Button(AppCopy.text("session.shell.stop"), role: .destructive, action: confirmStop)
              .disabled(current.isStopping)
              .accessibilityIdentifier("shell-output-stop")
          }
        }
      }
      .task { store.send(.shellOutputAppeared) }
      .onDisappear { store.send(.shellOutputDisappeared) }
    }
    .accessibilityIdentifier("shell-output-sheet")
    .tint(OpenCodeColors.color(.accent))
    .presentationBackground(OpenCodeColors.color(.canvas))
  }
}

// MARK: - Copy

private func validationText(_ problem: FormValidationProblem) -> String {
  switch problem {
  case .required: AppCopy.text("session.requests.validation.required")
  case .completeStep: AppCopy.text("session.requests.validation.complete_step")
  case .minLength(let value): AppCopy.format("session.requests.validation.min_length", value)
  case .maxLength(let value): AppCopy.format("session.requests.validation.max_length", value)
  case .invalidFormat: AppCopy.text("session.requests.validation.invalid_format")
  case .chooseOption: AppCopy.text("session.requests.validation.choose_option")
  case .invalidEmail: AppCopy.text("session.requests.validation.invalid_email")
  case .invalidURL: AppCopy.text("session.requests.validation.invalid_url")
  case .invalidDate: AppCopy.text("session.requests.validation.invalid_date")
  case .invalidDateTime: AppCopy.text("session.requests.validation.invalid_date_time")
  case .minimum(let value): AppCopy.format("session.requests.validation.minimum", value)
  case .maximum(let value): AppCopy.format("session.requests.validation.maximum", value)
  case .wholeNumber: AppCopy.text("session.requests.validation.whole_number")
  case .minItems(let value): AppCopy.format("session.requests.validation.min_items", value)
  case .maxItems(let value): AppCopy.format("session.requests.validation.max_items", value)
  case .invalidValue: AppCopy.text("session.requests.validation.invalid_value")
  }
}

private func failureText(_ failure: RequestFailure) -> String {
  switch failure {
  case .validation(let problem, _, _): validationText(problem)
  case .reply: AppCopy.text("session.requests.failed_reply")
  case .dismissal, .settledDismissal: AppCopy.text("session.requests.failed_dismiss")
  case .settled: AppCopy.text("session.requests.settled")
  case .conflict(.answeredElsewhere), .conflict(.dismissedElsewhere):
    AppCopy.text("session.requests.settled_elsewhere")
  case .conflict(.noLongerWaiting): AppCopy.text("session.requests.no_longer_waiting")
  }
}

private struct NoticeRow: View {
  let text: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top) {
      Text(text)
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.danger))
      Spacer()
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(AppCopy.text("common.dismiss"))
    }
    .padding(OpenCodeSpacing.s10)
    .background(OpenCodeColors.color(.surfaceStrong), in: .rect(cornerRadius: OpenCodeRadius.control))
    .accessibilityIdentifier("session-notice")
  }
}
