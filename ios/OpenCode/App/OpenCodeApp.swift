import OpenCodeApp
import ComposableArchitecture
import SwiftUI
#if canImport(UIKit)
  import UIKit
#endif

@main
struct OpenCodeApp: App {
  @State private var store: StoreOf<AppFeature>
  @Environment(\.scenePhase) private var scenePhase
  private let configuration: AppLaunchConfiguration
  private let keychainSelfTest: String?

  init() {
    let configuration = AppLaunchConfiguration.current
    self.configuration = configuration
    _store = State(initialValue: Store(initialState: configuration.initialState) { AppFeature() })

    #if DEBUG
      if let clipboard = configuration.uiTestClipboard {
        UIPasteboard.general.string = clipboard
      }
      keychainSelfTest = KeychainSelfTest.runIfRequested()
      // Device-only probes print one classification line; nothing runs without its launch argument.
      _ = DeviceProbes.startIfRequested()
    #else
      keychainSelfTest = nil
    #endif
  }

  var body: some Scene {
    WindowGroup {
      ZStack {
        RootView(store: store)
        if let keychainSelfTest {
          Text(keychainSelfTest)
            .font(.caption2)
            .accessibilityIdentifier("keychain-probe-\(keychainSelfTest)")
        }
      }
      .task {
        store.send(.task)
        if let url = configuration.uiTestOpenURL {
          store.send(.openURL(url))
        }
      }
      .onOpenURL { url in
        store.send(.openURL(url.absoluteString))
      }
      .onChange(of: scenePhase) { _, phase in
        store.send(.scenePhaseChanged(isActive: phase == .active))
      }
    }
  }
}
