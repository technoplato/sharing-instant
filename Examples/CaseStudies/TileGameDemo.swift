import IdentifiedCollections
import Sharing
import SharingInstant
import SwiftUI

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
  @Shared(.instantSync(
    Schema.boards
      .where(\.id, .equals("a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"))
      .with(\.tiles)
  ))
  private var boards: IdentifiedArrayOf<Board> = []
  
  /// Ephemeral presence for who's playing.
  @Shared(.instantPresence(
    Schema.Rooms.tileGame,
    roomId: "demo-123",
    initialPresence: TileGamePresence(name: "", color: "")
  ))
  private var presence: RoomPresence<TileGamePresence>
  
  @State private var hoveredTile: String?
  
  var body: some View {
    VStack(spacing: 20) {
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
    guard let board = boards.first,
          let tiles = board.tiles,
          let tile = tiles.first(where: { Int($0.x) == row && Int($0.y) == col }) else {
      return .white
    }
    return Color(hex: tile.color) ?? .white
  }
  
  private func initializeGame() {
    // Choose a color that's not taken by peers
    let takenColors = Set(presence.peers.compactMap { $0.data.color })
    let availableColors: [Color] = [.red, .green, .blue, .yellow, .purple, .orange]
      .filter { !takenColors.contains($0.hexString) }
    
    if let available = availableColors.randomElement() {
      myColor = available
    }
    
    // Set presence
    _ = $presence.withLock { state in
      state.user = TileGamePresence(name: userId, color: myColor.hexString)
    }
    
    // Initialize board if it doesn't exist
    if boards.first == nil {
      let newBoard = Board(id: boardId, title: "Collaborative Game", createdAt: Date().timeIntervalSince1970)
      
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
      
      var boardWithTiles = newBoard
      boardWithTiles.tiles = newTiles
      
      _ = $boards.withLock { $0.append(boardWithTiles) }
    }
  }
  
  private func setTileColor(row: Int, col: Int) {
    guard let board = boards.first, var tiles = board.tiles else { return }
    guard let index = tiles.firstIndex(where: { Int($0.x) == row && Int($0.y) == col }) else { return }
    
    var tile = tiles[index]
    tile.color = myColor.hexString
    tiles[index] = tile
    
    var newBoard = board
    newBoard.tiles = tiles
    
    _ = $boards.withLock { $0[id: boardId] = newBoard }
  }
  
  private func resetBoard() {
    guard let board = boards.first, var tiles = board.tiles else { return }
    
    for i in 0..<tiles.count {
      tiles[i].color = "#FFFFFF"
    }
    
    var newBoard = board
    newBoard.tiles = tiles
    
    _ = $boards.withLock { $0[id: boardId] = newBoard }
  }
}

// Board is defined in Models/Todo.swift

#Preview {
  TileGameDemo()
}
