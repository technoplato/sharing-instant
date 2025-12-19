// SchemaParser.swift
// InstantSchemaCodegen
//
// ═══════════════════════════════════════════════════════════════════════════════
// FULL SCHEMA PARSER
// ═══════════════════════════════════════════════════════════════════════════════
//
// This file contains the top-level schema parser that composes all the smaller
// parsers to parse a complete InstantDB TypeScript schema file into SchemaIR.
//
// ## Architecture
//
// ```
// Layer 4: Full Schema Parser (THIS FILE)
//     ↓ uses
// Layer 3: InstantDB Constructs (InstantDBParsers.swift)
//     ↓ uses
// Layer 2: TypeScript Literals (TypeScriptParsers.swift)
//     ↓ uses
// Layer 1: Primitives (TypeScriptParsers.swift)
// ```
//
// ## What This Parser Handles
//
// A complete InstantDB schema file:
//
// ```typescript
// import { i } from "@instantdb/core";
//
// const _schema = i.schema({
//   entities: {
//     todos: i.entity({ title: i.string(), done: i.boolean() }),
//     users: i.entity({ name: i.string(), email: i.string() }),
//   },
//   links: {
//     userTodos: {
//       forward: { on: "users", has: "many", label: "todos" },
//       reverse: { on: "todos", has: "one", label: "owner" },
//     },
//   },
//   rooms: {
//     chat: {
//       presence: i.entity({ name: i.string(), isTyping: i.boolean() }),
//       topics: { emoji: i.entity({ name: i.string() }) },
//     },
//   },
// });
//
// export type Schema = typeof _schema;
// ```
//
// ## Output
//
// Returns a `SchemaIR` containing:
// - entities: Array of EntityIR
// - links: Array of LinkIR
// - rooms: Array of RoomIR
//
// ## Error Handling
//
// The parser provides detailed error messages with:
// - Line and column numbers
// - Context showing the problematic code
// - Suggestions for fixing common mistakes

import Foundation
@preconcurrency import Parsing

// MARK: - Full Schema Parser

/// Parses a complete InstantDB TypeScript schema file.
///
/// ## Usage
///
/// ```swift
/// let parser = SwiftParsingSchemaParser()
/// let schema = try parser.parse(content: schemaFileContent)
/// ```
///
/// ## What It Parses
///
/// A TypeScript file containing:
/// 1. Import statement (skipped)
/// 2. Schema definition with `i.schema({ ... })`
/// 3. Entities block
/// 4. Links block (optional)
/// 5. Rooms block (optional)
/// 6. Export statement (skipped)
///
/// ## Output
///
/// Returns a `SchemaIR` with all parsed entities, links, and rooms.
public struct SwiftParsingSchemaParser {
  
  public init() {}
  
  /// Parse a TypeScript schema file from a file path.
  public func parse(fileAt path: String) throws -> SchemaIR {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    return try parse(content: content, sourceFile: path)
  }
  
