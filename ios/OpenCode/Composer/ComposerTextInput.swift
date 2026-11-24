import OpenCodeCore
import OpenCodeMedia
import SwiftUI
import UIKit

/// A focused UIKit text bridge. SwiftUI's `TextField` cannot preserve an IME's marked text while an
/// external draft changes, and it does not expose the selection a quote or a restored caret needs.
/// This view owns the text view, keeps marked composition intact, and reports Return as Send.
struct ComposerTextInput: UIViewRepresentable {
  @Binding var text: String
  @Binding var height: CGFloat
  let focusRequest: Int
  let placeholder: String
  let isEnabled: Bool
  let onSend: () -> Void
  var onPasteImages: ([Data]) -> Void = { _ in }
  var onPasteFiles: ([URL]) -> Void = { _ in }
  var onPasteText: (String) -> Void = { _ in }
  /// Reports the draft, the UTF-16 caret and whether an IME composition is open. The reducer
  /// never queries suggestions or commits text while marked text exists.
  var onCaretChanged: (String, Int?, Bool) -> Void = { _, _, _ in }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIView(context: Context) -> ComposerTextView {
    let view = ComposerTextView()
    view.delegate = context.coordinator
    view.font = UIFont.preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.backgroundColor = .clear
    view.textColor = UIColor(OpenCodeColors.color(.textStrong))
    view.tintColor = UIColor(OpenCodeColors.color(.accent))
    view.textContainerInset = UIEdgeInsets(top: 7, left: 4, bottom: 7, right: 4)
    view.textContainer.lineFragmentPadding = 0
    view.isScrollEnabled = false
    view.keyboardDismissMode = .interactive
    view.returnKeyType = .default
    view.autocorrectionType = .default
    view.spellCheckingType = .default
    view.accessibilityIdentifier = "composer-field"
    view.accessibilityLabel = placeholder
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    context.coordinator.textView = view
    context.coordinator.placeholder = placeholder
    view.placeholder = placeholder
    view.pasteHandler = context.coordinator
    return view
  }

  func updateUIView(_ view: ComposerTextView, context: Context) {
    context.coordinator.parent = self
    view.isEditable = isEnabled
    view.isUserInteractionEnabled = isEnabled
    view.font = UIFont.preferredFont(forTextStyle: .body)
    view.textColor = UIColor(OpenCodeColors.color(isEnabled ? .textStrong : .textWeak))
    view.tintColor = UIColor(OpenCodeColors.color(.accent))
    context.coordinator.updatePlaceholder(placeholder, isEmpty: view.text.isEmpty)
    context.coordinator.syncText(text, into: view)
    context.coordinator.applyFocusRequest(focusRequest, to: view)
    context.coordinator.updateHeight(view, binding: $height)
  }

  final class Coordinator: NSObject, UITextViewDelegate, ComposerPasteHandling {
    var parent: ComposerTextInput
    weak var textView: ComposerTextView?
    var placeholder = ""
    private var lastFocusRequest = 0
    private var isPublishing = false
    private var pendingExternalText: String?
    private var lastHeight: CGFloat = 0

    init(parent: ComposerTextInput) {
      self.parent = parent
    }

    func syncText(_ text: String, into view: UITextView) {
      if isPublishing { return }
      if view.markedTextRange != nil {
        if view.text != text { pendingExternalText = text }
        return
      }
      guard view.text != text else { return }
      let selection = view.selectedTextRange
      isPublishing = true
      view.text = text
      isPublishing = false
      if let selection {
        let start = view.offset(from: view.beginningOfDocument, to: selection.start)
        let end = view.offset(from: view.beginningOfDocument, to: selection.end)
        let length = (view.text as NSString).length
        if let newStart = view.position(from: view.beginningOfDocument, offset: min(start, length)),
          let newEnd = view.position(from: view.beginningOfDocument, offset: min(end, length))
        {
          view.selectedTextRange = view.textRange(from: newStart, to: newEnd)
        }
      }
      updatePlaceholder(placeholder, isEmpty: view.text.isEmpty)
      scrollCaretIfNeeded(view)
    }

    func applyFocusRequest(_ request: Int, to view: UIView) {
      guard request != lastFocusRequest else { return }
      lastFocusRequest = request
      guard request > 0 else { return }
      DispatchQueue.main.async {
        view.becomeFirstResponder()
      }
    }

