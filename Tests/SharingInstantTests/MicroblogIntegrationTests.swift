import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - Microblog Integration Tests

/// Integration tests that exercise the @Shared wrappers verbatim from the MicroblogDemo.
///
/// These tests verify that entity links work correctly:
/// - Profiles can be created and synced
/// - Posts can be created with linked authors
/// - The `.with(\.author)` query correctly populates linked entities
/// - Links are correctly persisted in InstantDB
///
/// ## Test App Configuration
///
/// Uses test app: b9319949-2f2d-410b-8f8a-6990177c1d44
/// Schema defined in: Examples/CaseStudies/instant.schema.ts
final class MicroblogIntegrationTests: XCTestCase {
  
  /// The test InstantDB app ID
  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  
  /// Connection timeout in seconds
  static let connectionTimeout: TimeInterval = 10.0
  
  /// Query timeout in seconds
  static let queryTimeout: TimeInterval = 15.0
  
  var client: InstantClient!
  
  // Deterministic UUIDs matching MicroblogDemo
  let aliceId = "00000000-0000-0000-0000-00000000a11c"
  let bobId = "00000000-0000-0000-0000-0000000000b0"
  
  // MARK: - Setup / Teardown
  
  @MainActor
  override func setUp() async throws {
    try await super.setUp()

    try IntegrationTestGate.requireEnabled()
    
    // Configure the dependency for the test app ID
    prepareDependencies {
      $0.context = .live
      $0.instantAppID = Self.testAppID
      $0.instantEnableLocalPersistence = false
    }

    InstantClientFactory.clearCache()
    
    // Create client and wait for authentication.
    //
    // Why disable local persistence here?
    // InstantDB's query cache can emit a cached, non-loading result before the
    // server responds. For this suite we want deterministic read-after-write
    // behavior, so we opt out of local persistence.
    client = InstantClient(appID: Self.testAppID, enableLocalPersistence: false)
    client.connect()
    
    // Wait for authentication with timeout
    let deadline = Date().addingTimeInterval(Self.connectionTimeout)
    while client.connectionState != .authenticated && Date() < deadline {
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }
    
    guard client.connectionState == .authenticated else {
      XCTFail("Client failed to authenticate within \(Self.connectionTimeout)s. State: \(client.connectionState)")
      return
    }
    
    // Clean up any existing test data
    await cleanupTestData()
  }
  
  @MainActor
  override func tearDown() async throws {
    // Clean up test data
    await cleanupTestData()
    
    client?.disconnect()
    client = nil
    try await super.tearDown()
  }
  
  // MARK: - Cleanup Helper
  
  @MainActor
  private func cleanupTestData() async {
    guard let client else { return }

    // Delete test profiles and posts
    // Delete Alice profile
    let deleteAlice = TransactionChunk(
      namespace: "profiles",
      id: aliceId,
      ops: [["delete", "profiles", aliceId]]
    )
    try? client.transact(deleteAlice)
    
    // Delete Bob profile  
    let deleteBob = TransactionChunk(
      namespace: "profiles",
      id: bobId,
      ops: [["delete", "profiles", bobId]]
    )
    try? client.transact(deleteBob)
    
    // Wait for cleanup
    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
  }
  
  // MARK: - Profile Tests
  
