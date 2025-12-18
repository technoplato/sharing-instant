import InstantDB
import SharingInstant
import SwiftUI

/// Demonstrates ephemeral topics (broadcast events) using InstantDB presence.
///
/// This example shows how to use topics to send fire-and-forget messages
/// that don't persist in the database - perfect for emoji reactions,
/// notifications, or other ephemeral events.
struct TopicsDemo: View, SwiftUICaseStudy {
  var caseStudyTitle: String { "Topics (Emoji Reactions)" }
  var readMe: String {
    """
    This demo shows ephemeral topics (broadcast events) using InstantDB presence.
    
    Topics are fire-and-forget messages that don't persist in the database. \
    They're perfect for emoji reactions, notifications, or other ephemeral events.
    
    Tap an emoji to broadcast it to all users in the room. The emoji will \
    animate outward and fade away.
    """
  }
  
  let room = InstantRoom(type: "topics", id: "demo-123")
  
  @State private var unsubscribe: (() -> Void)?
  @State private var animations: [EmojiAnimation] = []
  
  private let emojis: [(name: String, emoji: String)] = [
    ("fire", "🔥"),
    ("wave", "👋"),
    ("confetti", "🎉"),
    ("heart", "❤️"),
  ]
  
  var body: some View {
    ZStack {
      // Animated emojis
      ForEach(animations) { animation in
        Text(animation.emoji)
          #if os(watchOS)
          .font(.system(size: 24))
          #else
          .font(.system(size: 40))
          #endif
          .rotationEffect(.degrees(animation.rotation))
          .offset(x: animation.offset.width, y: animation.offset.height)
          .opacity(animation.opacity)
      }
      
      VStack {
        Spacer()
        
        #if !os(watchOS)
        Text("Tap an emoji to broadcast it!")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        
        Text("Open in multiple windows to see reactions from others.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .padding(.bottom, 20)
        #endif
        
        // Emoji buttons
        #if os(watchOS)
        // 2x2 grid for watchOS
        VStack(spacing: 8) {
          HStack(spacing: 8) {
            ForEach(emojis.prefix(2), id: \.name) { item in
              emojiButton(item)
            }
          }
          HStack(spacing: 8) {
            ForEach(emojis.suffix(2), id: \.name) { item in
              emojiButton(item)
            }
          }
        }
        .padding(.bottom, 8)
        #else
        HStack(spacing: 16) {
          ForEach(emojis, id: \.name) { item in
            emojiButton(item)
          }
        }
        .padding(.bottom, 40)
        #endif
      }
    }
    .task {
      await setupTopics()
    }
    .onDisappear {
      unsubscribe?()
    }
  }
  
  @ViewBuilder
  private func emojiButton(_ item: (name: String, emoji: String)) -> some View {
    Button {
      publishEmoji(item.name)
    } label: {
      Text(item.emoji)
        #if os(watchOS)
        .font(.system(size: 24))
        .padding(8)
        #else
        .font(.system(size: 32))
        .padding(12)
        #endif
        .background(
          RoundedRectangle(cornerRadius: 12)
            #if os(iOS)
            .fill(Color(uiColor: .secondarySystemBackground))
            #elseif os(macOS)
            .fill(Color(nsColor: .controlBackgroundColor))
            #else
            .fill(Color.gray.opacity(0.2))
            #endif
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        )
    }
    .buttonStyle(.plain)
    .scaleEffect(1.0)
    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: animations.count)
  }
  
  @MainActor
  private func setupTopics() async {
    let client = InstantClientFactory.makeClient()
    
    // Wait for connection
    while client.connectionState != .authenticated {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    
    // Join the room
    _ = client.presence.joinRoom(room.roomId)
    
    // Subscribe to emoji topic
    unsubscribe = client.presence.subscribeTopic(roomId: room.roomId, topic: "emoji") { message in
      guard let name = message.data["name"] as? String,
            let directionAngle = message.data["directionAngle"] as? Double,
            let rotationAngle = message.data["rotationAngle"] as? Double else {
        return
      }
      
      let emoji = emojis.first { $0.name == name }?.emoji ?? "❓"
      animateEmoji(emoji: emoji, directionAngle: directionAngle, rotationAngle: rotationAngle)
    }
  }
  
  @MainActor
  private func publishEmoji(_ name: String) {
    let params: [String: Any] = [
      "name": name,
      "directionAngle": Double.random(in: 0...1),
      "rotationAngle": Double.random(in: 0...1)
    ]
    
    // Animate locally
    let emoji = emojis.first { $0.name == name }?.emoji ?? "❓"
    animateEmoji(
      emoji: emoji,
      directionAngle: params["directionAngle"] as! Double,
      rotationAngle: params["rotationAngle"] as! Double
    )
    
    // Broadcast to others
    room.publishTopic("emoji", data: params)
  }
  
  @MainActor
  private func animateEmoji(emoji: String, directionAngle: Double, rotationAngle: Double) {
    let id = UUID()
    let angle = directionAngle * 2 * .pi
    
    let animation = EmojiAnimation(
      id: id,
      emoji: emoji,
      rotation: rotationAngle * 360,
      offset: .zero,
      opacity: 1.0
    )
    
    animations.append(animation)
    
    // Animate outward (smaller distance on watchOS)
    #if os(watchOS)
    let distance: CGFloat = 80
    let verticalOffset: CGFloat = 40
    #else
    let distance: CGFloat = 200
    let verticalOffset: CGFloat = 100
    #endif
    
    withAnimation(.easeOut(duration: 0.6)) {
      if let index = animations.firstIndex(where: { $0.id == id }) {
        animations[index].offset = CGSize(
          width: cos(angle) * distance,
          height: sin(angle) * distance - verticalOffset
        )
        animations[index].opacity = 0
      }
    }
    
    // Remove after animation
    Task {
      try? await Task.sleep(nanoseconds: 800_000_000)
      animations.removeAll { $0.id == id }
    }
  }
}

// MARK: - Emoji Animation

struct EmojiAnimation: Identifiable {
  let id: UUID
  let emoji: String
  var rotation: Double
  var offset: CGSize
  var opacity: Double
}

#Preview {
  TopicsDemo()
}


