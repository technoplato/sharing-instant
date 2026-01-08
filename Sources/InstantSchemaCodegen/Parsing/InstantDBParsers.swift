// InstantDBParsers.swift
// InstantSchemaCodegen
//
// ═══════════════════════════════════════════════════════════════════════════════
// INSTANTDB-SPECIFIC PARSERS
// ═══════════════════════════════════════════════════════════════════════════════
//
// This file contains parsers for InstantDB schema constructs. These build on the
// primitive parsers from TypeScriptParsers.swift to parse:
//
// - Field types: i.string(), i.number(), i.boolean(), i.date(), i.json()
// - Fields: fieldName: i.string().optional()
// - Entities: entityName: i.entity({ ...fields... })
// - Links: linkName: { forward: {...}, reverse: {...} }
// - Rooms: roomName: { presence: {...}, topics: {...} }
//
// ## Architecture
//
// ```
// Layer 4: Full Schema Parser (SchemaParser.swift)
//     ↓ uses
// Layer 3: InstantDB Constructs (THIS FILE)
//     ↓ uses
// Layer 2: TypeScript Literals (TypeScriptParsers.swift)
//     ↓ uses
// Layer 1: Primitives (TypeScriptParsers.swift)
// ```
//
// ## InstantDB Schema Structure
//
// InstantDB schemas follow this TypeScript structure:
//
// ```typescript
// import { i } from "@instantdb/core";
//
// const _schema = i.schema({
//   entities: {
//     todos: i.entity({
//       title: i.string(),
//       done: i.boolean(),
//     }),
//   },
//   links: {
//     userTodos: {
//       forward: { on: "users", has: "many", label: "todos" },
//       reverse: { on: "todos", has: "one", label: "owner" },
//     },
//   },
//   rooms: {
//     chat: {
//       presence: i.entity({ name: i.string() }),
//       topics: { emoji: i.entity({ name: i.string() }) },
//     },
//   },
// });
// ```
//
// ## Reference
//
// - InstantDB Schema Docs: https://www.instantdb.com/docs/modeling-data
// - SchemaIR: The target data structures these parsers produce

import Foundation
@preconcurrency import Parsing

// MARK: - Field Type Parser

/// Parses an InstantDB field type declaration.
///
/// ## What It Parses
///
/// ```typescript
/// i.string()
/// i.number()
/// i.boolean()
/// i.date()
/// i.json()
/// i.string<"pending" | "active">()
/// i.json<{ text: string, start: number }>()
/// ```
///
/// ## Output
///
/// Returns a tuple of `(FieldType, GenericTypeIR?)`.
///
/// ```swift
/// try FieldTypeParser().parse("i.string()")
/// // Returns: (FieldType.string, nil)
///
/// try FieldTypeParser().parse("i.string<\"a\" | \"b\">()")
/// // Returns: (FieldType.string, .stringUnion(["a", "b"]))
/// ```
///
/// ## Why This Exists
///
/// InstantDB uses a builder pattern for field types. Each type maps to a
/// Swift type:
///
/// | InstantDB     | Swift Type |
/// |---------------|------------|
/// | i.string()    | String     |
/// | i.number()    | Double     |
/// | i.boolean()   | Bool       |
/// | i.date()      | Date       |
/// | i.json()      | AnyCodable |
public struct FieldTypeParser: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> (FieldType, GenericTypeIR?) {
    guard input.hasPrefix("i.") else {
      struct ExpectedFieldType: Error {}
      throw ExpectedFieldType()
    }
    input.removeFirst(2)
    
    // Parse the type name
    let typeName = try Identifier().parse(&input)
    
    // Try to parse generic parameter <T>
    try OptionalWhitespace().parse(&input)
    let genericType = try GenericParameterParser().parse(&input)
    
    // Consume the ()
    try OptionalWhitespace().parse(&input)
    guard input.hasPrefix("()") else {
      struct ExpectedParentheses: Error {}
      throw ExpectedParentheses()
    }
    input.removeFirst(2)
    
