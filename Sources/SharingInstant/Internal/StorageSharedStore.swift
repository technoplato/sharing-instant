import Foundation
import Sharing

// MARK: - StorageSharedStore

enum StorageSharedStore {
  static func state(appID: String) -> Shared<StorageSharedState> {
    Shared(
      wrappedValue: StorageSharedState(),
      InMemoryKey<StorageSharedState>.inMemory("sharingInstant.storage.state.\(appID)")
    )
  }
}

