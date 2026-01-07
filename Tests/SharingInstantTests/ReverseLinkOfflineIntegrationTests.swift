/**
 * HOW:
 *   INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS=1 \
 *   swift test -c debug --filter ReverseLinkOfflineIntegrationTests
 *
 *   [Inputs]
 *   - INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS: Set to "1" to enable tests that create ephemeral apps.
 *   - NetworkMonitorClient.mock: Used to force offline/online transitions deterministically.
 *
 *   [Outputs]
 *   - XCTest results.
 *
 *   [Side Effects]
 *   - Creates an ephemeral InstantDB app.
 *   - Writes and deletes test data in that app.
 *   - Forces the InstantClient to disconnect/reconnect via simulated network changes.
 *
 * WHO:
 *   Agent, User
 *   (Context: Debugging reverse-link propagation + offline link replay parity with JS Reactor.)
 *
 * WHAT:
 *   Validates an important InstantDB UX invariant:
 *   - When you create a ref link while offline (e.g., `post.author = profile`),
 *     the *reverse* link view (e.g., `profile.posts`) should update immediately
 *     from optimistic local state, without waiting for a server refresh.
 *
 *   It then verifies that the same link is eventually persisted to the server
 *   when connectivity returns (offline queue flush).
 *
 * WHEN:
 *   2026-01-02
 *   Last Modified: 2026-01-02
 *
 * WHERE:
 *   instantdb/sharing-instant/Tests/SharingInstantTests/ReverseLinkOfflineIntegrationTests.swift
 *
 * WHY:
 *   SpeechRecorderApp relies on reverse links heavily:
 *   - `TranscriptionRun.media = Media(...)` (forward)
 *   - `Media.transcriptionRuns` (reverse-derived view)
 *
 *   When reverse-link propagation is wrong, the UI symptom is:
 *   - "I created/linked the run, but it doesn't show up on the media until restart."
 *
 *   This test reproduces the same shape using the Microblog schema:
 *   - `Post.author = Profile` (forward)
 *   - `Profile.posts` (reverse-derived view)
 *
 *   Running the link mutation while offline makes the test deterministic:
 *   there is no server refresh that can mask missing local store notifications.
 */

import Dependencies
import Foundation
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - ReverseLinkOfflineIntegrationTests

final class ReverseLinkOfflineIntegrationTests: XCTestCase {
  private static let timeout: TimeInterval = 30.0

  // MARK: - Tests

