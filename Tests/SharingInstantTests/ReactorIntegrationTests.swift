
import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

final class ReactorIntegrationTests: XCTestCase {
  
  // Same as Microblog
  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  static let timeout: TimeInterval = 10
  
  override func setUp() async throws {
    try await super.setUp()
    try IntegrationTestGate.requireEnabled()
  }
  
  @MainActor
  func testReactorTransactAndSubscribe() async throws {
    // Explicitly scope TripleStore to avoid ambiguity with InstantDB's TripleStore
    let store = SharedTripleStore()
    // Reactor is unique to SharingInstant
    let reactor = Reactor(store: store)
    
    let id = UUID().uuidString
    
    let config = SharingInstantSync.CollectionConfiguration<Profile>(
      namespace: "profiles",
      orderBy: .desc("createdAt")
    )
    
    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)
    
    let subscriptionReady = XCTestExpectation(description: "Subscription registered on the server")
    let receivedProfile = XCTestExpectation(description: "Receives profile from server")
    
    let consumeTask = Task { @MainActor in
      var emissionCount = 0
      for await profiles in stream {
        emissionCount += 1
        
        if emissionCount == 2 {
          subscriptionReady.fulfill()
        }
        
        if profiles.contains(where: { $0.id == id }) {
          receivedProfile.fulfill()
          break
        }
      }
    }
    
    defer {
      consumeTask.cancel()
    }
    
    await fulfillment(of: [subscriptionReady], timeout: Self.timeout)
    
    let chunk = TransactionChunk(
      namespace: "profiles",
      id: id,
      ops: [["update", "profiles", id, [
        "displayName": "Alice",
        "handle": "@alice-\(id)",
        "createdAt": Date().timeIntervalSince1970 * 1_000
      ]]]
    )
    
    try await reactor.transact(appID: Self.testAppID, chunks: [chunk])
    
    await fulfillment(of: [receivedProfile], timeout: Self.timeout)
    
    // 3. Verify Store manually (optional, but good for integ)
    // Use SharingInstant.TripleStore explicitly
    let stored: Profile? = store.get(id: id)
    XCTAssertEqual(stored?.displayName, "Alice")
    
    // Cleanup
    let deleteChunk = TransactionChunk(
      namespace: "profiles",
      id: id,
      ops: [["delete", "profiles", id]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])
  }
}
