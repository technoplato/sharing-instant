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
                displayName: "Kim Kardashian",
                handle: "@kimkardashian_shared_test",
                bio: "Testing optimistic updates",
                avatarUrl: nil,
                createdAt: Date().timeIntervalSince1970 * 1000
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
}
