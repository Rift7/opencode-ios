import ComposableArchitecture
import OpenCodeComposer
import OpenCodeCore
import OpenCodeServer
import OpenCodeSession
import SwiftUI

/// The chat composer. Quote chips, the native text bridge and the sending controls share one
/// surface; a docked request replaces the answer bar without touching the chat draft.
struct ComposerPanel: View {
  let store: StoreOf<SessionFeature>
  @State private var height: CGFloat = 36
  @State private var commentingQuote: ComposerQuote?

  private var composer: ComposerFeature.State { store.composer }

  var body: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s8) {
      if !composer.quotes.isEmpty {
        quoteChips
      }
      if let problem = composer.problem {
        problemLine(problem)
      }
      if !composer.failedSends.isEmpty {
        failedSends
      }
      inputRow
      #if DEBUG
        Text("\(composer.draft.utf8.count):\(composer.revision)")
          .font(.caption2)
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .accessibilityIdentifier("composer-draft-probe")
        Text(TypingLatencyProbe.shared.summary)
          .font(.caption2)
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .accessibilityIdentifier("composer-typing-probe")
      #endif
    }
    .padding(.horizontal, OpenCodeSpacing.s12)
    .padding(.vertical, OpenCodeSpacing.s8)
    .background(OpenCodeColors.color(.surfaceStrong))
    .overlay(alignment: .top) {
      Rectangle()
        .fill(OpenCodeColors.color(.border))
        .frame(height: 0.5)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer")
    .sheet(item: $commentingQuote) { quote in
      QuoteCommentSheet(quote: quote) { comment in
        store.send(.composer(.quoteCommentChanged(id: quote.id, comment: comment)))
      }
    }
  }

  private var inputRow: some View {
    HStack(alignment: .bottom, spacing: OpenCodeSpacing.s8) {
      ComposerTextInput(
        text: Binding(
          get: { composer.draft },
          set: { store.send(.composer(.textChanged($0))) }
        ),
        height: $height,
        focusRequest: composer.focusRequest,
        placeholder: AppCopy.text("composer.placeholder"),
        isEnabled: true,
        onSend: { store.send(.composer(.sendTapped)) }
      )
      .frame(minHeight: 36, maxHeight: 168)
      .frame(height: height)

      Menu {
        Button {
          store.send(.composer(.queueTapped))
        } label: {
          Label(AppCopy.text("composer.send_queue"), systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Button {
          store.send(.composer(.sendTapped))
        } label: {
          Label(AppCopy.text("composer.send_steer"), systemImage: "arrow.up")
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
          .frame(width: 32, height: 44)
      }
      .disabled(!composer.canSend)
      .accessibilityIdentifier("composer-send-menu")
      .accessibilityLabel(AppCopy.text("composer.queue_menu"))

      Button {
        store.send(.composer(.sendTapped))
      } label: {
        sendLabel
      }
      .buttonStyle(.plain)
      .disabled(!composer.canSend)
      .accessibilityIdentifier("composer-send")
      .accessibilityLabel(AppCopy.text("composer.send"))
      .accessibilityHint(
        store.isRunning ? AppCopy.text("composer.send_steer_hint") : AppCopy.text("composer.send_hint")
      )
    }
  }

  private var sendLabel: some View {
    ZStack {
      Circle()
        .fill(composer.canSend ? OpenCodeColors.color(.accent) : OpenCodeColors.color(.codeBand))
        .frame(width: 36, height: 36)
      if composer.isSending {
        ProgressView()
          .controlSize(.small)
          .tint(OpenCodeColors.color(.canvas))
      } else {
        Image(systemName: store.isRunning ? "arrow.up.circle" : "arrow.up")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(composer.canSend ? OpenCodeColors.color(.canvas) : OpenCodeColors.color(.textTertiary))
      }
    }
    .frame(minWidth: 48, minHeight: 48)
  }

  private var quoteChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: OpenCodeSpacing.s8) {
        ForEach(composer.quotes) { quote in
          HStack(spacing: OpenCodeSpacing.s6) {
            Image(systemName: "quote.opening")
              .font(.caption2)
            Text(quote.text.replacingOccurrences(of: "\n", with: " "))
              .font(OpenCodeFonts.font(.caption))
              .lineLimit(1)
            if let comment = quote.comment {
              Text("· \(comment)")
                .font(OpenCodeFonts.font(.caption2))
                .foregroundStyle(OpenCodeColors.color(.textWeak))
                .lineLimit(1)
            }
            Button {
              store.send(.composer(.quoteRemoved(id: quote.id)))
            } label: {
              Image(systemName: "xmark")
                .font(.caption2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppCopy.text("composer.remove_quote"))
            .accessibilityIdentifier("composer-quote-remove-\(quote.id)")
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
          .accessibilityIdentifier("composer-quote-\(quote.id)")
          .contextMenu {
            Button {
              commentingQuote = quote
            } label: {
              Label(
                quote.comment == nil
                  ? AppCopy.text("composer.quote.add_comment")
                  : AppCopy.text("composer.quote.edit_comment"),
                systemImage: "text.bubble"
              )
            }
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer-quote-chips")
  }

  private var failedSends: some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s6) {
      ForEach(composer.failedSends) { failed in
        HStack(spacing: OpenCodeSpacing.s8) {
          Image(systemName: "exclamationmark.circle")
            .foregroundStyle(OpenCodeColors.color(.warning))
          Text(failed.text.isEmpty ? AppCopy.text("composer.failed_message") : failed.text)
            .font(OpenCodeFonts.font(.caption))
            .lineLimit(1)
          Spacer()
          Button(AppCopy.text("composer.retry")) {
            store.send(.composer(.retryFailed(messageID: failed.messageID)))
          }
          .font(OpenCodeFonts.font(.caption))
          .accessibilityIdentifier("composer-retry-\(failed.messageID)")
          Button(AppCopy.text("composer.edit")) {
            store.send(.composer(.editFailed(messageID: failed.messageID)))
          }
          .font(OpenCodeFonts.font(.caption))
          .accessibilityIdentifier("composer-edit-\(failed.messageID)")
          Button(role: .destructive) {
            store.send(.composer(.deleteFailed(messageID: failed.messageID)))
          } label: {
            Image(systemName: "trash")
              .font(.caption)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(AppCopy.text("composer.delete"))
        }
        .padding(OpenCodeSpacing.s8)
        .background(OpenCodeColors.color(.canvasWeak), in: .rect(cornerRadius: OpenCodeRadius.control))
      }
    }
  }

  private func problemLine(_ problem: ComposerProblem) -> some View {
    HStack(spacing: OpenCodeSpacing.s6) {
      Image(systemName: "exclamationmark.circle")
      Text(problemText(problem))
        .font(OpenCodeFonts.font(.caption))
      Spacer()
      if problem == .couldNotRestore {
        Button(AppCopy.text("composer.retry")) {
          store.send(.composer(.restoreRetried))
        }
        .font(OpenCodeFonts.font(.caption))
      }
    }
    .foregroundStyle(
      OpenCodeColors.color(problem == .couldNotVerifySend ? .warning : .danger)
    )
    .accessibilityIdentifier("composer-problem")
  }

  private func problemText(_ problem: ComposerProblem) -> String {
    switch problem {
    case .couldNotRestore: AppCopy.text("composer.problem.restore")
    case .couldNotSave: AppCopy.text("composer.problem.save")
    case .draftTooLarge: AppCopy.text("composer.problem.too_large")
    case .couldNotSend: AppCopy.text("composer.problem.send")
    case .couldNotVerifySend: AppCopy.text("composer.problem.verify")
    case .notConnected: AppCopy.text("composer.problem.offline")
    }
  }
}

/// The request dock above the answer bar: the question page, choices, permission actions and the
/// fold. The composer's own draft stays out of sight and untouched while this is up.
struct RequestDockPanel: View {
  let store: StoreOf<SessionFeature>

  private var requests: SessionRequests { store.requests }
  private var dock: RequestDockState { store.requestDock }
  private var selectedID: String? { requests.selectedRequestID }

  var body: some View {
    if let id = selectedID {
      if let permission = requests.permission(id) {
        permissionPanel(permission, id: id)
      } else if let form = requests.form(id) {
        formPanel(form, id: id)
      }
    }
  }

  private func permissionPanel(_ permission: PermissionRequest, id: String) -> some View {
    VStack(alignment: .leading, spacing: OpenCodeSpacing.s8) {
      HStack {
        Text(AppCopy.text("composer.request.permission"))
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
        Spacer()
        Button(AppCopy.text("composer.request.review")) {
          store.send(.requestReviewTapped)
        }
        .font(OpenCodeFonts.font(.caption))
        .accessibilityIdentifier("session-review-requests")
        Button {
          store.send(.requestDockToggled(id))
        } label: {
          Image(systemName: "rectangle.compress.vertical")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppCopy.text("composer.request.fold"))
        .accessibilityIdentifier("request-fold-\(id)")
      }
      if !dock.isCollapsed(id) {
        Text(permission.action)
          .font(OpenCodeFonts.font(.headline))
          .foregroundStyle(OpenCodeColors.color(.textStrong))
        if !permission.resources.isEmpty {
          VStack(alignment: .leading, spacing: OpenCodeSpacing.s2) {
            ForEach(permission.resources.prefix(3), id: \.self) { resource in
              Text(resource)
                .font(OpenCodeFonts.font(.codeSmall))
                .lineLimit(2)
            }
          }
          .padding(OpenCodeSpacing.s8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(OpenCodeColors.color(.codeBand), in: .rect(cornerRadius: OpenCodeRadius.control))
        }
        HStack(spacing: OpenCodeSpacing.s8) {
          Button(AppCopy.text("session.requests.deny")) {
            store.send(.requestBarSendTapped)
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("request-dock-deny")
          Spacer()
          if !(permission.save?.isEmpty ?? true) {
            Button(AppCopy.text("session.requests.always")) {
              store.send(
                .permissionReplyTapped(id: id, decision: .always, message: nil)
              )
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("request-dock-always")
          }
          Button(AppCopy.text("session.requests.allow_once")) {
            store.send(.permissionReplyTapped(id: id, decision: .once, message: nil))
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("request-dock-allow-once")
        }
        .font(OpenCodeFonts.font(.footnote))
        .disabled(requests.respondingIDs.contains(id))
      }
      if let failure = requests.failures[id] {
        Text(failureLine(failure))
          .font(OpenCodeFonts.font(.caption))
          .foregroundStyle(OpenCodeColors.color(.danger))
          .accessibilityIdentifier("request-dock-error")
      }
    }
    .padding(.horizontal, OpenCodeSpacing.s12)
    .padding(.vertical, OpenCodeSpacing.s10)
    .background(OpenCodeColors.color(.surfaceStrong))
    .overlay(alignment: .top) {
      Rectangle().fill(OpenCodeColors.color(.border)).frame(height: 0.5)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("request-dock")
  }

  private func formPanel(_ form: FormRequest, id: String) -> some View {
    let collapsed = dock.isCollapsed(id)
    let answers = requests.answers[id] ?? form.defaultAnswers
    let selected = dock.field(for: form, answers: answers)
    return VStack(alignment: .leading, spacing: OpenCodeSpacing.s8) {
      HStack(spacing: OpenCodeSpacing.s8) {
        Text(origin(form))
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
        Spacer()
        if form.isQuestion, let selected, selected.count > 1 {
          Button {
            store.send(.requestPageChanged(-1))
          } label: {
            Image(systemName: "chevron.left")
          }
          .buttonStyle(.plain)
          .disabled(selected.page == 0)
          .accessibilityLabel(AppCopy.text("composer.request.previous"))
          Text(AppCopy.format("composer.request.page", selected.page + 1, selected.count))
            .font(OpenCodeFonts.font(.caption2))
            .foregroundStyle(OpenCodeColors.color(.textWeak))
          Button {
            store.send(.requestPageChanged(1))
          } label: {
            Image(systemName: "chevron.right")
          }
          .buttonStyle(.plain)
          .disabled(selected.page >= selected.count - 1)
          .accessibilityLabel(AppCopy.text("composer.request.next"))
        }
        Button(AppCopy.text("composer.request.review")) {
          store.send(.requestReviewTapped)
        }
        .font(OpenCodeFonts.font(.caption))
        .accessibilityIdentifier("session-review-requests")
        Button {
          store.send(.requestDockToggled(id))
        } label: {
          Image(systemName: collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppCopy.text("composer.request.fold"))
        .accessibilityIdentifier("request-fold-\(id)")
      }
      if !collapsed {
        if form.isQuestion, let selected {
          Text(questionText(selected.field, form: form))
            .font(OpenCodeFonts.font(.body))
            .foregroundStyle(OpenCodeColors.color(.textStrong))
            .fixedSize(horizontal: false, vertical: true)
          choices(selected.field, form: form)
        } else if let selected {
          Text(selected.field.title ?? selected.field.description ?? form.title)
            .font(OpenCodeFonts.font(.headline))
          choices(selected.field, form: form)
        }
      }
      if dock.showsSheet, !form.fitsDock {
        Button(AppCopy.text("composer.request.open_form")) {
          store.send(.requestReviewTapped)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("request-dock-open-form")
      }
      if let failure = requests.failures[id] {
        Text(failureLine(failure))
          .font(OpenCodeFonts.font(.caption))
          .foregroundStyle(OpenCodeColors.color(.danger))
          .accessibilityIdentifier("request-dock-error")
      }
    }
    .padding(.horizontal, OpenCodeSpacing.s12)
    .padding(.vertical, OpenCodeSpacing.s10)
    .background(OpenCodeColors.color(.surfaceStrong))
    .overlay(alignment: .top) {
      Rectangle().fill(OpenCodeColors.color(.border)).frame(height: 0.5)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("request-dock")
  }

  @ViewBuilder
  private func choices(_ field: FormField, form: FormRequest) -> some View {
    let value = requests.answers[form.id]?[field.key]
    let options = dockOptions(field)
    if !options.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(options, id: \.value) { option in
          Button {
            store.send(
              .requestValueChanged(
                formID: form.id,
                key: field.key,
                value: toggled(option.value, field: field, current: value)
              )
            )
          } label: {
            HStack(spacing: OpenCodeSpacing.s10) {
              Image(systemName: selectionSymbol(option.value, field: field, value: value))
                .foregroundStyle(OpenCodeColors.color(.textBody))
              VStack(alignment: .leading, spacing: 1) {
                Text(option.label)
                  .font(OpenCodeFonts.font(.body))
                  .foregroundStyle(OpenCodeColors.color(.textStrong))
                if let description = option.description {
                  Text(description)
                    .font(OpenCodeFonts.font(.caption))
                    .foregroundStyle(OpenCodeColors.color(.textWeak))
                }
              }
              Spacer()
            }
            .padding(.vertical, OpenCodeSpacing.s8)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("request-dock-option-\(option.value)")
          if option.value != options.last?.value {
            Divider().padding(.leading, 32)
          }
        }
      }
    }
  }

  private func dockOptions(_ field: FormField) -> [FormOption] {
    if field.type == .boolean {
      return [
        FormOption(value: "true", label: AppCopy.text("session.requests.yes")),
        FormOption(value: "false", label: AppCopy.text("session.requests.no")),
      ]
    }
    return field.options ?? []
  }

  private func selectionSymbol(
    _ option: String,
    field: FormField,
    value: FormValue?
  ) -> String {
    let selected: Bool
    switch value {
    case .string(let text): selected = text == option
    case .strings(let values): selected = values.contains(option)
    case .boolean(let flag): selected = String(flag) == option
    default: selected = false
    }
    if field.type == .multiselect {
      return selected ? "checkmark.square.fill" : "square"
    }
    return selected ? "checkmark.circle.fill" : "circle"
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

  private func questionText(_ field: FormField, form: FormRequest) -> String {
    field.description?.isEmpty == false
      ? field.description!
      : (field.title?.isEmpty == false ? field.title! : form.title)
  }

  private func origin(_ form: FormRequest) -> String {
    if form.isGlobal { return form.mcpServer ?? AppCopy.text("composer.request.global") }
    if form.sessionID == store.activeSessionID { return form.title }
    if let owner = store.family?.session(form.sessionID) {
      return owner.title
    }
    return form.title
  }

  private func failureLine(_ failure: RequestFailure) -> String {
    switch failure {
    case .validation: AppCopy.text("session.requests.validation.required")
    case .reply: AppCopy.text("session.requests.failed_reply")
    case .dismissal, .settledDismissal: AppCopy.text("session.requests.failed_dismiss")
    case .settled, .conflict: AppCopy.text("session.requests.settled")
    }
  }
}

/// The answer bar shares the native input but sends through the request workflow.
struct RequestAnswerBar: View {
  let store: StoreOf<SessionFeature>
  @State private var height: CGFloat = 36
  private var requests: SessionRequests { store.requests }
  private var dock: RequestDockState { store.requestDock }
  private var selectedID: String? { requests.selectedRequestID }
  private var canAnswer: Bool {
    guard let id = selectedID else { return false }
    return !requests.respondingIDs.contains(id)
  }

  private var placeholder: String {
    guard let id = selectedID else { return AppCopy.text("composer.placeholder") }
    if requests.permission(id) != nil {
      return AppCopy.text("composer.request.reason")
    }
    if let form = requests.form(id), !form.fitsDock {
      return AppCopy.text("composer.request.review_placeholder")
    }
    return AppCopy.text("composer.request.answer_placeholder")
  }

  var body: some View {
    VStack(spacing: OpenCodeSpacing.s6) {
      if let id = selectedID, let form = requests.form(id), !form.fitsDock {
        emptyAnswerBar
      } else {
        HStack(alignment: .bottom, spacing: OpenCodeSpacing.s8) {
          ComposerTextInput(
            text: Binding(
              get: { dock.answerText(for: requests) },
              set: { store.send(.requestAnswerChanged($0)) }
            ),
            height: $height,
            focusRequest: 0,
            placeholder: placeholder,
            isEnabled: canAnswer,
            onSend: { store.send(.requestBarSendTapped) }
          )
          .frame(minHeight: 36, maxHeight: 168)
          .frame(height: height)
          Button {
            store.send(.requestBarSendTapped)
          } label: {
            ZStack {
              Circle()
                .fill(canAnswer ? OpenCodeColors.color(.accent) : OpenCodeColors.color(.codeBand))
                .frame(width: 36, height: 36)
              if let id = selectedID, requests.respondingIDs.contains(id) {
                ProgressView().controlSize(.small).tint(OpenCodeColors.color(.canvas))
              } else {
                Image(systemName: "arrow.up")
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundStyle(canAnswer ? OpenCodeColors.color(.canvas) : OpenCodeColors.color(.textTertiary))
              }
            }
            .frame(minWidth: 48, minHeight: 48)
          }
          .buttonStyle(.plain)
          .disabled(!canAnswer)
          .accessibilityIdentifier("request-answer-send")
          .accessibilityLabel(AppCopy.text("composer.request.send_answer"))
        }
      }
      if let id = selectedID, requests.permission(id) != nil {
        Text(AppCopy.text("composer.request.deny_hint"))
          .font(OpenCodeFonts.font(.caption2))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
      }
    }
    .padding(.horizontal, OpenCodeSpacing.s12)
    .padding(.vertical, OpenCodeSpacing.s8)
    .background(OpenCodeColors.color(.surfaceStrong))
    .overlay(alignment: .top) {
      Rectangle().fill(OpenCodeColors.color(.border)).frame(height: 0.5)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("request-answer-bar")
  }

  private var emptyAnswerBar: some View {
    HStack {
      Text(AppCopy.text("composer.request.large_form"))
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.textWeak))
      Spacer()
      Button(AppCopy.text("composer.request.open_form")) {
        store.send(.requestReviewTapped)
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("request-answer-open-form")
    }
    .frame(minHeight: 48)
  }
}

struct QueuedInputsSheet: View {
  let store: StoreOf<SessionFeature>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        if store.pendingInputs.isEmpty {
          ContentUnavailableView(
            AppCopy.text("composer.queued.empty"),
            systemImage: "tray",
            description: Text(AppCopy.text("composer.queued.empty_detail"))
          )
        } else {
          List {
            ForEach(Array(store.pendingInputs.enumerated()), id: \.element.id) { index, input in
              VStack(alignment: .leading, spacing: OpenCodeSpacing.s6) {
                HStack(alignment: .firstTextBaseline, spacing: OpenCodeSpacing.s8) {
                  Text("\(index + 1).")
                    .font(OpenCodeFonts.font(.caption))
                    .foregroundStyle(OpenCodeColors.color(.textTertiary))
                  Text(input.text.isEmpty ? input.id : input.text)
                    .font(OpenCodeFonts.font(.body))
                    .lineLimit(3)
                  Spacer()
                  Text(
                    input.delivery == .steer
                      ? AppCopy.text("session.inputs.steering")
                      : AppCopy.text("session.inputs.queued")
                  )
                  .font(OpenCodeFonts.font(.caption2))
                  .foregroundStyle(OpenCodeColors.color(.textWeak))
                }
                HStack(spacing: OpenCodeSpacing.s8) {
                  if input.delivery == .queue {
                    Button(AppCopy.text("composer.queued.send_now")) {
                      store.send(.pendingInputSendNowTapped(input.id))
                    }
                    .font(OpenCodeFonts.font(.caption))
                    .accessibilityIdentifier("queued-send-now-\(input.id)")
                  } else {
                    Button(AppCopy.text("composer.queued.move_to_queue")) {
                      store.send(.pendingInputQueueTapped(input.id))
                    }
                    .font(OpenCodeFonts.font(.caption))
                    .accessibilityIdentifier("queued-move-to-queue-\(input.id)")
                  }
                  Button(AppCopy.text("common.copy")) {
                    store.send(.transcriptCopyTapped(input.text))
                  }
                  .font(OpenCodeFonts.font(.caption))
                  .accessibilityIdentifier("queued-copy-\(input.id)")
                  Spacer()
                  Button(AppCopy.text("composer.queued.cancel"), role: .destructive) {
                    store.send(.pendingInputCancelTapped(input.id))
                  }
                  .font(OpenCodeFonts.font(.caption))
                  .accessibilityIdentifier("queued-cancel-\(input.id)")
                }
                .buttonStyle(.borderless)
              }
              .accessibilityIdentifier("queued-message-\(input.id)")
            }
          }
        }
      }
      .navigationTitle(AppCopy.text("composer.queued.title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(AppCopy.text("common.done")) { dismiss() }
            .accessibilityIdentifier("queued-messages-close")
        }
      }
    }
    .accessibilityIdentifier("queued-messages-sheet")
  }
}

struct QuoteCommentSheet: View {
  let quote: ComposerQuote
  let save: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var comment: String

  init(quote: ComposerQuote, save: @escaping (String) -> Void) {
    self.quote = quote
    self.save = save
    _comment = State(initialValue: quote.comment ?? "")
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: OpenCodeSpacing.s12) {
        Text(quote.text)
          .font(OpenCodeFonts.font(.footnote))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
          .lineLimit(4)
        TextField(
          AppCopy.text("composer.quote.comment_placeholder"),
          text: $comment,
          axis: .vertical
        )
        .textFieldStyle(.roundedBorder)
        .lineLimit(2...5)
        .accessibilityIdentifier("quote-comment-field")
        Spacer()
      }
      .padding(OpenCodeSpacing.s20)
      .navigationTitle(AppCopy.text("composer.quote.comment_title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppCopy.text("common.cancel")) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(AppCopy.text("common.save")) {
            save(comment)
            dismiss()
          }
          .accessibilityIdentifier("quote-comment-save")
        }
      }
    }
    .presentationDetents([.medium])
    .accessibilityIdentifier("quote-comment-sheet")
  }
}

struct QuoteSelection: Identifiable {
  let id = UUID()
  let text: String
}

/// UIKit selection over the block, so a quote carries the exact characters the person selected.
struct QuoteSelectionSheet: View {
  let text: String
  let onQuote: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var selectedText: String

  init(text: String, onQuote: @escaping (String) -> Void) {
    self.text = text
    self.onQuote = onQuote
    _selectedText = State(initialValue: text)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        SelectableText(text: text, selection: $selectedText)
          .padding(OpenCodeSpacing.s12)
        Text(AppCopy.text("composer.quote.selected_hint"))
          .font(OpenCodeFonts.font(.caption2))
          .foregroundStyle(OpenCodeColors.color(.textWeak))
          .padding(.bottom, OpenCodeSpacing.s12)
      }
      .navigationTitle(AppCopy.text("composer.quote.title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppCopy.text("common.cancel")) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(AppCopy.text("composer.quote.add")) {
            onQuote(selectedText)
            dismiss()
          }
          .disabled(selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("quote-selection-confirm")
        }
      }
    }
    .accessibilityIdentifier("quote-selection-sheet")
  }
}

#if DEBUG
  /// Main-queue latency from a text change to the next run-loop turn. A composer keystroke that
  /// triggered transcript work would show up here as a long turn; normal typing stays sub-frame.
  @MainActor
  final class TypingLatencyProbe {
    static let shared = TypingLatencyProbe()

    private(set) var count = 0
    private(set) var totalMilliseconds = 0.0
    private(set) var maximumMilliseconds = 0.0
    private var changedAt: CFTimeInterval?

    func noteChange() {
      changedAt = CACurrentMediaTime()
      DispatchQueue.main.async { [weak self] in
        guard let self, let changedAt = self.changedAt else { return }
        self.changedAt = nil
        let elapsed = (CACurrentMediaTime() - changedAt) * 1_000
        self.count += 1
        self.totalMilliseconds += elapsed
        self.maximumMilliseconds = max(self.maximumMilliseconds, elapsed)
      }
    }

    var summary: String {
      guard count > 0 else { return "0" }
      let average = totalMilliseconds / Double(count)
      return String(format: "%.1f/%.1f/%d", average, maximumMilliseconds, count)
    }
  }
#endif

private struct SelectableText: UIViewRepresentable {
  let text: String
  @Binding var selection: String

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.text = text
    view.font = UIFont.preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.backgroundColor = UIColor(OpenCodeColors.color(.canvas))
    view.textColor = UIColor(OpenCodeColors.color(.textBody))
    view.tintColor = UIColor(OpenCodeColors.color(.accent))
    view.isEditable = false
    view.isSelectable = true
    view.alwaysBounceVertical = true
    view.accessibilityIdentifier = "quote-selection-text"
    view.delegate = context.coordinator
    DispatchQueue.main.async {
      view.selectAll(nil)
      context.coordinator.publish(view)
    }
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.parent = self
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: SelectableText
    init(parent: SelectableText) { self.parent = parent }

    func textViewDidChangeSelection(_ textView: UITextView) {
      publish(textView)
    }

    func publish(_ textView: UITextView) {
      guard let range = textView.selectedTextRange else { return }
      let selected = textView.text(in: range) ?? ""
      if parent.selection != selected {
        DispatchQueue.main.async {
          self.parent.selection = selected
        }
      }
    }
  }
}
