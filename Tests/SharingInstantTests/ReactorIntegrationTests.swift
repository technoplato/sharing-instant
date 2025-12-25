
import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

final class ReactorIntegrationTests: XCTestCase {
  static let timeout: TimeInterval = 15
  
  @MainActor
  func testReactorTransactAndSubscribe() async throws {
    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-reactor",
      schema: EphemeralAppFactory.minimalProfilesSchema(),
      rules: EphemeralAppFactory.openRules(for: ["profiles"])
    )

    // Explicitly scope TripleStore to avoid ambiguity with InstantDB's TripleStore
    let store = SharedTripleStore()
    // Reactor is unique to SharingInstant
    let reactor = Reactor(
      store: store,
      clientInstanceID: "reactor-\(UUID().uuidString.lowercased())"
    )
    
    let id = UUID().uuidString.lowercased()
    
    let config = SharingInstantSync.CollectionConfiguration<Profile>(
      namespace: "profiles",
      orderBy: .desc("createdAt")
    )
    
    let stream = await reactor.subscribe(appID: app.id, configuration: config)
    
    let receivedInitialEmission = XCTestExpectation(description: "Receives initial emission from subscription")
    let receivedProfile = XCTestExpectation(description: "Receives profile from server")
    
    let consumeTask = Task { @MainActor in
      for await profiles in stream {
        receivedInitialEmission.fulfill()
        
        if profiles.contains(where: { $0.id == id }) {
          receivedProfile.fulfill()
          break
        }
      }
    }
    
    defer {
      consumeTask.cancel()
    }
    
    await fulfillment(of: [receivedInitialEmission], timeout: Self.timeout)
    
    let chunk = TransactionChunk(
      namespace: "profiles",
      id: id,
      ops: [["update", "profiles", id, [
        "displayName": "Alice",
        "handle": "@alice-\(id)",
        "createdAt": Date().timeIntervalSince1970 * 1_000
      ]]]
    )
    
    try await reactor.transact(appID: app.id, chunks: [chunk])
    
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
    try await reactor.transact(appID: app.id, chunks: [deleteChunk])
  }
}
