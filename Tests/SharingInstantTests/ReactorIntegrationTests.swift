import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

final class ReactorIntegrationTests: XCTestCase {
  
  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44" // Same as Microblog
  
  // Use Todo schema from existing tests or define a local struct?
  // Existing tests usage "Todo" from 'Generated'.
  // I'll use the Profile/Post from Microblog tests as they are known to work.
  // Or just simple Dictionary based entities if I use raw reactor?
  // Reactor uses EntityIdentifiable.
  // Profile is EntityIdentifiable.
  
  override func setUp() async throws {
      // Clear TripleStore between tests?
      // TripleStore.shared is a singleton.
      // We can't clear it easily without adding a method.
      // But it shouldn't matter if we use unique IDs.
  }
  
  @MainActor
  func testReactorFlow() async throws {
      // 1. Prepare
      let id = UUID().uuidString
      // profile variable is used to create data, but in manual transaction we construct dict manually.
      // So 'profile' variable provided in previous snippet might be unused or used for assertion?
      // I'll reconstruct it for clarity or just ignore
      
      // 2. Write data using manual client
      let client = InstantClient(appID: Self.testAppID)
      client.connect()
      
      // Wait for auth
      while client.connectionState != .authenticated {
          try await Task.sleep(nanoseconds: 100_000_000)
      }
      
      let chunk = TransactionChunk(
        namespace: "profiles",
        id: id,
        ops: [["update", "profiles", id, [
            "displayName": "Reactor Test",
            "handle": "reactor",
            "createdAt": Date().timeIntervalSince1970
        ] as [String: Any]]]
      )
      
      try client.transact(chunk)
      
      // 3. Setup observation via Reactor (indirectly via @Shared logic? No, manual checking TripleStore)
      // We need to START a subscription to populate the store.
      // TripleStore only gets data if Reactor subscribes.
      // TripleStore is empty if no one subscribes!
      
      // So we MUST create a subscription.
      // Use InstantSyncKey or Reactor directly.
      
      // Start subscription using Reactor directly to avoid Shared overhead for this test part
      
      let config = SharingInstantSync.CollectionConfiguration<Profile>(
        namespace: "profiles",
        whereClause: ["id": id],
        includedLinks: [],
        linkTree: []
      )
      
      let stream = await Reactor.shared.subscribe(appID: Self.testAppID, configuration: config)
      
      // Start a task to consume stream (keeps subscription alive)
      let consumerTask = Task {
          for await _ in stream {
              // consumes
          }
      }
      
      // Wait for sync/write
      try await Task.sleep(nanoseconds: 2_000_000_000)
      
      // 4. Verify TripleStore has it
      // Note: TripleStore is shared singleton.
      let stored: Profile? = await TripleStore.shared.get(id: id)
      XCTAssertNotNil(stored)
      XCTAssertEqual(stored?.displayName, "Reactor Test")
      
      // Cleanup
      let deleteChunk = TransactionChunk(namespace: "profiles", id: id, ops: [["delete", "profiles", id]])
      try client.transact(deleteChunk)
      
      consumerTask.cancel()
  }
}
