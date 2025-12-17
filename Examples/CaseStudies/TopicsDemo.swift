import InstantDB
import SharingInstant
import SwiftUI

/// Demonstrates ephemeral topics (broadcast events) using InstantDB presence.
///
/// This example shows how to use topics to send fire-and-forget messages
/// that don't persist in the database - perfect for emoji reactions,
/// notifications, or other ephemeral events.
struct TopicsDemo: View {
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
          .font(.system(size: 40))
          .rotationEffect(.degrees(animation.rotation))
          .offset(x: animation.offset.width, y: animation.offset.height)
          .opacity(animation.opacity)
      }
      
      VStack {
        Spacer()
        
        Text("Tap an emoji to broadcast it!")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        
        Text("Open in multiple windows to see reactions from others.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .padding(.bottom, 20)
        
        // Emoji buttons
        HStack(spacing: 16) {
          ForEach(emojis, id: \.name) { item in
            Button {
              publishEmoji(item.name)
            } label: {
              Text(item.emoji)
                .font(.system(size: 32))
                .padding(12)
                .background(
                  RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                )
            }
            .buttonStyle(.plain)
            .scaleEffect(1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: animations.count)
          }
        }
        .padding(.bottom, 40)
      }
    }
    .task {
      await setupTopics()
    }
    .onDisappear {
      unsubscribe?()
    }
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
    
    // Animate outward
    withAnimation(.easeOut(duration: 0.6)) {
      if let index = animations.firstIndex(where: { $0.id == id }) {
        animations[index].offset = CGSize(
          width: cos(angle) * 200,
          height: sin(angle) * 200 - 100
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

