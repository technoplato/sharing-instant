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
import InstantDB
import SharingInstant

// MARK: - Room Presence Types
//
// These types conform to PresenceData (which includes Codable, Sendable, Equatable)
// from the InstantDB SDK.

/// Presence data for 'avatars' room.
public struct AvatarsPresence: PresenceData {
  public var name: String
  public var color: String
  
  public init(name: String, color: String) {
    self.name = name
    self.color = color
  }
}

/// Presence data for 'chat' room.
public struct ChatPresence: PresenceData {
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
public struct CursorsPresence: PresenceData {
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
public struct ReactionsPresence: PresenceData {
  public var name: String
  
  public init(name: String) {
    self.name = name
  }
}

/// Presence data for 'tileGame' room.
public struct TileGamePresence: PresenceData {
  public var name: String
  public var color: String
  
  public init(name: String, color: String) {
    self.name = name
    self.color = color
  }
}

// MARK: - Topic Payload Types

/// Topic payload for 'reactions.emoji' events.
public struct EmojiTopic: PresenceData {
  public var name: String
  public var directionAngle: Double
  public var rotationAngle: Double
  
  public init(name: String, directionAngle: Double, rotationAngle: Double) {
    self.name = name
    self.directionAngle = directionAngle
    self.rotationAngle = rotationAngle
  }
}

// MARK: - Schema Namespace
//
// ⚠️ TEMPORARY: Define Schema namespace here until generated schema is available.
// The generated Schema.swift in Sources/Generated/ is not part of the SharingInstant
// library - it's meant to be generated per-project. For CaseStudies, we define
// Schema locally.

public enum Schema {}

// MARK: - Room Keys

/// Type-safe room keys for presence subscriptions.
///
/// ⚠️ These should be auto-generated from instant.schema.ts
public extension Schema {
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

/// Type-safe topic keys for fire-and-forget events.
///
/// ⚠️ These should be auto-generated from instant.schema.ts
public extension Schema {
  enum Topics {
    /// 'emoji' topic in 'reactions' room
    public static let emoji = TopicKey<EmojiTopic>(roomType: "reactions", topic: "emoji")
  }
}