  /// Parse TypeScript schema content.
  public func parse(content: String, sourceFile: String? = nil) throws -> SchemaIR {
    var input = content[...]
    
    // Skip everything before i.schema({
    guard let schemaStart = input.range(of: "i.schema") else {
      throw SchemaParseError.noSchemaFound(sourceFile: sourceFile)
    }
    input = input[schemaStart.lowerBound...]
    
    // Parse i.schema({
    guard input.hasPrefix("i.schema") else {
      throw SchemaParseError.noSchemaFound(sourceFile: sourceFile)
    }
    input.removeFirst(8) // "i.schema"
    
    try OptionalWhitespace().parse(&input)
    guard input.hasPrefix("(") else {
      throw SchemaParseError.expectedToken("(", after: "i.schema", sourceFile: sourceFile)
    }
    input.removeFirst(1)
    
    try OptionalWhitespace().parse(&input)
    guard input.hasPrefix("{") else {
      throw SchemaParseError.expectedToken("{", after: "i.schema(", sourceFile: sourceFile)
    }
    input.removeFirst(1)
    
    try SkipWhitespaceAndComments().parse(&input)
    
    // Parse the schema blocks
    var entities: [EntityIR] = []
    var links: [LinkIR] = []
    var rooms: [RoomIR] = []
    
    while !input.hasPrefix("}") && !input.isEmpty {
      // Parse the block name
      let blockName = try Identifier().parse(&input)
      try Colon().parse(&input)
      
      switch blockName {
      case "entities":
        entities = try parseEntitiesBlock(&input)
        
      case "links":
        links = try parseLinksBlock(&input)
        
      case "rooms":
        rooms = try parseRoomsBlock(&input)
        
      default:
        // Skip unknown blocks
        try skipValue(&input)
      }
      
      try SkipWhitespaceAndComments().parse(&input)
      
      // Optional trailing comma
      if input.hasPrefix(",") {
        input.removeFirst(1)
        try SkipWhitespaceAndComments().parse(&input)
      }
    }
    
    // Parse closing })
    guard input.hasPrefix("}") else {
      throw SchemaParseError.expectedToken("}", after: "schema content", sourceFile: sourceFile)
    }
    input.removeFirst(1)
    
    let schema = SchemaIR(
      entities: entities,
      links: links,
      rooms: rooms,
      sourceFile: sourceFile
    )
    
    // Validate the schema
    try schema.validate()
    
    return schema
  }
  
  // MARK: - Block Parsers
  
  /// Parses the entities block: { entityName: i.entity({...}), ... }
  private func parseEntitiesBlock(_ input: inout Substring) throws -> [EntityIR] {
    guard input.hasPrefix("{") else {
      throw SchemaParseError.expectedToken("{", after: "entities:", sourceFile: nil)
    }
    input.removeFirst(1)
    try SkipWhitespaceAndComments().parse(&input)
    
    var entities: [EntityIR] = []
    
    while !input.hasPrefix("}") && !input.isEmpty {
      // Try to extract documentation before the entity
      var documentation: String?
      if input.hasPrefix("/**") {
        documentation = try JSDocComment().parse(&input)
        try SkipWhitespaceAndComments().parse(&input)
      }
      
      let entity = try EntityParser().parse(&input)
      var entityWithDoc = entity
      entityWithDoc.documentation = documentation
      entities.append(entityWithDoc)
      
      try SkipWhitespaceAndComments().parse(&input)
      
      if input.hasPrefix(",") {
        input.removeFirst(1)
        try SkipWhitespaceAndComments().parse(&input)
      }
    }
    
    guard input.hasPrefix("}") else {
      throw SchemaParseError.expectedToken("}", after: "entities block", sourceFile: nil)
    }
    input.removeFirst(1)
    
    return entities
  }
  
  /// Parses the links block: { linkName: { forward: {...}, reverse: {...} }, ... }
  private func parseLinksBlock(_ input: inout Substring) throws -> [LinkIR] {
    guard input.hasPrefix("{") else {
      throw SchemaParseError.expectedToken("{", after: "links:", sourceFile: nil)
    }
    input.removeFirst(1)
    try SkipWhitespaceAndComments().parse(&input)
    
    var links: [LinkIR] = []
    
    while !input.hasPrefix("}") && !input.isEmpty {
      // Try to extract documentation
      var documentation: String?
      if input.hasPrefix("/**") {
        documentation = try JSDocComment().parse(&input)
        try SkipWhitespaceAndComments().parse(&input)
      }
      
      let link = try LinkParser().parse(&input)
      var linkWithDoc = link
      linkWithDoc.documentation = documentation
      links.append(linkWithDoc)
      
      try SkipWhitespaceAndComments().parse(&input)
      
      if input.hasPrefix(",") {
        input.removeFirst(1)
        try SkipWhitespaceAndComments().parse(&input)
      }
    }
    
    guard input.hasPrefix("}") else {
      throw SchemaParseError.expectedToken("}", after: "links block", sourceFile: nil)
    }
    input.removeFirst(1)
    
    return links
  }
  
