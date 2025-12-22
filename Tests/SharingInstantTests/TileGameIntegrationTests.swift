import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - Integration Test Model Definitions
// We duplicate Board here because it seems missing from the Test target's generated code,
// but we use the existing TileGamePresence from the generated code in the Test target to avoid conflicts.

private struct Board: EntityIdentifiable, Codable, Sendable {
  static var namespace: String { "boards" }
  
  var id: String
  var state: AnyCodable
  
  init(id: String = UUID().uuidString, state: AnyCodable) {
    self.id = id
    self.state = state
  }
}

private extension Schema {
  static var boards: EntityKey<Board> {
    EntityKey(namespace: "boards")
  }
  
  // We use the existing Schema.Rooms.tileGame from Generated/Rooms.swift
}

// MARK: - Tile Game Model Wrapper
// Encapsulates the logic from TileGameDemo to be tested

@MainActor
private class TileGameModel: ObservableObject {
  let userId = String(UUID().uuidString.prefix(4))
  var myColor: String = "#FF0000" // Fixed color for test
  let boardId: String // Passed in or generated
  let boardSize = 4
  
  @Shared var boards: IdentifiedArrayOf<Board>
  @Shared var presence: RoomPresence<TileGamePresence>
  
  init(boardId: String, appID: String) {
    self.boardId = boardId
    
    // Initialize @Shared properties manually for the test model
    // Use .instantSync with configuration to specific board for efficiency/test isolation
    _boards = Shared(
      .instantSync(
        configuration: .init(
          namespace: "boards",
          whereClause: ["id": boardId]
        )
      )
    )
    
    _presence = Shared(
      .instantPresence(
        Schema.Rooms.tileGame,
        roomId: "test-room-\(boardId)",
        initialPresence: TileGamePresence(name: "", color: "")
      )
    )
  }
  
  func tileColor(for key: String) -> String {
    guard let board = boards.first(where: { $0.id == boardId }),
          let stateDict = board.state.value as? [String: String],
          let colorHex = stateDict[key] else {
      return "#FFFFFF"
    }
    return colorHex
  }
  
  func initializeGame() {
    // Set presence
    $presence.withLock { state in
      state.user = TileGamePresence(name: userId, color: myColor)
    }
    
    // Initialize board if it doesn't exist
    if boards.first(where: { $0.id == boardId }) == nil {
      var stateDict: [String: String] = [:]
      for row in 0..<boardSize {
        for col in 0..<boardSize {
          stateDict["\(row)-\(col)"] = "#FFFFFF"
        }
      }
      let newBoard = Board(id: boardId, state: AnyCodable(stateDict))
      $boards.withLock { $0.append(newBoard) }
    }
  }
  
  func setTileColor(key: String) {
    guard var board = boards.first(where: { $0.id == boardId }) else { return }
    var stateDict = (board.state.value as? [String: String]) ?? [:]
    stateDict[key] = myColor
    board.state = AnyCodable(stateDict)
    $boards.withLock { $0[id: boardId] = board }
  }
  
  func resetBoard() {
    guard var board = boards.first(where: { $0.id == boardId }) else { return }
    var stateDict: [String: String] = [:]
    for row in 0..<boardSize {
      for col in 0..<boardSize {
        stateDict["\(row)-\(col)"] = "#FFFFFF"
      }
    }
    board.state = AnyCodable(stateDict)
    $boards.withLock { $0[id: boardId] = board }
  }
}

// MARK: - Integration Tests

final class TileGameIntegrationTests: XCTestCase {
  
  /// The test InstantDB app ID
  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  static let connectionTimeout: TimeInterval = 10.0
  
  @MainActor
  func testTileGameFlow() async throws {
    // 1. Setup Dependencies
    try await withDependencies {
      $0.instantAppID = Self.testAppID
    } operation: {
      
      // 2. Ensure Client Connection
      let client = InstantClientFactory.makeClient(appID: Self.testAppID)
      
      if client.connectionState != .authenticated {
        client.connect()
        
        let deadline = Date().addingTimeInterval(Self.connectionTimeout)
        while client.connectionState != .authenticated && Date() < deadline {
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(client.connectionState, .authenticated, "Client failed to authenticate")
      }
      
      // 3. Initialize Model
      let boardId = UUID().uuidString
      let model = TileGameModel(boardId: boardId, appID: Self.testAppID)
      
      // 4. Test Game Initialization
      model.initializeGame()
      
      // Wait for sync/local update
      // Since it's local-first, the shared array should update immediately.
      // But we might want to wait a tiny bit for the runloop/actors?
      try await Task.sleep(nanoseconds: 100_000_000)
      
      XCTAssertEqual(model.boards.count, 1, "Should have 1 board after init")
      XCTAssertEqual(model.boards.first?.id, boardId)
      
      // Check initial state
      let initialColor = model.tileColor(for: "0-0")
      XCTAssertEqual(initialColor, "#FFFFFF", "Initial tile color should be white")
      
      // 5. Test Color Update
      model.setTileColor(key: "0-0")
      
      // Wait for update
      try await Task.sleep(nanoseconds: 10_000_000)
      
      let updatedColor = model.tileColor(for: "0-0")
      XCTAssertEqual(updatedColor, "#FF0000", "Tile color should update to user color")
      
      // 6. Test Reset
      model.resetBoard()
      
      // Wait for update
      try await Task.sleep(nanoseconds: 10_000_000)
      
      let resetColor = model.tileColor(for: "0-0")
      XCTAssertEqual(resetColor, "#FFFFFF", "Tile color should reset to white")
      
      // 7. Cleanup
      let deleteChunk = TransactionChunk(
        namespace: "boards",
        id: boardId,
        ops: [["delete", "boards", boardId]]
      )
      try client.transact(deleteChunk)
      
      try await Task.sleep(nanoseconds: 500_000_000)
    }
  }
}
