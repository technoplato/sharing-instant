import Dependencies
import Foundation
import InstantDB
import os.log

// MARK: - Logging

private let logger = Logger(subsystem: "SharingInstant", category: "Room")

// MARK: - InstantRoom

/// A room for real-time presence and topic communication.
///
/// Rooms allow users to share ephemeral state like cursor positions, typing indicators,
/// and broadcast messages to other users in the same room.
///
/// ## Creating a Room
///
/// ```swift
/// let room = InstantRoom(type: "document", id: "doc-123")
/// ```
///
/// ## Presence
///
/// Presence allows you to see who else is in a room and share state:
///
/// ```swift
/// // Sync your presence data
/// room.syncPresence(["name": "Alice", "color": "#ff0000"])
///
/// // Subscribe to presence changes
/// let unsub = room.subscribePresence { slice in
///   print("Me: \(slice.user)")
///   print("Peers: \(slice.peers)")
/// }
///
/// // Update your presence
/// room.publishPresence(["cursor": ["x": 100, "y": 200]])
///
/// // Clean up when done
/// unsub()
/// ```
///
/// ## Topics (Ephemeral Events)
///
/// Topics are for fire-and-forget messages that don't persist:
///
/// ```swift
/// // Subscribe to emoji reactions
/// let unsub = room.subscribeTopic("emoji") { message in
///   animateEmoji(message.data)
/// }
///
/// // Publish an emoji reaction
/// room.publishTopic("emoji", data: ["name": "fire"])
/// ```
///
/// - Note: Rooms are lightweight and can be created on demand. Multiple subscriptions
///   to the same room share a single connection.
public final class InstantRoom: @unchecked Sendable {
  /// The room type (e.g., "document", "cursors", "chat")
  public let type: String
  
  /// The unique room identifier
  public let id: String
  
  /// The combined room ID used internally
  public var roomId: String {
    "\(type)-\(id)"
  }
  
  /// The app ID this room belongs to
  public let appID: String
  
  /// Creates a room reference.
  ///
  /// - Parameters:
  ///   - type: The room type (e.g., "document", "cursors")
  ///   - id: The unique room identifier
  ///   - appID: Optional app ID. Uses the default if not specified.
  public init(type: String, id: String, appID: String? = nil) {
    @Dependency(\.instantAppID) var defaultAppID
    self.type = type
    self.id = id
    self.appID = appID ?? defaultAppID
  }
  
  // MARK: - Presence
  
  /// Syncs your presence data to the room.
  ///
  /// This joins the room (if not already joined) and sets your initial presence.
  /// Use ``publishPresence(_:)`` to update presence after initial sync.
  ///
  /// - Parameter data: Your presence data (e.g., name, color, cursor position)
  /// - Returns: A cleanup function to stop syncing and leave the room
  ///
  /// ## Example
  ///
  /// ```swift
  /// let cleanup = room.syncPresence([
  ///   "name": "Alice",
  ///   "color": "#ff0000"
  /// ])
  ///
  /// // Later, when leaving:
  /// cleanup()
  /// ```
  @MainActor
  @discardableResult
  public func syncPresence(_ data: [String: Any]) -> () -> Void {
    let client = InstantClientFactory.makeClient(appID: appID)
    logger.debug("Syncing presence to room: \(self.roomId)")
    return client.presence.joinRoom(roomId, initialPresence: data)
  }
  
  /// Publishes updated presence data to the room.
  ///
  /// This merges with your existing presence data. Use ``syncPresence(_:)``
  /// first to join the room and set initial presence.
  ///
  /// - Parameter data: The presence data to merge
  ///
  /// ## Example
  ///
  /// ```swift
  /// // Update cursor position
  /// room.publishPresence([
  ///   "cursor": ["x": 150, "y": 250]
  /// ])
  /// ```
  @MainActor
  public func publishPresence(_ data: [String: Any]) {
    let client = InstantClientFactory.makeClient(appID: appID)
    client.presence.publishPresence(roomId: roomId, data: data)
  }
  
