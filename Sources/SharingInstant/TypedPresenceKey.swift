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
  public static func instantPresence<T: Codable & Sendable & Equatable>(
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
  public static func instantPresence<T: Codable & Sendable & Equatable>(
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
  public static func instantPresence<T: Codable & Sendable & Equatable>(
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
  public static func instantPresence<T: Codable & Sendable & Equatable>(
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
public struct TypedPresenceKey<T: Codable & Sendable & Equatable>: SharedKey, @unchecked Sendable {
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
      
      // Get initial presence state
      if let slice = client.presence.getPresence(roomId: combinedRoomId) {
        let state = buildRoomPresence(from: slice)
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
      
      // Encode initial presence to dictionary
      let initialDict = encodePresence(initialPresence)
      
      // Subscribe to presence
      let unsub = client.presence.subscribePresence(
        roomId: combinedRoomId,
        initialPresence: initialDict
      ) { slice in
        let state = buildRoomPresence(from: slice)
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
      
      // Encode and publish the updated presence
      let presenceDict = encodePresence(value.user)
      client.presence.publishPresence(roomId: combinedRoomId, data: presenceDict)
      
      continuation.resume()
    }
  }
  
  // MARK: - Helpers
  
  private func encodePresence(_ presence: T) -> [String: Any] {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .millisecondsSince1970
      let data = try encoder.encode(presence)
      if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return dict
      }
    } catch {
      logger.error("Failed to encode presence: \(error.localizedDescription)")
    }
    return [:]
  }
  
  private func decodePresence(from dict: [String: Any]) -> T? {
    do {
      let data = try JSONSerialization.data(withJSONObject: dict)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      return try decoder.decode(T.self, from: data)
    } catch {
      logger.error("Failed to decode presence: \(error.localizedDescription)")
      return nil
    }
  }
  
  private func buildRoomPresence(from slice: PresenceSlice) -> RoomPresence<T> {
    // Decode user presence
    let user = decodePresence(from: slice.user) ?? initialPresence
    
    // Decode peer presence
    var peers: IdentifiedArrayOf<Peer<T>> = []
    for (peerId, peerData) in slice.peers {
      if let peerPresence = decodePresence(from: peerData) {
        peers.append(Peer(id: peerId, data: peerPresence))
      }
    }
    
    // Build error if present
    let error: (any Error)? = slice.error.map { PresenceError.roomError($0) }
    
    return RoomPresence(
      user: user,
      peers: peers,
      isLoading: slice.isLoading,
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

