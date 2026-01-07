/**
 * HOW:
 *   INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS=1 \
 *   swift test -c debug --filter PendingFlushOrderingIntegrationTests
 *
 *   [Inputs]
 *   - INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS: Set to "1" to enable tests that create ephemeral apps.
 *   - NetworkMonitorClient.mock: Used to force offline/online transitions deterministically.
 *
 *   [Outputs]
 *   - XCTest results validating deterministic replay ordering across reconnect.
 *
 *   [Side Effects]
 *   - Creates an ephemeral InstantDB app.
 *   - Writes and deletes test data in that app.
 *   - Forces the InstantClient to disconnect/reconnect via simulated network changes.
 *
 * WHO:
 *   Agent, User
 *   (Context: Fixing "link-before-create" flake after offline → online in SpeechRecorderApp.)
 *
 * WHAT:
 *   Reproduces a subtle but common offline-mode failure mode:
 *   - While offline, we enqueue *many* pending mutations (to make flush slow enough to interleave).
 *   - We then go online and enqueue entity creates *before* authentication finishes.
 *   - Immediately after authentication, we enqueue a link that depends on those creates.
 *
 *   If the SDK sends "new" mutations immediately while a pending-mutation flush is in-flight,
 *   the link can reach the server before the creates, causing `entityNotFound` and an orphaned
 *   relationship. This is the root of "my nested data is missing until restart" symptoms.
 *
 * WHEN:
 *   2026-01-03
 *   Last Modified: 2026-01-03
 *
 * WHERE:
 *   instantdb/sharing-instant/Tests/SharingInstantTests/PendingFlushOrderingIntegrationTests.swift
 *
 * WHY:
 *   SpeechRecorderApp’s data model is link-heavy:
 *   - `TranscriptionRun.media = Media(...)`
 *   - `TranscriptionSegment.transcriptionRun = TranscriptionRun(...)`
 *
 *   If link replay order is ever wrong across reconnect, we can create permanently orphaned
 *   segments/runs that only “fix themselves” after app restart, when the client re-queries
 *   fresh server state.
 */

import Dependencies
import Foundation
import InstantDB
import XCTest

@testable import SharingInstant

// MARK: - PendingFlushOrderingIntegrationTests

final class PendingFlushOrderingIntegrationTests: XCTestCase {
  private static let timeout: TimeInterval = 30.0

  /// Ensures that a link created immediately after authentication does not "leapfrog"
  /// older pending creates that were queued while reconnecting.
  ///
  /// This test targets a concurrency interleaving:
  /// - `handleInitOk` triggers `flushPendingMutations()` and awaits a SQLite read.
  /// - While that `await` is suspended, other work on the main actor can run.
  /// - If a new mutation sends immediately (instead of going through the flush),
  ///   it can reach the server before older pending rows.
  @MainActor
  func testLinkDoesNotLeapfrogQueuedCreatesDuringReconnect() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-pending-flush-order",
      schema: EphemeralAppFactory.minimalMicroblogSchema(),
      rules: EphemeralAppFactory.openRules(for: ["profiles", "posts"])
    )

    InstantClientFactory.clearCache()

    let admin = InstantAdminAPI(appID: app.id, adminToken: app.adminToken)

    let store = SharedTripleStore()
    let clientInstanceID = "pending-flush-\(UUID().uuidString.prefix(8))"
    let reactor = Reactor(store: store, clientInstanceID: clientInstanceID)

    let (networkMonitor, setOnline) = NetworkMonitorClient.mock(initiallyOnline: true)

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = app.id
      $0.instantReactor = reactor
      $0.instantEnableLocalPersistence = true
      $0.instantNetworkMonitor = networkMonitor
    } operation: {
      let client = await MainActor.run {
        InstantClientFactory.makeClient(appID: app.id, instanceID: clientInstanceID)
      }
      try await InstantTestAuth.signInAsGuestAndReconnect(client: client, timeout: Self.timeout)
      try await waitForSchemaAttributes(client, timeout: Self.timeout)

      // MARK: - Go offline + enqueue many pending mutations

      setOnline(false)
      try await waitForDisconnected(client, timeout: Self.timeout)

      // Enqueue enough pending mutations to make `loadPendingMutations()` noticeably slow.
      // We update the same Post repeatedly so cleanup is a single delete.
      let bulkPostId = UUID().uuidString.lowercased()
      let nowMs = Date().timeIntervalSince1970 * 1000

      for index in 0..<200 {
        try await reactor.transact(
          appID: app.id,
          chunks: [
            TransactionChunk(
              namespace: "posts",
              id: bulkPostId,
              ops: [[
                "update", "posts", bulkPostId, [
                  "content": "offline-bulk-\(index)",
                  "createdAt": nowMs,
                ],
              ]]
            )
          ]
        )
      }

      // MARK: - Come back online and enqueue creates before auth completes

      setOnline(true)

      let profileId = UUID().uuidString.lowercased()
      let postId = UUID().uuidString.lowercased()
      let handle = "pending-flush-\(UUID().uuidString.prefix(8))"

      // These are intentionally executed immediately after `setOnline(true)`.
      // At this point the socket is reconnecting but typically not yet authenticated, so
      // these creates are persisted and queued (not sent).
      try await reactor.transact(
        appID: app.id,
        chunks: [
          TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [[
              "create", "profiles", profileId, [
                "displayName": "Pending Flush Profile",
                "handle": handle,
                "createdAt": nowMs,
              ],
            ]]
          )
        ]
      )

      try await reactor.transact(
        appID: app.id,
        chunks: [
          TransactionChunk(
            namespace: "posts",
            id: postId,
            ops: [[
              "create", "posts", postId, [
                "content": "Pending Flush Post",
                "createdAt": nowMs,
              ],
            ]]
          )
        ]
      )

      // Wait only for authentication (init-ok); do NOT wait for pending flush to complete.
      // We want the next link to be enqueued while a pending flush may still be in-flight.
      try await InstantTestAuth.waitForAuthenticated(client, timeout: Self.timeout)

      // Enqueue a link right after authentication. If new mutations could send immediately
      // while the flush is still reading/sending older pending rows, this link could reach the
      // server before the queued creates (link-before-create), causing entityNotFound.
      try await reactor.transact(
        appID: app.id,
        chunks: [
          TransactionChunk(
            namespace: "posts",
            id: postId,
            ops: [[
              "link", "posts", postId, [
                "author": profileId,
              ],
            ]]
          )
        ]
      )

      // MARK: - Server truth verification

      let serverAuthorId = try await waitForAdminPostAuthorId(admin, postId: postId, timeout: Self.timeout)
      XCTAssertEqual(serverAuthorId.lowercased(), profileId.lowercased())

      // Cleanup
      try await admin.transact(steps: [
        ["delete", "posts", postId],
        ["delete", "profiles", profileId],
        ["delete", "posts", bulkPostId],
      ])
    }
  }

  // MARK: - Helpers

  @MainActor
  private func waitForSchemaAttributes(_ client: InstantClient, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !client.attributes.isEmpty { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Timed out waiting for schema attributes.")
  }

  @MainActor
  private func waitForDisconnected(_ client: InstantClient, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if client.connectionState == .disconnected { return }
      if case .error(let error) = client.connectionState { throw error }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Timed out waiting for client to transition to disconnected.")
  }
}

