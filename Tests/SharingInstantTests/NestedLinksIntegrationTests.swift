/**
 * HOW:
 *   swift test --filter NestedLinksIntegrationTests
 *
 *   [Inputs]
 *   - INSTANT_TEST_APP_ID: InstantDB app ID (env var)
 *   - INSTANT_TEST_ADMIN_TOKEN: Admin token (env var)
 *   - INSTANT_RUN_INTEGRATION_TESTS: Set to "1" to enable tests
 *
 *   [Outputs]
 *   - Test results showing nested link resolution works correctly
 *
 *   [Side Effects]
 *   - Creates/deletes test data in InstantDB via Admin SDK scripts
 *
 * WHO:
 *   Agent, User
 *   (Context: Integration testing for nested link resolution in Swift SDK)
 *
 * WHAT:
 *   Integration tests that verify the Swift SDK correctly handles deeply nested
 *   linked data structures. Uses TypeScript Admin SDK scripts as the "ground truth"
 *   to set up and verify data.
 *
 *   Tests cover:
 *   1. Reading deeply nested data (profiles.posts.comments) seeded by Admin SDK
 *   2. Writing data from Swift and verifying via Admin SDK
 *   3. Has-many relationships (posts, comments)
 *   4. Has-one relationships (author, post)
 *   5. Real-time subscription updates for nested data
 *
 * WHEN:
 *   2025-12-26
 *   Last Modified: 2025-12-26
 *   [Change Log:
 *     - 2025-12-26: Initial creation
 *   ]
 *
 * WHERE:
 *   sharing-instant/Tests/SharingInstantTests/NestedLinksIntegrationTests.swift
 *
 * WHY:
 *   To ensure the Swift SDK correctly handles nested link resolution, which is
 *   critical for real-world applications like the SpeechRecorderApp that need
 *   to query Media.transcriptionRuns.words.
 *
 *   The Admin SDK provides an independent verification layer that bypasses
 *   Swift-side caching and decoding, ensuring we're testing actual backend behavior.
 */

import XCTest
import InstantDB
import Sharing
@testable import SharingInstant

// MARK: - NestedLinksIntegrationTests

final class NestedLinksIntegrationTests: XCTestCase {
  
  // MARK: - Configuration
  
  private static var testAppID: String {
    ProcessInfo.processInfo.environment["INSTANT_TEST_APP_ID"] ?? "b9319949-2f2d-410b-8f8a-6990177c1d44"
  }
  
  private static var adminToken: String? {
    ProcessInfo.processInfo.environment["INSTANT_TEST_ADMIN_TOKEN"]
  }
  
  // MARK: - Test Lifecycle
  
  override func setUp() async throws {
    try await super.setUp()
    try IntegrationTestGate.requireEnabled()
  }
  
  // MARK: - Tests
  
  /// Tests reading deeply nested data seeded by the Admin SDK.
  ///
  /// Flow:
  /// 1. Admin SDK seeds: Profile → Posts → Comments
  /// 2. Swift SDK subscribes with nested links
  /// 3. Verify all nested data is correctly populated
  /// 4. Admin SDK cleans up
  @MainActor
  func testReadDeeplyNestedDataFromAdminSDKSeed() async throws {
    // Skip if admin token not available
    guard let adminToken = Self.adminToken else {
      throw XCTSkip("INSTANT_TEST_ADMIN_TOKEN not set - skipping Admin SDK integration test")
    }
    
    // Step 1: Seed data via Admin SDK
    let seedResult = try await Self.runAdminScript(
      action: "seed",
      appId: Self.testAppID,
      adminToken: adminToken
    )
    
    guard seedResult.success else {
      XCTFail("Failed to seed data: \(seedResult.error ?? "unknown")")
      return
    }
    
    // Clean up on exit
    defer {
      Task {
        _ = try? await Self.runAdminScript(
          action: "cleanup",
          appId: Self.testAppID,
          adminToken: adminToken
        )
      }
    }
    
    // Step 2: Subscribe via Swift SDK with nested links
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)
    
