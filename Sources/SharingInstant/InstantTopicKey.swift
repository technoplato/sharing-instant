// InstantTopicKey.swift
// SharingInstant
//
// Type-safe topic key for fire-and-forget events in InstantDB rooms.

import Dependencies
import Foundation
import InstantDB
import os.log
import Sharing

#if canImport(SwiftUI)
  import SwiftUI
#endif

// MARK: - Logging

private let logger = Logger(subsystem: "SharingInstant", category: "Topic")

// MARK: - SharedKey Extension for Topics

extension SharedKey {
  /// A type-safe key that subscribes to topic events in an InstantDB room.
  ///
  /// Use this to receive fire-and-forget events from peers in a room.
  /// Events you publish are NOT included in the channel - use `onAttempt`
  /// callback for local handling.
  ///
  /// ```swift
  /// @Shared(.instantTopic(
  ///   Schema.Topics.emoji,
  ///   roomId: "room-123"
  /// ))
  /// var emojiChannel: TopicChannel<EmojiTopic>
  ///
  /// // Publish with local callback
  /// $emojiChannel.publish(
  ///   EmojiTopic(name: "fire", angle: 45.0),
  ///   onAttempt: { payload in
  ///     animateEmoji(payload)
  ///   }
  /// )
  ///
  /// // React to peer events
  /// .onChange(of: emojiChannel.latestEvent) { _, event in
  ///   guard let event = event else { return }
  ///   animateEmoji(event.data)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - topicKey: The type-safe topic key from your schema.
  ///   - roomId: The unique room identifier.
  /// - Returns: A key that can be passed to `@Shared`.
  public static func instantTopic<T: Codable & Sendable & Equatable>(
    _ topicKey: TopicKey<T>,
    roomId: String
  ) -> Self where Self == InstantTopicKey<T>.Default {
    Self[
      InstantTopicKey(
        roomType: topicKey.roomType,
        topic: topicKey.topic,
        roomId: roomId,
        appID: nil
      ),
      default: TopicChannel()
    ]
  }
  
  /// A type-safe key that subscribes to topic events in an InstantDB room for a specific app.
  ///
  /// ## Multi-App Support (Untested)
  ///
  /// This overload exists to support connecting to multiple InstantDB apps
  /// simultaneously. Each app ID creates a separate cached `InstantClient`.
  ///
  /// **This feature has not been tested.** If you need multi-app support,
  /// please test thoroughly and report any issues.
  ///
  /// - Parameters:
  ///   - topicKey: The type-safe topic key from your schema.
  ///   - roomId: The unique room identifier.
  ///   - appID: The app ID to use.
  /// - Returns: A key that can be passed to `@Shared`.
  @available(*, deprecated, message: "Multi-app support is untested. Remove appID parameter to use the default app ID configured via prepareDependencies.")
  public static func instantTopic<T: Codable & Sendable & Equatable>(
    _ topicKey: TopicKey<T>,
    roomId: String,
    appID: String
  ) -> Self where Self == InstantTopicKey<T>.Default {
    Self[
      InstantTopicKey(
        roomType: topicKey.roomType,
        topic: topicKey.topic,
        roomId: roomId,
        appID: appID
      ),
      default: TopicChannel()
    ]
  }
  
  /// A type-safe key that subscribes to topic events in an InstantDB room.
  ///
  /// Use this when you don't have a schema-generated topic key.
  ///
  /// ```swift
  /// @Shared(.instantTopic(
  ///   roomType: "reactions",
  ///   topic: "emoji",
  ///   roomId: "room-123"
  /// ))
  /// var emojiChannel: TopicChannel<EmojiTopic>
  /// ```
  public static func instantTopic<T: Codable & Sendable & Equatable>(
    roomType: String,
    topic: String,
    roomId: String
  ) -> Self where Self == InstantTopicKey<T>.Default {
    Self[
      InstantTopicKey(
        roomType: roomType,
        topic: topic,
        roomId: roomId,
        appID: nil
      ),
      default: TopicChannel()
    ]
  }
  