  /// Subscribes to presence changes in the room.
  ///
  /// The callback is called immediately with the current presence state,
  /// and again whenever presence changes.
  ///
  /// - Parameters:
  ///   - keys: Optional keys to filter peers by
  ///   - initialPresence: Optional initial presence data (also joins the room)
  ///   - callback: Called when presence changes
  /// - Returns: An unsubscribe function
  ///
  /// ## Example
  ///
  /// ```swift
  /// let unsub = room.subscribePresence { slice in
  ///   // Your presence
  ///   print("Me: \(slice.user)")
  ///   
  ///   // Other users
  ///   for (peerId, peerData) in slice.peers {
  ///     print("Peer \(peerId): \(peerData)")
  ///   }
  /// }
  ///
  /// // Clean up when done
  /// unsub()
  /// ```
  @MainActor
  @discardableResult
  public func subscribePresence(
    keys: [String]? = nil,
    initialPresence: [String: Any]? = nil,
    callback: @escaping (PresenceSlice) -> Void
  ) -> () -> Void {
    let client = InstantClientFactory.makeClient(appID: appID)
    logger.debug("Subscribing to presence in room: \(self.roomId)")
    return client.presence.subscribePresence(
      roomId: roomId,
      keys: keys,
      initialPresence: initialPresence,
      callback: callback
    )
  }
  
  /// Gets the current presence state for the room.
  ///
  /// - Parameter keys: Optional keys to filter peers by
  /// - Returns: The current presence slice, or nil if not in the room
  @MainActor
  public func getPresence(keys: [String]? = nil) -> PresenceSlice? {
    let client = InstantClientFactory.makeClient(appID: appID)
    return client.presence.getPresence(roomId: roomId, keys: keys)
  }
  
  // MARK: - Topics
  
  /// Publishes a message to a topic in the room.
  ///
  /// Topics are for ephemeral, fire-and-forget messages that don't persist.
  /// Use them for things like emoji reactions, cursor movements, or typing indicators.
  ///
  /// - Parameters:
  ///   - topic: The topic name (e.g., "emoji", "cursor", "typing")
  ///   - data: The message data
  ///
  /// ## Example
  ///
  /// ```swift
  /// // Send an emoji reaction
  /// room.publishTopic("emoji", data: [
  ///   "name": "fire",
  ///   "angle": 45.0
  /// ])
  /// ```
  @MainActor
  public func publishTopic(_ topic: String, data: [String: Any]) {
    let client = InstantClientFactory.makeClient(appID: appID)
    client.presence.publishTopic(roomId: roomId, topic: topic, data: data)
    logger.debug("Published to topic '\(topic)' in room: \(self.roomId)")
  }
  
  /// Subscribes to a topic in the room.
  ///
  /// - Parameters:
  ///   - topic: The topic name to subscribe to
  ///   - callback: Called when a message is received
  /// - Returns: An unsubscribe function
  ///
  /// ## Example
  ///
  /// ```swift
  /// let unsub = room.subscribeTopic("emoji") { message in
  ///   print("Received \(message.data) from \(message.peerId)")
  ///   animateEmoji(message.data)
  /// }
  ///
  /// // Clean up when done
  /// unsub()
  /// ```
  @MainActor
  @discardableResult
  public func subscribeTopic(
    _ topic: String,
    callback: @escaping (TopicMessage) -> Void
  ) -> () -> Void {
    let client = InstantClientFactory.makeClient(appID: appID)
    logger.debug("Subscribing to topic '\(topic)' in room: \(self.roomId)")
    return client.presence.subscribeTopic(
      roomId: roomId,
      topic: topic,
      callback: callback
    )
  }
}

// MARK: - Convenience Initializer

extension InstantRoom {
  /// Creates a room from a combined room ID string.
  ///
  /// - Parameters:
  ///   - roomId: Combined room ID in "type-id" format
  ///   - appID: Optional app ID
  public convenience init(roomId: String, appID: String? = nil) {
    let components = roomId.split(separator: "-", maxSplits: 1)
    if components.count == 2 {
      self.init(type: String(components[0]), id: String(components[1]), appID: appID)
    } else {
      self.init(type: "default", id: roomId, appID: appID)
    }
  }
}

// MARK: - Equatable & Hashable

extension InstantRoom: Equatable, Hashable {
  public static func == (lhs: InstantRoom, rhs: InstantRoom) -> Bool {
    lhs.roomId == rhs.roomId && lhs.appID == rhs.appID
  }
  
  public func hash(into hasher: inout Hasher) {
    hasher.combine(roomId)
    hasher.combine(appID)
  }
}

