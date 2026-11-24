import ComposableArchitecture
import OpenCodeCore
import OpenCodeMedia
import SwiftUI
import WebKit

/// The audited in-app browser: public pages only, a non-persistent store per visit, no injected
/// credentials, no script bridge and no file access. A link or a response the page can't show is
/// handed to the session, which opens it in the system browser or the app that owns it.
struct BrowserSheet: View {
  @Bindable var store: StoreOf<BrowserFeature>
  let onClose: () -> Void
  let onOpenExternal: (URL) -> Void
  let onPairing: (URL) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement()
          .accessibilityIdentifier("browser")
        addressBar
        BrowserWebView(
          store: store,
          allowsLoopback: store.allowsLoopback,
          onOpenExternal: onOpenExternal,
          onPairing: onPairing
        )
        .overlay {
          if store.didFail {
            VStack(spacing: OpenCodeSpacing.s12) {
              Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
              Text(AppCopy.text("browser.load_failed"))
                .font(OpenCodeFonts.font(.body))
              Button(AppCopy.text("common.try_again")) {
                store.send(.reloadTapped)
              }
              .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OpenCodeColors.color(.canvas))
            .accessibilityIdentifier("browser-load-failed")
          }
        }
      }
      .navigationBarHidden(true)
      .background(OpenCodeColors.color(.canvas))
      .safeAreaInset(edge: .bottom, spacing: 0) {
        Rectangle()
          .fill(OpenCodeColors.color(.surfaceStrong))
          .frame(height: 0)
      }
    }
  }

  private var addressBar: some View {
    VStack(spacing: OpenCodeSpacing.s6) {
      HStack(spacing: OpenCodeSpacing.s6) {
        Button {
          onClose()
        } label: {
          Image(systemName: "xmark")
            .frame(width: 40, height: 44)
        }
        .accessibilityLabel(AppCopy.text("browser.close"))
        .accessibilityIdentifier("browser-close")
        Button {
          store.send(.backTapped)
        } label: {
          Image(systemName: "chevron.left")
            .frame(width: 40, height: 44)
        }
        .disabled(!store.canGoBack)
        .accessibilityLabel(AppCopy.text("browser.back"))
        Button {
          store.send(.forwardTapped)
        } label: {
          Image(systemName: "chevron.right")
            .frame(width: 40, height: 44)
        }
        .disabled(!store.canGoForward)
        .accessibilityLabel(AppCopy.text("browser.forward"))
        Button {
          store.send(.addressTapped)
        } label: {
          VStack(alignment: .leading, spacing: 1) {
            Text(store.displayTitle)
              .font(OpenCodeFonts.font(.footnote))
              .foregroundStyle(OpenCodeColors.color(.textStrong))
              .lineLimit(1)
            Text(store.host)
              .font(OpenCodeFonts.font(.caption2))
              .foregroundStyle(OpenCodeColors.color(.textWeak))
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .accessibilityLabel(AppCopy.text("browser.scroll_top"))
        Button {
          store.send(.reloadTapped)
        } label: {
          Image(systemName: "arrow.clockwise")
            .frame(width: 40, height: 44)
        }
        .accessibilityLabel(AppCopy.text("browser.reload"))
        Button {
          if let url = URL(string: store.url) { onOpenExternal(url) }
        } label: {
          Image(systemName: "safari")
            .frame(width: 40, height: 44)
        }
        .accessibilityLabel(AppCopy.text("browser.open_safari"))
      }
      .buttonStyle(.plain)
      .foregroundStyle(OpenCodeColors.color(.textBody))
      if store.isLoading {
        ProgressView()
          .progressViewStyle(.linear)
          .tint(OpenCodeColors.color(.accent))
      }
    }
    .padding(.horizontal, OpenCodeSpacing.s6)
    .padding(.vertical, OpenCodeSpacing.s4)
    .background(OpenCodeColors.color(.surfaceStrong))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(OpenCodeColors.color(.border))
        .frame(height: 0.5)
    }
  }
}