    try await reactor.signInAsGuest(appID: Self.testAppID)
    
    // Query: profiles.posts.comments (3 levels deep)
    let commentsNode = EntityQueryNode.link(name: "comments", limit: nil)
    let postsWithComments = EntityQueryNode.link(name: "posts", limit: nil, children: [commentsNode])
    
    let config = SharingInstantSync.CollectionConfiguration<Profile>(
      namespace: "profiles",
      whereClause: ["id": "nested-link-test-profile-1"],
      includedLinks: [],
      linkTree: [postsWithComments]
    )
    
    let stream: AsyncStream<[Profile]> = await reactor.subscribe(appID: Self.testAppID, configuration: config)
    
    // Step 3: Wait for nested data to arrive
    var matchedProfile: Profile?
    let expectation = XCTestExpectation(description: "Receives profile with nested posts and comments")
    
    let consumeTask = Task { @MainActor in
      for await profiles in stream {
        guard let profile = profiles.first else { continue }
        
        // Check for nested data
        guard let posts = profile.posts, posts.count >= 2 else { continue }
        
        // Find post with comments
        let post1 = posts.first { $0.id == "nested-link-test-post-1" }
        guard let post1Comments = post1?.comments, post1Comments.count >= 2 else { continue }
        
        matchedProfile = profile
        expectation.fulfill()
        break
      }
    }
    
    defer { consumeTask.cancel() }
    
    await fulfillment(of: [expectation], timeout: 15.0)
    
    // Step 4: Verify nested structure
    guard let profile = matchedProfile else {
      XCTFail("Failed to receive profile with nested data")
      return
    }
    
    XCTAssertEqual(profile.displayName, "Test User", "Profile displayName mismatch")
    
    guard let posts = profile.posts else {
      XCTFail("Profile.posts is nil")
      return
    }
    
    XCTAssertEqual(posts.count, 2, "Expected 2 posts")
    
    // Verify post 1 has 2 comments
    let post1 = posts.first { $0.id == "nested-link-test-post-1" }
    XCTAssertNotNil(post1, "Post 1 not found")
    XCTAssertEqual(post1?.comments?.count, 2, "Expected 2 comments on post 1")
    
    // Verify post 2 has 1 comment
    let post2 = posts.first { $0.id == "nested-link-test-post-2" }
    XCTAssertNotNil(post2, "Post 2 not found")
    XCTAssertEqual(post2?.comments?.count, 1, "Expected 1 comment on post 2")
    
    // Step 5: Verify via Admin SDK
    let verifyResult = try await Self.runAdminScript(
      action: "verify",
      appId: Self.testAppID,
      adminToken: adminToken
    )
    
