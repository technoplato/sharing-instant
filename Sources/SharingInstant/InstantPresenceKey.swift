import Dependencies
import Foundation
import InstantDB
import os.log
import Sharing

#if canImport(SwiftUI)
  import SwiftUI
#endif

// MARK: - Logging

private let logger = Logger(subsystem: "SharingInstant", category: "Presence")

// MARK: - SharedReaderKey Extension

extension SharedReaderKey {
  /// A key that syncs presence state from an InstantDB room.
  ///
  /// Use this to create a reactive presence subscription that automatically
  /// updates when presence changes in the room.
  ///
  /// ```swift
  /// @SharedReader(.instantPresence(room: "document-123"))
  /// private var presence: InstantPresenceState
  ///
  /// var body: some View {
  ///   ForEach(presence.peersList, id: \.id) { peer in
  ///     Text(peer.name ?? "Anonymous")
  ///   }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - roomType: The room type (e.g., "document", "cursors")
  ///   - roomId: The unique room identifier
  ///   - initialPresence: Optional initial presence data to sync
  ///   - appID: Optional app ID. Uses the default if not specified.
  /// - Returns: A key that can be passed to `@SharedReader`
  public static func instantPresence(
    roomType: String,
    roomId: String,
    initialPresence: [String: Any]? = nil,
    appID: String? = nil
  ) -> Self where Self == InstantPresenceKey.Default {
    Self[
      InstantPresenceKey(
        roomType: roomType,
        roomId: roomId,
        initialPresence: initialPresence,
        appID: appID
      ),
      default: InstantPresenceState()
    ]
  }
  
  /// A key that syncs presence state from an InstantDB room.
  ///
  /// Convenience overload that takes a combined room ID.
  ///
  /// ```swift
  /// @SharedReader(.instantPresence(room: "cursors-example-123"))
  /// private var presence: InstantPresenceState
  /// ```
  public static func instantPresence(
    room: String,
    initialPresence: [String: Any]? = nil,
    appID: String? = nil
  ) -> Self where Self == InstantPresenceKey.Default {
    let components = room.split(separator: "-", maxSplits: 1)
    let roomType: String
    let roomId: String
    if components.count == 2 {
      roomType = String(components[0])
      roomId = String(components[1])
    } else {
      roomType = "default"
      roomId = room
    }
    return Self[
      InstantPresenceKey(
        roomType: roomType,
        roomId: roomId,
        initialPresence: initialPresence,
        appID: appID
      ),
      default: InstantPresenceState()
    ]
  }
}

// MARK: - InstantPresenceState

/// The state of presence in a room.
///
/// Contains your own presence data and the presence of all peers in the room.
public struct InstantPresenceState: Sendable, Equatable {
  /// Your own presence data
  public var user: [String: AnySendable]
  
  /// Presence data for all peers, keyed by session ID
  public var peers: [String: [String: AnySendable]]
  
  /// Whether we're still connecting to the room
  public var isLoading: Bool
  
  /// Error message if room join failed
  public var error: String?
  
  /// Creates an empty presence state
  public init() {
    self.user = [:]
    self.peers = [:]
    self.isLoading = true
    self.error = nil
  }
  
  /// Creates a presence state from a presence slice
  init(from slice: PresenceSlice) {
    self.user = slice.user.mapValues { AnySendable($0) }
    self.peers = slice.peers.mapValues { $0.mapValues { AnySendable($0) } }
    self.isLoading = slice.isLoading
    self.error = slice.error
  }
  
  /// Returns peers as an array for easier iteration
  public var peersList: [PeerPresence] {
    peers.map { PeerPresence(id: $0.key, data: $0.value) }
  }
  
  public static func == (lhs: InstantPresenceState, rhs: InstantPresenceState) -> Bool {
    lhs.user.description == rhs.user.description &&
    lhs.peers.description == rhs.peers.description &&
    lhs.isLoading == rhs.isLoading &&
    lhs.error == rhs.error
  }
}

