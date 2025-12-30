/// Tests for centralized pending mutations functionality.
///
/// These tests verify that the Swift SharingInstant library correctly mirrors
/// the TypeScript InstantDB client's behavior for optimistic updates and deletions.
///
/// ## Background
///
/// The TypeScript client uses a centralized `pendingMutations` Map that is applied
/// to ALL queries at read-time. This ensures:
/// 1. Optimistic updates propagate to all subscriptions regardless of query shape
/// 2. Deletions are tracked and can be applied when reconstructing results
/// 3. Server refreshes don't overwrite pending mutations
///
/// ## Reference Implementation
///
/// See: instant/client/packages/core/src/Reactor.js
/// - Lines 817-827: _pendingMutations() and _updatePendingMutations()
/// - Lines 1263-1272: _applyOptimisticUpdates()
/// - Lines 1348-1370: pushOps() which calls notifyAll()
///
/// ## Test Strategy
///
/// These tests are written FIRST as failing tests to demonstrate the bugs,
/// then the implementation is added to make them pass (TDD approach).

import XCTest
import IdentifiedCollections
import Sharing
@testable import SharingInstant
import InstantDB

// MARK: - Test Entities

/// A simple Post entity for testing different .with() clause scenarios
private struct TestPost: EntityIdentifiable, Codable, Sendable, Equatable {
    static var namespace: String { "test_posts" }
    
    let id: String
    var content: String
    var createdAt: Double
    var author: TestAuthor?
    var comments: [TestComment]?
    
    init(
        id: String = UUID().uuidString,
        content: String,
        createdAt: Double = Date().timeIntervalSince1970 * 1000,
        author: TestAuthor? = nil,
        comments: [TestComment]? = nil
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.author = author
        self.comments = comments
    }
}

private struct TestAuthor: EntityIdentifiable, Codable, Sendable, Equatable {
    static var namespace: String { "test_authors" }
    
    let id: String
    var name: String
    
    init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}

private struct TestComment: EntityIdentifiable, Codable, Sendable, Equatable {
    static var namespace: String { "test_comments" }
    
    let id: String
    var text: String
    
    init(id: String = UUID().uuidString, text: String) {
        self.id = id
        self.text = text
    }
}

// MARK: - Test Helpers

/// Helper for timeout in async tests
private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private struct TimeoutError: Error {}

// MARK: - Pending Mutations Tests

final class PendingMutationsTests: XCTestCase {
    
    static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
    
    override func setUp() async throws {
        try await super.setUp()
        try IntegrationTestGate.requireEnabled()
    }
    
    // MARK: - Test 1: Optimistic Updates Across Different Query Shapes
    
