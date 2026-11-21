import Foundation

/// One project on the server (`Project.Info`). `directory` is the canonical folder.
public struct ServerProject: Sendable, Equatable, Codable {
  public var id: String
  public var name: String
  public var directory: String
  /// Repository name from the git origin remote, when the server reports one.
  public var repository: String?
  public var icon: ProjectIcon?

  public init(id: String, name: String, directory: String, repository: String? = nil, icon: ProjectIcon? = nil) {
    self.id = id
    self.name = name
    self.directory = directory
    self.repository = repository
    self.icon = icon
  }

  /// The uppercase fallback initial for this project's tile.
  public var initial: String {
    ProjectName.initial(name)
  }

  public struct ProjectIcon: Sendable, Equatable, Codable {
    public var url: String?
    public var override: String?
    public var color: String?

    public init(url: String? = nil, override: String? = nil, color: String? = nil) {
      self.url = Self.nonEmpty(url)
      self.override = Self.nonEmpty(override)
      self.color = Self.nonEmpty(color)
    }

    public var isEmpty: Bool { url == nil && override == nil && color == nil }

    private static func nonEmpty(_ value: String?) -> String? {
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return trimmed.isEmpty ? nil : trimmed
    }
  }
}

/// Naming rules shared by the project list and the session header. Copy stays English data here;
/// the screen that shows it localizes in its own phase.
public enum ProjectName {
  /// A person's name for the project, else the repository slug, else the folder's name.
  public static func displayName(name: String?, repository: String?, directory: String) -> String {
    if let name = nonEmpty(name) { return name }
    if let slug = repositorySlug(repository) { return slug }
    let folder = folderName(directory)
    return folder.isEmpty ? directory : folder
  }

  /// The last path component of a repository remote, when it names one.
  public static func repositorySlug(_ raw: String?) -> String? {
    guard let value = nonEmpty(raw) else { return nil }
    if !value.contains("/") && !value.contains(":") { return value }
    if value.lowercased().hasPrefix("file:") { return nil }
    if value.contains("://") {
      guard let components = URLComponents(string: value), components.host != nil else { return nil }
      return lastSegment(components.path)
    }
    if let colon = value.firstIndex(of: ":") {
      let head = String(value[..<colon])
      let path = String(value[value.index(after: colon)...])
      guard let at = head.firstIndex(of: "@"), at != head.startIndex, head.index(after: at) < head.endIndex,
        !head.contains("/")
      else { return nil }
      return lastSegment(path)
    }
    return lastSegment(value)
  }

  public static func folderName(_ directory: String) -> String {
    lastSegment(directory) ?? ""
  }

  /// The single-letter fallback initial (`opencode-console` → `C`, `opencode` → `O`).
  public static func initial(_ name: String) -> String {
    let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return "?" }
    let base = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? raw
    let stripped = stripOrgPrefix(base)
    if let letter = stripped.first(where: { $0.isLetter || $0.isNumber }) {
      return String(letter).uppercased()
    }
    return stripped.first.map { String($0).uppercased() } ?? "?"
  }

  private static func lastSegment(_ path: String) -> String? {
    path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
  }

  private static func stripOrgPrefix(_ text: String) -> String {
    guard let slash = text.firstIndex(of: "/") else { return text }
    let after = text[text.index(after: slash)...]
    return after.isEmpty ? text : String(after)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// `{id, canonical, name?, repository?, icon?}` from `GET /api/project` and `project.updated`.
public struct ProjectPayload: Codable, Sendable {
  public var id: String
  public var canonical: String
  public var name: String?
  public var repository: String?
  public var icon: ServerProject.ProjectIcon?

  public init(id: String, canonical: String, name: String? = nil, repository: String? = nil, icon: ServerProject.ProjectIcon? = nil) {
    self.id = id
    self.canonical = canonical
    self.name = name
    self.repository = repository
    self.icon = icon
  }

  public var project: ServerProject {
    let slug = ProjectName.repositorySlug(repository)
    return ServerProject(
      id: id,
      name: ProjectName.displayName(name: name, repository: repository, directory: canonical),
      directory: canonical,
      repository: slug,
      icon: icon?.isEmpty == true ? nil : icon
    )
  }
}