  /// Ensures reverse links update from optimistic state while offline, and persist on reconnect.
  ///
  /// ## Scenario
  /// 1. Online: create Profile + Post.
  /// 2. Offline: link Post.author -> Profile.
  /// 3. Assert local `profiles` results now show Profile.posts includes Post.
  /// 4. Online again: assert the link is present on the server via Admin API.
  @MainActor
  func testReverseLinkUpdatesWhileOfflineAndPersistsAfterReconnect() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-reverse-link-offline",
      schema: EphemeralAppFactory.minimalMicroblogSchema(),
      rules: EphemeralAppFactory.openRules(for: ["profiles", "posts"])
    )

    InstantClientFactory.clearCache()

    let admin = InstantAdminAPI(appID: app.id, adminToken: app.adminToken)

    let store = SharedTripleStore()
    let clientInstanceID = "reverse-link-offline-\(UUID().uuidString.prefix(8))"
    let reactor = Reactor(store: store, clientInstanceID: clientInstanceID)

    let (networkMonitor, setOnline) = NetworkMonitorClient.mock(initiallyOnline: true)

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = app.id
      $0.instantReactor = reactor
      $0.instantEnableLocalPersistence = true
      $0.instantNetworkMonitor = networkMonitor
    } operation: {
      // Subscribe to both sides so the local TripleStore has enough data to resolve reverse links.
      @Shared(.instantSync(Schema.profiles.with(\.posts)))
      var profiles: IdentifiedArrayOf<Profile> = []

      @Shared(.instantSync(Schema.posts.with(\.author)))
      var posts: IdentifiedArrayOf<Post> = []

      let client = await MainActor.run {
        InstantClientFactory.makeClient(appID: app.id, instanceID: clientInstanceID)
      }
      try await InstantTestAuth.signInAsGuestAndReconnect(client: client, timeout: Self.timeout)
      try await waitForSchemaAttributes(client, timeout: Self.timeout)

      let profileId = UUID().uuidString.lowercased()
      let postId = UUID().uuidString.lowercased()
      let handle = "reverse-link-\(UUID().uuidString.prefix(8))"
      let nowMs = Date().timeIntervalSince1970 * 1000

      try await reactor.transact(
        appID: app.id,
        chunks: [
          TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [[
              "create", "profiles", profileId, [
                "displayName": "Reverse Link Author",
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
                "content": "Hello reverse links",
                "createdAt": nowMs,
              ],
            ]]
          ),
        ]
      )

      try await waitForProfileInLocalResults(id: profileId, profiles: { profiles }, timeout: Self.timeout)
      try await waitForPostInLocalResults(id: postId, posts: { posts }, timeout: Self.timeout)

      // Force offline so the only way for the Profile to reflect the link is via local store
      // notification (no server refresh can "paper over" a bug).
      setOnline(false)
      try await waitForDisconnected(client, timeout: Self.timeout)

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

      try await waitForProfileToContainPost(
        profileId: profileId,
        postId: postId,
        profiles: { profiles },
        timeout: Self.timeout
      )

      // Come back online and assert server truth via Admin API (no client caching).
      setOnline(true)
      try await InstantTestAuth.waitForAuthenticated(client, timeout: Self.timeout)

      let serverAuthorId = try await waitForAdminPostAuthorId(
        admin,
        postId: postId,
        timeout: Self.timeout
      )

      XCTAssertEqual(serverAuthorId.lowercased(), profileId.lowercased())

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
  private func waitForProfileInLocalResults(
    id: String,
    profiles: () -> IdentifiedArrayOf<Profile>,
    timeout: TimeInterval
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if profiles()[id: id] != nil { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Timed out waiting for Profile to appear in SharingInstant local results.")
  }

  @MainActor
  private func waitForPostInLocalResults(
    id: String,
    posts: () -> IdentifiedArrayOf<Post>,
    timeout: TimeInterval
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if posts()[id: id] != nil { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Timed out waiting for Post to appear in SharingInstant local results.")
  }

  @MainActor
  private func waitForProfileToContainPost(
    profileId: String,
    postId: String,
    profiles: () -> IdentifiedArrayOf<Profile>,
    timeout: TimeInterval
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      let profile = profiles()[id: profileId]
      if let posts = profile?.posts, posts.contains(where: { $0.id.lowercased() == postId.lowercased() }) {
        return
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    let profile = profiles()[id: profileId]
    XCTFail(
      """
      Timed out waiting for reverse link to appear in local results.

      Expected Profile.posts to include Post: \(postId)
      Actual Profile.posts count: \(profile?.posts?.count ?? 0)
      """
    )
  }

  @MainActor
  private func waitForAdminPostAuthorId(
    _ admin: InstantAdminAPI,
    postId: String,
    timeout: TimeInterval
  ) async throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    var lastSeenAuthor: String?

    while Date() < deadline {
      if let author = try await admin.queryPostAuthorId(postId: postId) {
        lastSeenAuthor = author
        return author
      }
      try await Task.sleep(nanoseconds: 200_000_000)
    }

    if let lastSeenAuthor {
      XCTFail("Timed out waiting for server to return author for post. Last seen author: \(lastSeenAuthor)")
    } else {
      XCTFail("Timed out waiting for server to return author for post: \(postId)")
    }

    throw NSError(domain: "ReverseLinkOfflineIntegrationTests", code: 1)
  }
}

// MARK: - InstantAdminAPI (Test-Only)

/// Minimal Swift wrapper over the InstantDB Admin HTTP API.
///
/// This test uses the admin API as the source of truth to avoid:
/// - client-side caching
/// - WebSocket reconnection races
/// - needing to "wait for a subscription refresh"
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

  func queryPostAuthorId(postId: String) async throws -> String? {
    let instaqlQuery: [String: Any] = [
      "posts": [
        "$": [
          "where": ["id": postId]
        ],
        // Include author so the response contains link data deterministically.
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

    // Some server responses represent one-to-one links as arrays.
    if let arr = authorValue as? [[String: Any]], let first = arr.first, let authorId = first["id"] as? String {
      return authorId
    }

    return nil
  }
}