    func updateHeight(_ view: UIView, binding: Binding<CGFloat>) {
      guard let view = view as? UITextView else { return }
      let width = max(view.bounds.width, 1)
      let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      let next = min(max(fitting.height, 36), 168)
      let scrolls = fitting.height > 168
      if view.isScrollEnabled != scrolls {
        view.isScrollEnabled = scrolls
        view.showsVerticalScrollIndicator = scrolls
        if !scrolls { view.setContentOffset(.zero, animated: false) }
      }
      if scrolls { scrollCaretIfNeeded(view) }
      guard abs(next - lastHeight) > 0.5 else { return }
      lastHeight = next
      DispatchQueue.main.async {
        if abs(binding.wrappedValue - next) > 0.5 { binding.wrappedValue = next }
      }
    }

    func scrollCaretIfNeeded(_ view: UITextView) {
      guard view.isScrollEnabled, let range = view.selectedTextRange else { return }
      let location = view.offset(from: view.beginningOfDocument, to: range.start)
      let length = view.offset(from: range.start, to: range.end)
      view.scrollRangeToVisible(NSRange(location: location, length: length))
    }

    func updatePlaceholder(_ text: String, isEmpty: Bool) {
      placeholder = text
      textView?.placeholder = isEmpty ? text : nil
      textView?.accessibilityLabel = text
    }

    func textViewDidChange(_ textView: UITextView) {
      guard !isPublishing else { return }
      isPublishing = true
      parent.text = textView.text
      isPublishing = false
      #if DEBUG
        TypingLatencyProbe.shared.noteChange()
      #endif
      if textView.markedTextRange == nil, let pending = pendingExternalText {
        pendingExternalText = nil
        if pending != textView.text { syncText(pending, into: textView) }
      }
      updatePlaceholder(placeholder, isEmpty: textView.text.isEmpty)
      if let view = textView as? ComposerTextView {
        updateHeight(view, binding: parent.$height)
        scrollCaretIfNeeded(view)
      }
      publishCaret(textView)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      scrollCaretIfNeeded(textView)
      publishCaret(textView)
    }

    private func publishCaret(_ textView: UITextView) {
      guard !isPublishing, let range = textView.selectedTextRange else { return }
      let caret = textView.offset(from: textView.beginningOfDocument, to: range.start)
      parent.onCaretChanged(textView.text, caret, textView.markedTextRange != nil)
    }

    func textView(
      _ textView: UITextView,
      shouldChangeTextIn range: NSRange,
      replacementText text: String
    ) -> Bool {
      guard text == "\n", textView.markedTextRange == nil else { return true }
      if let view = textView as? ComposerTextView, view.returnHasShift {
        view.returnHasShift = false
        return true
      }
      parent.onSend()
      return false
    }

    func paste(from view: ComposerTextView) -> Bool {
      let pasteboard = UIPasteboard.general
      if pasteboard.hasImages, let images = pasteboard.images {
        let data = images.compactMap { $0.jpegData(compressionQuality: 0.9) }
        if !data.isEmpty {
          parent.onPasteImages(data)
          return true
        }
      }
      if let urls = pasteboard.urls {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
          parent.onPasteFiles(files)
          return true
        }
      }
      if pasteboard.hasStrings, let text = pasteboard.string,
        MediaLimits.isLongPaste(text)
      {
        parent.onPasteText(text)
        return true
      }
      return false
    }
  }
}

protocol ComposerPasteHandling: AnyObject {
  func paste(from view: ComposerTextView) -> Bool
}

/// Tracks Shift+Return so the hardware keyboard can insert a newline while plain Return sends.
final class ComposerTextView: UITextView {
  weak var pasteHandler: ComposerPasteHandling?
  var placeholder: String? {
    didSet {
      placeholderLabel.text = placeholder
      placeholderLabel.isHidden = placeholder == nil
      setNeedsLayout()
    }
  }
  var returnHasShift = false
  private let placeholderLabel = UILabel()

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    placeholderLabel.font = UIFont.preferredFont(forTextStyle: .body)
    placeholderLabel.adjustsFontForContentSizeCategory = true
    placeholderLabel.textColor = UIColor(OpenCodeColors.color(.textTertiary))
    placeholderLabel.numberOfLines = 1
    placeholderLabel.isAccessibilityElement = false
    addSubview(placeholderLabel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let inset = textContainerInset
    let width = bounds.width - inset.left - inset.right
    placeholderLabel.frame = CGRect(
      x: inset.left,
      y: inset.top,
      width: max(0, width),
      height: placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    )
  }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for press in presses {
      guard let key = press.key, key.keyCode == .keyboardReturnOrEnter else { continue }
      returnHasShift = key.modifierFlags.contains(.shift)
    }
    super.pressesBegan(presses, with: event)
  }

  override func paste(_ sender: Any?) {
    if pasteHandler?.paste(from: self) == true { return }
    super.paste(sender)
  }
}
