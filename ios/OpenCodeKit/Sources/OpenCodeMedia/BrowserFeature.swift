import ComposableArchitecture
import Foundation
import OpenCodeCore

/// Experimental features this phase reads. Settings owns the visible switches; the defaults are off.
public struct MediaExperiments: Sendable {
  public var inAppBrowser: @Sendable () -> Bool
  /// DEBUG UI tests serve a loopback page; production never enables this.
  public var browserAllowsLoopback: @Sendable () -> Bool

  public init(
    inAppBrowser: @escaping @Sendable () -> Bool,
    browserAllowsLoopback: @escaping @Sendable () -> Bool = { false }
  ) {
    self.inAppBrowser = inAppBrowser
    self.browserAllowsLoopback = browserAllowsLoopback
  }

  public static var liveValue: MediaExperiments {
    MediaExperiments(
      inAppBrowser: {
        #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("-uiTestInAppBrowser") { return true }
        #endif
        return UserDefaults.standard.bool(forKey: "in-app-browser")
      },
      browserAllowsLoopback: {
        #if DEBUG
          return ProcessInfo.processInfo.arguments.contains("-uiTestBrowserLoopback")
        #else
          return false
        #endif
      }
    )
  }

  public static let testValue = MediaExperiments(inAppBrowser: { false })

  public static let enabledForTesting = MediaExperiments(
    inAppBrowser: { true },
    browserAllowsLoopback: { true }
  )
}

extension MediaExperiments: DependencyKey {}

extension DependencyValues {
  public var mediaExperiments: MediaExperiments {
    get { self[MediaExperiments.self] }
    set { self[MediaExperiments.self] = newValue }
  }
}

/// The in-app browser visit. It owns navigation presentation state only; the page itself lives in a
/// bounded `WKWebView` behind the Experimental switch. Every external handoff is a delegate action
/// so the session, not the page, decides where a URL goes.
@Reducer
public struct BrowserFeature: Sendable {
  @ObservableState
  public struct State: Equatable, Sendable, Identifiable {
    public var id: String
    public var openedURL: String
    public var url: String
    public var title: String
    public var allowsLoopback: Bool
    public var isLoading: Bool
    public var didFail: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var backRequest: Int
    public var forwardRequest: Int
    public var reloadRequest: Int
    public var scrollTopRequest: Int

    public init(id: String, url: String, allowsLoopback: Bool = false) {
      self.id = id
      self.openedURL = url
      self.url = url
      self.title = ""
      self.allowsLoopback = allowsLoopback
      self.isLoading = true
      self.didFail = false
      self.canGoBack = false
      self.canGoForward = false
      self.backRequest = 0
      self.forwardRequest = 0
      self.reloadRequest = 0
      self.scrollTopRequest = 0
    }

    /// The title the bar shows: the page's, or its host while loading.
    public var displayTitle: String {
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? (BrowserLinkPolicy.displayHost(url) ?? "") : trimmed
    }

    public var host: String { BrowserLinkPolicy.displayHost(url) ?? "" }

    public var shows: Bool { !openedURL.isEmpty }
  }

  public enum Action: Equatable, Sendable {
    case closeTapped
    case backTapped
    case forwardTapped
    case reloadTapped
    case addressTapped
    case navigated(url: String, title: String)
    case titleChanged(String)
    case loadingChanged(Bool)
    case loadFailed
    case canGoBackChanged(Bool)
    case canGoForwardChanged(Bool)
    case openInSystemTapped
    case delegate(Delegate)
  }

  public enum Delegate: Equatable, Sendable {
    case close
    case openExternally(URL)
    case pairingLink(URL)
  }

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .closeTapped:
        return .send(.delegate(.close))
      case .backTapped:
        state.backRequest += 1
        return .none
      case .forwardTapped:
        state.forwardRequest += 1
        return .none
      case .reloadTapped:
        state.reloadRequest += 1
        return .none
      case .addressTapped:
        state.scrollTopRequest += 1
        return .none
      case .navigated(let url, let title):
        state.url = url
        state.didFail = false
        if !title.isEmpty { state.title = title }
        return .none
      case .titleChanged(let title):
        state.title = title
        return .none
      case .loadingChanged(let loading):
        state.isLoading = loading
        if loading { state.didFail = false }
        return .none
      case .loadFailed:
        state.isLoading = false
        state.didFail = true
        return .none
      case .canGoBackChanged(let can):
        state.canGoBack = can
        return .none
      case .canGoForwardChanged(let can):
        state.canGoForward = can
        return .none
      case .openInSystemTapped:
        guard let url = URL(string: state.url) else { return .none }
        return .send(.delegate(.openExternally(url)))
      case .delegate:
        return .none
      }
    }
  }
}
