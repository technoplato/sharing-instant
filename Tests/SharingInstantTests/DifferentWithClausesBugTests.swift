/// Tests for the "Different .with() Clauses" bug.
///
/// ## Bug Description
///
/// When two subscriptions query the same namespace with DIFFERENT `.with()` clauses:
/// - Subscription A: `Schema.posts.with(\.author).orderBy(\.createdAt, .desc)`
/// - Subscription B: `Schema.posts.with(\.author).with(\.comments).orderBy(\.createdAt, .desc)`
///
/// Optimistic updates may NOT propagate correctly to all subscriptions because they have
/// different `UniqueRequestKeyID` values (due to different `includedLinks` and `linkTree`).
///
/// ## Expected Behavior (TypeScript SDK)
///
/// In the TypeScript SDK, ALL queries share a centralized `pendingMutations` store.
/// When you insert via one query, ALL queries see the optimistic update immediately
/// because `notifyAll()` recomputes ALL subscriptions after every mutation.
///
/// ## How This Manifests
///
/// 1. User creates a post via PostComposerView (uses simpler `.with(\.author)` query)
/// 2. PostComposerView immediately sees the post (optimistic update works for originating subscription)
/// 3. PostFeedView (uses `.with(\.author).with(\.comments)`) does NOT see the post
/// 4. After server round-trip, both subscriptions eventually show the post
///
/// ## Root Cause
///
/// The `notifyOptimisticUpsert()` function in Reactor.swift iterates subscriptions by namespace,
/// but each subscription's `SubscriptionState` tracks its own `optimisticIDs` array.
/// When `notifyAll()` is called with the sentinel `"__notifyAll__"`, it only triggers
/// `handleStoreUpdate()` without adding the ID to subscriptions that weren't the originator.

import XCTest
import IdentifiedCollections
import Sharing
import Dependencies
@testable import SharingInstant
import InstantDB

// MARK: - Different .with() Clauses Bug Tests

final class DifferentWithClausesBugTests: XCTestCase {

  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"

  override func setUp() async throws {
    try await super.setUp()
    try IntegrationTestGate.requireEnabled()
  }

  // MARK: - Test 1: Optimistic Insert Propagates Across Different .with() Configurations