    // Map to FieldType
    let fieldType: FieldType
    switch typeName.lowercased() {
    case "string": fieldType = .string
    case "number": fieldType = .number
    case "boolean", "bool": fieldType = .boolean
    case "date": fieldType = .date
    case "json", "any": fieldType = .json
    default:
      struct UnknownFieldType: Error { let typeName: String }
      throw UnknownFieldType(typeName: typeName)
    }
    
    return (fieldType, genericType)
  }
}

// MARK: - Field Parser

/// Parses a complete field declaration including optional modifiers.
///
/// ## What It Parses
///
/// ```typescript
/// title: i.string()
/// done: i.boolean()
/// priority: i.number().optional()
/// bio: i.string().optional()
/// status: i.string<"pending" | "active">()
/// metadata: i.json<{ key: string }>()
/// ```
///
/// ## Output
///
/// Returns a `FieldIR` with name, type, optionality, and generic type.
///
/// ```swift
/// try FieldParser().parse("title: i.string()")
/// // Returns: FieldIR(name: "title", type: .string, isOptional: false)
///
/// try FieldParser().parse("status: i.string<\"pending\" | \"active\">()")
/// // Returns: FieldIR(name: "status", type: .string, genericType: .stringUnion([...]))
/// ```
///
/// ## Why This Exists
///
/// Fields are the building blocks of entities. Each field has:
/// - A name (JavaScript identifier)
/// - A type (i.string(), i.number(), etc.)
/// - Optional modifier (.optional())
/// - Optional generic type parameter
public struct FieldParser: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> FieldIR {
    // Parse field name
    let name = try Identifier().parse(&input)
    
    // Parse colon
    try Colon().parse(&input)
    
    // Parse field type (now returns tuple with optional generic)
    let (fieldType, genericType) = try FieldTypeParser().parse(&input)
    
    // Check for modifiers like .optional(), .indexed(), .unique()
    var isOptional = false
    try OptionalWhitespace().parse(&input)
    
    while input.hasPrefix(".") {
      input.removeFirst(1)
      let modifier = try Identifier().parse(&input)
      try OptionalWhitespace().parse(&input)
      if input.hasPrefix("()") {
        input.removeFirst(2)
      }
      try OptionalWhitespace().parse(&input)
      
      if modifier == "optional" {
        isOptional = true
      }
      // Other modifiers like .indexed(), .unique() are ignored
    }
    
    return FieldIR(
      name: name,
      type: fieldType,
      isOptional: isOptional,
      genericType: genericType
    )
  }
}

// MARK: - Entity Parser

/// Parses an entity definition.
///
/// ## What It Parses
///
/// ```typescript
/// todos: i.entity({
///   title: i.string(),
///   done: i.boolean(),
///   priority: i.number().optional(),
/// })
/// ```
///
/// ## Output
///
/// Returns an `EntityIR` with name and fields.
///
/// ```swift
/// try EntityParser().parse("todos: i.entity({ title: i.string() })")
/// // Returns: EntityIR(name: "todos", fields: [FieldIR(name: "title", ...)])
/// ```
///
/// ## Why This Exists
///
/// Entities are the main data model in InstantDB. Each entity becomes:
/// - A Swift struct conforming to `Codable` and `Identifiable`
/// - An `EntityKey` for type-safe queries
public struct EntityParser: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> EntityIR {
    // Parse entity name (including $ prefix for system entities)
    let name = try Identifier().parse(&input)
    
    // Parse colon
    try Colon().parse(&input)
    
    // Parse i.entity({
    guard input.hasPrefix("i.entity") else {
      struct ExpectedEntity: Error {}
      throw ExpectedEntity()
    }
    input.removeFirst(8) // "i.entity"
    
    try OptionalWhitespace().parse(&input)
    guard input.hasPrefix("(") else {
      struct ExpectedOpenParen: Error {}
      throw ExpectedOpenParen()
    }
    input.removeFirst(1)
    
