import OpenCodeApp
import ComposableArchitecture
import OpenCodeCore
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
  private let savedServerProbe: String?

  init() {
    let configuration = AppLaunchConfiguration.current
    self.configuration = configuration
    #if DEBUG
      let initialStore: StoreOf<AppFeature>
      if configuration.usesFixtureClient {
        let fixture = UITestFixture.make(mode: configuration.uiTestFixture ?? "connected")
        initialStore = withDependencies {
          $0.openCodeClient = fixture.client
          $0.sharedStore = fixture.storage
          $0.homeSnapshotStore = .inMemory()
          $0.networkPath = UITestFixture.path
          $0.uuidClient = UuidClient.incrementing()
          $0.dateClient = DateClient { Date(timeIntervalSince1970: 1_700_000_000) }
          $0.pasteboard = PasteboardClient(string: { nil })
        } operation: {
          Store(initialState: configuration.initialState) { AppFeature() }
        }
      } else {
        initialStore = Store(initialState: configuration.initialState) { AppFeature() }
      }
    #else
      let initialStore = Store(initialState: configuration.initialState) { AppFeature() }
    #endif
    _store = State(initialValue: initialStore)

    #if DEBUG
      if let clipboard = configuration.uiTestClipboard {
        UIPasteboard.general.string = clipboard
      }
      keychainSelfTest = KeychainSelfTest.runIfRequested()
      savedServerProbe = SavedServerProbe.runIfRequested()
      // Device-only probes print one classification line; nothing runs without its launch argument.
      _ = DeviceProbes.startIfRequested()
    #else
      keychainSelfTest = nil
      savedServerProbe = nil
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
        if let savedServerProbe {
          Text(savedServerProbe)
            .font(.caption2)
            .accessibilityIdentifier("saved-server-probe-\(savedServerProbe)")
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
