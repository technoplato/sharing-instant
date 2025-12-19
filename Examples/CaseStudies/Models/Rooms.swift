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
//
// These types use explicit `nonisolated` conformances for Codable and Equatable
// to satisfy Swift 6 strict concurrency requirements. Without explicit implementations,
// Swift 6 infers @MainActor isolation from SwiftUI view context.

/// Presence data for 'avatars' room.
public struct AvatarsPresence: Sendable {
  public var name: String
  public var color: String
  
  public init(name: String, color: String) {
    self.name = name
    self.color = color
  }
}

extension AvatarsPresence: Equatable {
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name && lhs.color == rhs.color
  }
}

extension AvatarsPresence: Codable {
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try container.decode(String.self, forKey: .name)
    self.color = try container.decode(String.self, forKey: .color)
  }
  
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(color, forKey: .color)
  }
  
  private enum CodingKeys: String, CodingKey {
    case name, color
  }
}

/// Presence data for 'chat' room.
public struct ChatPresence: Sendable {
  public var name: String
  public var color: String
  public var isTyping: Bool
  
  public init(name: String, color: String, isTyping: Bool = false) {
    self.name = name
    self.color = color
    self.isTyping = isTyping
  }
}

extension ChatPresence: Equatable {
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name && lhs.color == rhs.color && lhs.isTyping == rhs.isTyping
  }
}

extension ChatPresence: Codable {
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try container.decode(String.self, forKey: .name)
    self.color = try container.decode(String.self, forKey: .color)
    self.isTyping = try container.decode(Bool.self, forKey: .isTyping)
  }
  
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(color, forKey: .color)
    try container.encode(isTyping, forKey: .isTyping)
  }
  
  private enum CodingKeys: String, CodingKey {
    case name, color, isTyping
  }
}

/// Presence data for 'cursors' room.
public struct CursorsPresence: Sendable {
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

extension CursorsPresence: Equatable {
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name && lhs.color == rhs.color && lhs.cursorX == rhs.cursorX && lhs.cursorY == rhs.cursorY
  }
}

extension CursorsPresence: Codable {
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try container.decode(String.self, forKey: .name)
    self.color = try container.decode(String.self, forKey: .color)
    self.cursorX = try container.decode(Double.self, forKey: .cursorX)
    self.cursorY = try container.decode(Double.self, forKey: .cursorY)
  }
  
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(color, forKey: .color)
    try container.encode(cursorX, forKey: .cursorX)
    try container.encode(cursorY, forKey: .cursorY)
  }
  
  private enum CodingKeys: String, CodingKey {
    case name, color, cursorX, cursorY
  }
}

/// Presence data for 'reactions' room.
public struct ReactionsPresence: Sendable {
  public var name: String
  
  public init(name: String) {
    self.name = name
  }
}

extension ReactionsPresence: Equatable {
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name
  }
}

extension ReactionsPresence: Codable {
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try container.decode(String.self, forKey: .name)
  }
  
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
  }
  
  private enum CodingKeys: String, CodingKey {
    case name
  }
}

/// Presence data for 'tileGame' room.
public struct TileGamePresence: Sendable {
  public var name: String
  public var color: String
  
  public init(name: String, color: String) {
    self.name = name
    self.color = color
  }
}

extension TileGamePresence: Equatable {
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name && lhs.color == rhs.color
  }
}

extension TileGamePresence: Codable {
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try container.decode(String.self, forKey: .name)
    self.color = try container.decode(String.self, forKey: .color)
  }
  
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(color, forKey: .color)
  }
  
  private enum CodingKeys: String, CodingKey {
    case name, color
  }
}

// MARK: - Topic Payload Types

/// Topic payload for 'reactions.emoji' events.
public struct EmojiTopic: Sendable {
  public var name: String
  public var directionAngle: Double
  public var rotationAngle: Double
  
  public init(name: String, directionAngle: Double, rotationAngle: Double) {
    self.name = name
    self.directionAngle = directionAngle
    self.rotationAngle = rotationAngle
  }
}

extension EmojiTopic: Equatable {
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name && lhs.directionAngle == rhs.directionAngle && lhs.rotationAngle == rhs.rotationAngle
  }
}

extension EmojiTopic: Codable {
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try container.decode(String.self, forKey: .name)
    self.directionAngle = try container.decode(Double.self, forKey: .directionAngle)
    self.rotationAngle = try container.decode(Double.self, forKey: .rotationAngle)
  }
  
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(directionAngle, forKey: .directionAngle)
    try container.encode(rotationAngle, forKey: .rotationAngle)
  }
  
  private enum CodingKeys: String, CodingKey {
    case name, directionAngle, rotationAngle
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
