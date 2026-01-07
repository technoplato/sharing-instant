/**
 * HOW:
 *   INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS=1 \
 *   swift test -c debug --filter NestedChildUpdateOfflineIntegrationTests
 *
 *   [Inputs]
 *   - INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS: Set to "1" to enable tests that create ephemeral apps.
 *   - NetworkMonitorClient.mock: Used to force offline/online transitions deterministically.
 *
 *   [Outputs]
 *   - XCTest results validating nested update propagation.
 *
 *   [Side Effects]
 *   - Creates an ephemeral InstantDB app.
 *   - Writes and deletes test data in that app.
 *   - Forces the InstantClient to disconnect/reconnect via simulated network changes.
 *
 * WHO:
 *   Agent, User
 *   (Context: Fixing "nested link data doesn't update until restart" in SpeechRecorderApp.)
 *
 * WHAT:
 *   Validates a key InstantDB UX invariant for nested queries:
 *   - If a parent entity is subscribed with nested links (e.g. `Profile.posts`),
 *     and a child entity updates (e.g. `Post.content`),
 *     then the subscription should re-yield the parent with the updated child fields.
 *
 *   This mirrors SpeechRecorderApp’s shape:
 *   - `Media.transcriptionRuns.transcriptionSegments.text` changes rapidly.
 *   - The UI is driven by a `Media` subscription and must reflect nested segment updates.
 *
 * WHEN:
 *   2026-01-02
 *   Last Modified: 2026-01-02
 *
 * WHERE:
 *   instantdb/sharing-instant/Tests/SharingInstantTests/NestedChildUpdateOfflineIntegrationTests.swift
 *
 * WHY:
 *   SharingInstant subscriptions previously observed only root entity IDs. That meant nested
 *   updates (child entity field changes) would not trigger a parent re-yield, causing UI to
 *   appear stale until a restart or unrelated parent mutation.
 *
 *   Running the child update while offline makes the failure deterministic:
 *   there is no server refresh that can mask missing local-store observation wiring.
 */

import Dependencies
import Foundation
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - NestedChildUpdateOfflineIntegrationTests

final class NestedChildUpdateOfflineIntegrationTests: XCTestCase {
  private static let timeout: TimeInterval = 30.0

