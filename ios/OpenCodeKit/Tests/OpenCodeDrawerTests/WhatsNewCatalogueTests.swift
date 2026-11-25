import Foundation
import OpenCodeDrawer
import Testing

@Suite("What's New catalogue")
struct WhatsNewCatalogueTests {
  @Test("the shipped catalogue is complete, unique and newest first")
  func catalogueShape() {
    let catalog = WhatsNewCatalog.migration
    #expect(catalog.entries.count >= 180)
    #expect(Set(catalog.entries.map(\.id)).count == catalog.entries.count)
    #expect(catalog.entries.first?.day ?? "" >= catalog.entries.last?.day ?? "")
    #expect(catalog.entries.contains { $0.id == "browser-push-in" })
    #expect(catalog.entries.contains { $0.id == "model-list-and-level-meter" })
    #expect(catalog.entries.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty })
  }

  @Test("seen IDs never return as new")
  func seenState() {
    let catalog = WhatsNewCatalog.migration
    let seen = Set(catalog.entries.map(\.id))
    #expect(catalog.unseen(seen: seen).isEmpty)
    #expect(catalog.unseen(seen: []).count == catalog.entries.count)
  }

  @Test("a destination is either implemented or explicitly unavailable")
  func destinationsAreHonest() {
    for entry in WhatsNewCatalog.migration.entries {
      guard let destination = entry.destination else { continue }
      switch destination {
      case .unavailable(let reason):
        #expect(!reason.isEmpty)
      case .newSession, .prompt, .appearance, .sessions, .servers, .modelPicker, .experiment:
        break
      }
    }
  }
}