// MARK: - Admin API Helper

private struct InstantAdminAPI {
  let appID: String
  let adminToken: String
  let apiOrigin: String

  init(appID: String, adminToken: String) {
    self.appID = appID
    self.adminToken = adminToken
    self.apiOrigin = ProcessInfo.processInfo.environment["INSTANT_TEST_API_ORIGIN"] ?? "https://api.instantdb.com"
  }

  func query(_ query: [String: Any]) async throws -> [String: Any] {
    guard let url = URL(string: "\(apiOrigin)/admin/query") else {
      throw NSError(domain: "InstantAdminAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid apiOrigin: \(apiOrigin)"])
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(appID, forHTTPHeaderField: "app-id")
    request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")

    let body: [String: Any] = [
      "query": query,
      "inference?": false,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw NSError(domain: "InstantAdminAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
      throw NSError(
        domain: "InstantAdminAPI",
        code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "Admin query failed (\(http.statusCode)): \(body)"]
      )
    }

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return json ?? [:]
  }

  func transact(steps: [[Any]]) async throws {
    guard let url = URL(string: "\(apiOrigin)/admin/transact") else {
      throw NSError(domain: "InstantAdminAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid apiOrigin: \(apiOrigin)"])
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(appID, forHTTPHeaderField: "app-id")
    request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")

    let body: [String: Any] = [
      "steps": steps,
      "throw-on-missing-attrs?": false,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw NSError(domain: "InstantAdminAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
    }
    guard (200..<300).contains(http.statusCode) else {
      throw NSError(
        domain: "InstantAdminAPI",
        code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "Admin transact failed (\(http.statusCode))"]
      )
    }
  }

  func queryPostAuthorId(postId: String) async throws -> String? {
    let instaqlQuery: [String: Any] = [
      "posts": [
        "$": [
          "where": ["id": postId]
        ],
        "author": [:] as [String: Any],
      ]
    ]

    let response = try await query(instaqlQuery)
    guard let rawPosts = response["posts"] else { return nil }

    let rows: [[String: Any]]
    if let arr = rawPosts as? [[String: Any]] {
      rows = arr
    } else if let single = rawPosts as? [String: Any] {
      rows = [single]
    } else {
      return nil
    }

    guard let row = rows.first(where: { ($0["id"] as? String)?.lowercased() == postId.lowercased() }) else {
      return nil
    }

    let authorValue = row["author"]

    if let authorId = authorValue as? String {
      return authorId
    }

    if let dict = authorValue as? [String: Any], let authorId = dict["id"] as? String {
      return authorId
    }

    return nil
  }
}

@MainActor
private func waitForAdminPostAuthorId(
  _ admin: InstantAdminAPI,
  postId: String,
  timeout: TimeInterval
) async throws -> String {
  let deadline = Date().addingTimeInterval(timeout)

  while Date() < deadline {
    if let authorId = try await admin.queryPostAuthorId(postId: postId) {
      return authorId
    }

    try await Task.sleep(nanoseconds: 200_000_000)
  }

  throw NSError(
    domain: "PendingFlushOrderingIntegrationTests",
    code: 1,
    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Admin API to show Post.author link."]
  )
}
