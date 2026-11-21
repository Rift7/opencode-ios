import OpenCodeApp
import ComposableArchitecture
import SwiftUI

@main
struct OpenCodeApp: App {
  @State private var store: StoreOf<AppFeature>

  init() {
    let configuration = AppLaunchConfiguration.current
    _store = State(initialValue: Store(initialState: configuration.initialState) { AppFeature() })
  }

  var body: some Scene {
    WindowGroup {
      RootView(store: store)
    }
  }
}
