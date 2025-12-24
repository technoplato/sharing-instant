
import XCTest
import InstantDB
import Sharing
@testable import SharingInstant

// Helper for timeout
func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T where T: Sendable {
  return try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw TimeoutError()
    }

    do {
      let result = try await group.next()!
      group.cancelAll()
      while let _ = try? await group.next() {}
      return result
    } catch {
      group.cancelAll()
      while let _ = try? await group.next() {}
      throw error
    }
  }
}

struct TimeoutError: Error {}

final class ReactorTests: XCTestCase {


    
    // Use the same App ID as other integration tests
    static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
    
    override func setUp() async throws {
      try await super.setUp()
      try IntegrationTestGate.requireEnabled()
    }

    // 1. Fetches Data
    func testFetchesData() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)

        let id = UUID().uuidString
        let expectedName = "Test Fetch \(id)"

        // Subscribe first so we don't miss the server refresh for this transaction.
        let config = SharingInstantSync.CollectionConfiguration<Profile>(
            namespace: "profiles",
            whereClause: ["id": id],
            includedLinks: [],
            linkTree: []
        )
        
        let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)
        
        let subscriptionReady = XCTestExpectation(description: "Subscription registered on the server")
        let receivedUpdatedProfile = XCTestExpectation(description: "Receives updated profile")
        
        let consumeTask = Task { @MainActor in
          var didMarkSubscriptionReady = false
          for await profiles in stream {
            if !didMarkSubscriptionReady {
              didMarkSubscriptionReady = true
              subscriptionReady.fulfill()
            }

            if let first = profiles.first, first.displayName == expectedName {
              receivedUpdatedProfile.fulfill()
              break
            }
          }
        }
        
        defer {
          consumeTask.cancel()
        }

        await fulfillment(of: [subscriptionReady], timeout: 10)

        // Setup data
        let chunk = TransactionChunk(
            namespace: "profiles",
            id: id,
            ops: [["update", "profiles", id, [
	                "displayName": expectedName,
	                "handle": "@test-\(id)",
	                "createdAt": Date().timeIntervalSince1970 * 1_000
	            ]]]
	        )
        try await reactor.transact(appID: ReactorTests.testAppID, chunks: [chunk])
        
        await fulfillment(of: [receivedUpdatedProfile], timeout: 10)
        
        // Cleanup
        let deleteChunk = TransactionChunk(namespace: "profiles", id: id, ops: [["delete", "profiles", id]])
        try await reactor.transact(appID: ReactorTests.testAppID, chunks: [deleteChunk])
    }
    
    @MainActor
    func testReactorFlow() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)
        
        let id = UUID().uuidString
        
        // Subscribe first so we don't miss the server refresh for this transaction.
        let config = SharingInstantSync.CollectionConfiguration<Profile>(
            namespace: "profiles",
            whereClause: ["id": id],
            includedLinks: [],
            linkTree: []
        )

        let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)
        
        let subscriptionReady = XCTestExpectation(description: "Subscription registered on the server")
        let receivedProfile = XCTestExpectation(description: "Receives profile from server")
        
        let consumeTask = Task { @MainActor in
          var didMarkSubscriptionReady = false
          for await profiles in stream {
            if !didMarkSubscriptionReady {
              didMarkSubscriptionReady = true
              subscriptionReady.fulfill()
            }
            
            if let first = profiles.first, first.displayName == "Reactor Test" {
              receivedProfile.fulfill()
              break
            }
          }
        }
        
        defer {
          consumeTask.cancel()
        }

        await fulfillment(of: [subscriptionReady], timeout: 10)

        let chunk = TransactionChunk(
            namespace: "profiles",
            id: id,
            ops: [["update", "profiles", id, [
	                "displayName": "Reactor Test",
	                "handle": "@reactor-\(id)",
	                "createdAt": Date().timeIntervalSince1970 * 1_000
	            ]]]
	        )
        try await reactor.transact(appID: ReactorTests.testAppID, chunks: [chunk])
        
        await fulfillment(of: [receivedProfile], timeout: 10)
        
        // Cleanup
        let deleteChunk = TransactionChunk(namespace: "profiles", id: id, ops: [["delete", "profiles", id]])
        try await reactor.transact(appID: ReactorTests.testAppID, chunks: [deleteChunk])
    }
    
    // 2. Accepts Mutations
    func testAcceptsMutations() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)

         let id = UUID().uuidString
         let name = "Mutation Test"
          
         // Verify via server subscription (integration style).
         let config = SharingInstantSync.CollectionConfiguration<Profile>(
             namespace: "profiles",
             whereClause: ["id": id],
             includedLinks: [],
             linkTree: []
         )
         let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)
         
         let subscriptionReady = XCTestExpectation(description: "Subscription registered on the server")
         let receivedProfile = XCTestExpectation(description: "Receives profile from server")
         
         let consumeTask = Task { @MainActor in
           var didMarkSubscriptionReady = false
           for await profiles in stream {
             if !didMarkSubscriptionReady {
               didMarkSubscriptionReady = true
               subscriptionReady.fulfill()
             }
             
             if let first = profiles.first, first.displayName == name {
               receivedProfile.fulfill()
               break
             }
           }
         }
         
         defer {
           consumeTask.cancel()
         }

         await fulfillment(of: [subscriptionReady], timeout: 10)

         let chunk = TransactionChunk(
             namespace: "profiles",
             id: id,
             ops: [["update", "profiles", id, [
	                 "displayName": name,
	                 "handle": "@mutation-\(id)",
	                 "createdAt": Date().timeIntervalSince1970 * 1_000
	             ]]]
	         )
         try await reactor.transact(appID: ReactorTests.testAppID, chunks: [chunk])
          
         await fulfillment(of: [receivedProfile], timeout: 10)
        
        // Cleanup
        let deleteChunk = TransactionChunk(namespace: "profiles", id: id, ops: [["delete", "profiles", id]])
        try await reactor.transact(appID: ReactorTests.testAppID, chunks: [deleteChunk])
    }
    
    // 3. Optimistic Updates
    func testOptimisticUpdates() async throws {
        let store = SharedTripleStore()
        let reactor = Reactor(store: store)

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
	                    "handle": "@optimistic-\(id)",
	                    "createdAt": Date().timeIntervalSince1970 * 1_000
	                ]]]
	            )
            try await reactor.transact(appID: ReactorTests.testAppID, chunks: [chunk])
        }
        
        // Wait until the store reflects the optimistic change.
        try await withTimeout(seconds: 2) {
          while true {
            let stored: Profile? = store.get(id: id)
            if stored?.displayName == optimisticName {
              return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
          }
        }
        
        _ = try await task.value
        
        // Cleanup
        let deleteChunk = TransactionChunk(namespace: "profiles", id: id, ops: [["delete", "profiles", id]])
        try await reactor.transact(appID: ReactorTests.testAppID, chunks: [deleteChunk])
    }
}
