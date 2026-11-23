import Foundation
import OpenCodeServer

/// Pure transcript reconciliation: authoritative windows replace their durable range, older pages
/// splice through overlapping IDs, and live content events upsert parts by the server's identity.
public enum TranscriptProjection {
  /// Splices a newest-first-decoded window (already oldest-first) into what is shown.
  public static func mergeNewest(
    fetched: [TranscriptItem],
    existing: [TranscriptItem],
    complete: Bool = false,
    preserveInProgress: Bool = true
  ) -> [TranscriptItem] {
    if fetched.isEmpty, !complete { return existing }
    let ids = Set(fetched.map(\.id))
    let windowStart = complete ? 0 : existing.firstIndex { ids.contains($0.id) }
    var older: [TranscriptItem] = []
    var trailing: [TranscriptItem] = []
    var retained: [TranscriptItem] = []
    if let windowStart {
      older = Array(existing[..<windowStart]).filter { !ids.contains($0.id) }
    }
    let scanStart = windowStart ?? 0
    for item in existing[scanStart...] where !ids.contains(item.id) {
      if preserveInProgress, item.isInProgressText {
        retained.append(item)
      } else if case .info(let id, _) = item, id.hasPrefix("info-") {
        trailing.append(item)
      }
    }
    var merged = older + fetched
    if retained.isEmpty { return merged + trailing }

    // Keep an unpersisted part before the next surviving row rather than moving it behind a later
    // steering message on every snapshot.
    let survivors = ids
    let nextSurvivor = nextSurvivingID(after: retained, in: existing, survivors: survivors)
    var buckets: [Int: [TranscriptItem]] = [:]
    for item in retained {
      let insertion: Int
      if let survivor = nextSurvivor[item.id], let index = merged.firstIndex(where: { $0.id == survivor }) {
        insertion = index
      } else if let index = merged.lastIndex(where: { messageID(of: $0) == item.messageID }) {
        insertion = index + 1
      } else {
        insertion = merged.count
      }
      buckets[insertion, default: []].append(item)
    }
    var result: [TranscriptItem] = []
    result.reserveCapacity(merged.count + retained.count)
    for index in 0...merged.count {
      result.append(contentsOf: buckets[index] ?? [])
      if index < merged.count { result.append(merged[index]) }
    }
    return result + trailing
  }

  /// Splices an older page (oldest first) before its earliest overlapping row. `nil` means the
  /// page does not reach the loaded rows yet and another cursor step must seek the overlap.
  public static func mergeOlder(
    page: [TranscriptItem],
    existing: [TranscriptItem],
    insertionAnchorID: String? = nil,
    reachedLoadedItems: Bool
  ) -> [TranscriptItem]? {
    guard !page.isEmpty else { return existing }
    let existingIDs = Set(existing.map(\.id))
    let pageIDs = Set(page.map(\.id))
    let overlap = existingIDs.intersection(pageIDs)
    if overlap.isEmpty {
      guard reachedLoadedItems || existing.isEmpty else { return nil }
      var insertion = existing.count
      if let insertionAnchorID, let index = existing.firstIndex(where: { $0.id == insertionAnchorID }) {
        insertion = index
      }
      return Array(existing[..<insertion]) + page + Array(existing[insertion...])
    }
    var merged = existing
    let anchor = existing.firstIndex { overlap.contains($0.id) } ?? 0
    var insertion = anchor
    for item in page where !existingIDs.contains(item.id) {
      merged.insert(item, at: insertion)
      insertion += 1
    }
    return merged
  }

