import ComposableArchitecture
import OpenCodeCore
import OpenCodeServer
import OpenCodeSession
import SwiftUI

struct FolderBrowserView: View {
  let store: StoreOf<FolderBrowserFeature>
  let onClose: () -> Void
  var onSelect: ((String) -> Void)? = nil

  private var route: FolderBrowserFeature.State.Route { store.route }

  var body: some View {
    NavigationStack {
      Group {
        switch store.listings[route] {
        case .loading:
          ProgressView(AppCopy.text("folder.loading"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
          ContentUnavailableView {
            Label(AppCopy.text("folder.failed"), systemImage: "folder.badge.questionmark")
          } description: {
            Text(error.copy)
          } actions: {
            Button(AppCopy.text("common.try_again")) { store.send(.retryTapped) }
              .accessibilityIdentifier("folder-retry")
          }
        case .loaded(let listing):
          List {
            if listing.folders.isEmpty {
              Text(AppCopy.text("folder.empty"))
                .foregroundStyle(OpenCodeColors.color(.textWeak))
                .accessibilityIdentifier("folder-empty")
            }
            ForEach(listing.folders, id: \.self) { path in
              Button {
                store.send(.folderTapped(path))
              } label: {
                HStack {
                  Image(systemName: "folder")
                    .foregroundStyle(OpenCodeColors.color(.accent))
                  Text(FolderBrowserFeature.name(path: path))
                    .foregroundStyle(OpenCodeColors.color(.textStrong))
                  Spacer()
                  Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(OpenCodeColors.color(.textTertiary))
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("folder-\(path)")
            }
          }
        case .none:
          ProgressView(AppCopy.text("folder.loading"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          if store.routes.count > 1 {
            Button(AppCopy.text("common.back")) { store.send(.backTapped) }
              .accessibilityIdentifier("folder-back")
          } else {
            Button(AppCopy.text("common.cancel")) { onClose() }
              .accessibilityIdentifier("folder-cancel")
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(AppCopy.text("folder.select")) {
            if let directory = store.state.directory(store.route), let onSelect {
              onSelect(directory)
            } else {
              store.send(.selectTapped)
            }
          }
          .disabled(!store.canSelect)
          .accessibilityIdentifier("folder-select")
        }
      }
    }
    .task { store.send(.appeared) }
  }

  private var title: String {
    if let directory = store.state.directory(route) {
      return FolderBrowserFeature.name(path: directory)
    }
    return AppCopy.text("folder.title")
  }
}
