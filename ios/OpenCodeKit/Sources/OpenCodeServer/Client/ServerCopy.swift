import Foundation

/// The English copy the server layer raises. One place, so a later phase moves it into string
/// catalogs without hunting through the transport. Tests assert these strings; no code compares
/// them, branches on them or stores them.
public enum ServerCopy {
  public static let unreachable = "Couldn’t reach the OpenCode server"
  public static let folderGone = "The folder is gone"
  public static let credentialsRejected = "The server rejected these credentials."
  public static let invalidURL = "Enter a valid HTTP or HTTPS server URL."
  public static let eventStreamOversizedFrame = "The event stream sent an oversized frame."
  public static let eventStreamEnded = "The event stream ended."
  public static let eventStreamServerFailure = "The event stream reported a server failure."
  public static let eventStreamOverflow = "The event stream fell behind and reconnected."
  /// A 2xx that is a web page: not a credential or connectivity failure, and not a decode mismatch.
  public static let incompatibleAPI =
    "This address answered with a web page, not the OpenCode V2 API. Check that the address is the OpenCode server, and update OpenCode on your computer." 
  public static let toolFailed = "Tool failed"

  public static func httpStatus(_ status: Int) -> String {
    "The server returned HTTP \(status)."
  }

  public static func eventStreamStatus(_ status: Int) -> String {
    "The event stream returned HTTP \(status)."
  }

  public static func undecodable(_ name: String) -> String {
    "The \(name) does not match the current OpenCode V2 contract."
  }

  public static func unencodable(_ name: String) -> String {
    "The \(name) could not be encoded."
  }

  public static func unsupported(_ feature: String) -> String {
    "This server doesn’t support \(feature). Update OpenCode on your computer."
  }

  // Pairing.

  public static let pairingExpired =
    "This pairing code expired or was already used. Run `opencode pair --remote` again."
  public static let pairingUnsupported =
    "This server doesn’t support pairing links. Update OpenCode on your computer, or enter the server manually."
  public static let invalidPairingCode =
    "That isn’t an OpenCode pairing code. Run opencode pair --remote on your computer, then scan its QR code or paste the link it prints."

  public static func unusableAddress(_ address: String, reason: String) -> String {
    "Couldn’t use “\(address)” from this pairing code: it \(reason)."
  }

  public static func loopback(deviceName: String) -> String {
    "That server only listens on localhost, so this \(deviceName) can’t reach it. Run opencode pair --remote on your computer instead, which works from any network."
  }

  /// Why an address cannot be a server base URL, finishing “it …”.
  public static func addressReason(_ problem: PairingAddressProblem) -> String {
    switch problem {
    case .notAWebAddress: return "isn’t a web address"
    case .badScheme: return "doesn’t start with http:// or https://"
    case .noHost: return "has no host name"
    case .credentials: return "includes a user name or password"
    case .query: return "has a query or fragment"
    case .port: return "has a port outside 1–65535"
    case .path: return "has a path, and the server must be at the root of its address"
    }
  }
}

extension OpenCodeClientError {
  /// The user-facing sentence for this failure. Pairing failures keep their specific copy.
  public var copy: String {
    switch failure {
    case .status(401):
      return ServerCopy.credentialsRejected
    case .status(let status):
      return isLocationMissing ? ServerCopy.folderGone : ServerCopy.httpStatus(status)
    case .transport, .unreachable:
      return ServerCopy.unreachable
    case .invalidURL:
      return ServerCopy.invalidURL
    case .unsupported:
      return ServerCopy.unsupported("that")
    case .undecodable(let feature):
      return ServerCopy.undecodable(feature)
    case .incompatibleAPI:
      return ServerCopy.incompatibleAPI
    case .streamEnded:
      return ServerCopy.eventStreamEnded
    case .streamServerFailure:
      return ServerCopy.eventStreamServerFailure
    case .streamOversizedFrame:
      return ServerCopy.eventStreamOversizedFrame
    case .streamOverflow:
      return ServerCopy.eventStreamOverflow
    case .pairingExpired:
      return ServerCopy.pairingExpired
    case .pairingUnsupported:
      return ServerCopy.pairingUnsupported
    }
  }
}
