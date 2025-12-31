import Dependencies
import IdentifiedCollections
import Sharing
import SharingInstant
import SwiftUI

// #region agent log
private func debugLog(_ message: String, data: [String: Any] = [:], hypothesisId: String = "TILE_GAME") {
  let payload: [String: Any] = [
    "location": "TileGameDemo.swift",
    "message": message,
    "data": data,
    "timestamp": Date().timeIntervalSince1970 * 1000,
    "sessionId": "debug-session",
    "hypothesisId": hypothesisId
  ]
  guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }
  var request = URLRequest(url: URL(string: "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385")!)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.httpBody = jsonData
  let task = URLSession.shared.dataTask(with: request) { _, _, _ in }
  task.resume()
}
// #endregion

// MARK: - Cross-Platform Color Helper

private var secondaryBackgroundColor: Color {
  #if os(iOS) || os(visionOS)
  Color(.secondarySystemBackground)
  #elseif os(macOS)
  Color(.windowBackgroundColor)
  #else
  Color.gray.opacity(0.2)
  #endif
}

/// Demonstrates a collaborative tile game using InstantDB presence and data sync.
///
/// This example combines presence (to show who's playing and their colors)
/// with data sync (to persist the board state). Users can click tiles to
/// color them, and the board updates in real-time across all clients.
///
/// ## Combined APIs
///
/// This demo shows how to use both:
/// - `@Shared(.instantSync(...))` for persisted board state
/// - `@Shared(.instantPresence(...))` for ephemeral player presence
struct TileGameDemo: SwiftUICaseStudy {
  var caseStudyTitle: String { "Tile Game" }
  
  var readMe: String {
    """
    This demo shows a collaborative tile game combining presence and data sync.
    
    **Features:**
    • Click tiles to color them with your color
    • Board state persists via `@Shared(.instantSync(...))`
    • Player presence via `@Shared(.instantPresence(...))`
    • Real-time updates across all clients
    
    Open this demo in multiple windows to play together!
    """
  }
  
  private let userId = String(UUID().uuidString.prefix(4))
  @State private var myColor: Color = .random
  // InstantDB requires UUIDs for entity IDs. We use a deterministic UUID
  // so all clients share the same board. This is a UUID v5 generated from
  // the namespace "tile-game-board-1".
  private let boardId = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
  private let boardSize = 4
  
  /// Persisted board state using data sync.
  /// The `.with(\.tiles)` clause fetches the linked tiles for each board.
  @Shared(.instantSync(
    Schema.boards
      .where(\.id, .eq("a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"))
      .with(\.tiles)
  ))
  private var boards: IdentifiedArrayOf<Board> = []
  
  // #region agent log
  // ═══════════════════════════════════════════════════════════════════════════
  // HYPOTHESIS TEST QUERIES - Testing different approaches to filter by link
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// HYPOTHESIS A: Dot notation "board.id" - standard approach from JS docs
  /// Query: tiles where board.id = boardId
  @Shared(.instantSync(
    Schema.tiles
      .where("board.id", .eq("a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"))
  ))
  private var testA_DotNotationBoardId: IdentifiedArrayOf<Tile> = []
  
  /// HYPOTHESIS B: Just the link name without .id
  /// Query: tiles where board = boardId (might need the ID directly on link)
  @Shared(.instantSync(
    Schema.tiles
      .where("board", .eq("a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"))
  ))
  private var testB_LinkNameOnly: IdentifiedArrayOf<Tile> = []
  
  /// HYPOTHESIS C: Using the schema link attribute name "boardTiles"
  /// The link is defined as "boardTiles" in schema, maybe server expects that?
  @Shared(.instantSync(
    Schema.tiles
      .where("boardTiles.id", .eq("a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"))
  ))
  private var testC_SchemaLinkName: IdentifiedArrayOf<Tile> = []
  
  /// HYPOTHESIS D: Query tiles with .with(\.board) to get linked board data
  /// This tests if the link resolution works at all
  @Shared(.instantSync(
    Schema.tiles
      .with(\.board)
  ))
  private var testD_TilesWithBoard: IdentifiedArrayOf<Tile> = []
  
  /// HYPOTHESIS E: Filter by a regular field (x coordinate) to verify filtering works
  /// This is a control test - if this works, filtering infrastructure is fine
  @Shared(.instantSync(
    Schema.tiles
      .where(\.x, .eq(0))
  ))
  private var testE_FilterByX: IdentifiedArrayOf<Tile> = []
  