  /// Ensures nested child entity updates propagate to the parent subscription while offline,
  /// and that the queued mutation persists to the server after reconnect.
  ///
  /// Scenario:
  /// 1) Online: create Profile + Post + link Post.author -> Profile (so Profile.posts is populated).
  /// 2) Offline: update Post.content.
  /// 3) Assert the `profiles` subscription re-yields Profile.posts with updated content (offline).
  /// 4) Online: assert server truth via Admin API.
  @MainActor
  func testOfflineChildUpdateTriggersParentSubscriptionYield() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-nested-child-update-offline",
      schema: EphemeralAppFactory.minimalMicroblogSchema(),
      rules: EphemeralAppFactory.openRules(for: ["profiles", "posts"])
    )

    InstantClientFactory.clearCache()

    let admin = InstantAdminAPI(appID: app.id, adminToken: app.adminToken)

    let store = SharedTripleStore()
    let clientInstanceID = "nested-child-update-\(UUID().uuidString.prefix(8))"
    let reactor = Reactor(store: store, clientInstanceID: clientInstanceID)

    let (networkMonitor, setOnline) = NetworkMonitorClient.mock(initiallyOnline: true)

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = app.id
      $0.instantReactor = reactor
      $0.instantEnableLocalPersistence = true
      $0.instantNetworkMonitor = networkMonitor
    } operation: {
      @Shared(.instantSync(Schema.profiles.with(\.posts)))
      var profiles: IdentifiedArrayOf<Profile> = []

      let client = await MainActor.run {
        InstantClientFactory.makeClient(appID: app.id, instanceID: clientInstanceID)
      }
      try await InstantTestAuth.signInAsGuestAndReconnect(client: client, timeout: Self.timeout)
      try await waitForSchemaAttributes(client, timeout: Self.timeout)

      let profileId = UUID().uuidString.lowercased()
      let postId = UUID().uuidString.lowercased()
      let handle = "nested-child-\(UUID().uuidString.prefix(8))"
      let nowMs = Date().timeIntervalSince1970 * 1000

      let initialContent = "initial-content-\(UUID().uuidString.prefix(8))"

      try await reactor.transact(
        appID: app.id,
        chunks: [
          TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [[
              "create", "profiles", profileId, [
                "displayName": "Nested Child Author",
                "handle": handle,
                "createdAt": nowMs,
              ],
            ]]
          ),
          TransactionChunk(
            namespace: "posts",
            id: postId,
            ops: [[
              "create", "posts", postId, [
                "content": initialContent,
                "createdAt": nowMs,
              ],
            ]]
          ),
          TransactionChunk(
            namespace: "posts",
            id: postId,
            ops: [[
              "link", "posts", postId, [
                "author": profileId,
              ],
            ]]
          ),
        ]
      )

      try await waitForProfilePostContent(
        profileId: profileId,
        postId: postId,
        expectedContent: initialContent,
        profiles: { profiles },
        timeout: Self.timeout
      )

      // Force offline so the only way for the Profile to reflect the Post update is via
      // local store notifications (no refresh can "paper over" missing observation wiring).
      setOnline(false)
      try await waitForDisconnected(client, timeout: Self.timeout)

      let offlineContent = "offline-content-\(UUID().uuidString.prefix(8))"

      try await reactor.transact(
        appID: app.id,
        chunks: [
          TransactionChunk(
            namespace: "posts",
            id: postId,
            ops: [[
              "update", "posts", postId, [
                "content": offlineContent,
              ],
            ]]
          )
        ]
      )

      // Assert local nested propagation while offline.
      try await waitForProfilePostContent(
        profileId: profileId,
        postId: postId,
        expectedContent: offlineContent,
        profiles: { profiles },
        timeout: Self.timeout
      )

      // Come back online and assert server truth via Admin API (no client caching).
      setOnline(true)
      try await InstantTestAuth.waitForAuthenticated(client, timeout: Self.timeout)

      let serverContent = try await waitForAdminPostContent(
        admin,
        postId: postId,
        expectedContent: offlineContent,
        timeout: Self.timeout
      )
      XCTAssertEqual(serverContent, offlineContent)

      // Cleanup
      try await admin.transact(steps: [
        ["delete", "posts", postId],
        ["delete", "profiles", profileId],
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

      if case .error(let error) = client.connectionState {
        throw error
      }

      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTFail("Timed out waiting for client to transition to disconnected.")
  }

  @MainActor
  private func waitForProfilePostContent(
    profileId: String,
    postId: String,
    expectedContent: String,
    profiles: () -> IdentifiedArrayOf<Profile>,
    timeout: TimeInterval
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let profile = profiles()[id: profileId],
         let posts = profile.posts,
         let post = posts.first(where: { $0.id.lowercased() == postId.lowercased() }),
         post.content == expectedContent {
        return
      }

      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTFail("Timed out waiting for Profile.posts to reflect Post.content == \(expectedContent).")
  }

  @MainActor
  private func waitForAdminPostContent(
    _ admin: InstantAdminAPI,
    postId: String,
    expectedContent: String,
    timeout: TimeInterval
  ) async throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    var lastSeen: String?

    while Date() < deadline {
      if let content = try await admin.queryPostContent(postId: postId) {
        lastSeen = content
        if content == expectedContent { return content }
      }

      try await Task.sleep(nanoseconds: 200_000_000)
    }

    if let lastSeen {
      XCTFail("Timed out waiting for server post content. Last seen: \(lastSeen)")
    } else {
      XCTFail("Timed out waiting for server post content for post: \(postId)")
    }

    throw NSError(domain: "NestedChildUpdateOfflineIntegrationTests", code: 1)
  }
}

// MARK: - InstantAdminAPI (Test-Only)

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
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(domain: "InstantAdminAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
      throw NSError(domain: "InstantAdminAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Admin query failed (\(httpResponse.statusCode)): \(raw)"])
    }

    let json = try JSONSerialization.jsonObject(with: data, options: [])
    return (json as? [String: Any]) ?? [:]
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
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(domain: "InstantAdminAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw NSError(domain: "InstantAdminAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Admin transact failed (\(httpResponse.statusCode))"])
    }
  }

  func queryPostContent(postId: String) async throws -> String? {
    let instaqlQuery: [String: Any] = [
      "posts": [
        "$": [
          "where": ["id": postId]
        ],
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

    return row["content"] as? String
  }
}

