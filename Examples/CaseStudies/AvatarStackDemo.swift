import InstantDB
import SharingInstant
import SwiftUI

/// Demonstrates a real-time avatar stack using InstantDB presence.
///
/// This example shows how to display all users currently in a room
/// as an overlapping avatar stack, similar to collaboration indicators
/// in apps like Figma or Google Docs.
struct AvatarStackDemo: View {
  let room = InstantRoom(type: "avatars", id: "demo-123")
  
  @State private var presenceState = InstantPresenceState()
  @State private var unsubscribe: (() -> Void)?
  
  private let userId = String(UUID().uuidString.prefix(4))
  private let userColor = Color.random
  
  var body: some View {
    VStack(spacing: 40) {
      Text("Who's Here")
        .font(.headline)
      
      // Avatar stack
      HStack(spacing: -12) {
        // Current user
        AvatarView(
          name: userId,
          color: userColor,
          isCurrentUser: true
        )
        
        // Peers
        ForEach(presenceState.peersList, id: \.id) { peer in
          AvatarView(
            name: peer.name ?? String(peer.id.prefix(4)),
            color: peer.color.flatMap { Color(hex: $0) } ?? .gray,
            isCurrentUser: false
          )
        }
      }
      
      Text("\(1 + presenceState.peers.count) \(presenceState.peers.count == 0 ? "person" : "people") in this room")
        .font(.caption)
        .foregroundStyle(.secondary)
      
      Spacer()
      
      VStack(spacing: 8) {
        Text("Open this demo in multiple windows or devices")
          .font(.caption)
          .foregroundStyle(.tertiary)
        
        Text("to see the avatar stack grow!")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(.bottom, 40)
    }
    .padding(.top, 60)
    .task {
      await setupPresence()
    }
    .onDisappear {
      unsubscribe?()
    }
  }
  
  @MainActor
  private func setupPresence() async {
    let client = InstantClientFactory.makeClient()
    
    // Wait for connection
    while client.connectionState != .authenticated {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    
    // Join room with our presence
    _ = client.presence.joinRoom(room.roomId, initialPresence: [
      "name": userId,
      "color": userColor.hexString
    ])
    
    // Subscribe to presence updates
    unsubscribe = client.presence.subscribePresence(roomId: room.roomId) { slice in
      withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
        presenceState = InstantPresenceState(from: slice)
      }
    }
  }
}

// MARK: - Avatar View

struct AvatarView: View {
  let name: String
  let color: Color
  let isCurrentUser: Bool
  
  @State private var isHovered = false
  
  var body: some View {
    ZStack {
      Circle()
        .fill(Color(.systemBackground))
        .frame(width: 48, height: 48)
      
      Circle()
        .fill(color.gradient)
        .frame(width: 44, height: 44)
      
      Text(String(name.prefix(1)).uppercased())
        .font(.headline)
        .fontWeight(.semibold)
        .foregroundStyle(.white)
      
      // "You" indicator
      if isCurrentUser {
        Circle()
          .fill(Color.green)
          .frame(width: 12, height: 12)
          .overlay(
            Circle()
              .strokeBorder(Color(.systemBackground), lineWidth: 2)
          )
          .offset(x: 14, y: 14)
      }
    }
    .overlay {
      if isHovered {
        Text(isCurrentUser ? "\(name) (You)" : name)
          .font(.caption)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            Capsule()
              .fill(Color(.systemBackground))
              .shadow(radius: 2)
          )
          .offset(y: -40)
          .transition(.opacity.combined(with: .scale))
      }
    }
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.15)) {
        isHovered = hovering
      }
    }
    .onTapGesture {
      withAnimation(.easeInOut(duration: 0.15)) {
        isHovered.toggle()
      }
    }
  }
}

#Preview {
  AvatarStackDemo()
}