  /// Test creating a profile using the @Shared wrapper pattern from MicroblogDemo
  @MainActor
  func testCreateProfileWithSharedWrapper() async throws {
    // This mirrors the pattern from MicroblogDemo:
    // @Shared(.instantSync(Schema.profiles.orderBy(\.createdAt, .asc)))
    // private var profiles: IdentifiedArrayOf<Profile> = []
    
    @Shared(.instantSync(Schema.profiles.orderBy(\.createdAt, .asc)))
    var profiles: IdentifiedArrayOf<Profile> = []
    
    // Wait for initial load
    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
    
    let initialCount = profiles.count
    TestLog.log("[MicroblogTest] Initial profiles count: \(initialCount)")
    
    // Create Alice profile (matching MicroblogDemo pattern)
    let now = Date().timeIntervalSince1970 * 1_000
    let alice = Profile(
      id: aliceId,
      bio: "Swift enthusiast",
      createdAt: now,
      displayName: "Alice",
      handle: "alice"
    )
    
    // Use withLock to add (same pattern as MicroblogDemo)
    _ = $profiles.withLock { $0.append(alice) }
    
    TestLog.log("[MicroblogTest] Added Alice profile with id: \(aliceId)")
    
    // Wait for sync
    try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
    
    // Verify Alice was added
    XCTAssertNotNil(profiles[id: aliceId], "Alice profile should exist after sync")
    XCTAssertEqual(profiles[id: aliceId]?.displayName, "Alice")
    XCTAssertEqual(profiles[id: aliceId]?.handle, "alice")
    
    let query = client.query(Profile.self)
    let result = try await client.queryOnce(query, timeout: Self.queryTimeout)

    let serverProfile = result.data.first { $0.id.lowercased() == aliceId.lowercased() }
    XCTAssertNotNil(serverProfile, "Expected profile to exist on the server after round-trip")
    XCTAssertEqual(serverProfile?.displayName, "Alice")
    XCTAssertEqual(serverProfile?.handle, "alice")

    TestLog.log("[MicroblogTest] ✅ Profile creation test passed")
  }
  
  // MARK: - Post with Link Tests
  
  /// Test creating a post with an author link using the @Shared wrapper pattern
  ///
  /// This is the key test - it verifies that when we create a Post with an
  /// `author: Profile` link, the link is correctly persisted to InstantDB.
  @MainActor
  func testCreatePostWithAuthorLink() async throws {
    // First, create the profile that will be the author
    @Shared(.instantSync(Schema.profiles.orderBy(\.createdAt, .asc)))
    var profiles: IdentifiedArrayOf<Profile> = []
    
    // Wait for initial load
    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
    
    // Create Alice as the author
    let now = Date().timeIntervalSince1970 * 1_000
    let alice = Profile(
      id: aliceId,
      bio: "Swift enthusiast",
      createdAt: now,
      displayName: "Alice",
      handle: "alice"
    )
    
    _ = $profiles.withLock { $0.append(alice) }
    
    // Wait for profile to sync
    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
    
    TestLog.log("[MicroblogTest] Created author profile: \(aliceId)")
    
    // Now create a post with the author link
    // This mirrors MicroblogDemo:
    // @Shared(.instantSync(Schema.posts.with(\.author).orderBy(\.createdAt, .desc)))
    // private var posts: IdentifiedArrayOf<Post> = []
    
    @Shared(.instantSync(Schema.posts.with(\.author).orderBy(\.createdAt, .desc)))
    var posts: IdentifiedArrayOf<Post> = []
    
    // Wait for initial load
    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
    
    let initialPostCount = posts.count
    TestLog.log("[MicroblogTest] Initial posts count: \(initialPostCount)")
    
    // Create a post with the author link (same pattern as MicroblogDemo.createPost())
    let postId = UUID().uuidString.lowercased()
    let post = Post(
      id: postId,
      content: "Hello from integration test! 🚀",
      createdAt: now,
      // The author link - this connects the post to its profile
      author: alice
    )
    
    TestLog.log("[MicroblogTest] Creating post with ID: \(postId)")
    TestLog.log("[MicroblogTest] Post author link -> Profile ID: \(alice.id)")
    
    // Add the post (same pattern as MicroblogDemo)
    _ = $posts.withLock { $0.insert(post, at: 0) }
    
    // Wait for sync
    try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
    
    // Verify post was created
    XCTAssertNotNil(posts[id: postId], "Post should exist after sync")
    XCTAssertEqual(posts[id: postId]?.content, "Hello from integration test! 🚀")
    
    TestLog.log("[MicroblogTest] Post created, now verifying author link...")
    
    // CRITICAL: Verify the author link was populated
    // When we query with .with(\.author), the linked Profile should be populated
    let createdPost = posts[id: postId]
    XCTAssertNotNil(createdPost?.author, "Post should have author link populated")
    XCTAssertEqual(createdPost?.author?.id, aliceId, "Author ID should match Alice's ID")
    XCTAssertEqual(createdPost?.author?.displayName, "Alice", "Author displayName should be Alice")
    
    let query = client.query(Post.self).including(["author"])
    let result = try await client.queryOnce(query, timeout: Self.queryTimeout)
    let serverPost = result.data.first { $0.id.lowercased() == postId.lowercased() }

    XCTAssertNotNil(serverPost, "Expected post to exist on the server after round-trip")
    XCTAssertEqual(serverPost?.author?.id.lowercased(), aliceId.lowercased())
    XCTAssertEqual(serverPost?.author?.displayName, "Alice")

    TestLog.log("[MicroblogTest] ✅ Post with author link test passed")
    TestLog.log("[MicroblogTest]   Post ID: \(postId)")
    TestLog.log("[MicroblogTest]   Author: \(createdPost?.author?.displayName ?? "nil") (\(createdPost?.author?.id ?? "nil"))")
    
    // Cleanup: delete the test post
    _ = $posts.withLock { $0.remove(id: postId) }
    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
  }
  
