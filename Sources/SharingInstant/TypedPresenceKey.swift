// TypedPresenceKey.swift
// SharingInstant
//
// Type-safe presence key for InstantDB rooms using generics.

import Dependencies
import Foundation
import IdentifiedCollections
import InstantDB
import os.log
import Sharing

#if canImport(SwiftUI)
  import SwiftUI
#endif

// MARK: - Logging

private let logger = Logger(subsystem: "SharingInstant", category: "TypedPresence")

// MARK: - SharedKey Extension for Type-Safe Presence

extension SharedKey {
  /// A type-safe key that syncs presence state from an InstantDB room.
  ///
  /// Use this to create a reactive presence subscription with full type safety.
  /// The presence type is inferred from your schema-generated room key.
  ///
  /// ```swift
  /// @Shared(.instantPresence(
  ///   Schema.Rooms.chat,
  ///   roomId: "room-123",
  ///   initialPresence: ChatPresence(name: "Alice", isTyping: false)
  /// ))
  /// var presence: RoomPresence<ChatPresence>
  ///
  /// // Update your presence
  /// $presence.withLock { $0.user.isTyping = true }
  /// ```
  ///
  /// - Parameters:
  ///   - roomKey: The type-safe room key from your schema.
  ///   - roomId: The unique room identifier.
  ///   - initialPresence: Your initial presence data.
  /// - Returns: A key that can be passed to `@Shared`.
  public static func instantPresence<T: PresenceData>(
    _ roomKey: RoomKey<T>,
    roomId: String,
    initialPresence: T
  ) -> Self where Self == TypedPresenceKey<T>.Default {
    Self[
      TypedPresenceKey(
        roomType: roomKey.type,
        roomId: roomId,
        initialPresence: initialPresence,
        appID: nil
      ),
      default: RoomPresence(user: initialPresence)
    ]
  }
  
  /// A type-safe key that syncs presence state from an InstantDB room for a specific app.
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
  ///   - roomKey: The type-safe room key from your schema.
  ///   - roomId: The unique room identifier.
  ///   - initialPresence: Your initial presence data.
  ///   - appID: The app ID to use.
  /// - Returns: A key that can be passed to `@Shared`.
  @available(*, deprecated, message: "Multi-app support is untested. Remove appID parameter to use the default app ID configured via prepareDependencies.")
  public static func instantPresence<T: PresenceData>(
    _ roomKey: RoomKey<T>,
    roomId: String,
    initialPresence: T,
    appID: String
  ) -> Self where Self == TypedPresenceKey<T>.Default {
    Self[
      TypedPresenceKey(
        roomType: roomKey.type,
        roomId: roomId,
        initialPresence: initialPresence,
        appID: appID
      ),
      default: RoomPresence(user: initialPresence)
    ]
  }
  
  /// A type-safe key that syncs presence state from an InstantDB room.
  ///
  /// Use this when you don't have a schema-generated room key.
  ///
  /// ```swift
  /// @Shared(.instantPresence(
  ///   roomType: "chat",
  ///   roomId: "room-123",
  ///   initialPresence: ChatPresence(name: "Alice", isTyping: false)
  /// ))
  /// var presence: RoomPresence<ChatPresence>
  /// ```
  public static func instantPresence<T: PresenceData>(
    roomType: String,
    roomId: String,
    initialPresence: T
  ) -> Self where Self == TypedPresenceKey<T>.Default {
    Self[
      TypedPresenceKey(
        roomType: roomType,
        roomId: roomId,
        initialPresence: initialPresence,
        appID: nil
      ),
      default: RoomPresence(user: initialPresence)
    ]
  }
  
  /// A type-safe key that syncs presence state from an InstantDB room for a specific app.
  ///
  /// ## Multi-App Support (Untested)
  ///
  /// This overload exists to support connecting to multiple InstantDB apps
  /// simultaneously. Each app ID creates a separate cached `InstantClient`.
  ///
  /// **This feature has not been tested.** If you need multi-app support,
  /// please test thoroughly and report any issues.
  ///
  /// Use this when you don't have a schema-generated room key.
  @available(*, deprecated, message: "Multi-app support is untested. Remove appID parameter to use the default app ID configured via prepareDependencies.")
  public static func instantPresence<T: PresenceData>(
    roomType: String,
    roomId: String,
    initialPresence: T,
    appID: String
  ) -> Self where Self == TypedPresenceKey<T>.Default {
    Self[
      TypedPresenceKey(
        roomType: roomType,
        roomId: roomId,
        initialPresence: initialPresence,
        appID: appID
      ),
      default: RoomPresence(user: initialPresence)
    ]
  }
}

// MARK: - TypedPresenceKey

/// A type-safe SharedKey for subscribing to presence in an InstantDB room.
///
/// This key provides bidirectional sync: subscribing to presence updates from
/// peers, and publishing your presence updates when modified via `withLock`.
public struct TypedPresenceKey<T: PresenceData>: SharedKey, @unchecked Sendable {
  public typealias Value = RoomPresence<T>
  