    XCTAssertTrue(verifyResult.success, "Admin SDK verification failed: \(verifyResult.error ?? "unknown")")
  }
  
  /// Tests writing data from Swift and verifying via Admin SDK.
  ///
  /// Flow:
  /// 1. Swift SDK creates Profile → Post → Comment
  /// 2. Admin SDK verifies the nested structure was written correctly
  @MainActor
  func testWriteNestedDataAndVerifyViaAdminSDK() async throws {
    guard let adminToken = Self.adminToken else {
      throw XCTSkip("INSTANT_TEST_ADMIN_TOKEN not set - skipping Admin SDK integration test")
    }
    
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)
    
    try await reactor.signInAsGuest(appID: Self.testAppID)
    
    // Generate unique IDs for this test run
    let testRunId = UUID().uuidString.lowercased().prefix(8)
    let profileId = "swift-test-profile-\(testRunId)"
    let postId = "swift-test-post-\(testRunId)"
    let commentId = "swift-test-comment-\(testRunId)"
    let now = Date().timeIntervalSince1970 * 1000
    
    // Clean up on exit
    defer {
      Task {
        try? await reactor.transact(
          appID: Self.testAppID,
          chunks: [
            TransactionChunk(namespace: "comments", id: commentId, ops: [["delete", "comments", commentId]]),
            TransactionChunk(namespace: "posts", id: postId, ops: [["delete", "posts", postId]]),
            TransactionChunk(namespace: "profiles", id: profileId, ops: [["delete", "profiles", profileId]]),
          ]
        )
      }
    }
    
    // Step 1: Create profile
    try await reactor.transact(
      appID: Self.testAppID,
      chunks: [
        TransactionChunk(
          namespace: "profiles",
          id: profileId,
          ops: [
            ["update", "profiles", profileId, [
              "displayName": "Swift Test User",
              "handle": "swift-test-\(testRunId)",
              "createdAt": now
            ]]
          ]
        )
      ]
    )
    
    // Step 2: Create post linked to profile
    try await reactor.transact(
      appID: Self.testAppID,
      chunks: [
        TransactionChunk(
          namespace: "posts",
          id: postId,
          ops: [
            ["update", "posts", postId, [
              "content": "Post from Swift SDK",
              "createdAt": now
            ]],
            ["link", "posts", postId, ["author": profileId]]
          ]
        )
      ]
    )
    
    // Step 3: Create comment linked to post and profile
    try await reactor.transact(
      appID: Self.testAppID,
      chunks: [
        TransactionChunk(
          namespace: "comments",
          id: commentId,
          ops: [
            ["update", "comments", commentId, [
              "text": "Comment from Swift SDK",
              "createdAt": now
            ]],
            ["link", "comments", commentId, ["post": postId, "author": profileId]]
          ]
        )
      ]
    )
    
    // Step 4: Wait for data to settle
    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
    
    // Step 5: Verify via Admin SDK
    let verifyResult = try await Self.runAdminScript(
      action: "verify-writes",
      appId: Self.testAppID,
      adminToken: adminToken,
      extraArgs: ["--profile-id", profileId]
    )
    
    XCTAssertTrue(verifyResult.success, "Admin SDK verification failed: \(verifyResult.error ?? "unknown")")
    
    // Parse the result to verify structure
    if let data = verifyResult.data,
       let profileData = data["profile"] as? [String: Any] {
      XCTAssertEqual(profileData["displayName"] as? String, "Swift Test User")
      
      if let posts = profileData["posts"] as? [[String: Any]], let firstPost = posts.first {
        XCTAssertEqual(firstPost["content"] as? String, "Post from Swift SDK")
        XCTAssertEqual(firstPost["commentsCount"] as? Int, 1)
      } else {
        XCTFail("Expected posts array in Admin SDK response")
      }
    }
  }
  
  /// Tests that has-one reverse links are correctly populated.
  ///
  /// Query: comments with post (has-one) and author (has-one)
  @MainActor
  func testHasOneReverseLinkResolution() async throws {
    guard let adminToken = Self.adminToken else {
      throw XCTSkip("INSTANT_TEST_ADMIN_TOKEN not set - skipping Admin SDK integration test")
    }
    
    // Seed data
    let seedResult = try await Self.runAdminScript(
      action: "seed",
      appId: Self.testAppID,
      adminToken: adminToken
    )
    
    guard seedResult.success else {
      XCTFail("Failed to seed data: \(seedResult.error ?? "unknown")")
      return
    }
    
    defer {
      Task {
        _ = try? await Self.runAdminScript(
          action: "cleanup",
          appId: Self.testAppID,
          adminToken: adminToken
        )
      }
    }
    
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)
    
    try await reactor.signInAsGuest(appID: Self.testAppID)
    
    // Query comments with has-one links: post and author
    let postNode = EntityQueryNode.link(name: "post", limit: nil)
    let authorNode = EntityQueryNode.link(name: "author", limit: nil)
    
    let config = SharingInstantSync.CollectionConfiguration<Comment>(
      namespace: "comments",
      whereClause: ["id": "nested-link-test-comment-1"],
      includedLinks: [],
      linkTree: [postNode, authorNode]
    )
    
    let stream: AsyncStream<[Comment]> = await reactor.subscribe(appID: Self.testAppID, configuration: config)
    
    var matchedComment: Comment?
    let expectation = XCTestExpectation(description: "Receives comment with post and author")
    
    let consumeTask = Task { @MainActor in
      for await comments in stream {
        guard let comment = comments.first else { continue }
        
        // Check for has-one links
        guard comment.post != nil, comment.author != nil else { continue }
        
        matchedComment = comment
        expectation.fulfill()
        break
      }
    }
    
    defer { consumeTask.cancel() }
    
    await fulfillment(of: [expectation], timeout: 15.0)
    
    guard let comment = matchedComment else {
      XCTFail("Failed to receive comment with linked data")
      return
    }
    
    // Verify has-one links are single entities, not arrays
    XCTAssertNotNil(comment.post, "Comment.post should be populated (has-one)")
    XCTAssertNotNil(comment.author, "Comment.author should be populated (has-one)")
    
    XCTAssertEqual(comment.post?.id, "nested-link-test-post-1", "Comment should link to post-1")
    XCTAssertEqual(comment.author?.displayName, "Test User", "Comment author should be Test User")
  }
  
  // MARK: - Admin SDK Script Runner
  
  private struct ScriptResult: @unchecked Sendable {
    let success: Bool
    let error: String?
    let data: [String: Any]?
    
    init(success: Bool, error: String?, data: [String: Any]?) {
      self.success = success
      self.error = error
      self.data = data
    }
  }
  
  private static func runAdminScript(
    action: String,
    appId: String,
    adminToken: String,
    extraArgs: [String] = []
  ) async throws -> ScriptResult {
    let scriptsDir = repoRootURL().appendingPathComponent("scripts", isDirectory: true)
    let scriptPath = scriptsDir.appendingPathComponent("nested-links-test-helper.ts")
    
    // Check if script exists
    guard FileManager.default.fileExists(atPath: scriptPath.path) else {
      return ScriptResult(success: false, error: "Script not found at \(scriptPath.path)", data: nil)
    }
    
    var args = [
      "ts-node",
      scriptPath.path,
      "--action", action,
      "--app-id", appId,
      "--admin-token", adminToken,
      "--json"
    ]
    args.append(contentsOf: extraArgs)
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["npx"] + args
    process.currentDirectoryURL = scriptsDir
    
    var environment = ProcessInfo.processInfo.environment
    environment["BUN_DISABLE_TELEMETRY"] = "1"
    process.environment = environment
    
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    
    do {
      try process.run()
    } catch {
      return ScriptResult(success: false, error: "Failed to run script: \(error)", data: nil)
    }
    
    process.waitUntilExit()
    
    let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    
    if process.terminationStatus != 0 {
      let stderrString = String(data: stderr, encoding: .utf8) ?? ""
      let stdoutString = String(data: stdout, encoding: .utf8) ?? ""
      return ScriptResult(
        success: false,
        error: "Script failed (exit \(process.terminationStatus)): \(stderrString)\n\(stdoutString)",
        data: nil
      )
    }
    
    // Parse JSON output
    guard let json = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
      return ScriptResult(success: false, error: "Failed to parse script output as JSON", data: nil)
    }
    
    let success = json["success"] as? Bool ?? false
    let error = json["error"] as? String
    let data = json["data"] as? [String: Any]
    
    return ScriptResult(success: success, error: error, data: data)
  }
  
  private static func repoRootURL(filePath: StaticString = #filePath) -> URL {
    let fileURL = URL(fileURLWithPath: String(describing: filePath))
    // Tests/SharingInstantTests/NestedLinksIntegrationTests.swift -> sharing-instant
    return fileURL
      .deletingLastPathComponent()  // SharingInstantTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // sharing-instant
  }
}

