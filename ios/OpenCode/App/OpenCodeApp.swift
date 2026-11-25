import OpenCodeApp
import ComposableArchitecture
import OpenCodeComposer
import OpenCodeCore
import OpenCodeSettings
import OpenCodeTranscript
import SwiftUI
#if canImport(UIKit)
  import UIKit
#endif

@main
struct OpenCodeApp: App {
  @State private var store: StoreOf<AppFeature>
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("appearance-color-scheme") private var appearanceChoice = "system"
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
          $0.pasteboard = .liveValue
          $0.composerDrafts = UITestFixture.draftClient()
          if let payload = Self.uiTestPairingPayload {
            $0.pairingScanner = PairingScannerClient(
              start: {
                AsyncStream { continuation in
                  continuation.yield(.code(payload))
                  continuation.finish()
                }
              }
            )
          }
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
      if ProcessInfo.processInfo.environment["OPENCODE_UI_TEST_CLIPBOARD_IMAGE"] == "1",
        let image = UIImage(data: UITestFixture.syntheticImageData())
      {
        UIPasteboard.general.image = image
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

  private static var uiTestPairingPayload: String? {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "-uiTestPairingPayload"),
        arguments.indices.contains(index + 1)
      else { return nil }
      return arguments[index + 1]
    #else
      return nil
    #endif
  }

  private var preferredColorScheme: ColorScheme? {
    switch configuration.uiTestAppearance {
    case "dark": return .dark
    case "light": return .light
    default: break
    }
    switch appearanceChoice {
    case "dark": return .dark
    case "light": return .light
    default: return nil
    }
  }

  var body: some Scene {
    WindowGroup {
      ZStack {
        RootView(store: store)
          .preferredColorScheme(preferredColorScheme)
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
      .onReceive(
        NotificationCenter.default.publisher(
          for: UIApplication.didReceiveMemoryWarningNotification
        )
      ) { _ in
        Task { await MarkdownBlockCache.shared.clear() }
      }
      .onChange(of: scenePhase) { _, phase in
        store.send(.scenePhaseChanged(isActive: phase == .active))
      }
    }
  }
}
