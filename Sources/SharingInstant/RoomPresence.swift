// RoomPresence.swift
// SharingInstant
//
// Type-safe presence state for InstantDB rooms.

import Foundation
import IdentifiedCollections

// MARK: - RoomPresence

/// The state of presence in an InstantDB room.
///
/// This type is returned by `@Shared(.instantPresence(...))` and contains
/// your own presence data, the presence of all peers in the room, and
/// connection state information.
///
/// ## Example
///
/// ```swift
/// @Shared(.instantPresence(
///   Schema.Rooms.chat,
///   roomId: "room-123",
///   initialPresence: ChatPresence(name: "Alice", isTyping: false)
/// ))
/// var presence: RoomPresence<ChatPresence>
///
/// // Access your presence
/// let myName = presence.user.name
///
/// // Access peers
/// for peer in presence.peers {
///   print("\(peer.data.name) is typing: \(peer.data.isTyping)")
/// }
///
/// // Update your presence
/// $presence.withLock { $0.user.isTyping = true }
/// ```
public struct RoomPresence<T: Codable & Sendable & Equatable>: Sendable, Equatable {
  /// Your own presence data.
  ///
  /// Modify this via `$presence.withLock { $0.user.property = value }`.
  public var user: T
  
  /// All peers currently in the room.
  ///
  /// This is automatically updated as peers join, leave, or update their presence.
  public var peers: IdentifiedArrayOf<Peer<T>>
  
  /// Whether the room connection is still being established.
  public var isLoading: Bool
  
  /// An error that occurred during room connection or presence sync.
  public var error: (any Error)?
  
  /// Creates a new room presence state.
  ///
  /// - Parameters:
  ///   - user: Your initial presence data.
  ///   - peers: Initial peers (usually empty).
  ///   - isLoading: Whether still connecting.
  ///   - error: Any connection error.
  public init(
    user: T,
    peers: IdentifiedArrayOf<Peer<T>> = [],
    isLoading: Bool = true,
    error: (any Error)? = nil
  ) {
    self.user = user
    self.peers = peers
    self.isLoading = isLoading
    self.error = error
  }
  
  /// Convenience accessor for peers as an array.
  public var peersList: [Peer<T>] {
    Array(peers)
  }
  
  /// Total count of users in the room (including yourself).
  public var totalCount: Int {
    1 + peers.count
  }
  
  /// Whether there are any peers in the room.
  public var hasPeers: Bool {
    !peers.isEmpty
  }
  
  public static func == (lhs: RoomPresence<T>, rhs: RoomPresence<T>) -> Bool {
    lhs.user == rhs.user &&
    lhs.peers == rhs.peers &&
    lhs.isLoading == rhs.isLoading &&
    // Compare error descriptions since Error isn't Equatable
    lhs.error?.localizedDescription == rhs.error?.localizedDescription
  }
}

// MARK: - Peer

/// A peer in an InstantDB room with their presence data.
///
/// Each peer has a unique session ID and their current presence data.
/// The data type matches the room's presence type.
public struct Peer<T: Codable & Sendable & Equatable>: Identifiable, Sendable, Equatable {
  /// The peer's unique session ID.
  ///
  /// This is assigned by InstantDB and is unique per connection.
  public let id: String
  
  /// The peer's current presence data.
  public var data: T
  
  /// Creates a new peer.
  ///
  /// - Parameters:
  ///   - id: The peer's session ID.
  ///   - data: The peer's presence data.
  public init(id: String, data: T) {
    self.id = id
    self.data = data
  }
}