  let roomType: String
  let roomId: String
  let initialPresence: T
  let appID: String
  
  public var id: String {
    "\(appID)-presence-\(roomType)-\(roomId)"
  }
  
  init(
    roomType: String,
    roomId: String,
    initialPresence: T,
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
  
  // MARK: - Load
  
  public func load(
    context: LoadContext<Value>,
    continuation: LoadContinuation<Value>
  ) {
    guard case .userInitiated = context else {
      continuation.resumeReturningInitialValue()
      return
    }
    
    logger.debug("Loading typed presence for room: \(self.combinedRoomId)")
    
    Task { @MainActor in
      let client = InstantClientFactory.makeClient(appID: appID)
      
      // Wait for authentication
      let timeout: UInt64 = 5_000_000_000
      let startTime = DispatchTime.now()
      
      while client.connectionState != .authenticated {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        if elapsed > timeout {
          logger.error("Presence load timeout for room: \(self.combinedRoomId)")
          continuation.resume(returning: RoomPresence(user: initialPresence, isLoading: false, error: InstantError.notAuthenticated))
          return
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      
      // Get initial presence state using the SDK's type-safe API
      if let typedSlice: TypedPresenceSlice<T> = client.presence.getTypedPresence(
        roomId: combinedRoomId,
        fallbackUser: initialPresence
      ) {
        let state = buildRoomPresence(from: typedSlice)
        continuation.resume(returning: state)
      } else {
        continuation.resume(returning: RoomPresence(user: initialPresence, isLoading: false))
      }
    }
  }
  
  // MARK: - Subscribe
  
  public func subscribe(
    context: LoadContext<Value>,
    subscriber: SharedSubscriber<Value>
  ) -> SharedSubscription {
    logger.info("Subscribing to typed presence for room: \(self.combinedRoomId)")
    
    let task = Task { @MainActor in
      let client = InstantClientFactory.makeClient(appID: appID)
      
      // Wait for authentication
      let timeout: UInt64 = 5_000_000_000
      let startTime = DispatchTime.now()
      
      while client.connectionState != .authenticated {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        if elapsed > timeout {
          logger.error("Presence subscribe timeout for room: \(self.combinedRoomId)")
          subscriber.yield(RoomPresence(user: initialPresence, isLoading: false, error: InstantError.notAuthenticated))
          return
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      
      // Subscribe to typed presence using the SDK's type-safe API
      // This eliminates manual JSON encode/decode at this layer
      let unsub = client.presence.subscribeTypedPresence(
        roomId: combinedRoomId,
        initialPresence: initialPresence
      ) { (typedSlice: TypedPresenceSlice<T>) in
        let state = buildRoomPresence(from: typedSlice)
        subscriber.yield(state)
      }
      
      // Keep subscription alive
      try? await Task.sleep(nanoseconds: .max)
      unsub()
    }
    
    return SharedSubscription {
      logger.debug("Unsubscribing from typed presence for room: \(self.combinedRoomId)")
      task.cancel()
    }
  }
  
  // MARK: - Save
  
  public func save(
    _ value: Value,
    context: SaveContext,
    continuation: SaveContinuation
  ) {
    // When the user updates presence via withLock, publish the changes
    logger.debug("Saving typed presence for room: \(self.combinedRoomId)")
    
    Task { @MainActor in
      let client = InstantClientFactory.makeClient(appID: appID)
      
      guard client.connectionState == .authenticated else {
        logger.warning("Cannot save presence - not authenticated")
        continuation.resume()
        return
      }
      
      // Publish the updated presence using the SDK's type-safe API
      client.presence.publishTypedPresence(roomId: combinedRoomId, data: value.user)
      
      continuation.resume()
    }
  }
  
  // MARK: - Helpers
  
  private func buildRoomPresence(from typedSlice: TypedPresenceSlice<T>) -> RoomPresence<T> {
    // Convert TypedPeer<T> to Peer<T>
    var peers: IdentifiedArrayOf<Peer<T>> = []
    for typedPeer in typedSlice.peers {
      peers.append(Peer(id: typedPeer.id, data: typedPeer.data))
    }
    
    // Build error if present
    let error: (any Error)? = typedSlice.error.map { PresenceError.roomError($0) }
    
    return RoomPresence(
      user: typedSlice.user,
      peers: peers,
      isLoading: typedSlice.isLoading,
      error: error
    )
  }
}

// MARK: - PresenceError

/// Errors that can occur during presence operations.
public enum PresenceError: Error, LocalizedError {
  case roomError(String)
  case decodingFailed(String)
  case encodingFailed(String)
  
  public var errorDescription: String? {
    switch self {
    case .roomError(let message):
      return "Room error: \(message)"
    case .decodingFailed(let message):
      return "Presence decoding failed: \(message)"
    case .encodingFailed(let message):
      return "Presence encoding failed: \(message)"
    }
  }
}