  // MARK: - Link Verification Tests
  
  /// Test that links are correctly persisted by querying from a fresh subscription
  @MainActor
  func testLinkPersistenceAcrossSubscriptions() async throws {
    // Step 1: Create profile
    @Shared(.instantSync(Schema.profiles))
    var profiles: IdentifiedArrayOf<Profile> = []
    
    try await Task.sleep(nanoseconds: 2_000_000_000)
    
    let alice = Profile(
      id: aliceId,
      bio: "Swift enthusiast",
      createdAt: Date().timeIntervalSince1970 * 1_000,
      displayName: "Alice",
      handle: "alice"
    )
    _ = $profiles.withLock { $0.append(alice) }
    
    try await Task.sleep(nanoseconds: 2_000_000_000)
    
    // Step 2: Create post with link
    let postId = UUID().uuidString.lowercased()
    
    @Shared(.instantSync(Schema.posts.with(\.author)))
    var posts: IdentifiedArrayOf<Post> = []
    
    try await Task.sleep(nanoseconds: 2_000_000_000)
    
    let post = Post(
      id: postId,
      content: "Persistence test post",
      createdAt: Date().timeIntervalSince1970 * 1_000,
      author: alice
    )
    _ = $posts.withLock { $0.append(post) }
    
    try await Task.sleep(nanoseconds: 3_000_000_000)
    
    TestLog.log("[MicroblogTest] Created post \(postId) with author link")
    
    // Step 3: Create a NEW subscription to verify link persisted
    // This simulates a fresh app launch or view appearing
    @Shared(.instantSync(Schema.posts.with(\.author)))
    var freshPosts: IdentifiedArrayOf<Post> = []
    
    try await Task.sleep(nanoseconds: 3_000_000_000)
    
    // Verify the link is populated in the fresh subscription
    let fetchedPost = freshPosts[id: postId]
    XCTAssertNotNil(fetchedPost, "Post should be found in fresh subscription")
    XCTAssertNotNil(fetchedPost?.author, "Author link should be populated in fresh subscription")
    XCTAssertEqual(fetchedPost?.author?.id, aliceId, "Author ID should match")
    XCTAssertEqual(fetchedPost?.author?.displayName, "Alice", "Author name should match")
    
    let query = client.query(Post.self).including(["author"])
    let result = try await client.queryOnce(query, timeout: Self.queryTimeout)
    let serverPost = result.data.first { $0.id.lowercased() == postId.lowercased() }

    XCTAssertNotNil(serverPost, "Expected post to exist on the server after round-trip")
    XCTAssertEqual(serverPost?.author?.id.lowercased(), aliceId.lowercased())
    XCTAssertEqual(serverPost?.author?.displayName, "Alice")

    TestLog.log("[MicroblogTest] ✅ Link persistence test passed")
    TestLog.log("[MicroblogTest]   Fresh fetch author: \(fetchedPost?.author?.displayName ?? "nil")")
    
    // Cleanup
    _ = $posts.withLock { $0.remove(id: postId) }
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }
  
