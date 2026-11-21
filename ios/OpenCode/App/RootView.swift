import ComposableArchitecture
import OpenCodeApp
import OpenCodeCore
import SwiftUI

struct RootView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    ZStack {
      OpenCodeColors.color(.canvas)
        .ignoresSafeArea()

      switch store.phase {
      case .disconnected:
        DisconnectedView { store.send(.connectTapped) }
      case .loading:
        LoadingView()
      case .failed(let failure):
        FailureView(failure: failure) { store.send(.retryTapped) }
      case .connected:
        ConnectedView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct DisconnectedView: View {
  let connect: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("OpenCode")
        .font(OpenCodeFonts.font(.largeTitle))
        .foregroundStyle(OpenCodeColors.color(.textStrong))

      Text("Keep your coding sessions moving from your phone.")
        .font(OpenCodeFonts.font(.body))
        .foregroundStyle(OpenCodeColors.color(.textBody))

      Text("No server is configured yet.")
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.textWeak))

      Button("Connect", action: connect)
        .font(OpenCodeFonts.font(.headline))
        .foregroundStyle(OpenCodeColors.color(.canvas))
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(OpenCodeColors.color(.accent), in: .rect(cornerRadius: 10, style: .continuous))
        .padding(.top, 8)
    }
    .padding(24)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("root-phase-disconnected")
  }
}

private struct LoadingView: View {
  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Connecting…")
        .font(OpenCodeFonts.font(.body))
        .foregroundStyle(OpenCodeColors.color(.textBody))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("root-phase-loading")
  }
}

private struct FailureView: View {
  let failure: ProbeFailure
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Couldn’t connect")
        .font(OpenCodeFonts.font(.title2))
        .foregroundStyle(OpenCodeColors.color(.textStrong))

      Text(message)
        .font(OpenCodeFonts.font(.body))
        .foregroundStyle(OpenCodeColors.color(.textBody))

      Button("Try Again", action: retry)
        .font(OpenCodeFonts.font(.headline))
        .foregroundStyle(OpenCodeColors.color(.link))
        .padding(.top, 8)
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("root-phase-failed")
  }

  private var message: String {
    switch failure {
    case .notConfigured:
      "No server is configured yet."
    case .unreachable:
      "Couldn’t reach the OpenCode server."
    case .rejected:
      "The server rejected these credentials."
    }
  }
}

private struct ConnectedView: View {
  var body: some View {
    VStack(spacing: 8) {
      Text("Connected")
        .font(OpenCodeFonts.font(.title2))
        .foregroundStyle(OpenCodeColors.color(.textStrong))
      Text("Sessions arrive in a later phase.")
        .font(OpenCodeFonts.font(.footnote))
        .foregroundStyle(OpenCodeColors.color(.textWeak))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("root-phase-connected")
  }
}