    try OptionalWhitespace().parse(&input)
    guard input.hasPrefix("{") else {
      struct ExpectedOpenBrace: Error {}
      throw ExpectedOpenBrace()
    }
    input.removeFirst(1)
    
    // Parse fields
    var fields: [FieldIR] = []
    try SkipWhitespaceAndComments().parse(&input)
    
    while !input.hasPrefix("}") && !input.isEmpty {
      let field = try FieldParser().parse(&input)
      fields.append(field)
      
      try SkipWhitespaceAndComments().parse(&input)
      
      // Optional trailing comma
      if input.hasPrefix(",") {
        input.removeFirst(1)
        try SkipWhitespaceAndComments().parse(&input)
      }
    }
    
    // Parse closing })
    guard input.hasPrefix("}") else {
      struct ExpectedCloseBrace: Error {}
      throw ExpectedCloseBrace()
    }
    input.removeFirst(1)
    
    try OptionalWhitespace().parse(&input)
    guard input.hasPrefix(")") else {
      struct ExpectedCloseParen: Error {}
      throw ExpectedCloseParen()
    }
    input.removeFirst(1)
    
    return EntityIR(name: name, fields: fields)
  }
}

// MARK: - Link Side Parser

/// Parses one side of a link (forward or reverse).
///
/// ## What It Parses
///
/// ```typescript
/// forward: { on: "users", has: "many", label: "todos" }
/// reverse: { on: "todos", has: "one", label: "owner" }
/// ```
///
/// ## Output
///
/// Returns a `LinkSide` with entity name, cardinality, and label.
public struct LinkSideParser: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> LinkSide {
    // Parse opening brace
    guard input.hasPrefix("{") else {
      struct ExpectedOpenBrace: Error {}
      throw ExpectedOpenBrace()
    }
    input.removeFirst(1)
    try SkipWhitespaceAndComments().parse(&input)
    
    var entityName: String?
    var cardinality: Cardinality?
    var label: String?
    
    // Parse key-value pairs
    while !input.hasPrefix("}") && !input.isEmpty {
      let key = try Identifier().parse(&input)
      try Colon().parse(&input)

      // Handle string values for known keys, skip non-string values (like `required: true`)
      if input.first == "\"" || input.first == "'" {
        let value = try StringLiteral().parse(&input)

        switch key {
        case "on": entityName = value
        case "has":
          switch value {
          case "one": cardinality = .one
          case "many": cardinality = .many
          default:
            struct InvalidCardinality: Error { let value: String }
            throw InvalidCardinality(value: value)
          }
        case "label": label = value
        default: break // Ignore unknown string keys like "onDelete"
        }
      } else {
        // Skip non-string values (booleans like `required: true`)
        // Consume until comma or closing brace
        while !input.isEmpty && !input.hasPrefix(",") && !input.hasPrefix("}") {
          input.removeFirst(1)
        }
      }

      try SkipWhitespaceAndComments().parse(&input)
      if input.hasPrefix(",") {
        input.removeFirst(1)
        try SkipWhitespaceAndComments().parse(&input)
      }
    }
    
    // Parse closing brace
    guard input.hasPrefix("}") else {
      struct ExpectedCloseBrace: Error {}
      throw ExpectedCloseBrace()
    }
    input.removeFirst(1)
    
    // Validate required fields
    guard let entity = entityName else {
      struct MissingEntityName: Error {}
      throw MissingEntityName()
    }
    guard let card = cardinality else {
      struct MissingCardinality: Error {}
      throw MissingCardinality()
    }
    guard let lbl = label else {
      struct MissingLabel: Error {}
      throw MissingLabel()
    }
    
    return LinkSide(entityName: entity, cardinality: card, label: lbl)
  }
}

// MARK: - Link Parser

/// Parses a complete link definition.
///
/// ## What It Parses
///
/// ```typescript
/// userTodos: {
///   forward: { on: "users", has: "many", label: "todos" },
///   reverse: { on: "todos", has: "one", label: "owner" },
/// }
/// ```
///
/// ## Output
///
/// Returns a `LinkIR` with name, forward side, and reverse side.
public struct LinkParser: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> LinkIR {
    // Parse link name
    let name = try Identifier().parse(&input)
    
