import DependenciesTestSupport
import Foundation
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - StorageSharedIntegrationTests

final class StorageSharedIntegrationTests: XCTestCase {
  private static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  private static let timeout: TimeInterval = 30.0

  // MARK: - StorageItem + StorageFeed

  /// Validates the Shared-based storage ergonomics:
  /// - `upload(...)` returns a stable `StorageRef` immediately
  /// - `.storageItem(ref)` observes local optimistic state and then server `$files` metadata
  /// - `.storageFeed(scope: .user)` includes optimistic items and then merges server results
  @MainActor
  func testStorageItemAndFeedMergeOptimisticUploadThenServerURL() async throws {
    try IntegrationTestGate.requireEnabled()

    prepareDependencies {
      $0.context = .live
      $0.instantAppID = Self.testAppID
      $0.instantEnableLocalPersistence = false
    }

    InstantClientFactory.clearCache()

    let client = InstantClientFactory.makeClient(appID: Self.testAppID)

    do {
      _ = try await client.authManager.signInAsGuest()
    } catch {
      throw XCTSkip("Storage integration requires guest auth. Error: \(error)")
    }

    let storage = InstantStorageClient(appID: Self.testAppID)

    // Ensure we start from a clean local mutation store so we don't accidentally merge stale
    // optimistic entries from previous test runs in the same process.
    let localState = StorageSharedStore.state(appID: Self.testAppID)
    localState.withLock { $0.entries.removeAll() }

    let payloadString = "sharing-instant-shared-storage-\(UUID().uuidString)"
    guard let payload = payloadString.data(using: .utf8) else {
      XCTFail("Failed to encode payload as UTF-8")
      return
    }

    var observedUploadError: (any Error)?

    let ref = storage.upload(
      data: payload,
      filename: "note.txt",
      contentType: "text/plain",
      contentDisposition: "inline",
      folder: "sharing-storage-shared-tests",
      scope: .user,
      onFailure: { _, error in
        observedUploadError = error
      }
    )

    @SharedReader(.storageItem(ref))
    var item: StorageItem

    @SharedReader(.storageFeed(scope: .user))
    var feed: IdentifiedArrayOf<StorageItem>

    // 1) Optimistic: should show up immediately (local preview + path identity).
    let optimisticDeadline = Date().addingTimeInterval(5)
    var sawOptimisticPreview = false
    while Date() < optimisticDeadline {
      if item.ref.path == ref.path, item.localPreview != nil {
        sawOptimisticPreview = true
        break
      }
      if observedUploadError != nil { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }

    if let error = observedUploadError {
      try skipIfStorageUnavailable(error, operation: "upload")
      return
    }

    XCTAssertTrue(sawOptimisticPreview, "Expected StorageItem to surface a local preview soon after upload()")

    let feedDeadline = Date().addingTimeInterval(5)
    var feedContainsRef = false
    while Date() < feedDeadline {
      feedContainsRef = feed.contains(where: { $0.ref.path == ref.path })
      if feedContainsRef { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertTrue(feedContainsRef, "Expected StorageFeed to include the optimistic upload immediately")

    // 2) Server catch-up: eventually we should have a $files id and a url.
    let serverDeadline = Date().addingTimeInterval(Self.timeout)
    var didGetServerURL = false
    while Date() < serverDeadline {
      if item.status.isFailed, let error = observedUploadError {
        try skipIfStorageUnavailable(error, operation: "upload")
        return
      }

      if item.status.isUploaded, item.fileID != nil, item.url != nil {
        didGetServerURL = true
        break
      }

      try await Task.sleep(nanoseconds: 200_000_000)
    }

    XCTAssertTrue(didGetServerURL, "Expected StorageItem to eventually include fileID + url after upload completes")

    // Cleanup best-effort: avoid leaving test files around in the shared test app.
    storage.delete(ref)
  }

  // MARK: - Helpers

  private func skipIfStorageUnavailable(_ error: any Error, operation: String) throws {
    guard let instantError = error as? InstantError else {
      throw error
    }

    switch instantError {
    case .serverError(let message, _):
      throw XCTSkip(
        """
        Storage integration test is not runnable for appID=\(Self.testAppID).

        WHAT HAPPENED:
          Operation '\(operation)' failed with a server error.

        WHY THIS HAPPENS:
          Storage is gated by `$files` permissions and may be disabled per app.

        HOW TO FIX:
          1) Ensure storage is enabled for the app, and
          2) Add `$files` rules allowing create/view/delete for the test user.

          A good default is scoping files to an auth-id prefix:
            auth.id != null && data.path.startsWith(auth.id + '/')

          Then push perms:
            npx instant-cli@latest push perms --app \(Self.testAppID)

        SERVER MESSAGE:
          \(message)
        """
      )

    default:
      throw error
    }
  }
}
