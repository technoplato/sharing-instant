import InstantDB
import SharingInstant
import SwiftUI

/// Demonstrates real-time typing indicators using InstantDB presence.
///
/// This example shows how to build a typing indicator that shows
/// when other users are actively typing in a shared input.
struct TypingIndicatorDemo: View, SwiftUICaseStudy {
  var caseStudyTitle: String { "Typing Indicators" }
  var readMe: String {
    """
    This demo shows real-time typing indicators using InstantDB presence.
    
    When you type in the text field, your typing state is broadcast to all \
    other users in the room. The avatar shows animated dots when a user is \
    actively typing.
    
    This pattern is commonly used in chat applications to show when other \
    participants are composing a message.
    """
  }
  
  let room = InstantRoom(type: "typing", id: "demo-123")
  
  @State private var message = ""
  @State private var presenceState = InstantPresenceState()
  @State private var isTyping = false
  @State private var unsubscribe: (() -> Void)?
  
  private let userId = String(UUID().uuidString.prefix(4))
  private let userColor = Color.random
  
  var body: some View {
    #if os(watchOS)
    watchOSBody
    #else
    regularBody
    #endif
  }
  
  private var watchOSBody: some View {
    VStack(spacing: 8) {
      // Compact peers row
      HStack(spacing: 4) {
        // Current user
        PeerAvatar(
          name: userId,
          color: userColor,
          isTyping: isTyping
        )
        
        // Other peers
        ForEach(presenceState.peersList, id: \.id) { peer in
          let peerIsTyping = (peer.data["isTyping"]?.value as? Bool) ?? false
          PeerAvatar(
            name: peer.name ?? String(peer.id.prefix(4)),
            color: peer.color.flatMap { Color(hex: $0) } ?? .gray,
            isTyping: peerIsTyping
          )
        }
      }
      
      // Typing indicator text
      if !activeTypers.isEmpty {
        Text(typingText)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      
      // Message input
      TextField("Type...", text: $message)
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
    .padding(4)
  }
  
  private var regularBody: some View {
    VStack(spacing: 0) {
      // Peers list
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          // Current user
          PeerAvatar(
            name: userId,
            color: userColor,
            isTyping: isTyping
          )
          .overlay(
            Text("You")
              .font(.caption2)
              .offset(y: 28)
          )
          
          // Other peers
          ForEach(presenceState.peersList, id: \.id) { peer in
            let peerIsTyping = (peer.data["isTyping"]?.value as? Bool) ?? false
            PeerAvatar(
              name: peer.name ?? String(peer.id.prefix(4)),
              color: peer.color.flatMap { Color(hex: $0) } ?? .gray,
              isTyping: peerIsTyping
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
          #if !os(tvOS) && !os(watchOS)
          .textFieldStyle(.roundedBorder)
          #endif
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
    .task {
      await setupPresence()
    }
    .onDisappear {
      unsubscribe?()
    }
  }
  
  private var activeTypers: [PeerPresence] {
    presenceState.peersList.filter { peer in
      (peer.data["isTyping"]?.value as? Bool) ?? false
    }
  }
  
  private var typingText: String {
    switch activeTypers.count {
    case 0:
      return ""
    case 1:
      let name = activeTypers[0].name ?? "Someone"
      return "\(name) is typing..."
    case 2:
      let name1 = activeTypers[0].name ?? "Someone"
      let name2 = activeTypers[1].name ?? "Someone"
      return "\(name1) and \(name2) are typing..."
    default:
      let name = activeTypers[0].name ?? "Someone"
      return "\(name) and \(activeTypers.count - 1) others are typing..."
    }
  }
  
  @MainActor
  private func setupPresence() async {
    let client = InstantClientFactory.makeClient()
    
    // Wait for connection
    while client.connectionState != .authenticated {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    
    // Join room with initial presence
    _ = client.presence.joinRoom(room.roomId, initialPresence: [
      "name": userId,
      "color": userColor.hexString,
      "isTyping": false
    ])
    
    // Subscribe to presence updates
    unsubscribe = client.presence.subscribePresence(roomId: room.roomId) { slice in
      presenceState = InstantPresenceState(from: slice)
    }
  }
  
  @MainActor
  private func updateTypingState(_ typing: Bool) {
    guard typing != isTyping else { return }
    isTyping = typing
    
    room.publishPresence(["isTyping": typing])
  }
  
  @MainActor
  private func sendMessage() {
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
  
  #if os(watchOS)
  private let size: CGFloat = 28
  private let dotOffset: CGFloat = 10
  #else
  private let size: CGFloat = 44
  private let dotOffset: CGFloat = 16
  #endif
  
  var body: some View {
    ZStack {
      Circle()
        .fill(color.opacity(0.2))
        .frame(width: size, height: size)
      
      Circle()
        .strokeBorder(color, lineWidth: 2)
        .frame(width: size, height: size)
      
      Text(String(name.prefix(1)).uppercased())
        #if os(watchOS)
        .font(.caption)
        #else
        .font(.headline)
        #endif
        .foregroundStyle(color)
      
      // Typing indicator
      if isTyping {
        TypingDots()
          .offset(x: dotOffset, y: dotOffset)
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
        #if os(iOS)
        .fill(Color(uiColor: .systemBackground))
        #elseif os(macOS)
        .fill(Color(nsColor: .windowBackgroundColor))
        #else
        .fill(Color.white)
        #endif
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