  /// HYPOTHESIS F: Filter tiles by board.title (linked entity attribute, not ID)
  /// This tests if the issue is specific to filtering by .id or affects all link attributes
  @Shared(.instantSync(
    Schema.tiles
      .where("board.title", .eq("Collaborative Game"))
  ))
  private var testF_LinkAttribute: IdentifiedArrayOf<Tile> = []
  
  /// HYPOTHESIS G: Filter boards by tiles.x (reverse direction, filtering parent by child attribute)
  /// This tests if the link direction matters
  @Shared(.instantSync(
    Schema.boards
      .where("tiles.x", .eq(0))
  ))
  private var testG_ReverseLink: IdentifiedArrayOf<Board> = []
  // #endregion
  
  /// All tiles subscription - we subscribe to all tiles and filter client-side.
  /// Note: Link-based where clauses (e.g., where("board.id", .eq(boardId))) don't work
  /// as expected in InstantDB, so we filter client-side using the board's linked tile IDs.
  @Shared(.instantSync(Schema.tiles))
  private var allTiles: IdentifiedArrayOf<Tile> = []
  
  /// Computed property to get tiles for this board.
  /// Uses the board's linked tiles (from .with(\.tiles)) to determine which tile IDs belong to this board,
  /// then returns matching tiles from allTiles for mutation support.
  private var tiles: [Tile] {
    guard let board = boards[id: boardId], let linkedTiles = board.tiles else {
      return []
    }
    let linkedTileIds = Set(linkedTiles.map { $0.id })
    return allTiles.filter { linkedTileIds.contains($0.id) }
  }
  
  /// Ephemeral presence for who's playing.
  @Shared(.instantPresence(
    Schema.Rooms.tileGame,
    roomId: "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
    initialPresence: TileGamePresence(name: "", color: "")
  ))
  private var presence: RoomPresence<TileGamePresence>
  
  @State private var hoveredTile: String?
  @State private var hasLoggedAfterDelay = false
  
  var body: some View {
    VStack(spacing: 20) {
      // #region agent log
      // HYPOTHESIS TESTS: Log state after data has had time to load
      Color.clear
        .frame(width: 0, height: 0)
        .onAppear {
          // Log after a delay to allow subscriptions to receive data
          DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if !hasLoggedAfterDelay {
              hasLoggedAfterDelay = true
              
              // Log all hypothesis test results
              debugLog("═══ HYPOTHESIS TEST RESULTS ═══", data: [
                "testA_DotNotationBoardId": testA_DotNotationBoardId.count,
                "testB_LinkNameOnly": testB_LinkNameOnly.count,
                "testC_SchemaLinkName": testC_SchemaLinkName.count,
                "testD_TilesWithBoard": testD_TilesWithBoard.count,
                "testE_FilterByX": testE_FilterByX.count,
                "testF_LinkAttribute": testF_LinkAttribute.count,
                "testG_ReverseLink": testG_ReverseLink.count,
                "allTiles": allTiles.count,
                "boardLinkedTiles": boards[id: boardId]?.tiles?.count ?? -1,
                "clientFilteredTiles": tiles.count
              ], hypothesisId: "SUMMARY")
              
              // Log details for testD to see if board link is populated
              if let firstTileWithBoard = testD_TilesWithBoard.first {
                debugLog("testD_TilesWithBoard first tile details", data: [
                  "tileId": firstTileWithBoard.id,
                  "hasBoard": firstTileWithBoard.board != nil,
                  "boardId": firstTileWithBoard.board?.id ?? "nil",
                  "boardTitle": firstTileWithBoard.board?.title ?? "nil"
                ], hypothesisId: "D")
              }
              
              // Log testE details to verify control test
              debugLog("testE_FilterByX (x=0) details", data: [
                "count": testE_FilterByX.count,
                "tileIds": testE_FilterByX.map { $0.id },
                "positions": testE_FilterByX.map { "(\($0.x), \($0.y))" }
              ], hypothesisId: "E")
              
              // Log testF details - filtering by linked entity attribute
              debugLog("testF_LinkAttribute (board.title) details", data: [
                "count": testF_LinkAttribute.count,
                "tileIds": testF_LinkAttribute.map { $0.id }
              ], hypothesisId: "F")
              
              // Log testG details - reverse link direction
              debugLog("testG_ReverseLink (boards with tiles.x=0) details", data: [
                "count": testG_ReverseLink.count,
                "boardIds": testG_ReverseLink.map { $0.id }
              ], hypothesisId: "G")
            }
          }
        }
      // #endregion
      
      // Players section
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Me:")
            .font(.caption)
            .foregroundStyle(.secondary)
          Circle()
            .fill(myColor)
            .frame(width: 24, height: 24)
            .overlay(
              Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
            )
        }
        
