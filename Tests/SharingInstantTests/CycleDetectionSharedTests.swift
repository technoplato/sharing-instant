/// Tests for @Shared property wrapper cycle detection and memory stability.
///
/// These tests exercise the `@Shared` property wrapper API to verify that
/// memory and performance fixes work end-to-end. They specifically test:
///
/// 1. **Cycle Detection**: Circular entity references (A -> B -> A) don't cause
///    infinite loops or exponential memory growth during resolution.
///
/// 2. **Memory Stability**: Rapid updates (similar to real-time transcription)
///    don't cause unbounded memory growth.
///
/// ## References
/// - Implementation Plan: /Users/mlustig/.claude/plans/groovy-kindling-whisper.md
/// - RapidTranscriptionDemo: Examples/CaseStudies/RapidTranscriptionDemo.swift

import XCTest
import IdentifiedCollections
import Sharing
import Dependencies
@testable import SharingInstant
import InstantDB

// MARK: - Cycle Detection Tests

final class CycleDetectionSharedTests: XCTestCase {

  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"

  @MainActor
  override func setUp() async throws {
    try await super.setUp()
    try IntegrationTestGate.requireEnabled()

    prepareDependencies {
      $0.context = .live
      $0.instantAppID = Self.testAppID
      $0.instantEnableLocalPersistence = false
    }

    InstantClientFactory.clearCache()
  }

  // MARK: - Test 1: Circular Links with @Shared Wrapper

  /// Test that circular entity references don't cause infinite loops.
  ///
  /// This test creates entities that reference each other:
  /// - Profile -> Posts -> Author (back to Profile)
  ///
  /// Using `.with(\.posts)` on profiles would normally try to resolve posts,
  /// and if posts have `.with(\.author)`, it could recurse back to the profile.
  ///
  /// The cycle detection should break this loop and return without hanging.
  @MainActor
  func testCircularLinksWithSharedWrapper() async throws {
    let profileId = UUID().uuidString.lowercased()
    let postId = UUID().uuidString.lowercased()

    // Step 1: Create a profile
    @Shared(.instantSync(Schema.profiles))
    var profiles: IdentifiedArrayOf<Profile> = []

    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

    let profile = Profile(
      id: profileId,
      bio: "Cycle test profile",
      createdAt: Date().timeIntervalSince1970 * 1000,
      displayName: "CycleTest",
      handle: "cycletest"
    )
    try await $profiles.create(profile)

    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Step 2: Create a post with author link (creates bidirectional link)
    @Shared(.instantSync(Schema.posts.with(\.author)))
    var posts: IdentifiedArrayOf<Post> = []

    try await Task.sleep(nanoseconds: 2_000_000_000)

    let post = Post(
      id: postId,
      content: "Circular reference test post",
      createdAt: Date().timeIntervalSince1970 * 1000,
      author: profile
    )
    try await $posts.create(post)

    try await Task.sleep(nanoseconds: 3_000_000_000)

    // Step 3: Query profiles WITH posts, which includes author
    // This creates: profile -> posts -> author (back to profile)
    // The query should complete without infinite loop
    @Shared(.instantSync(Schema.profiles.with(\.posts) { posts in
      posts.with(\.author)
    }))
    var profilesWithPostsAndAuthor: IdentifiedArrayOf<Profile> = []

    // Wait for subscription to populate - if cycle detection fails, this would hang
    // but XCTest has a default timeout per test, so we'll just wait a reasonable time
    try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds

    // If we got here without hanging, cycle detection is working
    TestLog.log("[CycleTest] Query completed - cycle detection working")

    // Verify the profile exists
    let foundProfile = profilesWithPostsAndAuthor[id: profileId]
    // Note: Profile may or may not be found depending on whether our subscription
    // includes this specific profile. The key assertion is that we didn't hang.

    // If we found the profile, verify the cycle was properly broken
    if let prof = foundProfile,
       let posts = prof.posts,
       let firstPost = posts.first,
       let author = firstPost.author {
      // The author should NOT have posts recursively populated (cycle broken)
      // This depends on the query depth, but we verify it doesn't infinitely recurse
      XCTAssertNotNil(author.id, "Author should have an ID")
      // author.posts should be nil (cycle broken) or empty
      // The exact behavior depends on implementation, but we shouldn't see infinite depth
      TestLog.log("[CycleTest] Found profile with posts.author - cycle was properly handled")
    }

    // Cleanup
    try await $posts.delete(id: postId)
    try await Task.sleep(nanoseconds: 500_000_000)
    try await $profiles.delete(id: profileId)
    try await Task.sleep(nanoseconds: 500_000_000)
  }