  /// Tests that an optimistic insert via one subscription is immediately visible
  /// in another subscription with a DIFFERENT `.with()` clause.
  ///
  /// ## Bug Being Tested
  ///
  /// This test demonstrates the core bug from `DifferentWithClausesDemo.swift`:
  /// - `subscriptionA` uses `.with(\.author)` (simpler query)
  /// - `subscriptionB` uses `.with(\.author).with(\.comments)` (more complex query)
  ///
  /// When we create a post via subscriptionA's mutation method:
  /// - ✅ subscriptionA sees the post immediately
  /// - ❌ subscriptionB should ALSO see the post immediately (currently fails)
  func testOptimisticInsertPropagatesAcrossDifferentWithConfigurations() async throws {
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    let postId = UUID().uuidString.lowercased()
    let postContent = "Test post for cross-subscription propagation"

    // Create two subscriptions with DIFFERENT .with() configurations
    // Subscription A: posts with author only (simpler)
    let configA = SharingInstantSync.CollectionConfiguration<Post>(
      namespace: "posts",
      orderBy: .desc("createdAt"),
      includedLinks: ["author"],
      linkTree: [.link(name: "author")]
    )
    let streamA = await reactor.subscribe(appID: Self.testAppID, configuration: configA)

    // Subscription B: posts with author AND comments (more complex)
    let configB = SharingInstantSync.CollectionConfiguration<Post>(
      namespace: "posts",
      orderBy: .desc("createdAt"),
      includedLinks: ["author", "comments"],
      linkTree: [.link(name: "author"), .link(name: "comments")]
    )
    let streamB = await reactor.subscribe(appID: Self.testAppID, configuration: configB)

    // Thread-safe collectors
    let collectorA = PostCollector()
    let collectorB = PostCollector()

    let subscriptionAReady = XCTestExpectation(description: "Subscription A ready")
    let subscriptionBReady = XCTestExpectation(description: "Subscription B ready")

    let consumeTaskA = Task {
      for await posts in streamA {
        await collectorA.update(posts)
        if await !collectorA.getIsReady() {
          await collectorA.markReady()
          subscriptionAReady.fulfill()
        }
      }
    }

    let consumeTaskB = Task {
      for await posts in streamB {
        await collectorB.update(posts)
        if await !collectorB.getIsReady() {
          await collectorB.markReady()
          subscriptionBReady.fulfill()
        }
      }
    }

    defer {
      consumeTaskA.cancel()
      consumeTaskB.cancel()
    }

    await fulfillment(of: [subscriptionAReady, subscriptionBReady], timeout: 10)

    // Create a post via the Reactor (simulating what $posts.createPost does)
    let now = Date().timeIntervalSince1970 * 1000
    let postChunk = TransactionChunk(
      namespace: "posts",
      id: postId,
      ops: [["update", "posts", postId, [
        "content": postContent,
        "createdAt": now
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [postChunk])

    // Wait a short time for optimistic updates to propagate
    // (should be immediate, but add small delay for async propagation)
    try await Task.sleep(nanoseconds: 200_000_000) // 200ms

    // Check both subscriptions
    let postInA = await collectorA.contains(id: postId)
    let postInB = await collectorB.contains(id: postId)

    // Debug output
    let postsA = await collectorA.getPosts()
    let postsB = await collectorB.getPosts()
    print("DEBUG: Post ID = \(postId)")
    print("DEBUG: Subscription A (with author only) has \(postsA.count) posts, contains target: \(postInA)")
    print("DEBUG: Subscription B (with author+comments) has \(postsB.count) posts, contains target: \(postInB)")
    print("DEBUG: Post IDs in A: \(postsA.map { $0.id })")
    print("DEBUG: Post IDs in B: \(postsB.map { $0.id })")

    // CRITICAL ASSERTIONS
    XCTAssertTrue(postInA, "Subscription A (originator) should see the optimistic insert")

    // THIS IS THE BUG: Subscription B should ALSO see the post immediately
    // Currently this fails because the ID is not added to subscriptionB's optimisticIDs
    XCTAssertTrue(postInB, """
      BUG: Subscription B should ALSO see the optimistic insert immediately.

      Subscription B uses a DIFFERENT .with() clause than Subscription A:
      - A: .with(\\.author)
      - B: .with(\\.author).with(\\.comments)

      Despite having different UniqueRequestKeyID values, both subscriptions query
      the same namespace ("posts"). When a post is created, it should appear in
      BOTH subscriptions immediately via optimistic updates.

      TypeScript SDK Reference: Reactor.js notifyAll() re-computes ALL subscriptions.
      """)

    // Cleanup
    let deleteChunk = TransactionChunk(
      namespace: "posts",
      id: postId,
      ops: [["delete", "posts", postId]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])
  }

  // MARK: - Test 2: Multiple Subscriptions All See Optimistic Updates

  /// Tests that creating N subscriptions with varying `.with()` configurations
  /// all see optimistic updates propagate correctly.
  func testMultipleSubscriptionsWithVaryingWithClausesAllSeeOptimisticUpdates() async throws {
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    let postId = UUID().uuidString.lowercased()

    // Create 4 subscriptions with increasingly complex .with() configurations
    var streams: [AsyncStream<[Post]>] = []
    var collectors: [PostCollector] = []
    let configurations: [String] = [
      "no includes",
      "with author",
      "with author+comments",
      "with author+comments+likes"
    ]

    // Config 0: No includes
    let config0 = SharingInstantSync.CollectionConfiguration<Post>(
      namespace: "posts",
      orderBy: .desc("createdAt"),
      includedLinks: [],
      linkTree: []
    )
    streams.append(await reactor.subscribe(appID: Self.testAppID, configuration: config0))
    collectors.append(PostCollector())

    // Config 1: with author
    let config1 = SharingInstantSync.CollectionConfiguration<Post>(
      namespace: "posts",
      orderBy: .desc("createdAt"),
      includedLinks: ["author"],
      linkTree: [.link(name: "author")]
    )
    streams.append(await reactor.subscribe(appID: Self.testAppID, configuration: config1))
    collectors.append(PostCollector())

    // Config 2: with author + comments
    let config2 = SharingInstantSync.CollectionConfiguration<Post>(
      namespace: "posts",
      orderBy: .desc("createdAt"),
      includedLinks: ["author", "comments"],
      linkTree: [.link(name: "author"), .link(name: "comments")]
    )
    streams.append(await reactor.subscribe(appID: Self.testAppID, configuration: config2))
    collectors.append(PostCollector())

    // Config 3: with author + comments + likes
    let config3 = SharingInstantSync.CollectionConfiguration<Post>(
      namespace: "posts",
      orderBy: .desc("createdAt"),
      includedLinks: ["author", "comments", "likes"],
      linkTree: [.link(name: "author"), .link(name: "comments"), .link(name: "likes")]
    )
    streams.append(await reactor.subscribe(appID: Self.testAppID, configuration: config3))
    collectors.append(PostCollector())

    // Start consuming all streams
    let allReady = XCTestExpectation(description: "All subscriptions ready")
    allReady.expectedFulfillmentCount = streams.count

    // Capture collectors in a way that satisfies Swift 6 concurrency
    let collector0 = collectors[0]
    let collector1 = collectors[1]
    let collector2 = collectors[2]
    let collector3 = collectors[3]
    let allCollectors = [collector0, collector1, collector2, collector3]

    let task0 = Task {
      for await posts in streams[0] {
        await collector0.update(posts)
        if await !collector0.getIsReady() {
          await collector0.markReady()
          allReady.fulfill()
        }
      }
    }

    let task1 = Task {
      for await posts in streams[1] {
        await collector1.update(posts)
        if await !collector1.getIsReady() {
          await collector1.markReady()
          allReady.fulfill()
        }
      }
    }

    let task2 = Task {
      for await posts in streams[2] {
        await collector2.update(posts)
        if await !collector2.getIsReady() {
          await collector2.markReady()
          allReady.fulfill()
        }
      }
    }

    let task3 = Task {
      for await posts in streams[3] {
        await collector3.update(posts)
        if await !collector3.getIsReady() {
          await collector3.markReady()
          allReady.fulfill()
        }
      }
    }

    let tasks = [task0, task1, task2, task3]

    defer {
      tasks.forEach { $0.cancel() }
    }

    await fulfillment(of: [allReady], timeout: 15)

    // Create a post
    let now = Date().timeIntervalSince1970 * 1000
    let postChunk = TransactionChunk(
      namespace: "posts",
      id: postId,
      ops: [["update", "posts", postId, [
        "content": "Test post for multi-subscription propagation",
        "createdAt": now
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [postChunk])

    // Wait for propagation
    try await Task.sleep(nanoseconds: 200_000_000) // 200ms

    // Check ALL subscriptions see the post
    print("DEBUG: Testing optimistic propagation across \(streams.count) subscriptions with different .with() clauses:")
    var allContain = true

    for (index, collector) in allCollectors.enumerated() {
      let contains = await collector.contains(id: postId)
      let posts = await collector.getPosts()
      print("DEBUG: Subscription \(index) (\(configurations[index])): \(posts.count) posts, contains target: \(contains)")

      XCTAssertTrue(contains, """
        Subscription \(index) (\(configurations[index])) should see the optimistic insert.
        Different .with() clauses should NOT prevent optimistic updates from propagating.
        """)

      allContain = allContain && contains
    }

    // Cleanup
    let deleteChunk = TransactionChunk(
      namespace: "posts",
      id: postId,
      ops: [["delete", "posts", postId]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])

    XCTAssertTrue(allContain, "ALL subscriptions should see the optimistic insert regardless of .with() configuration")
  }

  // MARK: - Test 3: Simulating DifferentWithClausesDemo Exact Scenario

  /// Tests the exact scenario from DifferentWithClausesDemo.swift:
  /// PostComposerView and PostFeedView with different .with() clauses.
  ///
  /// This test simulates what happens when:
  /// 1. User has both views open (two subscriptions active)
  /// 2. User creates a post via the composer
  /// 3. Both views should show the post immediately
  @MainActor
  func testDifferentWithClausesDemoScenario() async throws {
    let instanceID = "different-with-clauses-\(UUID().uuidString.lowercased())"

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = Self.testAppID
      $0.instantEnableLocalPersistence = false
      $0.instantClientInstanceID = instanceID
    } operation: {
      // Simulating PostComposerView's subscription
      @Shared(.instantSync(Schema.posts.with(\.author).orderBy(\.createdAt, .desc)))
      var composerPosts: IdentifiedArrayOf<Post> = []

      // Simulating PostFeedView's subscription (MORE complex query)
      @Shared(.instantSync(Schema.posts.with(\.author).with(\.comments).orderBy(\.createdAt, .desc)))
      var feedPosts: IdentifiedArrayOf<Post> = []

      // Wait for subscriptions to connect
      print("DEBUG: Waiting for subscriptions to connect...")
      try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

      let initialComposerCount = composerPosts.count
      let initialFeedCount = feedPosts.count
      print("DEBUG: Initial counts - Composer: \(initialComposerCount), Feed: \(initialFeedCount)")

      // Create a post using explicit mutation (like the fixed DifferentWithClausesDemo)
      let postId = UUID().uuidString.lowercased()
      let now = Date().timeIntervalSince1970 * 1_000

      $composerPosts.createPost(
        id: postId,
        content: "Test post from composer",
        createdAt: now
      )

      // Small delay for optimistic updates to propagate
      try await Task.sleep(nanoseconds: 300_000_000) // 300ms

      // Check both subscriptions
      let composerHasPost = composerPosts.contains { $0.id.lowercased() == postId }
      let feedHasPost = feedPosts.contains { $0.id.lowercased() == postId }

      print("DEBUG: After creation:")
      print("DEBUG: Composer has \(composerPosts.count) posts, contains new: \(composerHasPost)")
      print("DEBUG: Feed has \(feedPosts.count) posts, contains new: \(feedHasPost)")
      print("DEBUG: Composer post IDs: \(composerPosts.map { $0.id })")
      print("DEBUG: Feed post IDs: \(feedPosts.map { $0.id })")

      XCTAssertTrue(composerHasPost, "Composer subscription should see the post it created")

      // THIS IS THE BUG being tested
      XCTAssertTrue(feedHasPost, """
        BUG: Feed subscription should ALSO see the post immediately!

        This is the exact scenario from DifferentWithClausesDemo.swift:
        - PostComposerView uses: Schema.posts.with(\\.author)
        - PostFeedView uses: Schema.posts.with(\\.author).with(\\.comments)

        When the composer creates a post, the feed should see it immediately
        via optimistic updates, not just after a server round-trip.
        """)

      // Cleanup
      $composerPosts.deletePost(postId)
      try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
    }
  }
}

// MARK: - Thread-safe Post Collector

private actor PostCollector {
  var posts: [Post] = []
  var isReady = false

  func update(_ newPosts: [Post]) {
    posts = newPosts
  }

  func markReady() {
    isReady = true
  }

  func getPosts() -> [Post] {
    return posts
  }

  func getIsReady() -> Bool {
    return isReady
  }

  func contains(id: String) -> Bool {
    // Case-insensitive comparison for UUID matching
    return posts.contains { $0.id.lowercased() == id.lowercased() }
  }
}