    // Parse colon
    try Colon().parse(&input)
    
    // Parse opening brace
    guard input.hasPrefix("{") else {
      struct ExpectedOpenBrace: Error {}
      throw ExpectedOpenBrace()
    }
    input.removeFirst(1)
    try SkipWhitespaceAndComments().parse(&input)
    
    var forward: LinkSide?
    var reverse: LinkSide?
    
    // Parse forward and reverse
    while !input.hasPrefix("}") && !input.isEmpty {
      let key = try Identifier().parse(&input)
      try Colon().parse(&input)
      
      let side = try LinkSideParser().parse(&input)
      
      switch key {
      case "forward": forward = side
      case "reverse": reverse = side
      default: break
      }
      
      try SkipWhitespaceAndComments().parse(&input)
      if input.hasPrefix(",") {
        input.removeFirst(1)
        try SkipWhitespaceAndComments().parse(&input)
      }
    }
    
    // Parse closing brace
    guard input.hasPrefix("}") else {
      struct ExpectedCloseBrace: Error {}
      throw ExpectedCloseBrace()
    }
    input.removeFirst(1)
    
    // Validate
    guard let fwd = forward else {
      struct MissingForward: Error {}
      throw MissingForward()
    }
    guard let rev = reverse else {
      struct MissingReverse: Error {}
      throw MissingReverse()
    }
    
    return LinkIR(name: name, forward: fwd, reverse: rev)
  }
}

// MARK: - Topic Parser

/// Parses a topic definition within a room.
///
/// ## What It Parses
///
/// ```typescript
/// emoji: i.entity({
///   name: i.string(),
///   angle: i.number(),
/// })
/// ```
///
/// ## Output
///
/// Returns a `TopicIR` with name and payload entity.
public struct TopicParser: Parser {
  let roomName: String
  
  public init(roomName: String) {
    self.roomName = roomName
  }
  
  public func parse(_ input: inout Substring) throws -> TopicIR {
    // Parse topic name
    let name = try Identifier().parse(&input)
    
    // Parse colon
    try Colon().parse(&input)
    
    // Parse i.entity({ ... })
    guard input.hasPrefix("i.entity") else {
      struct ExpectedEntity: Error {}
      throw ExpectedEntity()
    }
    input.removeFirst(8)
    
    try OptionalWhitespace().parse(&input)
    guard input.hasPrefix("(") else {
      struct ExpectedOpenParen: Error {}
      throw ExpectedOpenParen()
    }
    input.removeFirst(1)
    
    try OptionalWhitespace().parse(&input)
    guard input.hasPrefix("{") else {
      struct ExpectedOpenBrace: Error {}
      throw ExpectedOpenBrace()
    }
    input.removeFirst(1)
    
    // Parse fields
    var fields: [FieldIR] = []
    try SkipWhitespaceAndComments().parse(&input)
    
    while !input.hasPrefix("}") && !input.isEmpty {
      let field = try FieldParser().parse(&input)
      fields.append(field)
      
      try SkipWhitespaceAndComments().parse(&input)
      if input.hasPrefix(",") {
        input.removeFirst(1)
        try SkipWhitespaceAndComments().parse(&input)
      }
    }
    
    // Parse closing })
    guard input.hasPrefix("}") else {
      struct ExpectedCloseBrace: Error {}
      throw ExpectedCloseBrace()
    }
    input.removeFirst(1)
    
    try OptionalWhitespace().parse(&input)
    guard input.hasPrefix(")") else {
      struct ExpectedCloseParen: Error {}
      throw ExpectedCloseParen()
    }
    input.removeFirst(1)
    
    let payload = EntityIR(name: name, fields: fields)
    return TopicIR(name: name, payload: payload, roomName: roomName)
  }
}

// MARK: - Room Parser