    /// Tests that optimistic updates propagate to ALL subscriptions, even those
    /// with different `.with()` clauses.
    ///
    /// ## Bug Being Tested
    ///
    /// When two features query the same entity type with DIFFERENT `.with()` clauses:
    /// - PostComposerView uses: `Schema.posts.with(\.author)`
    /// - PostFeedView uses: `Schema.posts.with(\.author).with(\.comments)`
    ///
    /// These create different `UniqueRequestKeyID` values, which means they create
    /// separate subscriptions. When an entity is inserted via one subscription,
    /// the other subscription may not see it immediately.
    ///
    /// ## Expected Behavior (TypeScript)
    ///
    /// In the TypeScript client, ALL queries share a centralized `pendingMutations`
    /// store. When you insert via one query, ALL queries see the optimistic update
    /// immediately because `notifyAll()` is called after every mutation.
    ///
    /// ## Reference
    ///
    /// See: instant/client/packages/core/src/Reactor.js lines 1367
    /// ```javascript
    /// this.notifyAll();  // Re-compute ALL subscriptions after mutation
    /// ```
    func testOptimisticUpdatePropagatesAcrossDifferentWithClauses() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)
        
        let postId = UUID().uuidString
        let authorId = UUID().uuidString
        let postContent = "Test post for cross-subscription propagation"
        
        // First, create an author so we have something to link to
        let authorChunk = TransactionChunk(
            namespace: "test_authors",
            id: authorId,
            ops: [["update", "test_authors", authorId, [
                "name": "Test Author"
            ]]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [authorChunk])
        
        // Create two subscriptions with DIFFERENT .with() configurations
        // This simulates the real-world scenario where different features
        // query the same entity type with different link inclusions.
        
        // Subscription A: posts with author only (simpler query)
        let configA = SharingInstantSync.CollectionConfiguration<TestPost>(
            namespace: "test_posts",
            orderBy: .desc("createdAt"),
            includedLinks: ["author"],
            linkTree: [EntityQueryNode(name: "author", children: [])]
        )
        let streamA = await reactor.subscribe(appID: Self.testAppID, configuration: configA)
        
        // Subscription B: posts with author AND comments (more complex query)
        let configB = SharingInstantSync.CollectionConfiguration<TestPost>(
            namespace: "test_posts",
            orderBy: .desc("createdAt"),
            includedLinks: ["author", "comments"],
            linkTree: [
                EntityQueryNode(name: "author", children: []),
                EntityQueryNode(name: "comments", children: [])
            ]
        )
        let streamB = await reactor.subscribe(appID: Self.testAppID, configuration: configB)
        
        // Wait for both subscriptions to be ready
        let subscriptionAReady = XCTestExpectation(description: "Subscription A ready")
        let subscriptionBReady = XCTestExpectation(description: "Subscription B ready")
        
        var latestPostsA: [TestPost] = []
        var latestPostsB: [TestPost] = []
        
        let consumeTaskA = Task { @MainActor in
            var didMarkReady = false
            for await posts in streamA {
                latestPostsA = posts
                if !didMarkReady {
                    didMarkReady = true
                    subscriptionAReady.fulfill()
                }
            }
        }
        
        let consumeTaskB = Task { @MainActor in
            var didMarkReady = false
            for await posts in streamB {
                latestPostsB = posts
                if !didMarkReady {
                    didMarkReady = true
                    subscriptionBReady.fulfill()
                }
            }
        }
        
        defer {
            consumeTaskA.cancel()
            consumeTaskB.cancel()
        }
        
        await fulfillment(of: [subscriptionAReady, subscriptionBReady], timeout: 10)
        
        // Now create a post via the Reactor (simulating insertion via Subscription A)
        let postChunk = TransactionChunk(
            namespace: "test_posts",
            id: postId,
            ops: [
                ["update", "test_posts", postId, [
                    "content": postContent,
                    "createdAt": Date().timeIntervalSince1970 * 1000
                ]],
                ["link", "test_posts", postId, ["author": ["id": authorId]]]
            ]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [postChunk])
        
        // Give a brief moment for async propagation
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // CRITICAL ASSERTION: Both subscriptions should see the new post
        // This is the bug we're testing - currently Subscription B may NOT see it
        // because it has a different UniqueRequestKeyID
        
        let postInA = latestPostsA.contains { $0.id == postId }
        let postInB = latestPostsB.contains { $0.id == postId }
        
        XCTAssertTrue(postInA, "Subscription A should see the optimistic insert")
        XCTAssertTrue(postInB, "Subscription B should ALSO see the optimistic insert (BUG: currently fails)")
        
        // Cleanup
        let deleteChunk = TransactionChunk(
            namespace: "test_posts",
            id: postId,
            ops: [["delete", "test_posts", postId]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])
        
        let deleteAuthorChunk = TransactionChunk(
            namespace: "test_authors",
            id: authorId,
            ops: [["delete", "test_authors", authorId]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [deleteAuthorChunk])
    }
    
    // MARK: - Test 2: Optimistic Update Survives Server Refresh
    
    /// Tests that an optimistic insert survives a server refresh that doesn't
    /// yet include the newly created entity.
    ///
    /// ## Bug Being Tested
    ///
    /// When a user creates an entity:
    /// 1. Optimistic update is applied locally
    /// 2. Server receives the mutation but hasn't processed it yet
    /// 3. Server sends a refresh with the OLD data (doesn't include new entity)
    /// 4. The optimistic entity should NOT be removed from the local view
    ///
    /// ## Expected Behavior (TypeScript)
    ///
    /// The TypeScript client stores mutations in `pendingMutations` and applies
    /// them at read-time via `_applyOptimisticUpdates()`. Even when the server
    /// sends a refresh without the new entity, the pending mutation is re-applied.
    ///
    /// ## Reference
    ///
    /// See: instant/client/packages/core/src/Reactor.js lines 1263-1272
    /// ```javascript
    /// _applyOptimisticUpdates(store, attrsStore, mutations, processedTxId) {
    ///   for (const [_, mut] of mutations) {
    ///     if (!mut['tx-id'] || (processedTxId && mut['tx-id'] > processedTxId)) {
    ///       const result = s.transact(store, attrsStore, mut['tx-steps']);
    ///       // ...
    ///     }
    ///   }
    /// }
    /// ```
    func testOptimisticUpdateSurvivesServerRefresh() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)
        
        let postId = UUID().uuidString
        let postContent = "Optimistic post that should survive refresh"
        
        // Subscribe to posts
        let config = SharingInstantSync.CollectionConfiguration<TestPost>(
            namespace: "test_posts",
            orderBy: .desc("createdAt"),
            includedLinks: [],
            linkTree: []
        )
        let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)
        
        let subscriptionReady = XCTestExpectation(description: "Subscription ready")
        var latestPosts: [TestPost] = []
        
        let consumeTask = Task { @MainActor in
            var didMarkReady = false
            for await posts in stream {
                latestPosts = posts
                if !didMarkReady {
                    didMarkReady = true
                    subscriptionReady.fulfill()
                }
            }
        }
        
        defer {
            consumeTask.cancel()
        }
        
        await fulfillment(of: [subscriptionReady], timeout: 10)
        
        // Create a post optimistically
        let postChunk = TransactionChunk(
            namespace: "test_posts",
            id: postId,
            ops: [["update", "test_posts", postId, [
                "content": postContent,
                "createdAt": Date().timeIntervalSince1970 * 1000
            ]]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [postChunk])
        
        // Give a brief moment for optimistic update to propagate
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // Verify the post is present immediately after optimistic insert
        XCTAssertTrue(
            latestPosts.contains { $0.id == postId },
            "Post should be present immediately after optimistic insert"
        )
        
        // Wait for potential server refresh (which might not include our post yet)
        // In real scenarios, the server might send a refresh before processing our mutation
        try await Task.sleep(nanoseconds: 3_000_000_000)
        
        // CRITICAL ASSERTION: Post should STILL be present after server refresh
        // This tests that pending mutations are re-applied at read-time
        XCTAssertTrue(
            latestPosts.contains { $0.id == postId },
            "Post should STILL be present after server refresh (BUG: may be overwritten)"
        )
        
        // Cleanup
        let deleteChunk = TransactionChunk(
            namespace: "test_posts",
            id: postId,
            ops: [["delete", "test_posts", postId]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])
    }
    
    // MARK: - Test 3: Deletion Is Sent to Server
    
    /// Tests that removing an item via `withLock { remove() }` generates a delete
    /// operation that is sent to InstantDB.
    ///
    /// ## Bug Being Tested
    ///
    /// When calling:
    /// ```swift
    /// $todos.withLock { todos in
    ///     todos.remove(atOffsets: offsets)
    /// }
    /// ```
    ///
    /// The `InstantSyncKey.save()` method only iterates over items CURRENTLY in
    /// the collection. It doesn't know what was removed, so no delete operation
    /// is ever generated.
    ///
    /// ## Expected Behavior
    ///
    /// The save() method should:
    /// 1. Compare the new collection state with the previous state
    /// 2. Identify which IDs were removed
    /// 3. Generate `["delete", namespace, id]` operations for each removed item
    /// 4. Send those delete operations to InstantDB
    ///
    /// ## Reference
    ///
    /// See: instant/client/packages/core/src/instaml.ts lines 313-316
    /// ```javascript
    /// function expandDelete({ attrsStore }: Ctx, [etype, eid]) {
    ///   const lookup = extractLookup(attrsStore, etype, eid);
    ///   return [['delete-entity', lookup, etype]];
    /// }
    /// ```
    func testDeletionIsSentToServer() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)
        
        let postId = UUID().uuidString
        let postContent = "Post to be deleted"
        
        // First, create a post
        let createChunk = TransactionChunk(
            namespace: "test_posts",
            id: postId,
            ops: [["update", "test_posts", postId, [
                "content": postContent,
                "createdAt": Date().timeIntervalSince1970 * 1000
            ]]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [createChunk])
        
        // Subscribe to verify the post exists
        let config = SharingInstantSync.CollectionConfiguration<TestPost>(
            namespace: "test_posts",
            whereClause: ["id": postId],
            includedLinks: [],
            linkTree: []
        )
        let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)
        
        let postCreated = XCTestExpectation(description: "Post created and visible")
        var latestPosts: [TestPost] = []
        
        let consumeTask = Task { @MainActor in
            for await posts in stream {
                latestPosts = posts
                if posts.contains(where: { $0.id == postId }) {
                    postCreated.fulfill()
                    break
                }
            }
        }
        
        await fulfillment(of: [postCreated], timeout: 10)
        consumeTask.cancel()
        
        // Now delete the post via the Reactor
        let deleteChunk = TransactionChunk(
            namespace: "test_posts",
            id: postId,
            ops: [["delete", "test_posts", postId]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])
        
        // Wait for deletion to propagate
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // Subscribe again to verify the post is gone from the SERVER
        let verifyStream = await reactor.subscribe(appID: Self.testAppID, configuration: config)
        
        let postDeleted = XCTestExpectation(description: "Post deleted from server")
        
        let verifyTask = Task { @MainActor in
            for await posts in verifyStream {
                if !posts.contains(where: { $0.id == postId }) {
                    postDeleted.fulfill()
                    break
                }
            }
        }
        
        await fulfillment(of: [postDeleted], timeout: 10)
        verifyTask.cancel()
    }
    
    // MARK: - Test 4: Deletion Propagates Across Subscriptions
    
    /// Tests that a deletion is reflected in ALL subscriptions for that namespace.
    ///
    /// ## Bug Being Tested
    ///
    /// Similar to Test 1, but for deletions. When an entity is deleted via one
    /// subscription, other subscriptions with different `.with()` clauses should
    /// also see the deletion immediately.
    ///
    /// ## Expected Behavior
    ///
    /// After deleting an entity:
    /// 1. The delete mutation is stored in `pendingMutations`
    /// 2. `notifyAll()` is called to re-compute ALL subscriptions
    /// 3. When reconstructing results, pending delete mutations are applied
    /// 4. ALL subscriptions show the entity as deleted
    func testDeletionPropagatesAcrossSubscriptions() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)
        
        let postId = UUID().uuidString
        let postContent = "Post to be deleted across subscriptions"
        
        // Create a post first
        let createChunk = TransactionChunk(
            namespace: "test_posts",
            id: postId,
            ops: [["update", "test_posts", postId, [
                "content": postContent,
                "createdAt": Date().timeIntervalSince1970 * 1000
            ]]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [createChunk])
        
        // Create two subscriptions with different configurations
        let configA = SharingInstantSync.CollectionConfiguration<TestPost>(
            namespace: "test_posts",
            orderBy: .desc("createdAt"),
            includedLinks: [],
            linkTree: []
        )
        let streamA = await reactor.subscribe(appID: Self.testAppID, configuration: configA)
        
        let configB = SharingInstantSync.CollectionConfiguration<TestPost>(
            namespace: "test_posts",
            orderBy: .desc("createdAt"),
            includedLinks: ["author"],
            linkTree: [EntityQueryNode(name: "author", children: [])]
        )
        let streamB = await reactor.subscribe(appID: Self.testAppID, configuration: configB)
        
        // Wait for both to see the post
        let bothSeePost = XCTestExpectation(description: "Both subscriptions see the post")
        bothSeePost.expectedFulfillmentCount = 2
        
        var latestPostsA: [TestPost] = []
        var latestPostsB: [TestPost] = []
        
        let consumeTaskA = Task { @MainActor in
            for await posts in streamA {
                latestPostsA = posts
                if posts.contains(where: { $0.id == postId }) {
                    bothSeePost.fulfill()
                }
            }
        }
        
        let consumeTaskB = Task { @MainActor in
            for await posts in streamB {
                latestPostsB = posts
                if posts.contains(where: { $0.id == postId }) {
                    bothSeePost.fulfill()
                }
            }
        }
        
        defer {
            consumeTaskA.cancel()
            consumeTaskB.cancel()
        }
        
        await fulfillment(of: [bothSeePost], timeout: 10)
        
        // Now delete the post
        let deleteChunk = TransactionChunk(
            namespace: "test_posts",
            id: postId,
            ops: [["delete", "test_posts", postId]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])
        
        // Give time for deletion to propagate
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // CRITICAL ASSERTION: Both subscriptions should NOT contain the deleted post
        let postInA = latestPostsA.contains { $0.id == postId }
        let postInB = latestPostsB.contains { $0.id == postId }
        
        XCTAssertFalse(postInA, "Subscription A should NOT contain deleted post")
        XCTAssertFalse(postInB, "Subscription B should ALSO NOT contain deleted post")
    }
    
    // MARK: - Test 5: Parallel Notification (Race Condition Fix)
    
    /// Tests that optimistic notifications are sent to ALL subscriptions in parallel,
    /// preventing race conditions where a server refresh arrives before all
    /// subscriptions have been notified.
    ///
    /// ## Bug Being Tested
    ///
    /// The current `notifyOptimisticUpsert()` iterates through subscriptions
    /// SEQUENTIALLY with `await`. If there are multiple subscriptions, and a
    /// server refresh arrives between the first and second `await handle.upsert(id)`
    /// call, the second subscription won't have the ID in its `optimisticIDs` yet.
    ///
    /// ## Expected Behavior
    ///
    /// Use `TaskGroup` to notify all subscriptions in PARALLEL, ensuring all
    /// subscriptions receive the optimistic ID before any server refresh can process.
    ///
    /// ## Reference
    ///
    /// See: instant/client/packages/core/src/Reactor.js lines 1302-1310
    /// ```javascript
    /// notifyAll() {
    ///   Object.keys(this.queryCbs).forEach((hash) => {
    ///     this.querySubs
    ///       .waitForKeyToLoad(hash)
    ///       .then(() => this.notifyOne(hash))
    ///       .catch(() => this.notifyOne(hash));
    ///   });
    /// }
    /// ```
    func testParallelNotificationPreventsRaceCondition() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)
        
        let postId = UUID().uuidString
        
        // Create 5 subscriptions with slightly different configurations
        // This increases the chance of hitting the race condition
        var streams: [AsyncStream<[TestPost]>] = []
        for i in 0..<5 {
            let config = SharingInstantSync.CollectionConfiguration<TestPost>(
                namespace: "test_posts",
                orderBy: .desc("createdAt"),
                // Alternate between including author and not
                includedLinks: i % 2 == 0 ? ["author"] : [],
                linkTree: i % 2 == 0 ? [EntityQueryNode(name: "author", children: [])] : []
            )
            let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)
            streams.append(stream)
        }
        
        // Wait for all subscriptions to be ready
        let allReady = XCTestExpectation(description: "All subscriptions ready")
        allReady.expectedFulfillmentCount = 5
        
        var latestPostsPerSubscription: [[TestPost]] = Array(repeating: [], count: 5)
        
        let tasks = streams.enumerated().map { index, stream in
            Task { @MainActor in
                var didMarkReady = false
                for await posts in stream {
                    latestPostsPerSubscription[index] = posts
                    if !didMarkReady {
                        didMarkReady = true
                        allReady.fulfill()
                    }
                }
            }
        }
        
        defer {
            tasks.forEach { $0.cancel() }
        }
        
        await fulfillment(of: [allReady], timeout: 15)
        
        // Create a post
        let postChunk = TransactionChunk(
            namespace: "test_posts",
            id: postId,
            ops: [["update", "test_posts", postId, [
                "content": "Test post for parallel notification",
                "createdAt": Date().timeIntervalSince1970 * 1000
            ]]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [postChunk])
        
        // Give time for propagation
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // ALL 5 subscriptions should see the post
        for (index, posts) in latestPostsPerSubscription.enumerated() {
            XCTAssertTrue(
                posts.contains { $0.id == postId },
                "Subscription \(index) should see the optimistic insert"
            )
        }
        
        // Cleanup
        let deleteChunk = TransactionChunk(
            namespace: "test_posts",
            id: postId,
            ops: [["delete", "test_posts", postId]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])
    }
}
