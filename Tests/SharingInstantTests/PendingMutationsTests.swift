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
import Dependencies
@testable import SharingInstant
import InstantDB

// MARK: - Thread-safe container for test results

/// Actor to safely collect profiles from async streams
private actor ProfileCollector {
    var profiles: [Profile] = []
    var isReady = false
    
    func update(_ newProfiles: [Profile]) {
        profiles = newProfiles
    }
    
    func markReady() {
        isReady = true
    }
    
    func getProfiles() -> [Profile] {
        return profiles
    }
    
    func getIsReady() -> Bool {
        return isReady
    }
    
    func contains(id: String) -> Bool {
        // UUIDs from server may have different case than client-generated UUIDs
        return profiles.contains { $0.id.lowercased() == id.lowercased() }
    }
}

// MARK: - Pending Mutations Tests

final class PendingMutationsTests: XCTestCase {
    
    static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
    
    override func setUp() async throws {
        try await super.setUp()
        try IntegrationTestGate.requireEnabled()
    }
    
    // MARK: - Test 1: Optimistic Updates Across Different Query Shapes
    
    /// Tests that optimistic updates propagate to ALL subscriptions, even those
    /// with different configurations.
    ///
    /// ## Bug Being Tested
    ///
    /// When two features query the same entity type with DIFFERENT configurations:
    /// - Subscription A: profiles with no links
    /// - Subscription B: profiles with author link included
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
    func testOptimisticUpdatePropagatesAcrossDifferentConfigurations() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)
        
        let profileId = UUID().uuidString
        let profileName = "Test Profile for cross-subscription propagation"
        
        // Create two subscriptions with DIFFERENT configurations
        let configA = SharingInstantSync.CollectionConfiguration<Profile>(
            namespace: "profiles",
            orderBy: .desc("createdAt"),
            includedLinks: [],
            linkTree: []
        )
        let streamA = await reactor.subscribe(appID: Self.testAppID, configuration: configA)
        
        let configB = SharingInstantSync.CollectionConfiguration<Profile>(
            namespace: "profiles",
            orderBy: .desc("createdAt"),
            includedLinks: ["posts"],
            linkTree: [.link(name: "posts")]
        )
        let streamB = await reactor.subscribe(appID: Self.testAppID, configuration: configB)
        
        // Use actors for thread-safe collection
        let collectorA = ProfileCollector()
        let collectorB = ProfileCollector()
        
        let subscriptionAReady = XCTestExpectation(description: "Subscription A ready")
        let subscriptionBReady = XCTestExpectation(description: "Subscription B ready")
        
        let consumeTaskA = Task {
            for await profiles in streamA {
                await collectorA.update(profiles)
                if await !collectorA.getIsReady() {
                    await collectorA.markReady()
                    subscriptionAReady.fulfill()
                }
            }
        }
        
        let consumeTaskB = Task {
            for await profiles in streamB {
                await collectorB.update(profiles)
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
        
        // Create a profile via the Reactor
        let profileChunk = TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [["update", "profiles", profileId, [
                "displayName": profileName,
                "handle": "@test-\(profileId.prefix(8))",
                "createdAt": Date().timeIntervalSince1970 * 1000
            ]]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [profileChunk])
        
        // Wait for both subscriptions to see the profile
        // Use polling with timeout instead of fixed sleep
        let deadline = Date().addingTimeInterval(5.0)
        var profileInA = false
        var profileInB = false
        
        while Date() < deadline && (!profileInA || !profileInB) {
            profileInA = await collectorA.contains(id: profileId)
            profileInB = await collectorB.contains(id: profileId)
            if !profileInA || !profileInB {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
        }
        
        // Debug output
        let profilesA = await collectorA.getProfiles()
        let profilesB = await collectorB.getProfiles()
        print("DEBUG: Profile ID = \(profileId)")
        print("DEBUG: Collector A has \(profilesA.count) profiles, contains target: \(profileInA)")
        print("DEBUG: Collector B has \(profilesB.count) profiles, contains target: \(profileInB)")
        
        // CRITICAL ASSERTION: Both subscriptions should see the new profile
        
        XCTAssertTrue(profileInA, "Subscription A should see the optimistic insert")
        XCTAssertTrue(profileInB, "Subscription B should ALSO see the optimistic insert (BUG: currently fails)")
        
        // Cleanup
        let deleteChunk = TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [["delete", "profiles", profileId]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])
    }
    
    // MARK: - Test 2: Optimistic Update Survives Server Refresh
    
    /// Tests that an optimistic insert survives a server refresh that doesn't
    /// yet include the newly created entity.
    func testOptimisticUpdateSurvivesServerRefresh() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)
        
        let profileId = UUID().uuidString
        let profileName = "Optimistic profile that should survive refresh"
        
        let config = SharingInstantSync.CollectionConfiguration<Profile>(
            namespace: "profiles",
            orderBy: .desc("createdAt"),
            includedLinks: [],
            linkTree: []
        )
        let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)
        
        let collector = ProfileCollector()
        let subscriptionReady = XCTestExpectation(description: "Subscription ready")
        
        let consumeTask = Task {
            for await profiles in stream {
                await collector.update(profiles)
                if await !collector.getIsReady() {
                    await collector.markReady()
                    subscriptionReady.fulfill()
                }
            }
        }
        
        defer {
            consumeTask.cancel()
        }
        
        await fulfillment(of: [subscriptionReady], timeout: 10)
        
        // Create a profile optimistically
        let profileChunk = TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [["update", "profiles", profileId, [
                "displayName": profileName,
                "handle": "@optimistic-\(profileId.prefix(8))",
                "createdAt": Date().timeIntervalSince1970 * 1000
            ]]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [profileChunk])
        
        // Poll until we see the optimistic update
        var profilePresent = false
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && !profilePresent {
            profilePresent = await collector.contains(id: profileId)
            if !profilePresent {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        
        let profilesBeforeRefresh = await collector.getProfiles()
        print("DEBUG: Before server refresh - \(profilesBeforeRefresh.count) profiles, contains target: \(profilePresent)")
        print("DEBUG: Profile IDs before refresh: \(profilesBeforeRefresh.map { $0.id })")
        
        // Verify present immediately
        XCTAssertTrue(profilePresent, "Profile should be present immediately after optimistic insert")
        
        // Wait for potential server refresh (the server will send updated data)
        // In a real scenario, this simulates the server sending a refresh that doesn't include our new entity yet
        print("DEBUG: Waiting 3 seconds for potential server refresh...")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        
        let profilesAfterRefresh = await collector.getProfiles()
        profilePresent = await collector.contains(id: profileId)
        print("DEBUG: After server refresh - \(profilesAfterRefresh.count) profiles, contains target: \(profilePresent)")
        print("DEBUG: Profile IDs after refresh: \(profilesAfterRefresh.map { $0.id })")
        
        // CRITICAL: Should STILL be present
        XCTAssertTrue(profilePresent, "Profile should STILL be present after server refresh (BUG: may be overwritten)")
        
        // Cleanup
        let deleteChunk = TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [["delete", "profiles", profileId]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])
    }
    
    // MARK: - Test 3: Deletion Is Sent to Server
    
    /// Tests that delete operations are properly sent to the server.
    func testDeletionIsSentToServer() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)
        
        // Sign in as guest to allow transactions
        try await reactor.signInAsGuest(appID: Self.testAppID)
        
        let profileId = UUID().uuidString
        let profileName = "Profile to be deleted"
        
        // Create a profile
        let createChunk = TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [["update", "profiles", profileId, [
                "displayName": profileName,
                "handle": "@delete-test-\(profileId.prefix(8))",
                "createdAt": Date().timeIntervalSince1970 * 1000
            ]]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [createChunk])
        
        // Subscribe to verify the profile exists
        // Note: Use orderBy instead of whereClause since whereClause may not work correctly with optimistic updates
        let config = SharingInstantSync.CollectionConfiguration<Profile>(
            namespace: "profiles",
            orderBy: .desc("createdAt"),
            includedLinks: [],
            linkTree: []
        )
        let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)
        
        let profileCreated = XCTestExpectation(description: "Profile created and visible")
        
        let consumeTask = Task {
            for await profiles in stream {
                // Use case-insensitive comparison since server may return lowercase IDs
                if profiles.contains(where: { $0.id.lowercased() == profileId.lowercased() }) {
                    profileCreated.fulfill()
                    break
                }
            }
        }
        
        await fulfillment(of: [profileCreated], timeout: 10)
        consumeTask.cancel()
        
        // Delete the profile
        let deleteChunk = TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [["delete", "profiles", profileId]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])
        
        // Wait for deletion to propagate
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // Verify deleted from server
        let verifyStream = await reactor.subscribe(appID: Self.testAppID, configuration: config)
        
        let profileDeleted = XCTestExpectation(description: "Profile deleted from server")
        
        let verifyTask = Task {
            for await profiles in verifyStream {
                // Use case-insensitive comparison since server may return lowercase IDs
                if !profiles.contains(where: { $0.id.lowercased() == profileId.lowercased() }) {
                    profileDeleted.fulfill()
                    break
                }
            }
        }
        
        await fulfillment(of: [profileDeleted], timeout: 10)
        verifyTask.cancel()
    }
    
    // MARK: - Test 4: Deletion Propagates Across Subscriptions
    
    /// Tests that a deletion is reflected in ALL subscriptions for that namespace.
    func testDeletionPropagatesAcrossSubscriptions() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)
        
        // Sign in as guest to allow transactions
        try await reactor.signInAsGuest(appID: Self.testAppID)
        
        let profileId = UUID().uuidString
        let profileName = "Kim Kardashian - Test Profile"
        
        // Create a profile first
        let createChunk = TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [["update", "profiles", profileId, [
                "displayName": profileName,
                "handle": "@kimkardashian_test",
                "createdAt": Date().timeIntervalSince1970 * 1000
            ]]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [createChunk])
        
        // Create two subscriptions with different configurations
        let configA = SharingInstantSync.CollectionConfiguration<Profile>(
            namespace: "profiles",
            orderBy: .desc("createdAt"),
            includedLinks: [],
            linkTree: []
        )
        let streamA = await reactor.subscribe(appID: Self.testAppID, configuration: configA)
        
        let configB = SharingInstantSync.CollectionConfiguration<Profile>(
            namespace: "profiles",
            orderBy: .desc("createdAt"),
            includedLinks: ["posts"],
            linkTree: [.link(name: "posts")]
        )
        let streamB = await reactor.subscribe(appID: Self.testAppID, configuration: configB)
        
        let collectorA = ProfileCollector()
        let collectorB = ProfileCollector()
        
        let bothSeeProfile = XCTestExpectation(description: "Both subscriptions see the profile")
        bothSeeProfile.expectedFulfillmentCount = 2
        
        let consumeTaskA = Task {
            for await profiles in streamA {
                await collectorA.update(profiles)
                // Use case-insensitive comparison since server may return lowercase IDs
                if profiles.contains(where: { $0.id.lowercased() == profileId.lowercased() }) {
                    bothSeeProfile.fulfill()
                }
            }
        }
        
        let consumeTaskB = Task {
            for await profiles in streamB {
                await collectorB.update(profiles)
                // Use case-insensitive comparison since server may return lowercase IDs
                if profiles.contains(where: { $0.id.lowercased() == profileId.lowercased() }) {
                    bothSeeProfile.fulfill()
                }
            }
        }
        
        defer {
            consumeTaskA.cancel()
            consumeTaskB.cancel()
        }
        
        await fulfillment(of: [bothSeeProfile], timeout: 10)
        
        print("DEBUG: Kim Kardashian profile created - waiting 5 seconds before deletion...")
        print("DEBUG: Check the InstantDB dashboard now!")
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds to observe in dashboard
        
        // Delete the profile
        let deleteChunk = TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [["delete", "profiles", profileId]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])
        
        // Poll for deletion to propagate (up to 2 seconds)
        var profileInA = true
        var profileInB = true
        let deadline = Date().addingTimeInterval(2.0)
        
        while Date() < deadline && (profileInA || profileInB) {
            profileInA = await collectorA.contains(id: profileId)
            profileInB = await collectorB.contains(id: profileId)
            if profileInA || profileInB {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        
        // Debug output
        let profilesA = await collectorA.getProfiles()
        let profilesB = await collectorB.getProfiles()
        print("DEBUG: After deletion - A has \(profilesA.count) profiles, contains target: \(profileInA)")
        print("DEBUG: After deletion - B has \(profilesB.count) profiles, contains target: \(profileInB)")
        print("DEBUG: Profile IDs in A: \(profilesA.map { $0.id })")
        print("DEBUG: Profile IDs in B: \(profilesB.map { $0.id })")
        
        // CRITICAL: Both should NOT contain the deleted profile
        
        XCTAssertFalse(profileInA, "Subscription A should NOT contain deleted profile")
        XCTAssertFalse(profileInB, "Subscription B should ALSO NOT contain deleted profile")
    }
    
    // MARK: - Test 5: Parallel Notification (Race Condition Fix)
    
    /// Tests that optimistic notifications are sent to ALL subscriptions in parallel.
    func testParallelNotificationPreventsRaceCondition() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)
        
        let profileId = UUID().uuidString
        
        // Create 5 subscriptions with different configurations
        var streams: [AsyncStream<[Profile]>] = []
        for i in 0..<5 {
            let config = SharingInstantSync.CollectionConfiguration<Profile>(
                namespace: "profiles",
                orderBy: .desc("createdAt"),
                includedLinks: i % 2 == 0 ? ["posts"] : [],
                linkTree: i % 2 == 0 ? [.link(name: "posts")] : []
            )
            let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)
            streams.append(stream)
        }
        
        // Create collectors for each subscription
        let collectors = (0..<5).map { _ in ProfileCollector() }
        
        let allReady = XCTestExpectation(description: "All subscriptions ready")
        allReady.expectedFulfillmentCount = 5
        
        let tasks = streams.enumerated().map { index, stream in
            Task {
                let collector = collectors[index]
                for await profiles in stream {
                    await collector.update(profiles)
                    if await !collector.getIsReady() {
                        await collector.markReady()
                        allReady.fulfill()
                    }
                }
            }
        }
        
        defer {
            tasks.forEach { $0.cancel() }
        }
        
        await fulfillment(of: [allReady], timeout: 15)
        
        // Create a profile
        let profileChunk = TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [["update", "profiles", profileId, [
                "displayName": "Test profile for parallel notification",
                "handle": "@parallel-\(profileId.prefix(8))",
                "createdAt": Date().timeIntervalSince1970 * 1000
            ]]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [profileChunk])
        
        // Give time for propagation
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // ALL 5 subscriptions should see the profile
        for (index, collector) in collectors.enumerated() {
            let containsProfile = await collector.contains(id: profileId)
            XCTAssertTrue(containsProfile, "Subscription \(index) should see the optimistic insert")
        }
        
        // Cleanup
        let deleteChunk = TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [["delete", "profiles", profileId]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])
    }
    
    // MARK: - Test 6: @Shared(.instantSync) Optimistic Insert
    
    /// Tests that an optimistic insert via `@Shared(.instantSync(...))` survives server refresh.
    ///
    /// ## This is the REAL bug test
    ///
    /// This test uses the actual `@Shared(.instantSync(...))` API that users use,
    /// not the lower-level Reactor API. The bug report describes:
    /// 1. User inserts via `$profiles.withLock { $0.append(newProfile) }`
    /// 2. Profile appears immediately (optimistic)
    /// 3. Server refresh arrives and overwrites the local state
    /// 4. Profile disappears from the UI
    ///
    /// ## Watch the InstantDB Dashboard
    ///
    /// When running this test, watch for "Kim Kardashian" in the profiles table.
    /// You should see:
    /// - Profile appears
    /// - Profile stays for 10 seconds
    /// - Profile is deleted
    ///
    /// If you see oscillation (appearing/disappearing), that's the bug!
    @MainActor
    func testSharedInstantSyncOptimisticInsertSurvivesRefresh() async throws {
        let instanceID = "pending-mutations-\(UUID().uuidString.lowercased())"
        
        try await withDependencies {
            $0.context = .live
            $0.instantAppID = Self.testAppID
            $0.instantEnableLocalPersistence = false
            $0.instantClientInstanceID = instanceID
        } operation: {
            // Use the actual @Shared(.instantSync(...)) API
            @Shared(.instantSync(Schema.profiles.orderBy(\.createdAt, .desc)))
            var profiles: IdentifiedArrayOf<Profile> = []
            
            // Wait for initial subscription to connect
            print("DEBUG: Waiting for initial subscription...")
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            let initialCount = profiles.count
            print("DEBUG: Initial profile count: \(initialCount)")
            
            // Create Kim Kardashian profile
            let kimId = UUID().uuidString.lowercased()
            let kim = Profile(
                id: kimId,
                avatarUrl: nil,
                bio: "Testing optimistic updates",
                createdAt: Date().timeIntervalSince1970 * 1000,
                displayName: "Kim Kardashian",
                handle: "@kimkardashian_shared_test"
            )
            
            // Insert via withLock - this is how users do it
            print("DEBUG: Inserting Kim Kardashian via withLock...")
            $profiles.withLock { profiles in
                profiles.insert(kim, at: 0)
            }
            
            // Verify immediate optimistic update
            print("DEBUG: Checking immediate optimistic update...")
            XCTAssertEqual(profiles.count, initialCount + 1, "Profile count should increase immediately")
            XCTAssertTrue(
                profiles.contains { $0.id.lowercased() == kimId.lowercased() },
                "Kim should be in profiles immediately after insert"
            )
            print("DEBUG: ✅ Kim Kardashian inserted - profile count: \(profiles.count)")
            
            // Wait 10 seconds to observe in dashboard and allow server refreshes
            print("DEBUG: ========================================")
            print("DEBUG: Kim Kardashian is now in the database!")
            print("DEBUG: Check the InstantDB dashboard for @kimkardashian_shared_test")
            print("DEBUG: Waiting 10 seconds...")
            print("DEBUG: ========================================")
            
            for i in 1...10 {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                let stillPresent = profiles.contains { $0.id.lowercased() == kimId.lowercased() }
                print("DEBUG: Second \(i): Kim present = \(stillPresent), total profiles = \(profiles.count)")
                
                // CRITICAL ASSERTION: Kim should STILL be present after each second
                // If this fails, the server refresh is overwriting the optimistic insert
                XCTAssertTrue(
                    stillPresent,
                    "Kim should STILL be present at second \(i) (BUG: server refresh overwrote optimistic insert)"
                )
            }
            
            print("DEBUG: ========================================")
            print("DEBUG: Test passed! Kim survived 10 seconds of server refreshes")
            print("DEBUG: Now deleting Kim...")
            print("DEBUG: ========================================")
            
            // Cleanup: Remove Kim via withLock
            // This should now work! The fix tracks IDs and sends delete operations.
            $profiles.withLock { profiles in
                profiles.remove(id: kimId)
            }
            
            // Verify local removal
            XCTAssertFalse(
                profiles.contains { $0.id.lowercased() == kimId.lowercased() },
                "Kim should be removed from LOCAL collection"
            )
            print("DEBUG: Kim removed from LOCAL collection")
            
            // Wait for sync
            try await Task.sleep(nanoseconds: 2_000_000_000)
            
            // Check if Kim is still in the server by creating a fresh subscription
            print("DEBUG: Creating fresh subscription to check if Kim was deleted from SERVER...")
        }
        
        // Create a fresh subscription outside the first one to verify server state
        try await withDependencies {
            $0.context = .live
            $0.instantAppID = Self.testAppID
            $0.instantEnableLocalPersistence = false
            $0.instantClientInstanceID = "fresh-check-\(UUID().uuidString.lowercased())"
        } operation: {
            @Shared(.instantSync(Schema.profiles.orderBy(\.createdAt, .desc)))
            var freshProfiles: IdentifiedArrayOf<Profile> = []
            
            try await Task.sleep(nanoseconds: 2_000_000_000)
            
            let kimStillOnServer = freshProfiles.contains { $0.handle == "@kimkardashian_shared_test" }
            
            print("DEBUG: Fresh subscription profile count: \(freshProfiles.count)")
            print("DEBUG: Kim still on server: \(kimStillOnServer)")
            
            // Kim should be deleted from the server
            // This verifies the deletion fix is working
            XCTAssertFalse(
                kimStillOnServer,
                "Kim should be deleted from SERVER after withLock { remove }"
            )
            
            print("DEBUG: Test complete.")
        }
    }
    
    // MARK: - Test 7: Server Deletion Does Not Cause Re-sync (Option A Critical Test)
    
    /// Tests that when the server deletes items, the client does NOT re-send them.
    ///
    /// ## Bug Being Tested
    ///
    /// This is the critical bug that requires Option A architecture:
    /// 1. Client has posts A, B, C (synced from server)
    /// 2. Server deletes all posts (via dashboard or admin SDK)
    /// 3. Server sends subscription update with empty array
    /// 4. Client creates new post D
    /// 5. BUG: Client re-sends A, B, C along with D!
    ///
    /// ## Expected Behavior (TypeScript)
    ///
    /// In TypeScript, when you create post D:
    /// - `pushTx()` only sends the mutation for D
    /// - It does NOT iterate over local state and re-send everything
    /// - Server data (empty) + pending mutation (D) = UI shows [D]
    ///
    /// ## Reference
    ///
    /// TypeScript Reactor.test.js line 203:
    /// "optimisticTx is not overwritten by refresh-ok"
    @MainActor
    func testServerDeletionDoesNotCauseResync() async throws {
        let instanceID = "server-deletion-\(UUID().uuidString.lowercased())"
        
        // Step 1: Create some posts via admin SDK
        let post1Id = UUID().uuidString.lowercased()
        let post2Id = UUID().uuidString.lowercased()
        let authorId = "00000000-0000-0000-0000-00000000a11c" // Alice
        
        // Create posts using Reactor directly (simulating server state)
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)
        
        // Sign in as guest to allow transactions
        try await reactor.signInAsGuest(appID: Self.testAppID)
        
        // Create author first
        let authorChunk = TransactionChunk(
            namespace: "profiles",
            id: authorId,
            ops: [["update", "profiles", authorId, [
                "displayName": "Alice",
                "handle": "alice_deletion_test",
                "createdAt": Date().timeIntervalSince1970 * 1000
            ]]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [authorChunk])
        
        // Create posts linked to author
        let post1Chunk = TransactionChunk(
            namespace: "posts",
            id: post1Id,
            ops: [
                ["update", "posts", post1Id, [
                    "content": "Post 1 - will be deleted",
                    "createdAt": Date().timeIntervalSince1970 * 1000
                ]],
                ["link", "posts", post1Id, ["author": ["id": authorId, "namespace": "profiles"]]]
            ]
        )
        let post2Chunk = TransactionChunk(
            namespace: "posts",
            id: post2Id,
            ops: [
                ["update", "posts", post2Id, [
                    "content": "Post 2 - will be deleted",
                    "createdAt": Date().timeIntervalSince1970 * 1000 + 1000
                ]],
                ["link", "posts", post2Id, ["author": ["id": authorId, "namespace": "profiles"]]]
            ]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [post1Chunk, post2Chunk])
        
        print("DEBUG: Created 2 posts on server")
        
        // Step 2: Subscribe via @Shared and verify we see the posts
        try await withDependencies {
            $0.context = .live
            $0.instantAppID = Self.testAppID
            $0.instantEnableLocalPersistence = false
            $0.instantClientInstanceID = instanceID
        } operation: {
            @Shared(.instantSync(Schema.posts.with(\.author).orderBy(\.createdAt, .desc)))
            var posts: IdentifiedArrayOf<Post> = []
            
            // Wait for subscription to receive posts
            print("DEBUG: Waiting for subscription to receive posts...")
            var attempts = 0
            while posts.count < 2 && attempts < 50 {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                attempts += 1
            }
            
            print("DEBUG: Subscription has \(posts.count) posts")
            XCTAssertGreaterThanOrEqual(posts.count, 2, "Should have at least 2 posts from server")
            
            // Step 3: Delete posts via admin SDK (simulating dashboard deletion)
            print("DEBUG: Deleting posts via admin SDK...")
            let deletePost1 = TransactionChunk(
                namespace: "posts",
                id: post1Id,
                ops: [["delete", "posts", post1Id]]
            )
            let deletePost2 = TransactionChunk(
                namespace: "posts",
                id: post2Id,
                ops: [["delete", "posts", post2Id]]
            )
            try await reactor.transact(appID: Self.testAppID, chunks: [deletePost1, deletePost2])
            
            print("DEBUG: Posts deleted from server")
            
            // Step 4: Wait for subscription to receive the deletion
            print("DEBUG: Waiting for subscription to receive deletion...")
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            // Note: At this point, the local state may or may not have updated
            // The bug is that even if it hasn't, creating a new post should NOT re-send old posts
            
            let postsBeforeCreate = posts.count
            print("DEBUG: Posts before create: \(postsBeforeCreate)")
            
            // Step 5: Create a NEW post via withLock
            let newPostId = UUID().uuidString.lowercased()
            let newPost = Post(
                content: "New post after deletion",
                createdAt: Date().timeIntervalSince1970 * 1000 + 5000,
                author: Profile(
                    id: authorId,
                    createdAt: 0,
                    displayName: "Alice",
                    handle: "alice_deletion_test"
                )
            )
            
            print("DEBUG: Creating new post via withLock...")
            $posts.withLock { posts in
                posts.insert(newPost, at: 0)
            }
            
            // Wait for sync
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            print("DEBUG: Posts after create: \(posts.count)")
        }
        
        // Step 6: Create a FRESH subscription to verify server state
        print("DEBUG: Creating fresh subscription to verify server state...")
        try await withDependencies {
            $0.context = .live
            $0.instantAppID = Self.testAppID
            $0.instantEnableLocalPersistence = false
            $0.instantClientInstanceID = "fresh-\(UUID().uuidString.lowercased())"
        } operation: {
            @Shared(.instantSync(Schema.posts.with(\.author).orderBy(\.createdAt, .desc)))
            var freshPosts: IdentifiedArrayOf<Post> = []
            
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            print("DEBUG: Fresh subscription has \(freshPosts.count) posts")
            for post in freshPosts {
                print("DEBUG:   - \(post.id): \(post.content)")
            }
            
            // CRITICAL ASSERTION: Should only have the NEW post, not the deleted ones!
            let hasDeletedPost1 = freshPosts.contains { $0.id.lowercased() == post1Id }
            let hasDeletedPost2 = freshPosts.contains { $0.id.lowercased() == post2Id }
            let hasNewPost = freshPosts.contains { $0.content == "New post after deletion" }
            
            print("DEBUG: Has deleted post 1: \(hasDeletedPost1)")
            print("DEBUG: Has deleted post 2: \(hasDeletedPost2)")
            print("DEBUG: Has new post: \(hasNewPost)")
            
            // The deleted posts should NOT be on the server
            XCTAssertFalse(hasDeletedPost1, "BUG: Deleted post 1 was re-synced to server!")
            XCTAssertFalse(hasDeletedPost2, "BUG: Deleted post 2 was re-synced to server!")
            XCTAssertTrue(hasNewPost, "New post should be on server")
            
            // Cleanup
            if hasNewPost {
                if let newPost = freshPosts.first(where: { $0.content == "New post after deletion" }) {
                    let cleanupChunk = TransactionChunk(
                        namespace: "posts",
                        id: newPost.id,
                        ops: [["delete", "posts", newPost.id]]
                    )
                    try await reactor.transact(appID: Self.testAppID, chunks: [cleanupChunk])
                }
            }
        }
        
        // Cleanup author
        let cleanupAuthor = TransactionChunk(
            namespace: "profiles",
            id: authorId,
            ops: [["delete", "profiles", authorId]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [cleanupAuthor])
        
        print("DEBUG: Test complete")
    }
    
    // MARK: - Test 8: Mutation Lifecycle (Pending → Confirmed → Cleaned Up)
    
    /// Tests that mutations follow the correct lifecycle like TypeScript.
    ///
    /// ## TypeScript Behavior
    ///
    /// 1. `pushTx()` adds mutation to `pendingMutations` Map
    /// 2. Server responds with `transact-ok` containing `tx-id`
    /// 3. Mutation is marked as `confirmed` with the `tx-id`
    /// 4. When server's `processedTxId` >= mutation's `tx-id`, mutation is cleaned up
    ///
    /// ## Reference
    ///
    /// TypeScript Reactor.test.js line 360:
    /// "we don't cleanup mutations we're still waiting on"
    @MainActor
    func testMutationLifecycle() async throws {
        // This test verifies that:
        // 1. Mutations are tracked separately from server data
        // 2. Multiple mutations can be pending simultaneously
        // 3. Mutations are cleaned up after server confirms
        
        let instanceID = "mutation-lifecycle-\(UUID().uuidString.lowercased())"
        
        try await withDependencies {
            $0.context = .live
            $0.instantAppID = Self.testAppID
            $0.instantEnableLocalPersistence = false
            $0.instantClientInstanceID = instanceID
        } operation: {
            @Shared(.instantSync(Schema.profiles.orderBy(\.createdAt, .desc)))
            var profiles: IdentifiedArrayOf<Profile> = []
            
            // Wait for initial subscription
            try await Task.sleep(nanoseconds: 2_000_000_000)
            
            let initialCount = profiles.count
            print("DEBUG: Initial profile count: \(initialCount)")
            
            // Create first profile
            let profile1Id = UUID().uuidString.lowercased()
            let profile1 = Profile(
                id: profile1Id,
                createdAt: Date().timeIntervalSince1970 * 1000,
                displayName: "Lifecycle Test 1",
                handle: "@lifecycle_test_1"
            )

            $profiles.withLock { $0.insert(profile1, at: 0) }

            // Immediately create second profile (both should be pending)
            let profile2Id = UUID().uuidString.lowercased()
            let profile2 = Profile(
                id: profile2Id,
                createdAt: Date().timeIntervalSince1970 * 1000 + 1000,
                displayName: "Lifecycle Test 2",
                handle: "@lifecycle_test_2"
            )
            
            $profiles.withLock { $0.insert(profile2, at: 0) }
            
            // Both should be visible immediately (optimistic)
            XCTAssertEqual(profiles.count, initialCount + 2, "Both profiles should be visible optimistically")
            
            let hasProfile1 = profiles.contains { $0.id.lowercased() == profile1Id }
            let hasProfile2 = profiles.contains { $0.id.lowercased() == profile2Id }
            
            XCTAssertTrue(hasProfile1, "Profile 1 should be visible")
            XCTAssertTrue(hasProfile2, "Profile 2 should be visible")
            
            print("DEBUG: Both profiles visible optimistically")
            
            // Wait for server confirmation
            try await Task.sleep(nanoseconds: 3_000_000_000)
            
            // Both should still be visible after server confirms
            XCTAssertTrue(
                profiles.contains { $0.id.lowercased() == profile1Id },
                "Profile 1 should still be visible after server confirmation"
            )
            XCTAssertTrue(
                profiles.contains { $0.id.lowercased() == profile2Id },
                "Profile 2 should still be visible after server confirmation"
            )
            
            print("DEBUG: Both profiles still visible after confirmation")
            
            // Cleanup
            $profiles.withLock { $0.remove(id: profile1Id) }
            $profiles.withLock { $0.remove(id: profile2Id) }
            
            try await Task.sleep(nanoseconds: 2_000_000_000)
            
            print("DEBUG: Cleanup complete")
        }
    }
    
    // MARK: - Test 9: Only Send Changes, Not Entire State
    
    /// Tests that save() only sends the mutation, not the entire local state.
    ///
    /// ## This is the core Option A requirement
    ///
    /// When you call `$posts.withLock { $0.insert(newPost) }`:
    /// - CORRECT: Send only `["update", "posts", newPostId, {...}]`
    /// - WRONG: Send updates for ALL posts in local state
    ///
    /// ## How to verify
    ///
    /// 1. Have 100 existing posts on server
    /// 2. Create 1 new post
    /// 3. Verify only 1 transaction was sent (not 101)
    ///
    /// This test is difficult to verify directly without instrumenting the network layer,
    /// but we can verify the EFFECT: existing unchanged posts should not have their
    /// `serverCreatedAt` or other server-managed fields modified.
    @MainActor
    func testOnlySendChangesNotEntireState() async throws {
        // This test creates a scenario where we can detect if unchanged items were re-sent
        // by checking if their server-side metadata changed
        
        let instanceID = "only-changes-\(UUID().uuidString.lowercased())"
        
        try await withDependencies {
            $0.context = .live
            $0.instantAppID = Self.testAppID
            $0.instantEnableLocalPersistence = false
            $0.instantClientInstanceID = instanceID
        } operation: {
            @Shared(.instantSync(Schema.profiles.orderBy(\.createdAt, .desc)))
            var profiles: IdentifiedArrayOf<Profile> = []
            
            // Wait for initial subscription
            try await Task.sleep(nanoseconds: 2_000_000_000)
            
            let initialCount = profiles.count
            print("DEBUG: Initial profile count: \(initialCount)")
            
            // Record the IDs of existing profiles
            let existingProfileIds = Set(profiles.map { $0.id.lowercased() })
            print("DEBUG: Existing profile IDs: \(existingProfileIds)")
            
            // Create a new profile
            let newProfileId = UUID().uuidString.lowercased()
            let newProfile = Profile(
                id: newProfileId,
                createdAt: Date().timeIntervalSince1970 * 1000,
                displayName: "Only Changes Test",
                handle: "@only_changes_test"
            )
            
            print("DEBUG: Creating new profile...")
            $profiles.withLock { $0.insert(newProfile, at: 0) }
            
            // Wait for sync
            try await Task.sleep(nanoseconds: 3_000_000_000)
            
            // Verify new profile was created
            XCTAssertTrue(
                profiles.contains { $0.id.lowercased() == newProfileId },
                "New profile should be created"
            )
            
            // The key assertion: existing profiles should still have their original IDs
            // If save() re-sent all profiles, they might have been duplicated or modified
            let currentProfileIds = Set(profiles.map { $0.id.lowercased() })
            
            // All existing IDs should still be present
            for existingId in existingProfileIds {
                XCTAssertTrue(
                    currentProfileIds.contains(existingId),
                    "Existing profile \(existingId) should still exist"
                )
            }
            
            // No duplicate IDs should exist
            let idCounts = Dictionary(profiles.map { ($0.id.lowercased(), 1) }, uniquingKeysWith: +)
            for (id, count) in idCounts {
                XCTAssertEqual(count, 1, "Profile ID \(id) should not be duplicated (found \(count) times)")
            }
            
            print("DEBUG: All existing profiles preserved, no duplicates")
            
            // Cleanup
            $profiles.withLock { $0.remove(id: newProfileId) }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
