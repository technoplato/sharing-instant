
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
          .where(\.id, .eq(boardId))
          .with(\.tiles)
      )
    )
    
    // 2. Presence
    _presence = Shared(
      .instantPresence(
        Schema.Rooms.tileGame,
        roomId: boardId,
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
      let now = Date().timeIntervalSince1970 * 1_000
      let newBoard = Board(id: boardId, title: "Test Board", createdAt: now)
      $boards.withLock { $0.append(newBoard) }
      
      var newTiles: [Tile] = []
      for row in 0..<boardSize {
        for col in 0..<boardSize {
          newTiles.append(
            Tile(
              x: Double(row),
              y: Double(col),
              color: "#FFFFFF",
              createdAt: now
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
    try IntegrationTestGate.requireEnabled()

    // Clear any stale persistence
    if let bundleID = Bundle.main.bundleIdentifier {
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
    }
    // Also try to clear known keys if bundle ID method fails (CLI tests often have no bundle ID)
    UserDefaults.standard.dictionaryRepresentation().keys.forEach { key in
        if key.contains("instant") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    
    // 1. Setup two isolated environments (Client A and Client B)
    let storeA = SharedTripleStore()
    let reactorA = Reactor(store: storeA)
    
    let storeB = SharedTripleStore()
    let reactorB = Reactor(store: storeB)
    
    let boardId = UUID().uuidString
    
    // 2. Initialize Model A (Player 1)
    let modelA = withDependencies {
      $0.context = .live
      $0.instantReactor = reactorA
      $0.instantAppID = Self.testAppID
      $0.instantEnableLocalPersistence = false
    } operation: {
      TileGameModelRefactored(boardId: boardId, appID: Self.testAppID)
    }
    
    // 3. Initialize Model B (Player 2)
    let modelB = withDependencies {
      $0.context = .live
      $0.instantReactor = reactorB
      $0.instantAppID = Self.testAppID
      $0.instantEnableLocalPersistence = false
    } operation: {
      TileGameModelRefactored(boardId: boardId, appID: Self.testAppID)
    }
    
    // Connect both clients
    // Note: Reactor connects on demand, but we can force it or wait for basic query
    
    // Connect and Auth
    try await reactorA.signInAsGuest(appID: Self.testAppID)
    
    // 4. Player A initializes the game
    modelA.initializeGame()
    
    // Wait for A to write and B to receive
    // Since B is a separate Reactor/Store, it MUST receive data from the server.
    // Optimistic updates on A won't show up in B.
    try await Task.sleep(nanoseconds: 2_000_000_000) // 2s
    
    // Verify B sees the board created by A
    XCTAssertEqual(modelB.boards.count, 1, "Client B should see the board created by A")
    XCTAssertEqual(modelB.board?.tiles?.count, 16)
    
    // 5. Player A moves (sets color)
    modelA.setTileColor(x: 0, y: 0)
    
    // Wait for sync
    try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
    
    // Verify B sees the change
    XCTAssertEqual(modelB.tileColor(x: 0, y: 0), "#FF0000", "Client B should see A's move")
    
    // 6. Player B moves (resets board)
    modelB.resetBoard()
    
    // Wait for sync
    try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
    
    // Verify A sees the change
    XCTAssertEqual(modelA.tileColor(x: 0, y: 0), "#FFFFFF", "Client A should see B's reset")
    
    // Cleanup
    let deleteChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [["delete", "boards", boardId]]
    )
    try await reactorA.transact(appID: Self.testAppID, chunks: [deleteChunk])
    try await Task.sleep(nanoseconds: 500_000_000)
  }
}
