// BidirectionalSyncIntegrationTests.swift
// SharingInstantTests
//
// Comprehensive integration tests for bidirectional sync between Swift (@Shared)
// and TypeScript (Admin SDK). Uses Admin SDK as the source of truth.
//
// These tests verify:
// 1. Swift → TypeScript: Mutations from @Shared are received by Admin SDK
// 2. TypeScript → Swift: Mutations from Admin SDK are received by @Shared
// 3. Latency measurement for round-trip sync
// 4. Complex .with() queries sync correctly in both directions
// 5. Link mutations propagate correctly

import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// Note: This test file uses the generated Schema, Entities, and Mutations
// from Tests/SharingInstantTests/Generated/ which are compiled into this test target.

// MARK: - Test Result Types

/// Result from running the TypeScript bidirectional-sync-test script.
private struct ScriptResult: Decodable {
  let success: Bool
  let found: Bool?
  let namespace: String?
  let entityId: String?
  let latencyMs: Int?
  let durationMs: Int?
  let updateCount: Int?
  let error: String?
  let entity: AnyCodable?
  let linkedEntity: AnyCodable?
  let fieldsMatch: Bool?
  let mismatches: [String]?
  let appId: String?
  let adminToken: String?
  // Note: `updates` can be either an array (subscribe-and-wait) or dict (update-entity)
  // Using AnyCodable to handle both
  let updates: AnyCodable?
  let updateTimestampMs: Int?
}

// MARK: - Bidirectional Sync Integration Tests

/// Tests bidirectional sync between Swift @Shared and TypeScript Admin SDK.
///
/// ## Architecture
/// ```
/// ┌─────────────────────┐        ┌─────────────────────┐
/// │  Swift Test Code    │        │  TypeScript Script  │
/// │  (@Shared wrapper)  │◄──────►│  (Admin SDK)        │
/// └─────────────────────┘        └─────────────────────┘
///            │                            │
///            └──────────┬─────────────────┘
///                       ▼
///              ┌────────────────┐
///              │  InstantDB     │
///              │  Backend       │
///              └────────────────┘
/// ```
///
/// ## Test Pattern
/// 1. Create ephemeral app via TypeScript
/// 2. Swift subscribes via @Shared with complex queries
/// 3. Test sync in both directions, measure latency
/// 4. Verify data integrity using Admin SDK as source of truth
final class BidirectionalSyncIntegrationTests: XCTestCase {

  // MARK: - Properties

  private var appId: String!
  private var adminToken: String!
  private var store: SharedTripleStore!
  private var reactor: Reactor!

  // Latency tracking
  private var latencyMeasurements: [String: [Int]] = [:]

  // MARK: - Setup / Teardown

  @MainActor
  override func setUp() async throws {
    try await super.setUp()
    try IntegrationTestGate.requireEphemeralEnabled()

    // Clear any cached clients from previous tests FIRST
    InstantClientFactory.clearCache()

    // Create ephemeral app via TypeScript
    let createResult = try await runBidirectionalScript(mode: "create-app")
    guard createResult.success,
          let appId = createResult.appId,
          let adminToken = createResult.adminToken else {
      throw XCTSkip("Failed to create ephemeral app: \(createResult.error ?? "unknown")")
    }

    self.appId = appId
    self.adminToken = adminToken
    self.store = SharedTripleStore()

    // Use unique client instance ID per test to avoid cross-test interference
    let testName = String(describing: type(of: self)) + "-" + UUID().uuidString.prefix(8)
    self.reactor = Reactor(store: store, clientInstanceID: testName)
  }

  @MainActor
  override func tearDown() async throws {
    // Print latency summary if we collected any measurements
    if !latencyMeasurements.isEmpty {
      print("\n📊 Latency Summary:")
      for (name, measurements) in latencyMeasurements.sorted(by: { $0.key < $1.key }) {
        let avg = measurements.reduce(0, +) / max(1, measurements.count)
        let min = measurements.min() ?? 0
        let max = measurements.max() ?? 0
        print("  \(name): avg=\(avg)ms, min=\(min)ms, max=\(max)ms (n=\(measurements.count))")
      }
    }

    // Clear client cache to ensure clean state for next test
    InstantClientFactory.clearCache()

    // Small delay to allow async cleanup to complete
    try? await Task.sleep(nanoseconds: 100_000_000)

    appId = nil
    adminToken = nil
    store = nil
    reactor = nil
    latencyMeasurements = [:]
    try await super.tearDown()
  }