  /// A type-safe key that subscribes to topic events in an InstantDB room for a specific app.
  ///
  /// ## Multi-App Support (Untested)
  ///
  /// This overload exists to support connecting to multiple InstantDB apps
  /// simultaneously. Each app ID creates a separate cached `InstantClient`.
  ///
  /// **This feature has not been tested.** If you need multi-app support,
  /// please test thoroughly and report any issues.
  ///
  /// Use this when you don't have a schema-generated topic key.
  @available(*, deprecated, message: "Multi-app support is untested. Remove appID parameter to use the default app ID configured via prepareDependencies.")
  public static func instantTopic<T: Codable & Sendable & Equatable>(
    roomType: String,
    topic: String,
    roomId: String,
    appID: String
  ) -> Self where Self == InstantTopicKey<T>.Default {
    Self[
      InstantTopicKey(
        roomType: roomType,
        topic: topic,
        roomId: roomId,
        appID: appID
      ),
      default: TopicChannel()
    ]
  }
}

// MARK: - InstantTopicKey

/// A type-safe SharedKey for subscribing to topic events in an InstantDB room.
///
/// Topics are fire-and-forget events that don't persist to the database.
/// Use them for things like emoji reactions, cursor movements, or notifications.
public struct InstantTopicKey<T: Codable & Sendable & Equatable>: SharedKey, @unchecked Sendable {
  public typealias Value = TopicChannel<T>
  
  let roomType: String
  let topic: String
  let roomId: String
  let appID: String
  
  public var id: String {
    "\(appID)-topic-\(roomType)-\(roomId)-\(topic)"
  }
  
  init(
    roomType: String,
    topic: String,
    roomId: String,
    appID: String?
  ) {
    @Dependency(\.instantAppID) var defaultAppID
    self.roomType = roomType
    self.topic = topic
    self.roomId = roomId
    self.appID = appID ?? defaultAppID
  }
  
  private var combinedRoomId: String {
    "\(roomType)-\(roomId)"
  }
  
  // MARK: - Load
  
  public func load(
    context: LoadContext<Value>,
    continuation: LoadContinuation<Value>
  ) {
    // Topics don't have initial state to load
    continuation.resumeReturningInitialValue()
  }
  
  // MARK: - Subscribe
  
