// Rooms.swift
//
// ⚠️ TEMPORARY MANUAL DEFINITIONS
//
// This file contains manually-defined room types and Schema extensions.
// These should eventually be AUTO-GENERATED from `instant.schema.ts` by
// the InstantSchemaCodegen tool.
//
// TODO: The Swift schema generator needs to be updated to:
// 1. Parse the `rooms` section from instant.schema.ts
// 2. Generate presence types (e.g., AvatarsPresence, ChatPresence)
// 3. Generate Schema.Rooms with RoomKey instances
// 4. Generate Schema.Topics with TopicKey instances
//
// Once the generator is fixed, delete this file and regenerate from:
//   swift run instant-schema generate \
//     --from Examples/CaseStudies/instant.schema.ts \
//     --to Sources/Generated/
//
// See: Examples/CaseStudies/instant.schema.ts for the source schema

import Foundation
import SharingInstant

// MARK: - Room Presence Types

/// Presence data for 'avatars' room.
public struct AvatarsPresence: Codable, Sendable, Equatable {
  public var name: String
  public var color: String
  
  public init(name: String, color: String) {
    self.name = name
    self.color = color
  }
}

/// Presence data for 'chat' room.
public struct ChatPresence: Codable, Sendable, Equatable {
  public var name: String
  public var color: String
  public var isTyping: Bool
  
  public init(name: String, color: String, isTyping: Bool = false) {
    self.name = name
    self.color = color
    self.isTyping = isTyping
  }
}

/// Presence data for 'cursors' room.
public struct CursorsPresence: Codable, Sendable, Equatable {
  public var name: String
  public var color: String
  public var cursorX: Double
  public var cursorY: Double
  
  public init(name: String, color: String, cursorX: Double = 0, cursorY: Double = 0) {
    self.name = name
    self.color = color
    self.cursorX = cursorX
    self.cursorY = cursorY
  }
}

/// Presence data for 'reactions' room.
public struct ReactionsPresence: Codable, Sendable, Equatable {
  public var name: String
  
  public init(name: String) {
    self.name = name
  }
}

/// Presence data for 'tileGame' room.
public struct TileGamePresence: Codable, Sendable, Equatable {
  public var name: String
  public var color: String
  
  public init(name: String, color: String) {
    self.name = name
    self.color = color
  }
}

// MARK: - Topic Payload Types

/// Topic payload for 'reactions.emoji' events.
public struct EmojiTopic: Codable, Sendable, Equatable {
  public var name: String
  public var directionAngle: Double
  public var rotationAngle: Double
  
  public init(name: String, directionAngle: Double, rotationAngle: Double) {
    self.name = name
    self.directionAngle = directionAngle
    self.rotationAngle = rotationAngle
  }
}

// MARK: - Room Keys

public extension Schema {
  /// Type-safe room keys for presence subscriptions.
  ///
  /// ⚠️ These should be auto-generated from instant.schema.ts
  enum Rooms {
    /// 'avatars' room - presence sync
    public static let avatars = RoomKey<AvatarsPresence>(type: "avatars")
    
    /// 'chat' room - presence sync
    public static let chat = RoomKey<ChatPresence>(type: "chat")
    
    /// 'cursors' room - presence sync
    public static let cursors = RoomKey<CursorsPresence>(type: "cursors")
    
    /// 'reactions' room - presence sync
    public static let reactions = RoomKey<ReactionsPresence>(type: "reactions")
    
    /// 'tileGame' room - presence sync
    public static let tileGame = RoomKey<TileGamePresence>(type: "tileGame")
  }
}

// MARK: - Topic Keys

public extension Schema {
  /// Type-safe topic keys for fire-and-forget events.
  ///
  /// ⚠️ These should be auto-generated from instant.schema.ts
  enum Topics {
    /// 'emoji' topic in 'reactions' room
    public static let emoji = TopicKey<EmojiTopic>(roomType: "reactions", topic: "emoji")
  }
}

// MARK: - Schema Namespace

/// Schema namespace for generated types.
///
/// ⚠️ TEMPORARY: This conflicts with the generated Schema in Sources/Generated/Schema.swift.
/// Once the schema generator properly generates rooms, this entire file should be deleted
/// and the generated Schema.swift will contain both entities AND rooms.
///
/// For now, this is needed because the generated Schema.swift doesn't include rooms.
public enum Schema {}
