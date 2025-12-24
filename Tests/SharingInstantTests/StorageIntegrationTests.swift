import Dependencies
import Foundation
import InstantDB
import XCTest

@testable import SharingInstant

// MARK: - StorageIntegrationTests

final class StorageIntegrationTests: XCTestCase {

  private static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  private static let timeout: TimeInterval = 20.0

  // MARK: - Upload / Link / Delete

  @MainActor
  func testUploadLinkDeleteViaInstantStorage() async throws {
    try IntegrationTestGate.requireEnabled()

    InstantClientFactory.clearCache()

    let storage = InstantStorage(appID: Self.testAppID)
    let client = InstantClientFactory.makeClient(appID: Self.testAppID)

    let user: User
    do {
      user = try await client.authManager.signInAsGuest()
    } catch {
      throw XCTSkip("Storage integration requires guest auth. Error: \(error)")
    }

    let path = "\(user.id)/sharing-storage-tests/\(UUID().uuidString.lowercased()).txt"

    let payloadString = "hello sharing storage \(UUID().uuidString)"
    guard let payload = payloadString.data(using: .utf8) else {
      XCTFail("Failed to encode payload as UTF-8")
      return
    }

    defer {
      Task { @MainActor in
        _ = try? await storage.deleteFile(path: path)
        InstantClientFactory.clearCache()
      }
    }

    let uploaded: InstantStorage.UploadedFile
    do {
      uploaded = try await storage.uploadFile(
        path: path,
        data: payload,
        options: .init(contentType: "text/plain")
      )
    } catch {
      try self.skipIfStorageUnavailable(error, operation: "upload")
      return
    }

    XCTAssertEqual(uploaded.path, path)
    XCTAssertFalse(uploaded.id.isEmpty)

    switch storage.uploadState {
    case .success(let stateValue, _):
      XCTAssertEqual(stateValue, uploaded)
    default:
      XCTFail("Expected uploadState to be .success after a successful upload")
    }

    let link: InstantStorage.FileLink
    do {
      link = try await storage.link(path: path)
    } catch {
      try self.skipIfStorageUnavailable(error, operation: "link")
      return
    }

    XCTAssertEqual(link.path, path)

    let (downloadedData, _) = try await URLSession.shared.data(from: link.url)
    XCTAssertEqual(downloadedData, payload)

    switch storage.linkState {
    case .success(let stateValue, _):
      XCTAssertEqual(stateValue, link)
    default:
      XCTFail("Expected linkState to be .success after link generation")
    }

    let deleted: InstantStorage.DeletedFile
    do {
      deleted = try await storage.deleteFile(path: path)
    } catch {
      try self.skipIfStorageUnavailable(error, operation: "delete")
      return
    }

    XCTAssertEqual(deleted.path, path)
    XCTAssertEqual(deleted.id, uploaded.id)

    let deadline = Date().addingTimeInterval(Self.timeout)
    var didObserveNotFound = false
    while Date() < deadline && !didObserveNotFound {
      do {
        _ = try await storage.link(path: path)
        try await Task.sleep(nanoseconds: 200_000_000)
      } catch {
        didObserveNotFound = true
      }
    }

    XCTAssertTrue(didObserveNotFound)
  }

  // MARK: - Callback API

  @MainActor
  func testCallbackUploadUpdatesState() async throws {
    try IntegrationTestGate.requireEnabled()

    InstantClientFactory.clearCache()

    let storage = InstantStorage(appID: Self.testAppID)
    let client = InstantClientFactory.makeClient(appID: Self.testAppID)

    let user: User
    do {
      user = try await client.authManager.signInAsGuest()
    } catch {
      throw XCTSkip("Storage integration requires guest auth. Error: \(error)")
    }

    let path = "\(user.id)/sharing-storage-tests/\(UUID().uuidString.lowercased()).txt"
    let payloadString = "hello callback storage \(UUID().uuidString)"
    guard let payload = payloadString.data(using: .utf8) else {
      XCTFail("Failed to encode payload as UTF-8")
      return
    }

    defer {
      Task { @MainActor in
        _ = try? await storage.deleteFile(path: path)
        InstantClientFactory.clearCache()
      }
    }

    let uploaded: InstantStorage.UploadedFile
    do {
      uploaded = try await withCheckedThrowingContinuation { continuation in
        storage.uploadFile(
          path: path,
          data: payload,
          options: .init(contentType: "text/plain")
        ) { result in
          continuation.resume(with: result.mapError { $0 as Error })
        }
      }
    } catch {
      try self.skipIfStorageUnavailable(error, operation: "upload")
      return
    }

    XCTAssertEqual(uploaded.path, path)
    XCTAssertFalse(uploaded.id.isEmpty)

    switch storage.uploadState {
    case .success(let stateValue, _):
      XCTAssertEqual(stateValue, uploaded)
    default:
      XCTFail("Expected uploadState to be .success after callback upload completes")
    }
  }

  // MARK: - $files Query Updates

  @MainActor
  func testFilesQueryUpdatesAfterUploadAndDelete() async throws {
    try IntegrationTestGate.requireEnabled()

    InstantClientFactory.clearCache()

    let storage = InstantStorage(appID: Self.testAppID)
    let client = InstantClientFactory.makeClient(appID: Self.testAppID)

    let user: User
    do {
      user = try await client.authManager.signInAsGuest()
    } catch {
      throw XCTSkip("Storage integration requires guest auth. Error: \(error)")
    }

    let pathPrefix = "\(user.id)/sharing-storage-query-tests/"
    let path = "\(pathPrefix)\(UUID().uuidString.lowercased()).txt"

    let payloadString = "hello storage query \(UUID().uuidString)"
    guard let payload = payloadString.data(using: .utf8) else {
      XCTFail("Failed to encode payload as UTF-8")
      return
    }

    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    let config = SharingInstantQuery.Configuration<TestStorageFile>(
      namespace: "$files",
      orderBy: .asc("path"),
      whereClause: ["path": ["$ilike": "\(user.id)/%"]]
    )

    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)

    let observedUpload = XCTestExpectation(description: "File appears in $files subscription after upload")
    let observedDelete = XCTestExpectation(description: "File disappears from $files subscription after delete")

    let observeTask = Task { @MainActor in
      var didObserveUpload = false
      for await files in stream {
        let containsPath = files.contains(where: { $0.path == path })

        if containsPath && !didObserveUpload {
          didObserveUpload = true
          observedUpload.fulfill()
          continue
        }

        if didObserveUpload && !containsPath {
          observedDelete.fulfill()
          break
        }
      }
    }

    defer {
      observeTask.cancel()
      Task { @MainActor in
        _ = try? await storage.deleteFile(path: path)
        InstantClientFactory.clearCache()
      }
    }

    do {
      _ = try await storage.uploadFile(
        path: path,
        data: payload,
        options: .init(contentType: "text/plain")
      )
    } catch {
      try self.skipIfStorageUnavailable(error, operation: "upload")
      return
    }

    await fulfillment(of: [observedUpload], timeout: Self.timeout)

    do {
      _ = try await storage.deleteFile(path: path)
    } catch {
      try self.skipIfStorageUnavailable(error, operation: "delete")
      return
    }

    await fulfillment(of: [observedDelete], timeout: Self.timeout)
  }

  // MARK: - Private Helpers

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

// MARK: - Test Models

private struct TestStorageFile: Codable, EntityIdentifiable, Sendable, Equatable {
  static var namespace: String { "$files" }

  var id: String
  var path: String
  var url: String?
}
