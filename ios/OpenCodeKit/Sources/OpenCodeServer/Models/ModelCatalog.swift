import Foundation

// MARK: - Models

/// One model a server offers (`GET /api/model`). `id` is the catalogue key, which may differ from
/// the provider's API model ID when sibling modes share one ID.
public struct ServerModel: Codable, Sendable, Equatable, Identifiable {
  public var modelID: String
  public var providerID: String
  public var name: String
  public var inputs: [String]
  public var contextLimit: Int?
  public var catalogID: String?
  public var variants: [String]
  public var canonicalProviderID: String?

  public init(
    modelID: String,
    providerID: String,
    name: String,
    inputs: [String] = [],
    contextLimit: Int? = nil,
    catalogID: String? = nil,
    variants: [String] = [],
    canonicalProviderID: String? = nil
  ) {
    self.modelID = modelID
    self.providerID = providerID
    self.name = name
    self.inputs = inputs
    self.contextLimit = contextLimit
    self.catalogID = catalogID
    self.variants = variants.filter { $0 != "default" }
    self.canonicalProviderID = canonicalProviderID
  }

  /// The catalogue key: unique per provider, unlike `modelID`.
  public var key: String { catalogID ?? modelID }
  public var id: String { "\(providerID)/\(key)" }

  public var ref: ModelRef { ref(nil) }

  public func ref(_ variant: String?) -> ModelRef {
    ModelRef(id: key, providerID: providerID, variant: variant)
  }

  public func matches(_ ref: ModelRef) -> Bool {
    providerID == ref.providerID && key == ref.id
  }

  /// Compact display name without a redundant vendor or umbrella word.
  public var shortName: String {
    Self.shortName(name, providerID: providerID, canonicalProviderID: canonicalProviderID)
  }

  static let vendorPrefixes = [
    "OpenCode Zen", "OpenCode", "GitHub Copilot", "OpenRouter", "Amazon Bedrock", "Amazon",
    "Google Vertex", "Google", "Anthropic", "OpenAI", "Meta AI", "Meta", "Microsoft", "Azure",
    "xAI", "Cohere", "Alibaba", "Moonshot AI", "Moonshot", "Zhipu AI", "Zhipu", "Fireworks AI",
    "Fireworks", "Novita", "NVIDIA", "DeepSeek", "Mistral AI", "Mistral",
  ]
  static let familyPrefixes = ["Claude", "Gemini", "Mistral", "DeepSeek", "Grok", "Llama", "Qwen"]
  static let genericTierWords: Set<String> = [
    "pro", "flash", "mini", "nano", "lite", "fast", "ultrafast", "ultra", "max", "plus", "turbo",
    "large", "medium", "small", "coder", "code", "instruct", "chat", "thinking", "reasoning",
    "preview", "experimental", "free", "open", "super", "lightning", "spark", "latest",
  ]

  static func shortName(_ raw: String, providerID: String, canonicalProviderID: String?) -> String {
    var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { return raw }
    var prefixes = vendorPrefixes
    if let canonicalProviderID { prefixes.insert(canonicalProviderID, at: 0) }
    for prefix in prefixes {
      if let stripped = stripPrefix(prefix, result, requireAlphabeticSubmodel: false) {
        result = stripped
        break
      }
    }
    for family in familyPrefixes {
      if let stripped = stripPrefix(family, result, requireAlphabeticSubmodel: true) {
        result = stripped
        break
      }
    }
    return result
  }

  private static func stripPrefix(
    _ prefix: String,
    _ text: String,
    requireAlphabeticSubmodel: Bool
  ) -> String? {
    guard text.count > prefix.count, text.lowercased().hasPrefix(prefix.lowercased()) else {
      return nil
    }
    let tail = String(text.dropFirst(prefix.count))
    guard let first = tail.first, first == " " || first == ":" || first == "/" else { return nil }
    let explicitDelimiter = tail.hasPrefix(":") || tail.hasPrefix(" /") || tail.hasPrefix("/")
    let remainder = tail.drop { $0 == " " || $0 == ":" || $0 == "/" || $0 == "-" }
    guard !remainder.isEmpty else { return nil }
    let firstToken = remainder.prefix { !$0.isWhitespace && $0 != "(" }
    guard let firstChar = firstToken.first, firstChar.isLetter else { return nil }
    if genericTierWords.contains(firstToken.lowercased()) { return nil }
    if requireAlphabeticSubmodel {
      guard firstToken.allSatisfy(\.isLetter) else { return nil }
    } else if !explicitDelimiter {
      // Without ":" or "/", a version-like next token belongs to the model name, not the vendor.
      if (prefix.caseInsensitiveCompare("DeepSeek") == .orderedSame
        || prefix.caseInsensitiveCompare("Mistral") == .orderedSame),
        !firstToken.allSatisfy(\.isLetter)
      {
        return nil
      }
    }
    return String(remainder)
  }
}

/// Reasoning variants, labelled and ordered the way the audited catalogue orders them.
public enum ModelVariant {
  private static let order = [
    "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
  ]

  public static func label(_ id: String) -> String {
    switch id {
    case "none": return "Off"
    case "xhigh": return "Extra High"
    case "max": return "Max"
    default:
      guard let first = id.first else { return id }
      return first.uppercased() + id.dropFirst()
    }
  }

  public static func sorted(_ ids: [String]) -> [String] {
    ids.enumerated().sorted { lhs, rhs in
      let left = order.firstIndex(of: lhs.element) ?? order.count + lhs.offset
      let right = order.firstIndex(of: rhs.element) ?? order.count + rhs.offset
      return left < right
    }.map(\.element)
  }
}