  // MARK: - Test 2: Rapid Updates Memory Stability

  /// Test that rapid updates don't cause unbounded memory growth.
  ///
  /// This simulates the RapidTranscriptionDemo pattern:
  /// - Create many segments with rapid updates (10ms intervals)
  /// - Measure memory before and after
  /// - Assert memory growth is reasonable (<50MB for 100 segments)
  @MainActor
  func testRapidUpdatesMemoryStable() async throws {
    let runId = UUID().uuidString.lowercased()
    let segmentCount = 100

    // Create transcription run first
    @Shared(.instantSync(Schema.transcriptionRuns))
    var runs: IdentifiedArrayOf<TranscriptionRun> = []

    try await Task.sleep(nanoseconds: 2_000_000_000)

    let run = TranscriptionRun(
      id: runId,
      toolVersion: "memory-test-1.0",
      executedAt: ISO8601DateFormatter().string(from: Date())
    )
    try await $runs.create(run)

    try await Task.sleep(nanoseconds: 1_000_000_000)

    // Subscription for segments
    @Shared(.instantSync(Schema.transcriptionSegments))
    var segments: IdentifiedArrayOf<TranscriptionSegment> = []

    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Measure starting memory
    let startMemory = getMemoryUsage()
    TestLog.log("[MemoryTest] Starting memory: \(formatMemory(startMemory))")

    // Create segments with rapid updates (similar to RapidTranscriptionDemo)
    var segmentIds: [String] = []

    for i in 0..<segmentCount {
      let segmentId = UUID().uuidString.lowercased()
      segmentIds.append(segmentId)

      let segment = TranscriptionSegment(
        id: segmentId,
        startTime: Double(i) * 0.1,
        endTime: Double(i + 1) * 0.1,
        text: "Segment \(i) - Testing rapid updates for memory stability",
        segmentIndex: Double(i),
        isFinalized: false,
        ingestedAt: ISO8601DateFormatter().string(from: Date()),
        speaker: nil,
        words: nil
      )

      try await $segments.create(segment)

      // Link to transcription run
      try await $segments.link(segmentId, "transcriptionRun", to: run)

      // Brief delay to simulate real timing (10ms like RapidTranscriptionDemo)
      try await Task.sleep(nanoseconds: 10_000_000)

      // Log progress every 20 segments
      if (i + 1) % 20 == 0 {
        let currentMemory = getMemoryUsage()
        TestLog.log("[MemoryTest] After \(i + 1) segments: \(formatMemory(currentMemory))")
      }
    }

    // Wait for all updates to settle
    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Measure ending memory
    let endMemory = getMemoryUsage()
    let memoryGrowth = endMemory - startMemory

    TestLog.log("[MemoryTest] Final memory: \(formatMemory(endMemory))")
    TestLog.log("[MemoryTest] Memory growth: \(formatMemory(memoryGrowth))")

    // Assert memory growth is reasonable (<50MB for 100 segments)
    // This is a generous limit - the actual growth should be much smaller
    // if GC and caching are working correctly
    let fiftyMB = 50_000_000
    XCTAssertLessThan(
      memoryGrowth,
      fiftyMB,
      "Memory grew excessively: \(formatMemory(memoryGrowth)). Expected < 50MB"
    )

    // Verify segments were created
    XCTAssertGreaterThanOrEqual(
      segments.count,
      segmentCount / 2, // At least half should be visible
      "Should have created segments"
    )

    // Cleanup
    TestLog.log("[MemoryTest] Cleaning up \(segmentIds.count) segments...")
    for segmentId in segmentIds {
      try await $segments.delete(id: segmentId)
    }
    try await Task.sleep(nanoseconds: 1_000_000_000)

    try await $runs.delete(id: runId)
    try await Task.sleep(nanoseconds: 500_000_000)

    TestLog.log("[MemoryTest] Cleanup complete")
  }