  public func subscribe(
    context: LoadContext<Value>,
    subscriber: SharedSubscriber<Value>
  ) -> SharedSubscription {
    logger.info("Subscribing to topic '\(self.topic)' in room: \(self.combinedRoomId)")
    
    // Track current channel state
    var currentChannel = TopicChannel<T>(isConnected: false)
    
    let task = Task { @MainActor in
      let client = InstantClientFactory.makeClient(appID: appID)
      
      // Wait for authentication
      let timeout: UInt64 = 5_000_000_000
      let startTime = DispatchTime.now()
      
      while client.connectionState != .authenticated {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        if elapsed > timeout {
          logger.error("Topic subscribe timeout for room: \(self.combinedRoomId)")
          subscriber.yield(currentChannel)
          return
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      
      // Join the room first
      _ = client.presence.joinRoom(combinedRoomId)
      
      // Register for publishing and update connected state
      TopicPublisherRegistry.shared.register(
        keyID: self.id,
        roomId: self.combinedRoomId,
        topic: self.topic,
        appID: self.appID
      )
      currentChannel = TopicChannel(events: currentChannel.events, isConnected: true, keyID: self.id)
      subscriber.yield(currentChannel)
      
      // Subscribe to topic
      let unsub = client.presence.subscribeTopic(
        roomId: combinedRoomId,
        topic: topic
      ) { message in
        // Decode the topic payload
        if let payload = decodePayload(from: message.data) {
          let event = TopicEvent(
            peerId: message.peerId,
            data: payload
          )
          currentChannel.addEvent(event)
          subscriber.yield(currentChannel)
        }
      }
      
      // Keep subscription alive
      try? await Task.sleep(nanoseconds: .max)
      unsub()
    }
    
    return SharedSubscription {
      logger.debug("Unsubscribing from topic '\(self.topic)' in room: \(self.combinedRoomId)")
      task.cancel()
    }
  }
  
  // MARK: - Save
  
  public func save(
    _ value: Value,
    context: SaveContext,
    continuation: SaveContinuation
  ) {
    // Topic channels don't save state - use publish() instead
    continuation.resume()
  }
  
  // MARK: - Helpers
  
  private func decodePayload(from dict: [String: Any]) -> T? {
    do {
      let data = try JSONSerialization.data(withJSONObject: dict)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      return try decoder.decode(T.self, from: data)
    } catch {
      logger.error("Failed to decode topic payload: \(error.localizedDescription)")
      return nil
    }
  }
}

// MARK: - Shared Extension for Topic Publishing

extension Shared {
  /// Publishes a payload to a topic channel.
  ///
  /// - Parameters:
  ///   - payload: The data to publish.
  ///   - onAttempt: Called immediately with the payload (for local/optimistic handling).
  ///   - onError: Called if the publish fails.
  ///   - onSettled: Called when the publish completes (success or failure).
  ///
  /// ## Example
  ///
  /// ```swift
  /// $emojiChannel.publish(
  ///   EmojiTopic(name: "fire", angle: 45.0),
  ///   onAttempt: { payload in
  ///     // Animate locally immediately
  ///     animateEmoji(payload)
  ///   },
  ///   onError: { error in
  ///     showError(error)
  ///   }
  /// )
  /// ```
  @MainActor
  public func publish<T: Codable & Sendable & Equatable>(
    _ payload: T,
    onAttempt: ((T) -> Void)? = nil,
    onError: ((any Error) -> Void)? = nil,
    onSettled: (() -> Void)? = nil
  ) where Value == TopicChannel<T> {
    // Call onAttempt immediately (optimistic)
    onAttempt?(payload)
    
    // Get the key ID from the channel
    guard let keyID = self.wrappedValue._keyID else {
      onError?(TopicPublishError.notRegistered)
      onSettled?()
      return
    }
    
    // Encode payload
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    
    do {
      let data = try encoder.encode(payload)
      guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        let error = TopicPublishError.encodingFailed("Failed to encode topic payload")
        onError?(error)
        onSettled?()
        return
      }
      
      // Use the registry to publish
      TopicPublisherRegistry.shared.publish(
        keyID: keyID,
        payload: dict,
        onError: onError,
        onSettled: onSettled
      )
    } catch {
      onError?(error)
      onSettled?()
    }
  }
}

// MARK: - Topic Publish Error

/// Errors that can occur during topic publishing.
public enum TopicPublishError: Error, LocalizedError {
  case encodingFailed(String)
  case notRegistered
  
  public var errorDescription: String? {
    switch self {
    case .encodingFailed(let message):
      return "Topic encoding failed: \(message)"
    case .notRegistered:
      return "Topic publisher not registered"
    }
  }
}

// MARK: - Topic Publisher Registry

/// Internal registry for topic publishing.
///
/// This allows the `publish` method on `Shared` to find the correct
/// room and topic information for publishing.
@MainActor
final class TopicPublisherRegistry {
  static let shared = TopicPublisherRegistry()
  
  private var publishers: [String: TopicPublisher] = [:]
  
  private init() {}
  
  func register(keyID: String, roomId: String, topic: String, appID: String) {
    publishers[keyID] = TopicPublisher(roomId: roomId, topic: topic, appID: appID)
  }
  
  func publish(
    keyID: String,
    payload: [String: Any],
    onError: ((any Error) -> Void)?,
    onSettled: (() -> Void)?
  ) {
    guard let publisher = publishers[keyID] else {
      onError?(TopicPublishError.notRegistered)
      onSettled?()
      return
    }
    
    let client = InstantClientFactory.makeClient(appID: publisher.appID)
    client.presence.publishTopic(
      roomId: publisher.roomId,
      topic: publisher.topic,
      data: payload
    )
    
    onSettled?()
  }
  
  struct TopicPublisher {
    let roomId: String
    let topic: String
    let appID: String
  }
}