        HStack {
          Text("Others:")
            .font(.caption)
            .foregroundStyle(.secondary)
          
          if presence.peers.isEmpty {
            Text("No one else yet")
              .font(.caption)
              .foregroundStyle(.tertiary)
          } else {
            ForEach(presence.peers) { peer in
              Circle()
                .fill(Color(hex: peer.data.color) ?? .gray)
                .frame(width: 24, height: 24)
                .overlay(
                  Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
                )
            }
          }
        }
      }
      .padding()
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(secondaryBackgroundColor)
      )
      
      // Game board
      VStack(spacing: 2) {
        ForEach(0..<boardSize, id: \.self) { row in
          HStack(spacing: 2) {
            ForEach(0..<boardSize, id: \.self) { col in
              let tileKey = "\(row)-\(col)"
              let color = tileColor(row: row, col: col)
              
              Rectangle()
                .fill(hoveredTile == tileKey ? myColor : color)
                .frame(width: 60, height: 60)
                .overlay(
                  Rectangle()
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                )
                .onTapGesture {
                  setTileColor(row: row, col: col)
                }
                #if !os(watchOS) && !os(tvOS)
                .onHover { isHovered in
                  hoveredTile = isHovered ? tileKey : nil
                }
                #endif
            }
          }
        }
      }
      .padding()
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(secondaryBackgroundColor)
      )
      
      // Reset button
      Button("Reset Board") {
        resetBoard()
      }
      .buttonStyle(.bordered)
      
      Text("Click tiles to color them with your color!")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding()
    .onAppear {
      initializeGame()
    }
  }
  
  private func tileColor(row: Int, col: Int) -> Color {
    // Use the tiles subscription which is filtered by board
    guard let tile = tiles.first(where: { Int($0.x) == row && Int($0.y) == col }) else {
      return .white
    }
    return Color(hex: tile.color) ?? .white
  }
  
  private func initializeGame() {
    let now = Date().timeIntervalSince1970 * 1_000

    // #region agent log
    // Log initial state (before data loads)
    debugLog("initializeGame START - initial subscription states", data: [
      "testA_DotNotationBoardId": testA_DotNotationBoardId.count,
      "testB_LinkNameOnly": testB_LinkNameOnly.count,
      "testC_SchemaLinkName": testC_SchemaLinkName.count,
      "testD_TilesWithBoard": testD_TilesWithBoard.count,
      "testE_FilterByX": testE_FilterByX.count,
      "allTiles": allTiles.count,
      "boards": boards.count
    ], hypothesisId: "INIT")
    // #endregion

    // Choose a color that's not taken by peers
    let takenColors = Set(presence.peers.compactMap { $0.data.color })
    let availableColors: [Color] = [.red, .green, .blue, .yellow, .purple, .orange]
      .filter { !takenColors.contains($0.hexString) }
    
    if let available = availableColors.randomElement() {
      myColor = available
    }
    
    // Set presence
    $presence.withLock { state in
      state.user = TileGamePresence(name: userId, color: myColor.hexString)
    }

    // Ensure the deterministic board exists and has a full tile grid.
    //
    // Why this exists:
    // The Tile Game uses a fixed board ID so multiple clients share a single board.
    // If a previous run created the board without properly linking tiles (or if a
    // partial write occurred), the board may exist with `tiles == nil`, making the
    // UI appear "blank" and preventing local taps from updating any tile.
    ensureBoardHasTiles(now: now)
  }

  // MARK: - Board Initialization & Repair

  private func ensureBoardHasTiles(now: Double) {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    let expectedTileCount = boardSize * boardSize
    
    // #region agent log
    debugLog("ensureBoardHasTiles START", data: [
      "boardsCount": boards.count,
      "boardExists": boards[id: boardId] != nil,
      "boardLinkedTilesCount": boards[id: boardId]?.tiles?.count ?? -1,
      "allTilesCount": allTiles.count,
      "filteredTilesCount": tiles.count
    ])
    // #endregion
    
    let existingBoard = boards[id: boardId]
    
    // Build a map of existing tiles by position using the tiles subscription
    var existingTilesByPosition: [String: Tile] = [:]
    for tile in tiles {
      let key = "\(Int(tile.x))-\(Int(tile.y))"
      if existingTilesByPosition[key] == nil {
        existingTilesByPosition[key] = tile
      }
    }
    
    // If board exists with all tiles, nothing to do
    if existingBoard != nil && existingTilesByPosition.count == expectedTileCount {
      // #region agent log
      debugLog("ensureBoardHasTiles COMPLETE - board already has all tiles", data: [
        "tileCount": existingTilesByPosition.count
      ])
      // #endregion
      return
    }
    
    // Collect all transaction chunks
    var chunks: [TransactionChunk] = []
    
    // Create board if it doesn't exist
    if existingBoard == nil {
      // #region agent log
      debugLog("ensureBoardHasTiles CREATING BOARD", data: ["boardId": boardId])
      // #endregion
      
      chunks.append(TransactionChunk(
        namespace: "boards",
        id: boardId,
        ops: [["update", "boards", boardId, ["title": "Collaborative Game", "createdAt": now]]]
      ))
    }
    
    // Create missing tiles and link them to the board
    for row in 0..<boardSize {
      for col in 0..<boardSize {
        let key = "\(row)-\(col)"
        if existingTilesByPosition[key] == nil {
          // InstantDB requires valid lowercase UUIDs for entity IDs
          let tileId = UUID().uuidString.lowercased()
          
          // #region agent log
          debugLog("ensureBoardHasTiles CREATING TILE", data: [
            "tileId": tileId,
            "row": row,
            "col": col
          ])
          // #endregion
          
          // Create the tile
          chunks.append(TransactionChunk(
            namespace: "tiles",
            id: tileId,
            ops: [["update", "tiles", tileId, ["x": Double(row), "y": Double(col), "color": "#FFFFFF", "createdAt": now]]]
          ))
          
          // Link tile to board
          chunks.append(TransactionChunk(
            namespace: "boards",
            id: boardId,
            ops: [["link", "boards", boardId, ["tiles": ["id": tileId, "namespace": "tiles"]]]]
          ))
        }
      }
    }
    
    // #region agent log
    debugLog("ensureBoardHasTiles SENDING TRANSACTION", data: [
      "chunkCount": chunks.count
    ])
    // #endregion
    
    // Send all chunks in a single transaction
    if !chunks.isEmpty {
      Task {
        do {
          try await reactor.transact(appID: appID, chunks: chunks)
          // #region agent log
          debugLog("ensureBoardHasTiles TRANSACTION SUCCESS", data: ["chunkCount": chunks.count])
          // #endregion
        } catch {
          // #region agent log
          debugLog("ensureBoardHasTiles TRANSACTION FAILED", data: ["error": "\(error)"])
          // #endregion
        }
      }
    }
    
    // #region agent log
    debugLog("ensureBoardHasTiles END", data: [
      "createdTileCount": expectedTileCount - existingTilesByPosition.count
    ])
    // #endregion
  }
  
  private func setTileColor(row: Int, col: Int) {
    let now = Date().timeIntervalSince1970 * 1_000

    ensureBoardHasTiles(now: now)

    // Find the tile at this position from the tiles subscription
    guard let tile = tiles.first(where: { Int($0.x) == row && Int($0.y) == col }) else {
      // #region agent log
      debugLog("setTileColor TILE NOT FOUND", data: [
        "row": row,
        "col": col,
        "tilesCount": tiles.count,
        "tileIds": tiles.map { $0.id }
      ])
      // #endregion
      return
    }
    
    // #region agent log
    debugLog("setTileColor UPDATING", data: [
      "tileId": tile.id,
      "row": row,
      "col": col,
      "newColor": myColor.hexString
    ])
    // #endregion
    
    // Use the generated mutation on allTiles to update the tile color
    $allTiles.updateColor(tile.id, to: myColor.hexString)
  }
  
  private func resetBoard() {
    let now = Date().timeIntervalSince1970 * 1_000

    ensureBoardHasTiles(now: now)

    guard !tiles.isEmpty else {
      // #region agent log
      debugLog("resetBoard NO TILES", data: [
        "tilesCount": tiles.count
      ])
      // #endregion
      return
    }
    
    // #region agent log
    debugLog("resetBoard RESETTING", data: [
      "tileCount": tiles.count
    ])
    // #endregion

    // Reset each tile to white using the generated mutation on allTiles
    for tile in tiles {
      $allTiles.updateColor(tile.id, to: "#FFFFFF")
    }
  }
}

// Board is defined in Models/Todo.swift

#Preview {
  TileGameDemo()
}
