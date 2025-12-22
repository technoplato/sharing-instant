
import XCTest
import InstantDB
import Sharing
@testable import SharingInstant

final class ReactorTests: XCTestCase {
    
    // Use the same App ID as other integration tests
    static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
    
    override func setUp() async throws {
        // ideally reset store, but it is singleton.
    }

    // Helper for timeout
    func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T where T: Sendable {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
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
    
    struct TimeoutError: Error {}

    // 1. Fetches Data
    func testFetchesData() async throws {
        let id = UUID().uuidString
        let expectedName = "Test Fetch \(id)"
        
        // Setup data
        let chunk = TransactionChunk(
            namespace: "profiles",
            id: id,
            ops: [["update", "profiles", id, [
                "displayName": expectedName,
                "handle": "@test",
                "createdAt": Date().timeIntervalSince1970
            ]]]
        )
        // Use detached task to avoid isolation issues (compiler bug workaround)
        try await Task.detached {
            try await Reactor.shared.transact(appID: ReactorTests.testAppID, chunks: [chunk])
        }.value
        
        // Subscribe
        let config = SharingInstantSync.CollectionConfiguration<Profile>(
            namespace: "profiles",
            whereClause: ["id": id],
            includedLinks: [],
            linkTree: []
        )
        
        let stream = await Reactor.shared.subscribe(appID: Self.testAppID, configuration: config)
        
        // Expect data
        try await withTimeout(seconds: 5) {
            var iterator = stream.makeAsyncIterator()
            while let profiles = await iterator.next() {
                 if let first = profiles.first, first.displayName == expectedName {
                     return
                 }
            }
        }
        
        // Cleanup
        let deleteChunk = TransactionChunk(namespace: "profiles", id: id, ops: [["delete", "profiles", id]])
        try await Task.detached {
            try await Reactor.shared.transact(appID: ReactorTests.testAppID, chunks: [deleteChunk])
        }.value
    }
    
    // 2. Accepts Mutations
    func testAcceptsMutations() async throws {
         let id = UUID().uuidString
         let name = "Mutation Test"
         
         let chunk = TransactionChunk(
             namespace: "profiles",
             id: id,
             ops: [["update", "profiles", id, [
                 "displayName": name,
                 "handle": "@mutation",
                 "createdAt": Date().timeIntervalSince1970
             ]]]
         )
         
         try await Task.detached {
             try await Reactor.shared.transact(appID: ReactorTests.testAppID, chunks: [chunk])
         }.value
         
         // Verify via store directly (integration style) by subscribing
         let config = SharingInstantSync.CollectionConfiguration<Profile>(
             namespace: "profiles",
             whereClause: ["id": id],
             includedLinks: [],
             linkTree: []
         )
         let stream = await Reactor.shared.subscribe(appID: Self.testAppID, configuration: config)
         
         try await withTimeout(seconds: 5) {
             var iterator = stream.makeAsyncIterator()
             while let profiles = await iterator.next() {
                  if let first = profiles.first, first.displayName == name {
                      return
                  }
             }
         }
        
        // Cleanup
        let deleteChunk = TransactionChunk(namespace: "profiles", id: id, ops: [["delete", "profiles", id]])
        try await Task.detached {
             try await Reactor.shared.transact(appID: ReactorTests.testAppID, chunks: [deleteChunk])
        }.value
    }
    
    // 3. Optimistic Updates
    func testOptimisticUpdates() async throws {
        let id = UUID().uuidString
        let optimisticName = "Optimistic Update"
        
        // Ensure we are subscribed so Store cares about this ID
        // Only observed IDs are kept in Store?
        // Actually TripleStore merges everything it receives, but 'get' works for any ID in store.
        
        // 1. Subscribe first to ensure "connection" or interest?
        // TripleStore.shared.merge keeps everything.
        
        // We'll run transact in a Task
        let task = Task.detached {
            let chunk = TransactionChunk(
                namespace: "profiles",
                id: id,
                ops: [["update", "profiles", id, [
                    "displayName": optimisticName,
                    "handle": "@optimistic",
                    "createdAt": Date().timeIntervalSince1970
                ]]]
            )
            try await Reactor.shared.transact(appID: ReactorTests.testAppID, chunks: [chunk])
        }
        
        // 3. Immediately yield to let Reactor process the optimistic update
        // (Assuming Reactor.transact applies update on MainActor/actor before await client.transact)
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms wait
        
        // 4. Check Store
        let stored: Profile? = await TripleStore.shared.get(id: id)
        
        // This assertion will FAIL until we implement optimistic updates
        XCTAssertEqual(stored?.displayName, optimisticName, "Store should be optimistically updated")
        
        _ = try await task.value
        
        // Cleanup
        let deleteChunk = TransactionChunk(namespace: "profiles", id: id, ops: [["delete", "profiles", id]])
        try await Reactor.shared.transact(appID: Self.testAppID, chunks: [deleteChunk])
    }
}