  // MARK: - Direct InstantDB Verification
  
  /// Test that verifies the link was actually persisted in InstantDB using raw queries
  ///
  /// **ISSUE DOCUMENTED**: This test verifies that when a Post is created with an author link
  /// via `@Shared`, the link is correctly persisted and can be queried back.
  ///
  /// **NOTE**: The `@Shared` wrapper has an `isTesting` check that skips `save()` when
  /// `@Dependency(\.context) == .test`. For integration tests that need to verify data
  /// actually persists to InstantDB, we need to override the context to `.live`.
  ///
  /// This test verifies that the InstaQLProcessor correctly handles reverse links.
  ///
  /// It creates test data directly via the InstantClient (bypassing the isTesting check)
  /// and then queries to verify the reverse link is correctly populated.
  @MainActor
  func testVerifyLinkInInstantDB() async throws {
    // Create profile and post using raw transactions
    let profileChunk = TransactionChunk(
      namespace: "profiles",
      id: aliceId,
      ops: [["update", "profiles", aliceId, [
        "displayName": "Alice",
        "handle": "alice",
        "bio": "Swift enthusiast",
        "createdAt": Date().timeIntervalSince1970 * 1_000
      ] as [String: Any]]]
    )
    try client.transact(profileChunk)
    
    let postId = UUID().uuidString.lowercased()
    let postChunk = TransactionChunk(
      namespace: "posts",
      id: postId,
      ops: [["update", "posts", postId, [
        "content": "Reverse link test",
        "createdAt": Date().timeIntervalSince1970 * 1_000
      ] as [String: Any]]]
    )
    try client.transact(postChunk)
    
    // Create the link: profile.posts -> post (forward direction)
    // This also creates the reverse: post.author -> profile
    let linkChunk = TransactionChunk(
      namespace: "profiles",
      id: aliceId,
      ops: [["link", "profiles", aliceId, ["posts": postId]]]
    )
    try client.transact(linkChunk)
    
    try await Task.sleep(nanoseconds: 3_000_000_000)
    
    // Query using raw client with .including to verify reverse link decoding.
    //
    // IMPORTANT:
    // `subscribe` may emit cached results first (for offline UX), which can
    // cause a false negative in an integration test that expects to observe the
    // post after a server round-trip. `queryOnce` explicitly disables cached
    // emission so we only accept a server response.
    let query = client.query(Post.self).including(["author"])
    let result = try await client.queryOnce(query, timeout: 10.0)

    XCTAssertFalse(result.isLoading, "Query should not be loading")
    XCTAssertNil(result.error, "Query should not error")

    let foundPost = result.data.first { $0.id.lowercased() == postId.lowercased() }
    XCTAssertNotNil(foundPost, "Test post should be found")

    if let post = foundPost {
      // This is the key assertion - verify the reverse link is populated.
      XCTAssertNotNil(post.author, "Author should be populated via reverse link (InstaQLProcessor fix)")
      XCTAssertEqual(post.author?.id.lowercased(), aliceId.lowercased(), "Author ID should match Alice's ID")
    }
    
    // Cleanup
    let deletePost = TransactionChunk(
      namespace: "posts",
      id: postId,
      ops: [["delete", "posts", postId]]
    )
    try? client.transact(deletePost)
    
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }
  
  // MARK: - Two-Author Scenario (Full MicroblogDemo Pattern)
  
