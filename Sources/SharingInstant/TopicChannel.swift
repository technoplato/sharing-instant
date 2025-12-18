// TopicChannel.swift
// SharingInstant
//
// Type-safe topic channel for fire-and-forget events in InstantDB rooms.

import Foundation

// MARK: - TopicChannel

/// A channel for receiving and publishing fire-and-forget topic events.
///
/// Topics are ephemeral events that don't persist to the database. They're
/// ideal for things like emoji reactions, cursor movements, or notifications.
///
/// ## Example
///
/// ```swift
/// @Shared(.instantTopic(
///   Schema.Topics.emoji,
///   roomId: "room-123"
/// ))
/// var emojiChannel: TopicChannel<EmojiTopic>
///
/// // Publish an event with local callback
/// $emojiChannel.publish(
///   EmojiTopic(name: "fire", angle: 45.0),
///   onAttempt: { payload in
///     // Called immediately - animate locally
///     animateEmoji(payload)
///   }
/// )
///
/// // React to events from peers
/// .onChange(of: emojiChannel.latestEvent) { _, event in
///   guard let event = event else { return }
///   animateEmoji(event.data)
/// }
/// ```
public struct TopicChannel<T: Codable & Sendable & Equatable>: Sendable, Equatable {
  /// Recent events received from peers.
  ///
  /// This buffer holds the most recent events. Events you publish yourself
  /// are NOT included here - use `onAttempt` callback for local handling.
  public var events: [TopicEvent<T>]
  
  /// The most recent event received, if any.
  public var latestEvent: TopicEvent<T>? {
    events.last
  }
  
  /// Whether the room connection is established.
  public var isConnected: Bool
  
  /// Maximum number of events to keep in the buffer.
  public let maxEvents: Int
  
  /// Internal: The key ID for publishing (set by InstantTopicKey).
  internal var _keyID: String?
  
  /// Creates a new topic channel.
  ///
  /// - Parameters:
  ///   - events: Initial events (usually empty).
  ///   - isConnected: Whether connected to the room.
  ///   - maxEvents: Maximum events to buffer (default 50).
  ///   - keyID: Internal key ID for publishing.
  public init(
    events: [TopicEvent<T>] = [],
    isConnected: Bool = false,
    maxEvents: Int = 50,
    keyID: String? = nil
  ) {
    self.events = events
    self.isConnected = isConnected
    self.maxEvents = maxEvents
    self._keyID = keyID
  }
  
  public static func == (lhs: TopicChannel<T>, rhs: TopicChannel<T>) -> Bool {
    lhs.events == rhs.events &&
    lhs.isConnected == rhs.isConnected &&
    lhs.maxEvents == rhs.maxEvents
  }
  
  /// Adds an event to the channel, maintaining the max buffer size.
  public mutating func addEvent(_ event: TopicEvent<T>) {
    events.append(event)
    if events.count > maxEvents {
      events.removeFirst(events.count - maxEvents)
    }
  }
  
  /// Clears all buffered events.
  public mutating func clearEvents() {
    events.removeAll()
  }
}

// MARK: - TopicEvent

/// A single event received on a topic channel.
///
/// Each event contains the payload data, the sender's peer ID, and a timestamp.
public struct TopicEvent<T: Codable & Sendable & Equatable>: Identifiable, Sendable, Equatable {
  /// Unique identifier for this event.
  public let id: UUID
  
  /// The session ID of the peer who sent this event.
  public let peerId: String
  
  /// The event payload data.
  public let data: T
  
  /// When this event was received.
  public let timestamp: Date
  
  /// Creates a new topic event.
  ///
  /// - Parameters:
  ///   - id: Unique event ID (auto-generated if not provided).
  ///   - peerId: The sender's session ID.
  ///   - data: The event payload.
  ///   - timestamp: When the event was received (defaults to now).
  public init(
    id: UUID = UUID(),
    peerId: String,
    data: T,
    timestamp: Date = Date()
  ) {
    self.id = id
    self.peerId = peerId
    self.data = data
    self.timestamp = timestamp
  }
}

// MARK: - TopicPublishResult

/// The result of a topic publish operation.
///
/// This is used internally to track publish state and errors.
public struct TopicPublishResult: Sendable {
  /// Whether the publish was successful.
  public let success: Bool
  
  /// Any error that occurred during publish.
  public let error: (any Error)?
  
  /// Creates a successful result.
  public static var success: TopicPublishResult {
    TopicPublishResult(success: true, error: nil)
  }
  
  /// Creates a failure result with an error.
  public static func failure(_ error: any Error) -> TopicPublishResult {
    TopicPublishResult(success: false, error: error)
  }
}

