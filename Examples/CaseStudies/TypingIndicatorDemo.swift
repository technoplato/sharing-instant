import Sharing
import SharingInstant
import SwiftUI

/// Demonstrates real-time typing indicators using InstantDB presence.
///
/// This example shows how to build a typing indicator that shows
/// when other users are actively typing in a shared input.
///
/// ## Declarative API
///
/// This demo uses the type-safe `@Shared(.instantPresence(...))` API.
/// Typing state is updated via `$presence.withLock { $0.user.isTyping = true }`.
struct TypingIndicatorDemo: SwiftUICaseStudy {
  var caseStudyTitle: String { "Typing Indicator" }
  
  var readMe: String {
    """
    This demo shows real-time typing indicators using InstantDB presence.
    
    **Features:**
    • Shows when other users are actively typing
    • Uses `@Shared(.instantPresence(...))` for declarative presence
    • Typing state via `$presence.withLock { $0.user.isTyping = true }`
    
    Open this demo in multiple windows and start typing to see the indicators!
    """
  }
  
  private let userId = String(UUID().uuidString.prefix(4))
  private let userColor = Color.random
  
  /// Type-safe presence subscription with typing state.
  @Shared(.instantPresence(
    Schema.Rooms.chat,
    roomId: "demo-123",
    initialPresence: ChatPresence(name: "", color: "", isTyping: false)
  ))
  private var presence: RoomPresence<ChatPresence>
  
  @State private var message = ""
  
  /// Track previous peer count for logging
  @State private var previousPeerCount: Int = 0
  
  var body: some View {
    VStack(spacing: 0) {
      // Peers list
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          // Current user
          PeerAvatar(
            name: userId,
            color: userColor,
            isTyping: presence.user.isTyping
          )
          .overlay(
            Text("You")
              .font(.caption2)
              .offset(y: 28)
          )
          
          // Other peers
          ForEach(presence.peers) { peer in
            PeerAvatar(
              name: peer.data.name.isEmpty ? String(peer.id.prefix(4)) : peer.data.name,
              color: Color(hex: peer.data.color) ?? .gray,
              isTyping: peer.data.isTyping
            )
          }
        }
        .padding()
      }
      .frame(height: 80)
      
      Divider()
      
      Spacer()
      
      // Typing indicator text
      VStack {
        if !activeTypers.isEmpty {
          Text(typingText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .transition(.opacity)
        }
      }
      .frame(height: 20)
      .animation(.easeInOut(duration: 0.2), value: activeTypers.count)
      
      // Message input
      HStack {
        TextField("Type a message...", text: $message)
          .textFieldStyle(.roundedBorder)
          .onChange(of: message) { _, newValue in
            updateTypingState(!newValue.isEmpty)
          }
        
        Button {
          sendMessage()
        } label: {
          Image(systemName: "paperplane.fill")
        }
        .disabled(message.isEmpty)
      }
      .padding()
    }
    .onAppear {
      InstantLogger.viewAppeared("TypingIndicatorDemo")
      InstantLogger.info("Joining chat room", json: ["userId": userId, "roomId": "demo-123"])
      
      // Set initial presence with actual values
      $presence.withLock { state in
        state.user = ChatPresence(name: userId, color: userColor.hexString, isTyping: false)
      }
    }
    .onDisappear {
      InstantLogger.viewDisappeared("TypingIndicatorDemo")
    }
    .onChange(of: presence.peers.count) { oldCount, newCount in
      if newCount != previousPeerCount {
        InstantLogger.presenceUpdate(
          newCount > previousPeerCount ? "Peer joined chat" : "Peer left chat",
          peerCount: newCount,
          details: ["previousCount": previousPeerCount]
        )
        previousPeerCount = newCount
      }
    }
    .onChange(of: presence.isLoading) { _, isLoading in
      if !isLoading {
        InstantLogger.info("Chat presence connected", json: ["peerCount": presence.peers.count])
        previousPeerCount = presence.peers.count
      }
    }
    .onChange(of: activeTypers.count) { oldCount, newCount in
      if newCount != oldCount {
        let typerNames = activeTypers.map { $0.data.name.isEmpty ? $0.id : $0.data.name }
        InstantLogger.presenceUpdate(
          "Typing state changed",
          details: ["activeTypers": typerNames.joined(separator: ", "), "count": newCount]
        )
      }
    }
  }
  
  private var activeTypers: [Peer<ChatPresence>] {
    presence.peers.filter { $0.data.isTyping }
  }
  
  private var typingText: String {
    switch activeTypers.count {
    case 0:
      return ""
    case 1:
      let name = activeTypers[0].data.name.isEmpty ? "Someone" : activeTypers[0].data.name
      return "\(name) is typing..."
    case 2:
      let name1 = activeTypers[0].data.name.isEmpty ? "Someone" : activeTypers[0].data.name
      let name2 = activeTypers[1].data.name.isEmpty ? "Someone" : activeTypers[1].data.name
      return "\(name1) and \(name2) are typing..."
    default:
      let name = activeTypers[0].data.name.isEmpty ? "Someone" : activeTypers[0].data.name
      return "\(name) and \(activeTypers.count - 1) others are typing..."
    }
  }
  
  private func updateTypingState(_ typing: Bool) {
    guard typing != presence.user.isTyping else { return }
    
    InstantLogger.userAction(
      typing ? "Started typing" : "Stopped typing",
      details: ["userId": userId]
    )
    
    $presence.withLock { state in
      state.user.isTyping = typing
    }
  }
  
  private func sendMessage() {
    InstantLogger.userAction("Send message", details: ["messageLength": message.count])
    
    // In a real app, you'd send the message to your backend
    message = ""
    updateTypingState(false)
  }
}

// MARK: - Peer Avatar

struct PeerAvatar: View {
  let name: String
  let color: Color
  let isTyping: Bool
  
  var body: some View {
    ZStack {
      Circle()
        .fill(color.opacity(0.2))
        .frame(width: 44, height: 44)
      
      Circle()
        .strokeBorder(color, lineWidth: 2)
        .frame(width: 44, height: 44)
      
      Text(String(name.prefix(1)).uppercased())
        .font(.headline)
        .foregroundStyle(color)
      
      // Typing indicator
      if isTyping {
        TypingDots()
          .offset(x: 16, y: 16)
      }
    }
  }
}

// MARK: - Typing Dots Animation

struct TypingDots: View {
  @State private var animationPhase = 0
  
  var body: some View {
    HStack(spacing: 2) {
      ForEach(0..<3) { index in
        Circle()
          .fill(Color.primary)
          .frame(width: 4, height: 4)
          .offset(y: animationPhase == index ? -2 : 0)
      }
    }
    .padding(4)
    .background(
      Capsule()
        .fill(Color(.systemBackground))
        .shadow(radius: 1)
    )
    .onAppear {
      withAnimation(.easeInOut(duration: 0.3).repeatForever()) {
        animationPhase = (animationPhase + 1) % 3
      }
    }
  }
}

#Preview {
  TypingIndicatorDemo()
}
