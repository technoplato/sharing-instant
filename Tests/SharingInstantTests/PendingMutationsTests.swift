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
        let profileName = "Profile to be deleted across subscriptions"
        
        // Create a profile first
        let createChunk = TransactionChunk(
            namespace: "profiles",
            id: profileId,
            ops: [["update", "profiles", profileId, [
                "displayName": profileName,
                "handle": "@cross-delete-\(profileId.prefix(8))",
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
}
