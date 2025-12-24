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
  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  static let timeout: TimeInterval = 20.0

  @MainActor
  func testPostsWhereAuthorHandleStartsWith() async throws {
    try IntegrationTestGate.requireEnabled()

    InstantClientFactory.clearCache()
    addTeardownBlock {
      Task { @MainActor in
        InstantClientFactory.clearCache()
      }
    }

    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

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

    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: configuration)

    var latest: [Post] = []
    let expectation = XCTestExpectation(description: "Receives matching post from nested filter query")

    let consumeTask = Task { @MainActor in
      for await posts in stream {
        latest = posts

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
          "likesCount": 0,
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
          "likesCount": 0,
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
          appID: Self.testAppID,
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
      appID: Self.testAppID,
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

    XCTAssertFalse(latest.contains(where: { $0.id == nonMatchingPostId }))

    guard let returned = latest.first(where: { $0.id == matchingPostId }) else {
      XCTFail("Expected to find matching post in results")
      return
    }

    XCTAssertEqual(returned.author?.handle, matchingHandle)
    XCTAssertTrue(returned.author?.handle.hasPrefix(prefix) == true)
  }
}
