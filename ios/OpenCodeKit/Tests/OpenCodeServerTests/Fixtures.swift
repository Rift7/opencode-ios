import Foundation
import OpenCodeCore
import OpenCodeServer
import Synchronization

/// Records the requests a scripted transport saw, in order.
final class RequestLog: Sendable {
  private let state = Mutex<[HTTPRequest]>([])

  var requests: [HTTPRequest] {
    state.withLock { $0 }
  }

  func append(_ request: HTTPRequest) {
    state.withLock { $0.append(request) }
  }
}

enum Fixtures {
  static func transport(
    log: RequestLog = RequestLog(),
    handler: @escaping @Sendable (HTTPRequest, Int) async throws -> (status: Int, body: Data)
  ) -> HTTPTransport {
    HTTPTransport(
      send: { request in
        log.append(request)
        let index = log.requests.count
        let reply = try await handler(request, index)
        return HTTPResponse(status: reply.status, headers: [:], body: reply.body, finalURL: request.url)
      },
      open: { _ in throw TransportError.blocked }
    )
  }

  static func json(_ text: String, status: Int = 200) -> (status: Int, body: Data) {
    (status, Data(text.utf8))
  }

  static func session(
    id: String,
    title: String? = nil,
    parentID: String? = nil,
    archived: Double? = nil,
    directory: String = "/work/box"
  ) -> String {
    var fields = [
      #""id":"\#(id)""#,
      #""projectID":"p1""#,
      #""time":{"updated":1750000000000\#(archived.map { #","archived":\#($0)"# } ?? "")}"#,
      #""location":{"directory":"\#(directory)"}"#,
    ]
    if let title { fields.append(#""title":"\#(title)""#) }
    if let parentID { fields.append(#""parentID":"\#(parentID)""#) }
    return "{" + fields.joined(separator: ",") + "}"
  }

  static let code = "Pair-123_xyz"
}
