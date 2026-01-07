import InstantDB
import XCTest

@testable import SharingInstant

// MARK: - NestedFilteringIntegrationTests

/// Integration tests for InstaQL nested filtering (dot-path where clauses).
///
/// These tests exercise the Swift SharingInstant ergonomics (`EntityKeyPredicate`)
/// and the underlying InstantDB query semantics:
/// - Filtering a parent collection (`posts`) by a linked attribute (`author.handle`)
/// - Using case-insensitive prefix matching (`$ilike` via `.startsWith`)
final class NestedFilteringIntegrationTests: XCTestCase {
  static let timeout: TimeInterval = 20.0

  @MainActor
  func testPostsWhereAuthorHandleStartsWith() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-nested-filter",
      schema: EphemeralAppFactory.minimalMicroblogSchema(),
      rules: EphemeralAppFactory.openRules(for: ["profiles", "posts"])
    )

    let authClient = InstantClient(appID: app.id, enableLocalPersistence: false)
    try await InstantTestAuth.signInAsGuestAndReconnect(client: authClient, timeout: Self.timeout)
    authClient.disconnect()

    let store = SharedTripleStore()
    let reactor = Reactor(
      store: store,
      clientInstanceID: "nested-filter-\(UUID().uuidString.lowercased())"
    )

    let prefix = "b-nested-\(UUID().uuidString.lowercased())"

    let matchingProfileId = UUID().uuidString.lowercased()
    let nonMatchingProfileId = UUID().uuidString.lowercased()
    let matchingPostId = UUID().uuidString.lowercased()
    let nonMatchingPostId = UUID().uuidString.lowercased()

    let matchingHandle = "\(prefix)-match"
    let nonMatchingHandle = "a-nested-\(UUID().uuidString.lowercased())-other"

    let nowMs = Date().timeIntervalSince1970 * 1000

    // Subscribe before writing so we can verify the query updates in real time.
    let key = Schema.posts
      .with(\.author)
      .where("author.handle", .startsWith(prefix))

    let request = EntityKeyQueryRequest(key: key)
    guard let configuration = request.configuration else {
      XCTFail("Expected EntityKeyQueryRequest.configuration to be non-nil")
      return
    }

    let stream = await reactor.subscribe(appID: app.id, configuration: configuration)

    var latest: [Post] = []
    let receivedInitialEmission = XCTestExpectation(description: "Receives initial server emission for nested filter query")
    let expectation = XCTestExpectation(description: "Receives matching post from nested filter query")

    let consumeTask = Task { @MainActor in
      var didReceiveInitial = false
      for await posts in stream {
        latest = posts

        if !didReceiveInitial {
          didReceiveInitial = true
          receivedInitialEmission.fulfill()
        }

        let hasMatchingPost = posts.contains { $0.id == matchingPostId }
        if hasMatchingPost {
          expectation.fulfill()
          break
        }
      }
    }

    defer {
      consumeTask.cancel()
    }

    await fulfillment(of: [receivedInitialEmission], timeout: Self.timeout)

    // Create two authors and two posts, but only one author matches the prefix filter.
    let createMatchingProfile = TransactionChunk(
      namespace: "profiles",
      id: matchingProfileId,
      ops: [[
        "create", "profiles", matchingProfileId, [
          "displayName": "Nested Filter Match",
          "handle": matchingHandle,
          "createdAt": nowMs,
        ],
      ]]
    )

    let createNonMatchingProfile = TransactionChunk(
      namespace: "profiles",
      id: nonMatchingProfileId,
      ops: [[
        "create", "profiles", nonMatchingProfileId, [
          "displayName": "Nested Filter Non-Match",
          "handle": nonMatchingHandle,
          "createdAt": nowMs,
        ],
      ]]
    )

    let createMatchingPost = TransactionChunk(
      namespace: "posts",
      id: matchingPostId,
      ops: [[
        "create", "posts", matchingPostId, [
          "content": "Hello from matching author",
          "createdAt": nowMs,
        ],
      ]]
    )

    let createNonMatchingPost = TransactionChunk(
      namespace: "posts",
      id: nonMatchingPostId,
      ops: [[
        "create", "posts", nonMatchingPostId, [
          "content": "Hello from non-matching author",
          "createdAt": nowMs,
        ],
      ]]
    )

    let linkMatching = TransactionChunk(
      namespace: "posts",
      id: matchingPostId,
      ops: [[
        "link", "posts", matchingPostId, [
          "author": matchingProfileId,
        ],
      ]]
    )

    let linkNonMatching = TransactionChunk(
      namespace: "posts",
      id: nonMatchingPostId,
      ops: [[
        "link", "posts", nonMatchingPostId, [
          "author": nonMatchingProfileId,
        ],
      ]]
    )

    defer {
      Task {
        try? await reactor.transact(
          appID: app.id,
          chunks: [
            TransactionChunk(namespace: "posts", id: matchingPostId, ops: [["delete", "posts", matchingPostId]]),
            TransactionChunk(namespace: "posts", id: nonMatchingPostId, ops: [["delete", "posts", nonMatchingPostId]]),
            TransactionChunk(namespace: "profiles", id: matchingProfileId, ops: [["delete", "profiles", matchingProfileId]]),
            TransactionChunk(namespace: "profiles", id: nonMatchingProfileId, ops: [["delete", "profiles", nonMatchingProfileId]]),
          ]
        )
      }
    }

    try await reactor.transact(
      appID: app.id,
      chunks: [
        createMatchingProfile,
        createNonMatchingProfile,
        createMatchingPost,
        createNonMatchingPost,
        linkMatching,
        linkNonMatching,
      ]
    )

    await fulfillment(of: [expectation], timeout: Self.timeout)

    let verifierClient = InstantClient(appID: app.id, enableLocalPersistence: false)
    defer { verifierClient.disconnect() }
    try await InstantTestAuth.waitForAuthenticated(verifierClient, timeout: Self.timeout)

    let instaqlQuery: [String: Any] = [
      "posts": [
        "$": [
          "where": [
            "author.handle": ["$ilike": "\(prefix)%"],
          ]
        ]
      ]
    ]

    let serverSawMatching = try await waitForServerToReturn(
      client: verifierClient,
      query: instaqlQuery,
      expectedPostId: matchingPostId,
      timeout: Self.timeout
    )
    XCTAssertTrue(serverSawMatching, "Server should return the post for nested filter query.")

    XCTAssertFalse(latest.contains(where: { $0.id == nonMatchingPostId }))

    guard let returned = latest.first(where: { $0.id == matchingPostId }) else {
      XCTFail("Expected to find matching post in results")
      return
    }

    XCTAssertEqual(returned.author?.handle, matchingHandle)
    XCTAssertTrue(returned.author?.handle.hasPrefix(prefix) == true)
  }

  @MainActor
  private func waitForServerToReturn(
    client: InstantClient,
    query: [String: Any],
    expectedPostId: String,
    timeout: TimeInterval
  ) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      let result = try await client.queryOnce(query, timeout: min(5.0, timeout))
      let posts = result.get("posts")
      let containsExpected = posts.contains { row in
        (row["id"] as? String)?.lowercased() == expectedPostId
      }
      if containsExpected { return true }
      try await Task.sleep(nanoseconds: 200_000_000)
    }

    let result = try await client.queryOnce(query, timeout: min(5.0, timeout))
    let posts = result.get("posts")
    return posts.contains { row in
      (row["id"] as? String)?.lowercased() == expectedPostId
    }
  }
}