  /// Test the full MicroblogDemo scenario with two authors posting
  @MainActor
  func testTwoAuthorsMicroblogScenario() async throws {
    // Mirror the exact pattern from MicroblogDemo
    @Shared(.instantSync(Schema.posts.with(\.author).orderBy(\.createdAt, .desc)))
    var posts: IdentifiedArrayOf<Post> = []
    
    @Shared(.instantSync(Schema.profiles.orderBy(\.createdAt, .asc)))
    var profiles: IdentifiedArrayOf<Profile> = []
    
    // Wait for initial load
    try await Task.sleep(nanoseconds: 2_000_000_000)
    
    // Create Alice and Bob (same as MicroblogDemo.ensureProfilesExist())
    let alice = Profile(
      id: aliceId,
      bio: "Swift enthusiast",
      createdAt: Date().timeIntervalSince1970 * 1_000,
      displayName: "Alice",
      handle: "alice"
    )

    let bob = Profile(
      id: bobId,
      bio: "InstantDB fan",
      createdAt: Date().timeIntervalSince1970 * 1_000 + 1_000,
      displayName: "Bob",
      handle: "bob"
    )
    
    _ = $profiles.withLock { $0.append(alice) }
    _ = $profiles.withLock { $0.append(bob) }
    
    try await Task.sleep(nanoseconds: 2_000_000_000)
    
    TestLog.log("[MicroblogTest] Created profiles: Alice and Bob")
    
    // Alice creates a post
    let alicePostId = UUID().uuidString.lowercased()
    let alicePost = Post(
      id: alicePostId,
      content: "Just shipped a new feature! 🚀",
      createdAt: Date().timeIntervalSince1970 * 1_000,
      author: alice
    )

    _ = $posts.withLock { $0.insert(alicePost, at: 0) }

    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Bob creates a post
    let bobPostId = UUID().uuidString.lowercased()
    let bobPost = Post(
      id: bobPostId,
      content: "InstantDB makes building apps so much easier",
      createdAt: Date().timeIntervalSince1970 * 1_000 + 1_000,
      author: bob
    )
    
    _ = $posts.withLock { $0.insert(bobPost, at: 0) }
    
    try await Task.sleep(nanoseconds: 3_000_000_000)
    
    TestLog.log("[MicroblogTest] Created posts from Alice and Bob")
    
    // Verify both posts have correct authors
    let fetchedAlicePost = posts[id: alicePostId]
    let fetchedBobPost = posts[id: bobPostId]
    
    XCTAssertNotNil(fetchedAlicePost, "Alice's post should exist")
    XCTAssertNotNil(fetchedBobPost, "Bob's post should exist")
    
    XCTAssertEqual(fetchedAlicePost?.author?.id, aliceId, "Alice's post should have Alice as author")
    XCTAssertEqual(fetchedAlicePost?.author?.displayName, "Alice")
    
    XCTAssertEqual(fetchedBobPost?.author?.id, bobId, "Bob's post should have Bob as author")
    XCTAssertEqual(fetchedBobPost?.author?.displayName, "Bob")
    
    // Verify post counts per author (like MicroblogDemo shows)
    let alicePostCount = posts.filter { $0.author?.id == aliceId }.count
    let bobPostCount = posts.filter { $0.author?.id == bobId }.count
    
    TestLog.log("[MicroblogTest] Post counts - Alice: \(alicePostCount), Bob: \(bobPostCount)")
    
    XCTAssertGreaterThanOrEqual(alicePostCount, 1, "Alice should have at least 1 post")
    XCTAssertGreaterThanOrEqual(bobPostCount, 1, "Bob should have at least 1 post")
    
    TestLog.log("[MicroblogTest] ✅ Two-author scenario test passed")
    
    // Cleanup
    _ = $posts.withLock { $0.remove(id: alicePostId) }
    _ = $posts.withLock { $0.remove(id: bobPostId) }
    
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }
}