/// A peer's presence data
public struct PeerPresence: Identifiable, Sendable {
  /// The peer's session ID
  public let id: String
  
  /// The peer's presence data
  public let data: [String: AnySendable]
  
  /// Convenience accessor for common presence fields
  public var name: String? {
    data["name"]?.value as? String
  }
  
  /// Convenience accessor for color
  public var color: String? {
    data["color"]?.value as? String
  }
}

/// A type-erased sendable wrapper for presence values
public struct AnySendable: @unchecked Sendable, CustomStringConvertible {
  public let value: Any
  
  public init(_ value: Any) {
    self.value = value
  }
  
  public var description: String {
    String(describing: value)
  }
}

// MARK: - InstantPresenceKey

/// A SharedReaderKey for subscribing to presence in an InstantDB room.
public struct InstantPresenceKey: SharedKey, @unchecked Sendable {
  public typealias Value = InstantPresenceState
  
  let roomType: String
  let roomId: String
  let initialPresence: [String: Any]?
  let appID: String
  
  public var id: String {
    "\(appID)-\(roomType)-\(roomId)"
  }
  
  init(
    roomType: String,
    roomId: String,
    initialPresence: [String: Any]?,
    appID: String?
  ) {
    @Dependency(\.instantAppID) var defaultAppID
    self.roomType = roomType
    self.roomId = roomId
    self.initialPresence = initialPresence
    self.appID = appID ?? defaultAppID
  }
  
  private var combinedRoomId: String {
    "\(roomType)-\(roomId)"
  }
  
  public func load(
    context: LoadContext<Value>,
    continuation: LoadContinuation<Value>
  ) {
    guard case .userInitiated = context else {
      continuation.resumeReturningInitialValue()
      return
    }
    
    logger.debug("Loading presence for room: \(self.combinedRoomId)")
    
    Task { @MainActor in
      let client = InstantClientFactory.makeClient(appID: appID)
      
      // Wait for authentication
      let timeout: UInt64 = 5_000_000_000
      let startTime = DispatchTime.now()
      
      while client.connectionState != .authenticated {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        if elapsed > timeout {
          logger.error("Presence load timeout for room: \(self.combinedRoomId)")
          continuation.resume(returning: InstantPresenceState())
          return
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      
      // Get initial presence state
      if let slice = client.presence.getPresence(roomId: combinedRoomId) {
        continuation.resume(returning: InstantPresenceState(from: slice))
      } else {
        continuation.resume(returning: InstantPresenceState())
      }
    }
  }
  
  public func subscribe(
    context: LoadContext<Value>,
    subscriber: SharedSubscriber<Value>
  ) -> SharedSubscription {
    logger.info("Subscribing to presence for room: \(self.combinedRoomId)")
    
    let task = Task { @MainActor in
      let client = InstantClientFactory.makeClient(appID: appID)
      
      // Wait for authentication
      let timeout: UInt64 = 5_000_000_000
      let startTime = DispatchTime.now()
      
      while client.connectionState != .authenticated {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        if elapsed > timeout {
          logger.error("Presence subscribe timeout for room: \(self.combinedRoomId)")
          subscriber.yield(InstantPresenceState())
          return
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      
      // Subscribe to presence
      let unsub = client.presence.subscribePresence(
        roomId: combinedRoomId,
        initialPresence: initialPresence
      ) { slice in
        let state = InstantPresenceState(from: slice)
        subscriber.yield(state)
      }
      
      // Keep subscription alive
      try? await Task.sleep(nanoseconds: .max)
      unsub()
    }
    
    return SharedSubscription {
      logger.debug("Unsubscribing from presence for room: \(self.combinedRoomId)")
      task.cancel()
    }
  }
  
  public func save(
    _ value: Value,
    context: SaveContext,
    continuation: SaveContinuation
  ) {
    // Presence is read-only through this key
    // Use InstantRoom.publishPresence() to update presence
    continuation.resume()
  }
}

