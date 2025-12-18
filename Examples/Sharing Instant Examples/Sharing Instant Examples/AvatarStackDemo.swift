import InstantDB
import SharingInstant
import SwiftUI

/// Demonstrates a real-time avatar stack using InstantDB presence.
///
/// This example shows how to display all users currently in a room
/// as an overlapping avatar stack, similar to collaboration indicators
/// in apps like Figma or Google Docs.
struct AvatarStackDemo: View, SwiftUICaseStudy {
  var caseStudyTitle: String { "Avatar Stack" }
  var readMe: String {
    """
    This demo shows a real-time avatar stack using InstantDB presence.
    
    All users currently in the room are displayed as overlapping avatars, \
    similar to collaboration indicators in apps like Figma or Google Docs.
    
    The green dot indicates your own avatar. Hover or tap on avatars to see \
    the user's name.
    """
  }
  
  let room = InstantRoom(type: "avatars", id: "demo-123")
  
  @State private var presenceState = InstantPresenceState()
  @State private var unsubscribe: (() -> Void)?
  
  private let userId = String(UUID().uuidString.prefix(4))
  private let userColor = Color.random
  
  var body: some View {
    content
      .task {
        await setupPresence()
      }
      .onDisappear {
        unsubscribe?()
      }
  }
  
  @ViewBuilder
  private var content: some View {
    #if os(watchOS)
    VStack(spacing: 16) {
      Text("Who's Here")
        .font(.headline)
      
      // Avatar stack - smaller for watchOS
      HStack(spacing: -8) {
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
            color: peer.color.flatMap { Color($0) } ?? .gray,
            isCurrentUser: false
          )
        }
      }
      
      Text("\(1 + presenceState.peers.count) here")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.top, 20)
    #else
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
            color: peer.color.flatMap { Color($0) } ?? .gray,
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
    #endif
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
  
  #if os(watchOS)
  private let outerSize: CGFloat = 32
  private let innerSize: CGFloat = 28
  private let indicatorSize: CGFloat = 8
  private let indicatorOffset: CGFloat = 10
  #else
  private let outerSize: CGFloat = 48
  private let innerSize: CGFloat = 44
  private let indicatorSize: CGFloat = 12
  private let indicatorOffset: CGFloat = 14
  #endif
  
  var body: some View {
    ZStack {
      Circle()
        #if os(iOS)
        .fill(Color(uiColor: .systemBackground))
        #elseif os(macOS)
        .fill(Color(nsColor: .windowBackgroundColor))
        #else
        .fill(Color.white)
        #endif
        .frame(width: outerSize, height: outerSize)
      
      Circle()
        .fill(color.gradient)
        .frame(width: innerSize, height: innerSize)
      
      Text(String(name.prefix(1)).uppercased())
        #if os(watchOS)
        .font(.caption)
        #else
        .font(.headline)
        #endif
        .fontWeight(.semibold)
        .foregroundStyle(.white)
      
      // "You" indicator
      if isCurrentUser {
        Circle()
          .fill(Color.green)
          .frame(width: indicatorSize, height: indicatorSize)
          .overlay(
            Circle()
              #if os(iOS)
              .strokeBorder(Color(uiColor: .systemBackground), lineWidth: 2)
              #elseif os(macOS)
              .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
              #else
              .strokeBorder(Color.white, lineWidth: 2)
              #endif
          )
          .offset(x: indicatorOffset, y: indicatorOffset)
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
              #if os(iOS)
              .fill(Color(uiColor: .systemBackground))
              #elseif os(macOS)
              .fill(Color(nsColor: .windowBackgroundColor))
              #else
              .fill(Color.white)
              #endif
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


