
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
        initialPresence: TileGamePresence(color: "", name: "")
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
      state.user = TileGamePresence(color: myColor, name: userId)
    }

    if board == nil {
      let now = Date().timeIntervalSince1970 * 1_000
      let newBoard = Board(id: boardId, createdAt: now, title: "Test Board")
      $boards.withLock { $0.append(newBoard) }

      var newTiles: [Tile] = []
      for row in 0..<boardSize {
        for col in 0..<boardSize {
          newTiles.append(
            Tile(
              color: "#FFFFFF",
              createdAt: now,
              x: Double(row),
              y: Double(col)
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
  
  private struct TestHarnessError: Error {
    let message: String
  }

  private struct EphemeralAppResponse: Decodable {
    struct App: Decodable {
      let id: String
      let adminToken: String

      enum CodingKeys: String, CodingKey {
        case id
        case adminToken = "admin-token"
      }
    }

    let app: App
    let expiresMs: Int64

    enum CodingKeys: String, CodingKey {
      case app
      case expiresMs = "expires_ms"
    }
  }

  private struct EphemeralApp {
    let id: String
    let adminToken: String
  }
  
  @MainActor
  func testTileGameFlow() async throws {
    if ProcessInfo.processInfo.environment["INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS"] != "1" {
      throw XCTSkip(
        """
        Ephemeral backend integration tests are disabled.

        Set `INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS=1` to run tests that create a fresh \
        InstantDB app on each run via `/dash/apps/ephemeral`.
        """
      )
    }

    let app = try await Self.createEphemeralTileGameApp()

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
    
    await MainActor.run {
      InstantClientFactory.clearCache()
    }

    // 1. Setup two isolated environments (Client A and Client B)
    let storeA = SharedTripleStore()
    let reactorA = Reactor(store: storeA, clientInstanceID: "tile-game-client-a")
    
    let storeB = SharedTripleStore()
    let reactorB = Reactor(store: storeB, clientInstanceID: "tile-game-client-b")
    
    // InstantDB normalizes UUID entity IDs to lowercase on read.
    //
    // Why this exists:
    // Using `UUID().uuidString` (uppercase) for IDs causes the server to return a
    // lowercased ID, which can break queries that filter by `id` and can lead to
    // duplicate optimistic entities. Normalizing here keeps this test aligned with
    // real-world usage and prevents false negatives.
    let boardId = UUID().uuidString.lowercased()
    
    // 2. Initialize Model A (Player 1)
    let modelA = withDependencies {
      $0.context = .live
      $0.instantReactor = reactorA
      $0.instantAppID = app.id
      $0.instantEnableLocalPersistence = false
    } operation: {
      TileGameModelRefactored(boardId: boardId, appID: app.id)
    }
    
    // 3. Initialize Model B (Player 2)
    let modelB = withDependencies {
      $0.context = .live
      $0.instantReactor = reactorB
      $0.instantAppID = app.id
      $0.instantEnableLocalPersistence = false
    } operation: {
      TileGameModelRefactored(boardId: boardId, appID: app.id)
    }

    // Warm up both subscriptions before performing writes.
    //
    // Why this exists:
    // `@Shared` starts its underlying subscription lazily. If Client B has not yet
    // subscribed when Client A writes, we can miss the refresh window and end up
    // asserting on the initial empty value before the first `add-query-ok` arrives.
    _ = modelA.boards.count
    _ = modelB.boards.count
    try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
    
    // 4. Player A initializes the game
    modelA.initializeGame()
    
    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Client B should see the board created by A."
    ) {
      modelB.boards.count == 1
    }

    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Client B should see 16 tiles linked from the board."
    ) {
      modelB.board?.tiles?.count == 16
    }
    
    // 5. Player A moves (sets color)
    modelA.setTileColor(x: 0, y: 0)
    
    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Client B should see A's move."
    ) {
      modelB.tileColor(x: 0, y: 0) == "#FF0000"
    }
    
    // 6. Player B moves (resets board)
    modelB.resetBoard()
    
    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Client A should see B's reset."
    ) {
      modelA.tileColor(x: 0, y: 0) == "#FFFFFF"
    }
    
    // Cleanup
    let deleteChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [["delete", "boards", boardId]]
    )
    try await reactorA.transact(appID: app.id, chunks: [deleteChunk])
    try await Task.sleep(nanoseconds: 500_000_000)
  }

  // MARK: - Ephemeral App Creation

  private static func createEphemeralTileGameApp() async throws -> EphemeralApp {
    let apiOrigin = ProcessInfo.processInfo.environment["INSTANT_TEST_API_ORIGIN"] ?? "https://api.instantdb.com"

    guard let url = URL(string: "\(apiOrigin)/dash/apps/ephemeral") else {
      throw XCTSkip("Invalid INSTANT_TEST_API_ORIGIN: \(apiOrigin)")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let schema = minimalTileGameSchema()
    let rules: [String: Any] = [
      "boards": [
        "allow": [
          "view": "true",
          "create": "true",
          "update": "true",
          "delete": "true",
        ],
      ],
      "tiles": [
        "allow": [
          "view": "true",
          "create": "true",
          "update": "true",
          "delete": "true",
        ],
      ],
    ]

    let title = "sharing-instant-tile-game-\(UUID().uuidString.prefix(8))"
    let body: [String: Any] = [
      "title": title,
      "schema": schema,
      "rules": ["code": rules],
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw TestHarnessError(message: "Ephemeral app creation returned a non-HTTP response.")
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
      throw TestHarnessError(
        message:
        """
        Failed to create ephemeral app.

        Status: \(httpResponse.statusCode)
        Body: \(raw)
        """
      )
    }

    let decoded = try JSONDecoder().decode(EphemeralAppResponse.self, from: data)
    return EphemeralApp(id: decoded.app.id, adminToken: decoded.app.adminToken)
  }

  private static func minimalTileGameSchema() -> [String: Any] {
    func dataAttr(
      valueType: String,
      required: Bool,
      indexed: Bool = false,
      unique: Bool = false
    ) -> [String: Any] {
      [
        "valueType": valueType,
        "required": required,
        "isIndexed": indexed,
        "config": [
          "indexed": indexed,
          "unique": unique,
        ],
        "metadata": [:] as [String: Any],
      ]
    }

    func entityDef(
      attrs: [String: Any],
      links: [String: Any]
    ) -> [String: Any] {
      [
        "attrs": attrs,
        "links": links,
      ]
    }

    return [
      "entities": [
        "tiles": entityDef(
          attrs: [
            "x": dataAttr(valueType: "number", required: true, indexed: true),
            "y": dataAttr(valueType: "number", required: true, indexed: true),
            "color": dataAttr(valueType: "string", required: true),
            "createdAt": dataAttr(valueType: "number", required: true),
          ],
          links: [
            "board": [
              "entityName": "boards",
              "cardinality": "one",
            ],
          ]
        ),
        "boards": entityDef(
          attrs: [
            "title": dataAttr(valueType: "string", required: true),
            "createdAt": dataAttr(valueType: "number", required: true),
          ],
          links: [
            "tiles": [
              "entityName": "tiles",
              "cardinality": "many",
            ],
          ]
        ),
      ],
      "links": [
        "boardTiles": [
          "forward": [
            "on": "boards",
            "has": "many",
            "label": "tiles",
          ],
          "reverse": [
            "on": "tiles",
            "has": "one",
            "label": "board",
            "onDelete": "cascade",
          ],
        ],
      ],
      "rooms": [:] as [String: Any],
    ]
  }

  // MARK: - Helpers

  @MainActor
  private static func eventually(
    timeout: TimeInterval,
    pollInterval: TimeInterval,
    failureMessage: String,
    _ predicate: @escaping () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() {
        return
      }
      try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }

    XCTFail(failureMessage)
    throw TestHarnessError(message: failureMessage)
  }
}