  // MARK: - Swift → TypeScript Tests

  /// Test: Swift creates a Profile, TypeScript Admin SDK verifies it.
  @MainActor
  func testSwiftCreateProfile_TypeScriptVerifies() async throws {
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = appId
      $0.instantEnableLocalPersistence = false
    } operation: {
      @Shared(.instantSync(Schema.profiles))
      var profiles: IdentifiedArrayOf<Profile> = []

      // Wait for initial sync
      try await Task.sleep(nanoseconds: 1_500_000_000)

      // Create profile using low-level create method
      let profileId = UUID().uuidString.lowercased()
      let now = Date().timeIntervalSince1970 * 1_000

      let profile = Profile(
        id: profileId,
        createdAt: now,
        displayName: "Alice from Swift",
        handle: "alice_swift_\(profileId.prefix(8))"
      )
      try await $profiles.create(profile)

      // Verify via TypeScript Admin SDK
      let verifyResult = try await runBidirectionalScript(
        mode: "wait-for-entity",
        args: [
          "--namespace", "profiles",
          "--entity-id", profileId,
          "--timeout-ms", "15000",
          "--expected", "{\"displayName\":\"Alice from Swift\"}"
        ]
      )

      XCTAssertTrue(verifyResult.success, "TypeScript should find the profile created by Swift")
      XCTAssertTrue(verifyResult.found ?? false, "Entity should be found")
      XCTAssertEqual(verifyResult.fieldsMatch, true, "Fields should match: \(verifyResult.mismatches ?? [])")

      // Record latency
      if let latencyMs = verifyResult.latencyMs {
        recordLatency("Swift→TS Profile Create", latencyMs)
        print("✅ Swift→TS Profile Create latency: \(latencyMs)ms")
      }
    }
  }

  /// Test: Swift creates a Post and links to Profile, TypeScript verifies the link.
  @MainActor
  func testSwiftCreatePostWithLink_TypeScriptVerifiesLink() async throws {
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = appId
      $0.instantEnableLocalPersistence = false
    } operation: {
      @Shared(.instantSync(Schema.profiles))
      var profiles: IdentifiedArrayOf<Profile> = []

      @Shared(.instantSync(Schema.posts))
      var posts: IdentifiedArrayOf<Post> = []

      try await Task.sleep(nanoseconds: 1_500_000_000)

      // Create profile first
      let profileId = UUID().uuidString.lowercased()
      let postId = UUID().uuidString.lowercased()
      let now = Date().timeIntervalSince1970 * 1_000

      let profile = Profile(
        id: profileId,
        createdAt: now,
        displayName: "Bob from Swift",
        handle: "bob_swift_\(profileId.prefix(8))"
      )
      try await $profiles.create(profile)
      try await Task.sleep(nanoseconds: 500_000_000)

      // Create post
      let post = Post(
        id: postId,
        content: "Hello from Swift!",
        createdAt: now
      )
      try await $posts.create(post)
      try await Task.sleep(nanoseconds: 500_000_000)

      // Link post to profile
      try await $posts.link(postId, "author", to: profileId, namespace: "profiles")

      // Wait for link to propagate to server
      try await Task.sleep(nanoseconds: 2_000_000_000)

      // Verify link via TypeScript Admin SDK
      let verifyResult = try await runBidirectionalScript(
        mode: "verify-linked",
        args: [
          "--namespace", "posts",
          "--entity-id", postId,
          "--link-label", "author",
          "--target-id", profileId,
          "--expected", "{\"displayName\":\"Bob from Swift\"}"
        ]
      )

      XCTAssertTrue(verifyResult.success, "TypeScript should verify the link: \(verifyResult.error ?? verifyResult.mismatches?.joined(separator: ", ") ?? "unknown")")

      if let latencyMs = verifyResult.durationMs {
        recordLatency("Swift→TS Link Verify", latencyMs)
        print("✅ Swift→TS Link verification: \(latencyMs)ms")
      }
    }
  }

  // MARK: - TypeScript → Swift Tests

  /// Test: TypeScript creates a Profile, Swift @Shared receives it.
  @MainActor
  func testTypeScriptCreateProfile_SwiftReceives() async throws {
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = appId
      $0.instantEnableLocalPersistence = false
    } operation: {
      @Shared(.instantSync(Schema.profiles))
      var profiles: IdentifiedArrayOf<Profile> = []

      // Wait for initial sync
      try await Task.sleep(nanoseconds: 1_500_000_000)
      XCTAssertEqual(profiles.count, 0, "Should start empty")

      // TypeScript creates a profile
      let profileId = UUID().uuidString.lowercased()
      let now = Date().timeIntervalSince1970 * 1_000
      let startMs = Int(Date().timeIntervalSince1970 * 1000)

      let writeResult = try await runBidirectionalScript(
        mode: "write-entity",
        args: [
          "--namespace", "profiles",
          "--entity-id", profileId,
          "--data", "{\"displayName\":\"Carol from TypeScript\",\"handle\":\"carol_ts_\(profileId.prefix(8))\",\"createdAt\":\(now)}"
        ]
      )
      XCTAssertTrue(writeResult.success, "TypeScript write should succeed")

      // Wait for Swift to receive the update
      var receivedLatencyMs: Int?
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        if profiles[id: profileId] != nil {
          receivedLatencyMs = Int(Date().timeIntervalSince1970 * 1000) - startMs
          break
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }

      XCTAssertNotNil(profiles[id: profileId], "Swift @Shared should receive the profile created by TypeScript")
      XCTAssertEqual(profiles[id: profileId]?.displayName, "Carol from TypeScript")

      if let latencyMs = receivedLatencyMs {
        recordLatency("TS→Swift Profile Create", latencyMs)
        print("✅ TS→Swift Profile Create latency: \(latencyMs)ms")
      }
    }
  }

  /// Test: TypeScript creates a Post with link, Swift @Shared with .with(\.author) receives it populated.
  @MainActor
  func testTypeScriptCreateLinkedPost_SwiftWithQueryReceives() async throws {
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = appId
      $0.instantEnableLocalPersistence = false
    } operation: {
      // Use .with(\.author) query
      @Shared(.instantSync(Schema.posts.with(\.author)))
      var posts: IdentifiedArrayOf<Post> = []

      try await Task.sleep(nanoseconds: 1_500_000_000)

      // Create profile via TypeScript
      let profileId = UUID().uuidString.lowercased()
      let postId = UUID().uuidString.lowercased()
      let now = Date().timeIntervalSince1970 * 1_000

      let profileResult = try await runBidirectionalScript(
        mode: "write-entity",
        args: [
          "--namespace", "profiles",
          "--entity-id", profileId,
          "--data", "{\"displayName\":\"Dave from TS\",\"handle\":\"dave_ts_\(profileId.prefix(8))\",\"createdAt\":\(now)}"
        ]
      )
      XCTAssertTrue(profileResult.success)

      // Create post with link via TypeScript
      let startMs = Int(Date().timeIntervalSince1970 * 1000)
      let postResult = try await runBidirectionalScript(
        mode: "write-entity",
        args: [
          "--namespace", "posts",
          "--entity-id", postId,
          "--data", "{\"content\":\"Post from TypeScript\",\"createdAt\":\(now)}",
          "--link-label", "author",
          "--target-id", profileId,
          "--target-namespace", "profiles"
        ]
      )
      XCTAssertTrue(postResult.success)

      // Wait for Swift to receive the post WITH the populated author link
      var receivedLatencyMs: Int?
      let deadline = Date().addingTimeInterval(20)
      while Date() < deadline {
        if let post = posts[id: postId], post.author?.id == profileId {
          receivedLatencyMs = Int(Date().timeIntervalSince1970 * 1000) - startMs
          break
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }

      let post = posts[id: postId]
      XCTAssertNotNil(post, "Swift should receive the post")
      XCTAssertEqual(post?.content, "Post from TypeScript")
      XCTAssertNotNil(post?.author, "Author link should be populated via .with() query")
      XCTAssertEqual(post?.author?.id, profileId)
      XCTAssertEqual(post?.author?.displayName, "Dave from TS")

      if let latencyMs = receivedLatencyMs {
        recordLatency("TS→Swift Linked Post", latencyMs)
        print("✅ TS→Swift Linked Post (with .with() query) latency: \(latencyMs)ms")
      }
    }
  }

  /// Test: TypeScript updates a linked Profile, Swift @Shared with .with(\.author) sees the update.
  ///
  /// **Known Issue**: This test throws CancellationError due to Swift concurrency interaction
  /// with XCTest async cleanup. The root cause needs investigation - the CancellationError
  /// occurs early (~3-4s) before the test logic completes, suggesting an issue with how
  /// subscriptions are being cancelled when the test context exits.
  @MainActor
  func testTypeScriptUpdateLinkedEntity_SwiftWithQueryReceivesUpdate() async throws {
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = appId
      $0.instantEnableLocalPersistence = false
    } operation: {
      @Shared(.instantSync(Schema.posts.with(\.author)))
      var posts: IdentifiedArrayOf<Post> = []

      try await Task.sleep(nanoseconds: 1_500_000_000)

      // Setup: Create profile and linked post via TypeScript
      let profileId = UUID().uuidString.lowercased()
      let postId = UUID().uuidString.lowercased()
      let now = Date().timeIntervalSince1970 * 1_000

      _ = try await runBidirectionalScript(
        mode: "write-entity",
        args: [
          "--namespace", "profiles",
          "--entity-id", profileId,
          "--data", "{\"displayName\":\"Eve Original\",\"handle\":\"eve_ts_\(profileId.prefix(8))\",\"createdAt\":\(now)}"
        ]
      )

      _ = try await runBidirectionalScript(
        mode: "write-entity",
        args: [
          "--namespace", "posts",
          "--entity-id", postId,
          "--data", "{\"content\":\"Eve's post\",\"createdAt\":\(now)}",
          "--link-label", "author",
          "--target-id", profileId,
          "--target-namespace", "profiles"
        ]
      )

      // Wait for initial sync
      let initialDeadline = Date().addingTimeInterval(15)
      while Date() < initialDeadline {
        if posts[id: postId]?.author?.displayName == "Eve Original" {
          break
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      XCTAssertEqual(posts[id: postId]?.author?.displayName, "Eve Original", "Initial state should be synced")

      // TypeScript updates the profile
      let updateStartMs = Int(Date().timeIntervalSince1970 * 1000)
      let updateResult = try await runBidirectionalScript(
        mode: "update-entity",
        args: [
          "--namespace", "profiles",
          "--entity-id", profileId,
          "--data", "{\"displayName\":\"Eve Updated\"}"
        ]
      )
      XCTAssertTrue(updateResult.success)

      // Wait for Swift to see the update in the linked entity
      var receivedLatencyMs: Int?
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        if posts[id: postId]?.author?.displayName == "Eve Updated" {
          receivedLatencyMs = Int(Date().timeIntervalSince1970 * 1000) - updateStartMs
          break
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }

      XCTAssertEqual(
        posts[id: postId]?.author?.displayName,
        "Eve Updated",
        "Swift .with() query should reflect linked entity updates from TypeScript"
      )

      if let latencyMs = receivedLatencyMs {
        recordLatency("TS→Swift Linked Update", latencyMs)
        print("✅ TS→Swift Linked Entity Update latency: \(latencyMs)ms")
      }
    }
  }

  // MARK: - Rapid Bidirectional Sync Tests

  /// Test: Rapid updates from both Swift and TypeScript don't lose data.
  ///
  /// **Known Issue**: This test throws CancellationError due to Swift concurrency interaction
  /// with XCTest async cleanup. The root cause needs investigation - the CancellationError
  /// occurs early (~3-4s) before the test logic completes, suggesting an issue with how
  /// subscriptions are being cancelled when the test context exits.
  @MainActor
  func testRapidBidirectionalUpdates_NoDataLoss() async throws {
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = appId
      $0.instantEnableLocalPersistence = false
    } operation: {
      @Shared(.instantSync(Schema.profiles))
      var profiles: IdentifiedArrayOf<Profile> = []

      try await Task.sleep(nanoseconds: 1_500_000_000)

      let profileId = UUID().uuidString.lowercased()
      let now = Date().timeIntervalSince1970 * 1_000

      // Create initial profile via Swift
      let profile = Profile(
        id: profileId,
        createdAt: now,
        displayName: "Initial",
        handle: "rapid_\(profileId.prefix(8))"
      )
      try await $profiles.create(profile)
      try await Task.sleep(nanoseconds: 500_000_000)

      // Rapid updates: Swift updates displayName, TypeScript updates bio
      // These should not clobber each other

      // Use updateField for field-level update that doesn't read entity first
      try await $profiles.updateField(id: profileId, field: "displayName", value: "Swift Updated")

      // Small delay, then TypeScript updates bio
      try await Task.sleep(nanoseconds: 50_000_000) // 50ms

      _ = try await runBidirectionalScript(
        mode: "update-entity",
        args: [
          "--namespace", "profiles",
          "--entity-id", profileId,
          "--data", "{\"bio\":\"TS Updated Bio\"}"
        ]
      )

      // Wait for both updates to propagate
      try await Task.sleep(nanoseconds: 3_000_000_000)

      // Verify via TypeScript (source of truth) that BOTH updates persisted
      let verifyResult = try await runBidirectionalScript(
        mode: "verify-entity",
        args: [
          "--namespace", "profiles",
          "--entity-id", profileId,
          "--expected", "{\"displayName\":\"Swift Updated\",\"bio\":\"TS Updated Bio\"}"
        ]
      )

      XCTAssertTrue(
        verifyResult.success,
        "Both Swift and TypeScript updates should persist without clobbering: \(verifyResult.mismatches ?? [])"
      )

      // Also verify Swift sees both updates
      let updatedProfile = profiles[id: profileId]
      XCTAssertEqual(updatedProfile?.displayName, "Swift Updated", "Swift should see its own update")
      XCTAssertEqual(updatedProfile?.bio, "TS Updated Bio", "Swift should see TypeScript's update")
    }
  }

  // MARK: - Complex Query Sync Tests

  /// Test: TypeScript creates 3-level nested data, Swift with recursive .with() query receives it all.
  @MainActor
  func testTypeScriptCreatesNestedData_SwiftRecursiveQueryReceives() async throws {
    try await withDependencies {
      $0.context = .live
      $0.instantReactor = reactor
      $0.instantAppID = appId
      $0.instantEnableLocalPersistence = false
    } operation: {
      // 3-level query: posts -> author + comments -> comment.author
      @Shared(.instantSync(
        Schema.posts
          .with(\.author)
          .with(\.comments) { $0.with(\.author) }
      ))
      var posts: IdentifiedArrayOf<Post> = []

      try await Task.sleep(nanoseconds: 2_000_000_000)

      let profileId = UUID().uuidString.lowercased()
      let commentAuthorId = UUID().uuidString.lowercased()
      let postId = UUID().uuidString.lowercased()
      let commentId = UUID().uuidString.lowercased()
      let now = Date().timeIntervalSince1970 * 1_000

      // Create all entities via TypeScript
      _ = try await runBidirectionalScript(
        mode: "write-entity",
        args: [
          "--namespace", "profiles",
          "--entity-id", profileId,
          "--data", "{\"displayName\":\"Post Author\",\"handle\":\"author_\(profileId.prefix(8))\",\"createdAt\":\(now)}"
        ]
      )

      _ = try await runBidirectionalScript(
        mode: "write-entity",
        args: [
          "--namespace", "profiles",
          "--entity-id", commentAuthorId,
          "--data", "{\"displayName\":\"Comment Author\",\"handle\":\"commenter_\(commentAuthorId.prefix(8))\",\"createdAt\":\(now)}"
        ]
      )

      let startMs = Int(Date().timeIntervalSince1970 * 1000)

      _ = try await runBidirectionalScript(
        mode: "write-entity",
        args: [
          "--namespace", "posts",
          "--entity-id", postId,
          "--data", "{\"content\":\"Nested test post\",\"createdAt\":\(now)}",
          "--link-label", "author",
          "--target-id", profileId,
          "--target-namespace", "profiles"
        ]
      )

      _ = try await runBidirectionalScript(
        mode: "write-entity",
        args: [
          "--namespace", "comments",
          "--entity-id", commentId,
          "--data", "{\"text\":\"Great post!\",\"createdAt\":\(now)}",
          "--link-label", "post",
          "--target-id", postId,
          "--target-namespace", "posts"
        ]
      )

      // Link comment to its author
      _ = try await runBidirectionalScript(
        mode: "link-entities",
        args: [
          "--namespace", "comments",
          "--entity-id", commentId,
          "--link-label", "author",
          "--target-id", commentAuthorId
        ]
      )

      // Wait for Swift to receive the complete nested structure
      var receivedLatencyMs: Int?
      let deadline = Date().addingTimeInterval(25)
      while Date() < deadline {
        let post = posts[id: postId]
        let hasAuthor = post?.author?.displayName == "Post Author"
        let hasComment = post?.comments?.first(where: { $0.id == commentId }) != nil
        let hasCommentAuthor = post?.comments?.first(where: { $0.id == commentId })?.author?.displayName == "Comment Author"

        if hasAuthor && hasComment && hasCommentAuthor {
          receivedLatencyMs = Int(Date().timeIntervalSince1970 * 1000) - startMs
          break
        }
        try await Task.sleep(nanoseconds: 200_000_000)
      }

      let post = posts[id: postId]
      XCTAssertNotNil(post, "Post should be received")
      XCTAssertEqual(post?.author?.displayName, "Post Author", "Post author should be populated")

      let comment = post?.comments?.first(where: { $0.id == commentId })
      XCTAssertNotNil(comment, "Comment should be in post.comments")
      XCTAssertEqual(comment?.text, "Great post!")
      XCTAssertEqual(comment?.author?.displayName, "Comment Author", "Comment author should be populated (3-level deep)")

      if let latencyMs = receivedLatencyMs {
        recordLatency("TS→Swift 3-Level Nested", latencyMs)
        print("✅ TS→Swift 3-Level Nested Query latency: \(latencyMs)ms")
      }
    }
  }

  // MARK: - Helpers

  private func recordLatency(_ name: String, _ ms: Int) {
    if latencyMeasurements[name] == nil {
      latencyMeasurements[name] = []
    }
    latencyMeasurements[name]?.append(ms)
  }

  @MainActor
  private func runBidirectionalScript(
    mode: String,
    args: [String] = []
  ) async throws -> ScriptResult {
    let scriptsDir = Self.repoRootURL().appendingPathComponent("scripts", isDirectory: true)

    var allArgs = ["run", "test:bidirectional-sync", "--", "--mode", mode]

    // Add credentials for non-create-app modes
    if mode != "create-app", let appId = appId, let adminToken = adminToken {
      allArgs += ["--app-id", appId, "--admin-token", adminToken]
    }

    allArgs += args

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["bun"] + allArgs
    process.currentDirectoryURL = scriptsDir

    var environment = ProcessInfo.processInfo.environment
    environment["BUN_DISABLE_TELEMETRY"] = "1"
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    if process.terminationStatus != 0 {
      let stderrStr = String(data: stderr, encoding: .utf8) ?? ""
      let stdoutStr = String(data: stdout, encoding: .utf8) ?? ""
      print("Script stderr: \(stderrStr)")
      print("Script stdout: \(stdoutStr)")
    }

    // Parse JSON output
    guard let result = try? JSONDecoder().decode(ScriptResult.self, from: stdout) else {
      let stdoutStr = String(data: stdout, encoding: .utf8) ?? "<non-utf8>"
      throw NSError(domain: "BidirectionalSyncTest", code: -1, userInfo: [
        NSLocalizedDescriptionKey: "Failed to parse script output: \(stdoutStr)"
      ])
    }

    return result
  }

  private static func repoRootURL(filePath: StaticString = #filePath) -> URL {
    let fileURL = URL(fileURLWithPath: String(describing: filePath))
    // Navigate from Tests/SharingInstantTests/ up to repo root
    return fileURL
      .deletingLastPathComponent() // BidirectionalSyncIntegrationTests.swift
      .deletingLastPathComponent() // SharingInstantTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // sharing-instant
  }
}
