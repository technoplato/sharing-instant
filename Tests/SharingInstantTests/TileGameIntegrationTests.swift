import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - Integration Test Model Definitions
// We use generated models from Tests/SharingInstantTests/Generated.

// MARK: - Tile Game Model Wrapper

@MainActor
private class TileGameModelRefactored: ObservableObject {
  let userId = String(UUID().uuidString.prefix(4))
  var myColor: String = "#FF0000"
  let boardId: String
  let boardSize = 4
  
  @Shared var boards: IdentifiedArrayOf<Board>
  // We need access to tiles collection to add/update them.
  // We use .instantSync explicitly.
  @Shared(.instantSync(Schema.tiles)) var allTiles: IdentifiedArrayOf<Tile> = []
  @Shared var presence: RoomPresence<TileGamePresence>
  
  init(boardId: String, appID: String) {
    self.boardId = boardId
    
    // Initialize @Shared properties manually for the test model
    // 1. Fetch specific board with tile links using type-safe EntityKey
    _boards = Shared(
      .instantSync(
        Schema.boards
          .where(\.id, .equals(boardId))
          .with(\.tiles)
      )
    )
    
    // 2. Presence
    _presence = Shared(
      .instantPresence(
        Schema.Rooms.tileGame,
        roomId: "test-room-\(boardId)",
        initialPresence: TileGamePresence(name: "", color: "")
      )
    )
  }
  
  var board: Board? {
    boards.first
  }
  
  func tileColor(x: Int, y: Int) -> String {
    guard let board = board, let tiles = board.tiles else { return "#FFFFFF" }
    guard let tile = tiles.first(where: { Int($0.x) == x && Int($0.y) == y }) else { return "#FFFFFF" }
    return tile.color
  }
  
  func initializeGame() {
    $presence.withLock { state in
      state.user = TileGamePresence(name: userId, color: myColor)
    }
    
    if board == nil {
      let newBoard = Board(id: boardId, title: "Test Board", createdAt: Date().timeIntervalSince1970)
      $boards.withLock { $0.append(newBoard) }
      
      var newTiles: [Tile] = []
      for row in 0..<boardSize {
        for col in 0..<boardSize {
          newTiles.append(
            Tile(
              x: Double(row),
              y: Double(col),
              color: "#FFFFFF",
              createdAt: Date().timeIntervalSince1970
            )
          )
        }
      }
      
      // Update by setting tiles on the board, which should trigger link creation if handled by save
      // Or we might need to save tiles first.
      // In InstantDB (via Reactor), we usually save deep graphs.
      var boardWithTiles = newBoard
      boardWithTiles.tiles = newTiles
      
      $boards.withLock { $0[id: boardId] = boardWithTiles }
    }
  }
  
  func setTileColor(x: Int, y: Int) {
    guard let board = board, var tiles = board.tiles else { return }
    guard let tileIndex = tiles.firstIndex(where: { Int($0.x) == x && Int($0.y) == y }) else { return }
    
    var tile = tiles[tileIndex]
    tile.color = myColor
    
    // Update the tile in the board's tiles list
    tiles[tileIndex] = tile
    
    // Propagate change
    var newBoard = board
    newBoard.tiles = tiles
    
    $boards.withLock { $0[id: boardId] = newBoard }
  }
  
  func resetBoard() {
    guard let board = board, var tiles = board.tiles else { return }
    
    for i in 0..<tiles.count {
      tiles[i].color = "#FFFFFF"
    }
    
    var newBoard = board
    newBoard.tiles = tiles
    
    $boards.withLock { $0[id: boardId] = newBoard }
  }
}


final class TileGameIntegrationTests: XCTestCase {
  
  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  static let connectionTimeout: TimeInterval = 10.0
  
  @MainActor
  func testTileGameFlow() async throws {
    try await withDependencies {
      $0.instantAppID = Self.testAppID
    } operation: {
      let client = InstantClientFactory.makeClient(appID: Self.testAppID)
      if client.connectionState != .authenticated {
        client.connect()
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2s wait
      }
      
      let boardId = UUID().uuidString
      let model = TileGameModelRefactored(boardId: boardId, appID: Self.testAppID)
      
      // Init
      model.initializeGame()
      try await Task.sleep(nanoseconds: 500_000_000)
      
      XCTAssertEqual(model.boards.count, 1)
      XCTAssertEqual(model.board?.tiles?.count, 16)
      XCTAssertEqual(model.tileColor(x: 0, y: 0), "#FFFFFF")
      
      // Set Color
      model.setTileColor(x: 0, y: 0)
      try await Task.sleep(nanoseconds: 100_000_000)
      XCTAssertEqual(model.tileColor(x: 0, y: 0), "#FF0000")
      
      // Reset
      model.resetBoard()
      try await Task.sleep(nanoseconds: 100_000_000)
      XCTAssertEqual(model.tileColor(x: 0, y: 0), "#FFFFFF")
      
      // Cleanup
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
