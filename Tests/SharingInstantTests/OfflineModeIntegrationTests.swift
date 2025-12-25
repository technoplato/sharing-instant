import CryptoKit
import InstantDB
import XCTest

@testable import SharingInstant

// MARK: - OfflineModeIntegrationTests

/// Integration tests for local-first / offline mode parity with JS core.
///
/// ## Why These Tests Exist
/// InstantDB's TypeScript clients (core Reactor) distinguish between:
/// - Subscriptions: may return cached results immediately (offline-friendly UX).
/// - `queryOnce`: intentionally strict; should fail when offline so callers can't
///   accidentally treat stale cached data as a fresh read.
///
/// These tests validate the Swift iOS SDK behavior end-to-end against the real
/// server, while simulating offline periods via explicit WebSocket disconnects.
final class OfflineModeIntegrationTests: XCTestCase {
  static let timeout: TimeInterval = 30.0

  // MARK: - Cached Subscriptions

  @MainActor
  func testSubscribeEmitsCachedResultsWhileDisconnected() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-offline-cache",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )

    let appID = app.id
    let client = InstantClient(appID: appID)
    let storage = try LocalStorage(appId: appID)

    try await InstantTestAuth.signInAsGuestAndReconnect(client: client, timeout: Self.timeout)
    try await waitForSchemaPersistence(storage: storage, timeout: Self.timeout)

    let todoId = UUID().uuidString.lowercased()
    let todoTitle = "offline-cache-\(UUID().uuidString)"
    let now = Date().timeIntervalSince1970

    let createChunk = TransactionChunk(
      namespace: "todos",
      id: todoId,
      ops: [[
        "update", "todos", todoId, [
          "title": todoTitle,
          "done": false,
          "createdAt": now,
        ],
      ]]
    )

    _ = try await client.transactLocalFirst([createChunk])

    let query = client.query(Todo.self).where(["id": todoId])
    let instaqlQuery: [String: Any] = [
      "todos": [
        "$": [
          "where": ["id": todoId]
        ]
      ]
    ]
    let hash = Self.queryHash(instaqlQuery)

    var subscriptions = Set<SubscriptionToken>()

    let receivedFromServer = XCTestExpectation(description: "Receives server result for query (primes cache)")
    let onlineToken = try client.subscribe(query) { result in
      if result.isLoading { return }
      if let error = result.error {
        XCTFail("Unexpected subscription failure while online: \(error)")
        return
      }
      if result.data.contains(where: { $0.id == todoId }) {
        receivedFromServer.fulfill()
      }
    }
    onlineToken.store(in: &subscriptions)

    await fulfillment(of: [receivedFromServer], timeout: Self.timeout)
    try await waitForCachedQueryResult(storage: storage, hash: hash, timeout: Self.timeout)

    subscriptions.removeAll()
    client.disconnect()
    XCTAssertEqual(client.connectionState, .disconnected)

    let receivedFromCache = XCTestExpectation(description: "Receives cached result while offline")
    let offlineToken = try client.subscribe(query) { result in
      if result.isLoading { return }
      if let error = result.error {
        XCTFail("Unexpected subscription failure while offline: \(error)")
        return
      }
      if result.data.contains(where: { $0.id == todoId }) {
        receivedFromCache.fulfill()
      }
    }
    offlineToken.store(in: &subscriptions)

    await fulfillment(of: [receivedFromCache], timeout: Self.timeout)

    client.connect()
    try await InstantTestAuth.waitForAuthenticated(client, timeout: Self.timeout)

    let deleteChunk = TransactionChunk(
      namespace: "todos",
      id: todoId,
      ops: [["delete", "todos", todoId]]
    )
    _ = try await client.transactLocalFirst([deleteChunk])

