import OpenCodeApp
import ComposableArchitecture
import SwiftUI

@main
struct OpenCodeApp: App {
  @State private var store: StoreOf<AppFeature>
  private let keychainSelfTest: String?

  init() {
    let configuration = AppLaunchConfiguration.current
    _store = State(initialValue: Store(initialState: configuration.initialState) { AppFeature() })
    #if DEBUG
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
    }
  }
}