/// Parses a room definition with presence and optional topics.
///
/// ## What It Parses
///
/// ```typescript
/// chat: {
///   presence: i.entity({
///     name: i.string(),
///     isTyping: i.boolean(),
///   }),
///   topics: {
///     emoji: i.entity({ name: i.string() }),
///   },
/// }
/// ```
///
/// ## Output
///
/// Returns a `RoomIR` with name, optional presence, and topics.
public struct RoomParser: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> RoomIR {
    // Parse room name
    let name = try Identifier().parse(&input)
    
    // Parse colon
    try Colon().parse(&input)
    
    // Parse opening brace
    guard input.hasPrefix("{") else {
      struct ExpectedOpenBrace: Error {}
      throw ExpectedOpenBrace()
    }
    input.removeFirst(1)
    try SkipWhitespaceAndComments().parse(&input)
    
    var presence: EntityIR?
    var topics: [TopicIR] = []
    
    // Parse presence and topics
    while !input.hasPrefix("}") && !input.isEmpty {
      let key = try Identifier().parse(&input)
      try Colon().parse(&input)
      
      switch key {
      case "presence":
        // Parse i.entity({ ... })
        guard input.hasPrefix("i.entity") else {
          struct ExpectedEntity: Error {}
          throw ExpectedEntity()
        }
        input.removeFirst(8)
        
        try OptionalWhitespace().parse(&input)
        guard input.hasPrefix("(") else {
          struct ExpectedOpenParen: Error {}
          throw ExpectedOpenParen()
        }
        input.removeFirst(1)
        
        try OptionalWhitespace().parse(&input)
        guard input.hasPrefix("{") else {
          struct ExpectedOpenBrace: Error {}
          throw ExpectedOpenBrace()
        }
        input.removeFirst(1)
        
        var fields: [FieldIR] = []
        try SkipWhitespaceAndComments().parse(&input)
        
        while !input.hasPrefix("}") && !input.isEmpty {
          let field = try FieldParser().parse(&input)
          fields.append(field)
          
          try SkipWhitespaceAndComments().parse(&input)
          if input.hasPrefix(",") {
            input.removeFirst(1)
            try SkipWhitespaceAndComments().parse(&input)
          }
        }
        
        guard input.hasPrefix("}") else {
          struct ExpectedCloseBrace: Error {}
          throw ExpectedCloseBrace()
        }
        input.removeFirst(1)
        
        try OptionalWhitespace().parse(&input)
        guard input.hasPrefix(")") else {
          struct ExpectedCloseParen: Error {}
          throw ExpectedCloseParen()
        }
        input.removeFirst(1)
        
        presence = EntityIR(name: "\(name)Presence", fields: fields)
        
      case "topics":
        // Parse topics block { topicName: i.entity({...}), ... }
        guard input.hasPrefix("{") else {
          struct ExpectedOpenBrace: Error {}
          throw ExpectedOpenBrace()
        }
        input.removeFirst(1)
        try SkipWhitespaceAndComments().parse(&input)
        
        while !input.hasPrefix("}") && !input.isEmpty {
          let topic = try TopicParser(roomName: name).parse(&input)
          topics.append(topic)
          
          try SkipWhitespaceAndComments().parse(&input)
          if input.hasPrefix(",") {
            input.removeFirst(1)
            try SkipWhitespaceAndComments().parse(&input)
          }
        }
        
        guard input.hasPrefix("}") else {
          struct ExpectedCloseBrace: Error {}
          throw ExpectedCloseBrace()
        }
        input.removeFirst(1)
        
      default:
        // Skip unknown keys
        break
      }
      
      try SkipWhitespaceAndComments().parse(&input)
      if input.hasPrefix(",") {
        input.removeFirst(1)
        try SkipWhitespaceAndComments().parse(&input)
      }
    }
    
    // Parse closing brace
    guard input.hasPrefix("}") else {
      struct ExpectedCloseBrace: Error {}
      throw ExpectedCloseBrace()
    }
    input.removeFirst(1)
    
    return RoomIR(name: name, presence: presence, topics: topics)
  }
}