  /// Applies one batch of live content events. An item that is already present keeps its slot.
  public static func apply(
    events: [LiveContentEvent],
    to items: inout [TranscriptItem]
  ) {
    for event in events {
      switch event {
      case .stepStarted, .stepStreamed, .stepEnded,
        .reasoningStarted, .reasoningDelta, .reasoningEnded:
        continue

      case .textStarted(let messageID, let ordinal):
        let id = "\(messageID)-text-\(ordinal)"
        if index(of: id, in: items) == nil {
          items.append(.assistantMarkdown(id: id, text: "", inProgress: true))
        }

      case .textDelta(let messageID, let ordinal, let delta, let accumulated):
        let id = "\(messageID)-text-\(ordinal)"
        if let index = index(of: id, in: items),
          case .assistantMarkdown(_, let text, let inProgress) = items[index]
        {
          // REST may have already settled this part while the delta was queued.
          guard inProgress else { continue }
          items[index] = .assistantMarkdown(
            id: id,
            text: accumulated ?? (text + delta),
            inProgress: true
          )
        } else {
          items.append(
            .assistantMarkdown(id: id, text: accumulated ?? delta, inProgress: true)
          )
        }

      case .textEnded(let messageID, let ordinal, let text):
        let id = "\(messageID)-text-\(ordinal)"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          items.removeAll { $0.id == id }
        } else if let index = index(of: id, in: items) {
          guard case .assistantMarkdown(_, _, let inProgress) = items[index], inProgress else {
            continue
          }
          items[index] = .assistantMarkdown(id: id, text: trimmed, inProgress: false)
        } else {
          items.append(.assistantMarkdown(id: id, text: trimmed, inProgress: false))
        }

      case .toolInputStarted(let messageID, let toolID, let name):
        let id = "\(messageID)-tool-\(toolID)"
        guard !isSettledTool(id, in: items) else { continue }
        updateTool(id: id, messageID: messageID, in: &items) { call in
          call.name = name
          call.status = .streaming
        }

      case .toolInputDelta(let messageID, let toolID, let delta):
        let id = "\(messageID)-tool-\(toolID)"
        guard !isSettledTool(id, in: items) else { continue }
        updateTool(id: id, messageID: messageID, in: &items) { call in
          call.status = .streaming
          call.inputText += delta
        }

      case .toolInputEnded(let messageID, let toolID, let text):
        let id = "\(messageID)-tool-\(toolID)"
        guard !isSettledTool(id, in: items) else { continue }
        updateTool(id: id, messageID: messageID, in: &items) { call in
          call.inputText = text
        }

      case .toolCalled(let messageID, let toolID, let input):
        let id = "\(messageID)-tool-\(toolID)"
        guard !isSettledTool(id, in: items) else { continue }
        updateTool(id: id, messageID: messageID, in: &items) { call in
          call.status = .running
          call.input = input.bounded()
        }

      case .toolProgress(let messageID, let toolID, let metadata):
        let id = "\(messageID)-tool-\(toolID)"
        guard !isSettledTool(id, in: items) else { continue }
        updateTool(id: id, messageID: messageID, in: &items) { call in
          call.status = .running
          call.metadata.merge(
            metadata.mapValues { $0.bounded() },
            uniquingKeysWith: { _, new in new }
          )
        }

      case .toolSucceeded(let messageID, let toolID, let output, let metadata):
        let id = "\(messageID)-tool-\(toolID)"
        guard !isSettledTool(id, in: items) else { continue }
        updateTool(id: id, messageID: messageID, in: &items) { call in
          call.status = .completed
          call.output = output.map { TranscriptDecoder.bounded($0, 20_000) }
          call.metadata.merge(
            metadata.mapValues { $0.bounded() },
            uniquingKeysWith: { _, new in new }
          )
          call.completedAt = Date()
        }

      case .toolFailed(let messageID, let toolID, let error, let errorType, let output, let metadata):
        let id = "\(messageID)-tool-\(toolID)"
        guard !isSettledTool(id, in: items) else { continue }
        updateTool(id: id, messageID: messageID, in: &items) { call in
          call.status = .error
          call.error = error
          call.errorType = errorType
          call.output = output.map { TranscriptDecoder.bounded($0, 20_000) }
          call.metadata.merge(
            metadata.mapValues { $0.bounded() },
            uniquingKeysWith: { _, new in new }
          )
          call.completedAt = Date()
        }
      }
    }
  }

  public static func messageID(of item: TranscriptItem) -> String { item.messageID }

  private static func index(of id: String, in items: [TranscriptItem]) -> Int? {
    items.firstIndex { $0.id == id }
  }

  private static func isSettledTool(_ id: String, in items: [TranscriptItem]) -> Bool {
    guard let index = index(of: id, in: items), case .tool(_, let call) = items[index] else {
      return false
    }
    return call.status == .completed || call.status == .error
  }

  private static func updateTool(
    id: String,
    messageID: String,
    in items: inout [TranscriptItem],
    _ transform: (inout TranscriptToolCall) -> Void
  ) {
    if let index = index(of: id, in: items), case .tool(_, var call) = items[index] {
      transform(&call)
      items[index] = .tool(id: id, call: call)
    } else {
      var call = TranscriptToolCall(
        callID: id,
        messageID: messageID,
        name: "tool",
        status: .streaming
      )
      transform(&call)
      items.append(.tool(id: id, call: call))
    }
  }

  private static func nextSurvivingID(
    after retained: [TranscriptItem],
    in existing: [TranscriptItem],
    survivors: Set<String>
  ) -> [String: String] {
    let retainedIDs = Set(retained.map(\.id))
    var result: [String: String] = [:]
    var successor: String?
    for item in existing.reversed() {
      if retainedIDs.contains(item.id) {
        if let successor { result[item.id] = successor }
      } else if survivors.contains(item.id) {
        successor = item.id
      }
    }
    return result
  }
}