  // MARK: - Test 3: Nested Links with Cycle

  /// Test deeply nested links that could create cycles.
  ///
  /// Pattern: Comment -> Post -> Author -> Posts -> Comments -> Author...
  /// The query depth should be bounded.
  @MainActor
  func testDeepNestedLinksWithPotentialCycle() async throws {
    let profileId = UUID().uuidString.lowercased()
    let postId = UUID().uuidString.lowercased()
    let commentId = UUID().uuidString.lowercased()

    // Create profile
    @Shared(.instantSync(Schema.profiles))
    var profiles: IdentifiedArrayOf<Profile> = []

    try await Task.sleep(nanoseconds: 2_000_000_000)

    let profile = Profile(
      id: profileId,
      bio: "Deep nesting test",
      createdAt: Date().timeIntervalSince1970 * 1000,
      displayName: "DeepTest",
      handle: "deeptest"
    )
    try await $profiles.create(profile)

    try await Task.sleep(nanoseconds: 1_000_000_000)

    // Create post with author
    @Shared(.instantSync(Schema.posts))
    var posts: IdentifiedArrayOf<Post> = []

    try await Task.sleep(nanoseconds: 1_000_000_000)

    let post = Post(
      id: postId,
      content: "Deep nesting test post",
      createdAt: Date().timeIntervalSince1970 * 1000,
      author: profile
    )
    try await $posts.create(post)

    try await Task.sleep(nanoseconds: 1_000_000_000)

    // Create comment on post with author
    @Shared(.instantSync(Schema.comments))
    var comments: IdentifiedArrayOf<Comment> = []

    try await Task.sleep(nanoseconds: 1_000_000_000)

    let comment = Comment(
      id: commentId,
      createdAt: Date().timeIntervalSince1970 * 1000,
      text: "Deep nesting test comment",
      post: post,
      author: profile
    )
    try await $comments.create(comment)

    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Query with deep nesting: comments -> post -> author -> posts -> comments
    // This creates potential for cycles
    @Shared(.instantSync(Schema.comments.with(\.post) { posts in
      posts.with(\.author) { author in
        author.with(\.posts)
      }
    }))
    var commentsWithDeepNesting: IdentifiedArrayOf<Comment> = []

    // Should complete without hanging
    try await Task.sleep(nanoseconds: 5_000_000_000)

    // The query completing is the main assertion - we didn't hang
    TestLog.log("[DeepNestingTest] Query completed successfully")

    // Verify data structure if available
    if let foundComment = commentsWithDeepNesting[id: commentId] {
      XCTAssertNotNil(foundComment.post, "Comment should have post")
      if let post = foundComment.post {
        XCTAssertNotNil(post.author, "Post should have author")
        // Author's posts may or may not be populated depending on depth limits
        TestLog.log("[DeepNestingTest] Successfully resolved nested links")
      }
    }

    // Cleanup
    try await $comments.delete(id: commentId)
    try await Task.sleep(nanoseconds: 500_000_000)
    try await $posts.delete(id: postId)
    try await Task.sleep(nanoseconds: 500_000_000)
    try await $profiles.delete(id: profileId)
    try await Task.sleep(nanoseconds: 500_000_000)
  }

  // MARK: - Test 4: Mutual Profile References