  /// Parses the rooms block: { roomName: { presence: {...}, topics: {...} }, ... }
  private func parseRoomsBlock(_ input: inout Substring) throws -> [RoomIR] {
    guard input.hasPrefix("{") else {
      throw SchemaParseError.expectedToken("{", after: "rooms:", sourceFile: nil)
    }
    input.removeFirst(1)
    try SkipWhitespaceAndComments().parse(&input)
    
    var rooms: [RoomIR] = []
    
    while !input.hasPrefix("}") && !input.isEmpty {
      // Try to extract documentation
      var documentation: String?
      if input.hasPrefix("/**") {
        documentation = try JSDocComment().parse(&input)
        try SkipWhitespaceAndComments().parse(&input)
      }
      
      let room = try RoomParser().parse(&input)
      var roomWithDoc = room
      roomWithDoc.documentation = documentation
      rooms.append(roomWithDoc)
      
      try SkipWhitespaceAndComments().parse(&input)
      
      if input.hasPrefix(",") {
        input.removeFirst(1)
        try SkipWhitespaceAndComments().parse(&input)
      }
    }
    
    guard input.hasPrefix("}") else {
      throw SchemaParseError.expectedToken("}", after: "rooms block", sourceFile: nil)
    }
    input.removeFirst(1)
    
    return rooms
  }
  
  // MARK: - Helpers
  
  /// Skip a value (object, array, or primitive) - used for unknown blocks
  private func skipValue(_ input: inout Substring) throws {
    try SkipWhitespaceAndComments().parse(&input)
    
    if input.hasPrefix("{") {
      // Skip object
      input.removeFirst(1)
      var depth = 1
      while depth > 0 && !input.isEmpty {
        if input.first == "{" {
          depth += 1
        } else if input.first == "}" {
          depth -= 1
        }
        input.removeFirst(1)
      }
    } else if input.hasPrefix("[") {
      // Skip array
      input.removeFirst(1)
      var depth = 1
      while depth > 0 && !input.isEmpty {
        if input.first == "[" {
          depth += 1
        } else if input.first == "]" {
          depth -= 1
        }
        input.removeFirst(1)
      }
    } else if input.hasPrefix("\"") || input.hasPrefix("'") {
      // Skip string
      _ = try StringLiteral().parse(&input)
    } else {
      // Skip identifier or primitive
      while let char = input.first, char.isLetter || char.isNumber || char == "_" || char == "." || char == "(" || char == ")" {
        input.removeFirst(1)
      }
    }
  }
}

// MARK: - Schema Parse Errors

/// Errors that can occur during schema parsing.
///
/// These errors provide context about what went wrong and where,
/// making it easier to diagnose and fix schema issues.
public enum SchemaParseError: Error, LocalizedError {
  case noSchemaFound(sourceFile: String?)
  case expectedToken(String, after: String, sourceFile: String?)
  case unexpectedEnd(context: String, sourceFile: String?)
  case invalidSyntax(message: String, line: Int?, column: Int?, sourceFile: String?)
  
  public var errorDescription: String? {
    switch self {
    case .noSchemaFound(let file):
      let fileInfo = file.map { " in '\($0)'" } ?? ""
      return """
      ════════════════════════════════════════════════════════════════
      SCHEMA NOT FOUND\(fileInfo)
      ════════════════════════════════════════════════════════════════
      
      Could not find 'i.schema({ ... })' in the file.
      
      Expected format:
        import { i } from "@instantdb/core";
        
        const _schema = i.schema({
          entities: { ... },
          links: { ... },
          rooms: { ... },
        });
      
      Make sure your schema file:
      1. Imports from "@instantdb/core"
      2. Uses i.schema({ ... }) to define the schema
      """
      
    case .expectedToken(let token, let after, let file):
      let fileInfo = file.map { " in '\($0)'" } ?? ""
      return "Expected '\(token)' after \(after)\(fileInfo)"
      
    case .unexpectedEnd(let context, let file):
      let fileInfo = file.map { " in '\($0)'" } ?? ""
      return "Unexpected end of input while parsing \(context)\(fileInfo)"
      
    case .invalidSyntax(let message, let line, let column, let file):
      var location = ""
      if let l = line, let c = column {
        location = " at line \(l), column \(c)"
      }
      let fileInfo = file.map { " in '\($0)'" } ?? ""
      return "Invalid syntax\(location)\(fileInfo): \(message)"
    }
  }
}