    subscriptions.removeAll()
  }

  // MARK: - Strict Query Once

  @MainActor
  func testQueryOnceFailsOfflineAndCarriesLastKnownResultWhenAvailable() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-offline-query-once",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )

    let appID = app.id
    let client = InstantClient(appID: appID)
    let storage = try LocalStorage(appId: appID)

    try await InstantTestAuth.signInAsGuestAndReconnect(client: client, timeout: Self.timeout)
    try await waitForSchemaPersistence(storage: storage, timeout: Self.timeout)

    let todoId = UUID().uuidString.lowercased()
    let todoTitle = "offline-query-once-\(UUID().uuidString)"
    let now = Date().timeIntervalSince1970

    let createChunk = TransactionChunk(
      namespace: "todos",
      id: todoId,
      ops: [[
        "update", "todos", todoId, [
          "title": todoTitle,
          "done": false,
          "createdAt": now,
        ],
      ]]
    )

    _ = try await client.transactLocalFirst([createChunk])

    let query = client.query(Todo.self).where(["id": todoId])
    let instaqlQuery: [String: Any] = [
      "todos": [
        "$": [
          "where": ["id": todoId]
        ]
      ]
    ]
    let hash = Self.queryHash(instaqlQuery)

    var subscriptions = Set<SubscriptionToken>()
    let receivedFromServer = XCTestExpectation(description: "Receives server result for query (primes cache)")

    let token = try client.subscribe(query) { result in
      if result.isLoading { return }
      if let error = result.error {
        XCTFail("Unexpected subscription failure while online: \(error)")
        return
      }
      if result.data.contains(where: { $0.id == todoId }) {
        receivedFromServer.fulfill()
      }
    }
    token.store(in: &subscriptions)

    await fulfillment(of: [receivedFromServer], timeout: Self.timeout)
    try await waitForCachedQueryResult(storage: storage, hash: hash, timeout: Self.timeout)

    subscriptions.removeAll()
    client.disconnect()

    do {
      _ = try await client.queryOnce(query)
      XCTFail("Expected queryOnce to throw when offline.")
    } catch let error as QueryOnceError {
      guard case let .offline(queryHash, lastKnownResult) = error else {
        XCTFail("Expected QueryOnceError.offline, got: \(error)")
        return
      }

      XCTAssertEqual(queryHash, hash)
      XCTAssertNotNil(lastKnownResult)

      let cached: [Todo]? = error.decodeLastKnownEntities(Todo.self, from: "todos")
      XCTAssertEqual(cached?.first?.id, todoId)
    }
  }

  @MainActor
  func testQueryOnceFailsOfflineWithNilLastKnownResultWhenNoCacheExists() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-offline-query-once-no-cache",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )

    let appID = app.id
    let client = InstantClient(appID: appID)

    try await InstantTestAuth.signInAsGuestAndReconnect(client: client, timeout: Self.timeout)

    let todoId = UUID().uuidString.lowercased()
    let query = client.query(Todo.self).where(["id": todoId])
    let instaqlQuery: [String: Any] = [
      "todos": [
        "$": [
          "where": ["id": todoId]
        ]
      ]
    ]
    let expectedHash = Self.queryHash(instaqlQuery)

    client.disconnect()

    do {
      _ = try await client.queryOnce(query)
      XCTFail("Expected queryOnce to throw when offline.")
    } catch let error as QueryOnceError {
      guard case let .offline(queryHash, lastKnownResult) = error else {
        XCTFail("Expected QueryOnceError.offline, got: \(error)")
        return
      }

      XCTAssertEqual(queryHash, expectedHash)
      XCTAssertNil(lastKnownResult)
    }
  }

  // MARK: - Queued Writes + Subscription Refresh

  @MainActor
  func testOfflineWriteQueuesAndFlushesAfterReconnectRefreshingSubscriptions() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-offline-flush",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )

    let appID = app.id
    let client = InstantClient(appID: appID)
    let storage = try LocalStorage(appId: appID)

    try await InstantTestAuth.signInAsGuestAndReconnect(client: client, timeout: Self.timeout)
    try await waitForSchemaPersistence(storage: storage, timeout: Self.timeout)

    let todoId = UUID().uuidString.lowercased()
    let todoTitle = "offline-flush-\(UUID().uuidString)"
    let now = Date().timeIntervalSince1970

    let query = client.query(Todo.self).where(["id": todoId])

    var subscriptions = Set<SubscriptionToken>()
    let receivedAfterReconnect = XCTestExpectation(description: "Receives server data after reconnect + flush")

    let token = try client.subscribe(query) { result in
      if result.isLoading { return }
      if let error = result.error {
        XCTFail("Unexpected subscription failure: \(error)")
        return
      }
      if result.data.contains(where: { $0.id == todoId }) {
        receivedAfterReconnect.fulfill()
      }
    }
    token.store(in: &subscriptions)

    client.disconnect()
    XCTAssertEqual(client.connectionState, .disconnected)

    let createChunk = TransactionChunk(
      namespace: "todos",
      id: todoId,
      ops: [[
        "update", "todos", todoId, [
          "title": todoTitle,
          "done": false,
          "createdAt": now,
        ],
      ]]
    )

    let eventId = try await client.transactLocalFirst([createChunk])
    let pending = try await storage.loadPendingMutations()
    XCTAssertTrue(pending.contains(where: { $0.eventId == eventId }))

    client.connect()
    try await InstantTestAuth.waitForAuthenticated(client, timeout: Self.timeout)

    await fulfillment(of: [receivedAfterReconnect], timeout: Self.timeout)

    let deleteChunk = TransactionChunk(
      namespace: "todos",
      id: todoId,
      ops: [["delete", "todos", todoId]]
    )
    _ = try await client.transactLocalFirst([deleteChunk])

    subscriptions.removeAll()
  }

  // MARK: - Helpers

  @MainActor
  private func waitForSchemaPersistence(storage: LocalStorage, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      let attrs = try await storage.loadAttrs()
      if !attrs.isEmpty { return }
      try await Task.sleep(nanoseconds: 100_000_000)
    }

    XCTFail("Timed out waiting for persisted schema attrs.")
  }

  @MainActor
  private func waitForCachedQueryResult(storage: LocalStorage, hash: String, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if let data = try storage.getCachedQueryResultSync(hash: hash), !data.isEmpty {
        return
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }

    XCTFail("Timed out waiting for cached query result to persist (hash: \(hash)).")
  }

  private static func queryHash(_ query: [String: Any]) -> String {
    let canonical = canonicalize(query)

    guard let data = try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]) else {
      return UUID().uuidString.lowercased()
    }

    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func canonicalize(_ value: Any) -> Any {
    if let dict = value as? [String: Any] {
      var result: [String: Any] = [:]
      for key in dict.keys.sorted() {
        result[key] = canonicalize(dict[key] as Any)
      }
      return result
    }

    if let array = value as? [Any] {
      return array.map { canonicalize($0) }
    }

    return value
  }
}
