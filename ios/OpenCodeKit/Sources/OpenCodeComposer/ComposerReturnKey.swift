import Foundation

/// The one rule for a plain Return in a native text input. Shift+Return always inserts a new line;
/// a marked IME composition is never interrupted; otherwise the preference decides between sending
/// and inserting a new line.
public enum ComposerReturnKey {
  public enum Action: Equatable, Sendable {
    case send
    case insertNewline
    case passThrough
  }

  public static func action(
    replacement: String,
    markedText: Bool,
    shift: Bool,
    returnSends: Bool
  ) -> Action {
    guard replacement == "\n" else { return .passThrough }
    guard !markedText else { return .passThrough }
    if shift { return .insertNewline }
    return returnSends ? .send : .insertNewline
  }
}
