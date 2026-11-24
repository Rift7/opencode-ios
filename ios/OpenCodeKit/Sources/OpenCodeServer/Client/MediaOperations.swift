import Foundation
import OpenCodeCore
import Synchronization

/// One folder entry the server names. Paths and names are display data; the app never treats them
/// as instructions to read a local file.
public struct DirectoryEntry: Codable, Equatable, Sendable, Identifiable {
  public var path: String
  public var type: String

  public init(path: String, type: String) {
    self.path = path
    self.type = type
  }

  public var id: String { path }
  public var name: String {
    path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").last.map(String.init) ?? path
  }
  public var isDirectory: Bool { type == "directory" }
}

public struct DirectoryListing: Equatable, Sendable {
  public var directory: String
  public var entries: [DirectoryEntry]

  public init(directory: String, entries: [DirectoryEntry]) {
    self.directory = directory
    self.entries = entries
  }
}

extension Operations {
  static let mediaCapability = "experimental-media-uri"

  /// `GET /api/experimental/media/<hash>` on the media pool: authenticated, uncached, bounded.
  static func mediaBlob(
    _ server: OpenCodeServer,
    hash: String,
    maximumBytes: Int64,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> Data {
    guard MediaBlobHash.isValid(hash) else { throw OpenCodeClientError(.invalidURL) }
    var headers = server.wireHeaders.filter { $0.key != "Authorization" }
    headers["Accept"] = "*/*"
    headers["X-OpenCode-Capabilities"] = mediaCapability
    return try await mediaData(
      server,
      path: "/api/experimental/media/\(hash)",
      headers: headers,
      timeout: 60,
      maximumBytes: maximumBytes,
      environment: environment,
      policy: policy,
      feature: "media"
    )
  }

  /// `GET /api/fs/read/<relative>?location[directory]=<location>`, authenticated and bounded.
  static func readFile(
    _ server: OpenCodeServer,
    directory: String,
    relativePath: String,
    maximumBytes: Int64,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> Data {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
      throw OpenCodeClientError(.invalidURL)
    }
    var headers = server.wireHeaders.filter { $0.key != "Authorization" }
    headers["Accept"] = "*/*"
    headers["X-OpenCode-Capabilities"] = mediaCapability
    let data = try await mediaData(
      server,
      path: "/api/fs/read/\(relativePath)",
      query: [("location[directory]", directory)],
      headers: headers,
      timeout: 30,
      maximumBytes: maximumBytes,
      environment: environment,
      policy: policy,
      feature: "file"
    )
    guard Int64(data.count) <= maximumBytes else {
      throw OpenCodeClientError(.unsupported)
    }
    return data
  }

  /// `GET /api/fs/list?path=…`: the folders inside a server directory. A file or a missing folder is
  /// an error; nothing here is interpreted as a local path.
  static func listDirectory(
    _ server: OpenCodeServer,
    path: String?,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> DirectoryListing {
    struct Payload: Decodable {
      struct Location: Decodable { var directory: String }
      var location: Location
      var data: [DirectoryEntry]
    }
    let payload: Payload = try await get(
      server,
      path: "/api/fs/list",
      query: path.map { [("path", $0)] } ?? [],
      environment: environment,
      policy: policy,
      feature: "folder"
    )
    return DirectoryListing(
      directory: payload.location.directory,
      entries: payload.data
    )
  }

  /// `POST /api/experimental/fs/write?location[directory]=…&path=<tmp>/uploads/<id>/<name>`.
  /// Discovery reads `/api/info` once; without `paths.tmp` uploads are unsupported. The same path is
  /// reused on a retry, so a repeated attempt overwrites rather than duplicates.
  static func uploadFile(
    _ server: OpenCodeServer,
    directory: String?,
    fileURL: URL,
    name: String,
    uploadID: String,
    environment: ClientEnvironment,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> String {
    let info: ServerInfo
    do {
      info = try await health(server, environment: environment, policy: .once)
    } catch let error as OpenCodeClientError {
      if case .status(404) = error.failure { throw OpenCodeClientError(.unsupported) }
      throw error
    }
    guard let tmp = info.paths?.tmp, !tmp.isEmpty else {
      throw OpenCodeClientError(.unsupported)
    }
    // One stable path per attachment: a retry overwrites the same server file instead of
    // creating a duplicate. The id is an app-made UUID, never a credential.
    let remoteID = uploadID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    let stableID = remoteID.isEmpty ? UUID().uuidString.lowercased() : remoteID
    let uploadPath = "/\(tmp.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
      + "/uploads/\(stableID)/\(sanitizedUploadName(name))"
    var query: [(name: String, value: String)] = []
    if let directory { query.append(("location[directory]", directory)) }
    query.append(("path", uploadPath))
    guard let request = server.request(
      path: "/api/experimental/fs/write",
      query: query,
      method: "POST",
      timeout: 120
    ) else { throw OpenCodeClientError(.invalidURL) }

    struct Written: Decodable {
      struct Data: Decodable { var path: String }
      var data: Data
    }

    let total = Int64(
      (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    )
    let step = max(total / 100, 64 * 1024)
    let lastReported = Mutex<Int64>(-1)
    let report: @Sendable (Int64) -> Void = { sent in
      let frontier = lastReported.withLock { previous -> Bool in
        guard sent >= total || sent - previous >= step else { return false }
        previous = sent
        return true
      }
      if frontier { progress(sent) }
    }

    let data = try await NetworkRetry.run(
      policy: .send,
      idempotency: .idempotent,
      clock: environment.clock,
      environment: environment.retryEnvironment
    ) { _ in
      let response: HTTPResponse
      do {
        response = try await environment.transport.upload(request, fileURL, report)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw OpenCodeClientError(.unreachable)
      }
      guard (200...299).contains(response.status) else {
        if response.status == 404, !String(decoding: response.body, as: UTF8.self).contains("Location") {
          throw OpenCodeClientError(.unsupported)
        }
        throw OpenCodeClientError(.status(response.status))
      }
      return response.body
    }
    do {
      return try JSONDecoder().decode(Written.self, from: data).data.path
    } catch {
      throw OpenCodeClientError(.undecodable(feature: "upload"))
    }
  }

  private static func mediaData(
    _ server: OpenCodeServer,
    path: String,
    query: [(name: String, value: String)] = [],
    headers: [String: String],
    timeout: TimeInterval,
    maximumBytes: Int64,
    environment: ClientEnvironment,
    policy: RetryPolicy,
    feature: String
  ) async throws -> Data {
    guard var request = server.request(
      path: path,
      query: query,
      timeout: timeout,
      redirectPolicy: .followSameOrigin
    ) else { throw OpenCodeClientError(.invalidURL) }
    for (name, value) in headers {
      request.headers[name] = value
    }
    let outgoing = request
    return try await NetworkRetry.run(
      policy: policy,
      idempotency: .idempotent,
      clock: environment.clock,
      environment: environment.retryEnvironment
    ) { _ in
      let stream: HTTPStream
      do {
        stream = try await environment.transport.open(outgoing)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw OpenCodeClientError(.unreachable)
      }
      guard (200...299).contains(stream.status) else {
        let body = await boundedPrefix(of: stream, maximumBytes: 64 * 1024)
        stream.close()
        throw OpenCodeClientError(
          .status(stream.status),
          isLocationMissing: OpenCodeClientError.isLocationMissing(
            status: stream.status,
            body: body
          )
        )
      }
      if let contentType = stream.header("content-type")?.lowercased(),
        contentType.hasPrefix("text/html")
      {
        stream.close()
        throw OpenCodeClientError(.incompatibleAPI(feature: feature))
      }
      if let declared = stream.header("content-length").flatMap(Int64.init),
        declared > maximumBytes
      {
        stream.close()
        throw OpenCodeClientError(.responseTooLarge(feature: feature))
      }
      var data = Data()
      var received: Int64 = 0
      do {
        for try await chunk in stream.chunks {
          received += Int64(chunk.count)
          if received > maximumBytes {
            stream.close()
            throw OpenCodeClientError(.responseTooLarge(feature: feature))
          }
          data.append(chunk)
        }
      } catch is CancellationError {
        stream.close()
        throw CancellationError()
      } catch let error as OpenCodeClientError {
        stream.close()
        throw error
      } catch {
        stream.close()
        throw OpenCodeClientError(.unreachable)
      }
      stream.close()
      return data
    }
  }

  /// Reads a bounded prefix for an error body and stops consuming immediately. The stream is
  /// closed by the caller.
  private static func boundedPrefix(of stream: HTTPStream, maximumBytes: Int) async -> Data {
    var data = Data()
    do {
      for try await chunk in stream.chunks {
        let remaining = maximumBytes - data.count
        if remaining <= 0 { break }
        data.append(chunk.prefix(remaining))
        if data.count >= maximumBytes { break }
      }
    } catch {
      return data
    }
    return data
  }

  private static func sanitizedUploadName(_ name: String) -> String {
    let cleaned = name
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .drop(while: { $0 == "." })
    return cleaned.isEmpty ? "file" : String(cleaned)
  }
}

/// The audited blob identity: a lowercase SHA-256 hex string.
enum MediaBlobHash {
  static func isValid(_ hash: String) -> Bool {
    hash.count == 64 && hash.allSatisfy { $0.isHexDigit }
  }
}
