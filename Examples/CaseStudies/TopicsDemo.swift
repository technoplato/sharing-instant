import Sharing
import SharingInstant
import SwiftUI

/// Demonstrates ephemeral topics (broadcast events) using InstantDB.
///
/// This example shows how to use topics to send fire-and-forget messages
/// that don't persist in the database - perfect for emoji reactions,
/// notifications, or other ephemeral events.
///
/// ## Declarative API
///
/// This demo uses the type-safe `@Shared(.instantTopic(...))` API.
/// The `publish` method takes an `onAttempt` callback for local handling.
struct TopicsDemo: SwiftUICaseStudy {
  var caseStudyTitle: String { "Topics" }
  
  var readMe: String {
    """
    This demo shows ephemeral topics (broadcast events) using InstantDB.
    
    **Features:**
    • Fire-and-forget messages that don't persist
    • Perfect for emoji reactions, notifications, ephemeral events
    • Uses `@Shared(.instantTopic(...))` for declarative topics
    • Local handling via `publish(onAttempt:)` callback
    
    Open this demo in multiple windows and tap emojis to broadcast!
    """
  }
  
  private let emojis: [(name: String, emoji: String)] = [
    ("fire", "🔥"),
    ("wave", "👋"),
    ("confetti", "🎉"),
    ("heart", "❤️"),
  ]
  
  /// Type-safe topic subscription for emoji events.
  @Shared(.instantTopic(
    Schema.Topics.emoji,
    roomId: "topics-demo"
  ))
  private var emojiChannel: TopicChannel<EmojiTopic>
  
  @State private var animations: [EmojiAnimation] = []
  
  private var secondaryBackgroundColor: Color {
    #if os(iOS) || os(visionOS)
    Color(.secondarySystemBackground)
    #elseif os(macOS)
    Color(.windowBackgroundColor)
    #else
    Color.gray.opacity(0.2)
    #endif
  }
  
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
        
        if !emojiChannel.isConnected {
          ProgressView("Connecting...")
            .font(.caption)
            .padding(.bottom, 8)
        }
        
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
              publishEmoji(item)
            } label: {
              Text(item.emoji)
                .font(.system(size: 32))
                .padding(12)
                .background(
                  RoundedRectangle(cornerRadius: 12)
                    .fill(secondaryBackgroundColor)
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
    .onChange(of: emojiChannel.latestEvent) { _, event in
      // Handle events from OTHER peers
      guard let event = event else { return }
      let emoji = emojis.first { $0.name == event.data.name }?.emoji ?? "❓"
      animateEmoji(emoji: emoji, event: event.data)
    }
  }
  
  private func publishEmoji(_ item: (name: String, emoji: String)) {
    let payload = EmojiTopic(
      name: item.name,
      directionAngle: Double.random(in: 0...1),
      rotationAngle: Double.random(in: 0...1)
    )
    
    // Publish with onAttempt for local animation
    $emojiChannel.publish(payload) { payload in
      // Animate locally immediately
      animateEmoji(emoji: item.emoji, event: payload)
    }
  }
  
  @MainActor
  private func animateEmoji(emoji: String, event: EmojiTopic) {
    let id = UUID()
    let angle = event.directionAngle * 2 * .pi
    
    let animation = EmojiAnimation(
      id: id,
      emoji: emoji,
      rotation: event.rotationAngle * 360,
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