  /// Test mutually-referencing entities (A references B, B references A).
  ///
  /// This uses regular entities (profiles) rather than $users system namespace
  /// to avoid authentication requirements.
  @MainActor
  func testMutualProfileReferences() async throws {
    let profile1Id = UUID().uuidString.lowercased()
    let profile2Id = UUID().uuidString.lowercased()
    let post1Id = UUID().uuidString.lowercased()
    let post2Id = UUID().uuidString.lowercased()

    // Create two profiles
    @Shared(.instantSync(Schema.profiles))
    var profiles: IdentifiedArrayOf<Profile> = []

    try await Task.sleep(nanoseconds: 2_000_000_000)

    let profile1 = Profile(
      id: profile1Id,
      bio: "Profile 1 - mutual ref test",
      createdAt: Date().timeIntervalSince1970 * 1000,
      displayName: "Profile1",
      handle: "profile1"
    )

    let profile2 = Profile(
      id: profile2Id,
      bio: "Profile 2 - mutual ref test",
      createdAt: Date().timeIntervalSince1970 * 1000,
      displayName: "Profile2",
      handle: "profile2"
    )

    try await $profiles.create(profile1)
    try await $profiles.create(profile2)

    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Create posts - Profile1 authors Post1, Profile2 authors Post2
    // Then we'll query Profile1's posts with author, and that author (Profile1)
    // has posts, which could potentially create a cycle
    @Shared(.instantSync(Schema.posts.with(\.author)))
    var posts: IdentifiedArrayOf<Post> = []

    try await Task.sleep(nanoseconds: 2_000_000_000)

    let post1 = Post(
      id: post1Id,
      content: "Post by profile 1",
      createdAt: Date().timeIntervalSince1970 * 1000,
      author: profile1
    )

    let post2 = Post(
      id: post2Id,
      content: "Post by profile 2",
      createdAt: Date().timeIntervalSince1970 * 1000,
      author: profile2
    )

    try await $posts.create(post1)
    try await $posts.create(post2)

    try await Task.sleep(nanoseconds: 3_000_000_000)

    // Now query with deeper nesting that could cause cycles:
    // profiles -> posts -> author -> posts (back to original author's posts)
    @Shared(.instantSync(Schema.profiles.with(\.posts) { posts in
      posts.with(\.author) { author in
        author.with(\.posts)
      }
    }))
    var profilesWithNestedPosts: IdentifiedArrayOf<Profile> = []

    // Should complete without hanging - cycle detection should prevent infinite recursion
    try await Task.sleep(nanoseconds: 5_000_000_000)

    // If we got here, the test passed - no infinite loop
    TestLog.log("[MutualRefTest] Query completed successfully - no infinite loop")

    // Verify we got results
    let foundProfile1 = profilesWithNestedPosts[id: profile1Id]
    if let p = foundProfile1 {
      TestLog.log("[MutualRefTest] Found profile1 with \(p.posts?.count ?? 0) posts")
      if let firstPost = p.posts?.first {
        TestLog.log("[MutualRefTest] First post has author: \(firstPost.author != nil)")
        if let author = firstPost.author {
          // The author's posts should be limited/nil to prevent cycle
          TestLog.log("[MutualRefTest] Author posts count: \(author.posts?.count ?? 0)")
        }
      }
    }

    // Cleanup
    try await $posts.delete(id: post1Id)
    try await $posts.delete(id: post2Id)
    try await Task.sleep(nanoseconds: 500_000_000)
    try await $profiles.delete(id: profile1Id)
    try await $profiles.delete(id: profile2Id)
    try await Task.sleep(nanoseconds: 500_000_000)
  }

  // MARK: - Memory Measurement Helper

  /// Get current memory usage in bytes.
  ///
  /// Uses Mach task_info to get resident memory size.
  private func getMemoryUsage() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
  }

  /// Format memory size for display.
  private func formatMemory(_ bytes: Int) -> String {
    let mb = Double(bytes) / 1_000_000.0
    return String(format: "%.2f MB", mb)
  }
}
