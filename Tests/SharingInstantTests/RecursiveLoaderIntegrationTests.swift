import XCTest
import InstantDB
import Sharing
@testable import SharingInstant

// MARK: - RecursiveLoaderIntegrationTests

final class RecursiveLoaderIntegrationTests: XCTestCase {
  
  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  
  struct Tile: Codable, Identifiable, Equatable, EntityIdentifiable, Sendable {
    static var namespace: String { "tiles" }
    let id: String
    let color: String
  }
  
  struct Board: Codable, Identifiable, Equatable, EntityIdentifiable, Sendable {
    static var namespace: String { "boards" }
    let id: String
    let title: String
    let linkedTiles: [Tile]?
  }
  
  @MainActor
  func testRecursiveLoading() async throws {
    try IntegrationTestGate.requireEnabled()

    let store = SharedTripleStore()
    let reactor = Reactor(store: store)
    let boardId = UUID().uuidString.lowercased()
    let tileId = UUID().uuidString.lowercased()

    let nowMs = Date().timeIntervalSince1970 * 1000
    
    try await reactor.signInAsGuest(appID: Self.testAppID)
    
    defer {
      Task {
        try? await reactor.transact(
          appID: Self.testAppID,
          chunks: [
            TransactionChunk(namespace: "boards", id: boardId, ops: [["delete", "boards", boardId]]),
            TransactionChunk(namespace: "tiles", id: tileId, ops: [["delete", "tiles", tileId]]),
          ]
        )
      }
    }
    
    let boardOps: [[Any]] = [
      ["update", "boards", boardId, ["title": "Test", "createdAt": nowMs]],
    ]
    let tileOps: [[Any]] = [
      ["update", "tiles", tileId, ["color": "red", "x": 0, "y": 0, "createdAt": nowMs]],
    ]
    let linkOps: [[Any]] = [
      ["link", "boards", boardId, ["linkedTiles": tileId]],
    ]
    
    try await reactor.transact(
      appID: Self.testAppID,
      chunks: [
        TransactionChunk(namespace: "boards", id: boardId, ops: boardOps),
        TransactionChunk(namespace: "tiles", id: tileId, ops: tileOps),
        TransactionChunk(namespace: "boards", id: boardId, ops: linkOps),
      ]
    )
    
    let tilesNode = EntityQueryNode.link(name: "linkedTiles", limit: nil)
    let config = SharingInstantSync.CollectionConfiguration<Board>(
      namespace: "boards",
      whereClause: ["id": boardId],
      includedLinks: [],
      linkTree: [tilesNode]
    )
    
    let stream: AsyncStream<[Board]> = await reactor.subscribe(appID: Self.testAppID, configuration: config)
    
    var didMatch = false
    let expectation = XCTestExpectation(description: "Receives linked tile for board")
    
    let consumeTask = Task { @MainActor in
      for await boards in stream {
        guard let board = boards.first else { continue }
        guard let tile = board.linkedTiles?.first else { continue }
        
        if tile.id == tileId, tile.color == "red" {
          didMatch = true
          expectation.fulfill()
          break
        }
      }
    }
    
    defer {
      consumeTask.cancel()
    }
    
    await fulfillment(of: [expectation], timeout: 10.0)
    XCTAssertTrue(didMatch, "Expected subscription to include linked tile data")
  }
}