public struct ModelCatalog: Sendable, Equatable {
  public var models: [ServerModel]
  public var defaultModel: ServerModel?

  public init(models: [ServerModel], defaultModel: ServerModel? = nil) {
    self.models = models
    self.defaultModel = defaultModel
  }

  public var providers: [String] {
    var seen = Set<String>()
    return models.map(\.providerID).filter { seen.insert($0).inserted }
  }

  public var ambiguousShortNames: Set<String> {
    var counts: [String: Int] = [:]
    var seen = Set<String>()
    for model in models where seen.insert(model.id).inserted {
      counts[model.shortName, default: 0] += 1
    }
    return Set(counts.filter { $0.value > 1 }.keys)
  }

  public func model(_ ref: ModelRef) -> ServerModel? {
    models.first { $0.matches(ref) }
  }

  /// The model a new session starts on, with the level last picked for it.
  public func newSessionModel(levels: [String: String]) -> ModelRef? {
    guard let named = defaultModel else { return nil }
    let model = self.model(named.ref) ?? named
    return model.ref(model.savedLevel(levels))
  }
}

extension ServerModel {
  /// A variant is adjustable only when the server names one other than `default`.
  public var isAdjustable: Bool {
    variants.contains { $0 != "default" }
  }

  /// The level last picked for this model, while it still offers it.
  public func savedLevel(_ saved: [String: String]) -> String? {
    guard isAdjustable, let level = saved[id], level != "default", variants.contains(level) else {
      return nil
    }
    return level
  }
}

// MARK: - Agents, skills, commands and files

public struct ServerAgent: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var description: String?
  public var mode: String
  public var hidden: Bool
  public var model: ModelRef?

  public init(
    id: String,
    name: String? = nil,
    description: String? = nil,
    mode: String = "subagent",
    hidden: Bool = false,
    model: ModelRef? = nil
  ) {
    self.id = id
    self.name = name ?? id
    self.description = description
    self.mode = mode
    self.hidden = hidden
    self.model = model
  }

  public var displayName: String {
    name == id ? String(id.prefix(1)).uppercased() + String(id.dropFirst()) : name
  }

  public var isChoosable: Bool {
    !hidden && (mode == "primary" || mode == "all")
  }

  public static func choosable(_ agents: [ServerAgent]) -> [ServerAgent] {
    agents.filter(\.isChoosable)
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, description, mode, hidden, model
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    let name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    self.id = id.isEmpty ? name : id
    self.name = name.isEmpty ? id : name
    description = try container.decodeIfPresent(String.self, forKey: .description)
    mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "subagent"
    hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    model = try container.decodeIfPresent(ModelRef.self, forKey: .model)
  }
}

public struct ServerSkill: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var description: String?

  public init(id: String, name: String, description: String? = nil) {
    self.id = id
    self.name = name
    self.description = description
  }
}

public struct ServerCommand: Codable, Sendable, Equatable, Identifiable {
  public var name: String
  public var description: String?

  public var id: String { name }

  public init(name: String, description: String? = nil) {
    self.name = name
    self.description = description
  }
}

/// One file the server's `fs/find` returned. The path is a remote identifier.
public struct ServerFileSuggestion: Codable, Sendable, Equatable, Identifiable {
  public var path: String

  public var id: String { path }
  public var relativePath: String { path.hasPrefix("/") ? String(path.dropFirst()) : path }
  public var name: String { relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").last.map(String.init) ?? relativePath }

  /// The audited `file://` mention URI. A Windows drive path becomes `/C:/…`; nothing is read.
  public var uri: String {
    let normalized: String
    if path.utf8.count > 2, path[path.index(path.startIndex, offsetBy: 1)] == ":" {
      normalized = "/" + path.replacingOccurrences(of: "\\", with: "/")
    } else if path.hasPrefix("/") {
      normalized = path
    } else {
      normalized = "/" + path
    }
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
    return "file://" + (normalized.addingPercentEncoding(withAllowedCharacters: allowed) ?? normalized)
  }

  public init(path: String) {
    self.path = path
  }
}

public struct MentionRange: Codable, Sendable, Equatable {
  public var text: String
  public var start: Int
  public var end: Int

  public init(text: String, start: Int, end: Int) {
    self.text = text
    self.start = start
    self.end = end
  }
}

public struct AgentMention: Codable, Sendable, Equatable {
  public var name: String
  public var mention: MentionRange?

  public init(name: String, mention: MentionRange? = nil) {
    self.name = name
    self.mention = mention
  }
}

public struct SkillMention: Codable, Sendable, Equatable {
  public var id: String
  public var mention: MentionRange?

  public init(id: String, mention: MentionRange? = nil) {
    self.id = id
    self.mention = mention
  }
}

public struct FileMention: Codable, Sendable, Equatable {
  public var uri: String
  public var name: String?
  public var description: String?
  public var mention: MentionRange?

  public init(uri: String, name: String? = nil, description: String? = nil, mention: MentionRange? = nil) {
    self.uri = uri
    self.name = name
    self.description = description
    self.mention = mention
  }
}

/// Structured mentions carried by `POST /api/session/{id}/prompt`.
public struct AutocompleteMentions: Codable, Sendable, Equatable {
  public var files: [FileMention]
  public var agents: [AgentMention]
  public var skills: [SkillMention]

  public init(
    files: [FileMention] = [],
    agents: [AgentMention] = [],
    skills: [SkillMention] = []
  ) {
    self.files = files
    self.agents = agents
    self.skills = skills
  }

  public var isEmpty: Bool { files.isEmpty && agents.isEmpty && skills.isEmpty }
}
