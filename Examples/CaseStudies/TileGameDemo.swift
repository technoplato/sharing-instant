import IdentifiedCollections
import InstantDB
import Sharing
import SharingInstant
import SwiftUI

/// Demonstrates a collaborative tile game using InstantDB presence and data sync.
///
/// This example combines presence (to show who's playing and their colors)
/// with data sync (to persist the board state). Users can click tiles to
/// color them, and the board updates in real-time across all clients.
struct TileGameDemo: View {
  let room = InstantRoom(type: "tile-game", id: "demo-123")
  
  @Shared(.instantSync(configuration: .init(namespace: "boards")))
  private var boards: IdentifiedArrayOf<Board> = []
  
  @State private var presenceState = InstantPresenceState()
  @State private var unsubscribe: (() -> Void)?
  @State private var hoveredTile: String?
  
  private let userId = String(UUID().uuidString.prefix(4))
  @State private var myColor: Color = .random
  
  private let boardId = "tile-game-board-1"
  private let boardSize = 4
  
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
          
          if presenceState.peers.isEmpty {
            Text("No one else yet")
              .font(.caption)
              .foregroundStyle(.tertiary)
          } else {
            ForEach(presenceState.peersList, id: \.id) { peer in
              Circle()
                .fill(peer.color.flatMap { Color(hex: $0) } ?? .gray)
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
          .fill(Color(.secondarySystemBackground))
      )
      
      // Game board
      VStack(spacing: 2) {
        ForEach(0..<boardSize, id: \.self) { row in
          HStack(spacing: 2) {
            ForEach(0..<boardSize, id: \.self) { col in
              let key = "\(row)-\(col)"
              let color = tileColor(for: key)
              
              Rectangle()
                .fill(hoveredTile == key ? myColor : color)
                .frame(width: 60, height: 60)
                .overlay(
                  Rectangle()
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                )
                .onTapGesture {
                  setTileColor(key: key)
                }
                .onHover { isHovered in
                  hoveredTile = isHovered ? key : nil
                }
            }
          }
        }
      }
      .padding()
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(Color(.secondarySystemBackground))
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
    .task {
      await setupGame()
    }
    .onDisappear {
      unsubscribe?()
    }
  }
  
  private func tileColor(for key: String) -> Color {
    guard let board = boards.first(where: { $0.id == boardId }),
          let colorHex = board.state[key] else {
      return .white
    }
    return Color(hex: colorHex) ?? .white
  }
  
  @MainActor
  private func setupGame() async {
    let client = InstantClientFactory.makeClient()
    
    // Wait for connection
    while client.connectionState != .authenticated {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    
    // Choose a color that's not taken by peers
    let takenColors = Set(presenceState.peersList.compactMap { $0.color })
    let availableColors: [Color] = [.red, .green, .blue, .yellow, .purple, .orange]
      .filter { !takenColors.contains($0.hexString) }
    
    if let available = availableColors.randomElement() {
      myColor = available
    }
    
    // Join room with our presence
    _ = client.presence.joinRoom(room.roomId, initialPresence: [
      "name": userId,
      "color": myColor.hexString
    ])
    
    // Subscribe to presence
    unsubscribe = client.presence.subscribePresence(roomId: room.roomId) { slice in
      presenceState = InstantPresenceState(from: slice)
    }
    
    // Initialize board if it doesn't exist
    if boards.first(where: { $0.id == boardId }) == nil {
      var newBoard = Board(id: boardId)
      for row in 0..<boardSize {
        for col in 0..<boardSize {
          newBoard.state["\(row)-\(col)"] = "#FFFFFF"
        }
      }
      $boards.withLock { $0.append(newBoard) }
    }
  }
  
  @MainActor
  private func setTileColor(key: String) {
    guard var board = boards.first(where: { $0.id == boardId }) else { return }
    board.state[key] = myColor.hexString
    $boards.withLock { $0[id: boardId] = board }
  }
  
  @MainActor
  private func resetBoard() {
    guard var board = boards.first(where: { $0.id == boardId }) else { return }
    for row in 0..<boardSize {
      for col in 0..<boardSize {
        board.state["\(row)-\(col)"] = "#FFFFFF"
      }
    }
    $boards.withLock { $0[id: boardId] = board }
  }
}

// MARK: - Board Model

struct Board: Codable, Identifiable, Equatable, Sendable {
  var id: String
  var state: [String: String] = [:]
}

extension Board: EntityIdentifiable {
  static var namespace: String { "boards" }
}

#Preview {
  TileGameDemo()
}