private struct BrowserWebView: UIViewRepresentable {
  let store: StoreOf<BrowserFeature>
  let allowsLoopback: Bool
  let onOpenExternal: (URL) -> Void
  let onPairing: (URL) -> Void

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.preferences.isElementFullscreenEnabled = true
    configuration.allowsInlineMediaPlayback = true
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.uiDelegate = context.coordinator
    view.allowsBackForwardNavigationGestures = true
    view.isOpaque = false
    view.backgroundColor = .clear
    if let url = URL(string: store.url) {
      view.load(URLRequest(url: url))
    }
    context.coordinator.webView = view
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {
    context.coordinator.allowsLoopback = allowsLoopback
    if context.coordinator.backRequest != store.backRequest {
      context.coordinator.backRequest = store.backRequest
      if view.canGoBack { view.goBack() }
    }
    if context.coordinator.forwardRequest != store.forwardRequest {
      context.coordinator.forwardRequest = store.forwardRequest
      if view.canGoForward { view.goForward() }
    }
    if context.coordinator.reloadRequest != store.reloadRequest {
      context.coordinator.reloadRequest = store.reloadRequest
      view.reload()
    }
    if context.coordinator.scrollTopRequest != store.scrollTopRequest {
      context.coordinator.scrollTopRequest = store.scrollTopRequest
      view.evaluateJavaScript("window.scrollTo({ top: 0, behavior: 'instant' })", completionHandler: nil)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      store: store,
      allowsLoopback: allowsLoopback,
      onOpenExternal: onOpenExternal,
      onPairing: onPairing
    )
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let store: StoreOf<BrowserFeature>
    var allowsLoopback: Bool
    let onOpenExternal: (URL) -> Void
    let onPairing: (URL) -> Void
    weak var webView: WKWebView?
    var backRequest = 0
    var forwardRequest = 0
    var reloadRequest = 0
    var scrollTopRequest = 0

    init(
      store: StoreOf<BrowserFeature>,
      allowsLoopback: Bool,
      onOpenExternal: @escaping (URL) -> Void,
      onPairing: @escaping (URL) -> Void
    ) {
      self.store = store
      self.allowsLoopback = allowsLoopback
      self.onOpenExternal = onOpenExternal
      self.onPairing = onPairing
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if navigationAction.shouldPerformDownload {
        if let url = navigationAction.request.url {
          onOpenExternal(url)
        }
        decisionHandler(.cancel)
        return
      }
      let isUserTap = navigationAction.navigationType == .linkActivated
      let decision = BrowserNavigationPolicy.decide(
        url: navigationAction.request.url?.absoluteString,
        isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
        isUserTap: isUserTap,
        allowsLoopback: allowsLoopback
      )
      switch decision {
      case .allow:
        decisionHandler(.allow)
      case .cancel:
        decisionHandler(.cancel)
      case .openInSystem(let url):
        if let url = URL(string: url) { onOpenExternal(url) }
        decisionHandler(.cancel)
      case .pair(let url):
        if let url = URL(string: url) { onPairing(url) }
        decisionHandler(.cancel)
      }
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationResponse: WKNavigationResponse,
      decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
      let disposition = (navigationResponse.response as? HTTPURLResponse)?
        .value(forHTTPHeaderField: "Content-Disposition")
      if BrowserNavigationPolicy.handsToSystem(
        canShow: navigationResponse.canShowMIMEType,
        disposition: disposition
      ) {
        if let url = navigationResponse.response.url {
          onOpenExternal(url)
        }
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      store.send(.loadingChanged(true))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      store.send(.loadingChanged(false))
      store.send(.navigated(url: webView.url?.absoluteString ?? store.url, title: webView.title ?? ""))
      store.send(.canGoBackChanged(webView.canGoBack))
      store.send(.canGoForwardChanged(webView.canGoForward))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
      store.send(.loadingChanged(false))
      store.send(.loadFailed)
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: any Error
    ) {
      store.send(.loadingChanged(false))
      store.send(.loadFailed)
    }

    func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if let url = navigationAction.request.url {
        let decision = BrowserNavigationPolicy.decide(
          url: url.absoluteString,
          isMainFrame: true,
          isUserTap: navigationAction.navigationType == .linkActivated,
          allowsLoopback: allowsLoopback
        )
        if case .allow = decision { webView.load(navigationAction.request) } else {
          onOpenExternal(url)
        }
      }
      return nil
    }
  }
}

/// The system hand-off used by the browser bar and its navigation delegates.
enum OpenURLAccess {
  @MainActor
  static func open(_ url: URL) -> Bool {
    UIApplication.shared.open(url, options: [:], completionHandler: nil)
    return true
  }
}
