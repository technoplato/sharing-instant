import Sharing
import SharingInstant
import SwiftUI

/// Demonstrates a real-time avatar stack using InstantDB presence.
///
/// This example shows how to display all users currently in a room
/// as an overlapping avatar stack, similar to collaboration indicators
/// in apps like Figma or Google Docs.
///
/// ## Declarative API
///
/// This demo uses the new type-safe `@Shared(.instantPresence(...))` API
/// which eliminates manual setup, subscription management, and cleanup.
struct AvatarStackDemo: SwiftUICaseStudy {
  var caseStudyTitle: String { "Avatar Stack" }
  
  var readMe: String {
    """
    This demo shows a real-time avatar stack using InstantDB presence.
    
    **Features:**
    • Display all users currently in a room as an overlapping avatar stack
    • Similar to collaboration indicators in Figma or Google Docs
    • Uses `@Shared(.instantPresence(...))` for declarative presence
    
    Open this demo in multiple windows or devices to see the avatar stack grow!
    """
  }
  
  private let userId = String(UUID().uuidString.prefix(4))
  private let userColor = Color.random
  
  /// Type-safe presence subscription.
  ///
  /// The `@Shared` property wrapper handles:
  /// - Connecting to the room
  /// - Publishing initial presence
  /// - Subscribing to presence updates
  /// - Automatic cleanup on view disappear
  @Shared(.instantPresence(
    Schema.Rooms.avatars,
    roomId: "demo-123",
    initialPresence: AvatarsPresence(name: "", color: "")
  ))
  private var presence: RoomPresence<AvatarsPresence>
  
  var body: some View {
    VStack(spacing: 40) {
      Text("Who's Here")
        .font(.headline)
      
      // Avatar stack
      HStack(spacing: -12) {
        // Current user
        AvatarView(
          name: presence.user.name.isEmpty ? userId : presence.user.name,
          color: Color(hex: presence.user.color) ?? userColor,
          isCurrentUser: true
        )
        
        // Peers
        ForEach(presence.peers) { peer in
          AvatarView(
            name: peer.data.name.isEmpty ? String(peer.id.prefix(4)) : peer.data.name,
            color: Color(hex: peer.data.color) ?? .gray,
            isCurrentUser: false
          )
        }
      }
      
      Text("\(presence.totalCount) \(presence.peers.isEmpty ? "person" : "people") in this room")
        .font(.caption)
        .foregroundStyle(.secondary)
      
      if presence.isLoading {
        ProgressView("Connecting...")
          .font(.caption)
      }
      
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
    .onAppear {
      // Set initial presence with actual values
      $presence.withLock { state in
        state.user = AvatarsPresence(name: userId, color: userColor.hexString)
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
    #if !os(watchOS) && !os(tvOS)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.15)) {
        isHovered = hovering
      }
    }
    #endif
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
