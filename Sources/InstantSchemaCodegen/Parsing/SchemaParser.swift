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
/// 1. Import statements (parsed for type resolution)
/// 2. Type alias declarations (parsed for type resolution)
/// 3. Schema definition with `i.schema({ ... })`
/// 4. Entities block
/// 5. Links block (optional)
/// 6. Rooms block (optional)
/// 7. Export statement (skipped)
///
/// ## Output
///
/// Returns a `SchemaIR` with all parsed entities, links, rooms, type aliases, and imports.
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
    let originalInput = input
    
    // Build symbol table from imports and type aliases
    let symbolTable = SymbolTable()
    symbolTable.basePath = sourceFile.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
    
    // First pass: collect imports and type aliases
    var imports: [ImportDeclaration] = []
    var typeAliases: [TypeAliasIR] = []
    
    try collectImportsAndTypeAliases(
      &input,
      imports: &imports,
      typeAliases: &typeAliases,
      symbolTable: symbolTable,
      sourceFile: sourceFile
    )
    
    // Resolve imported types from external files
    try resolveImportedTypes(imports: imports, symbolTable: symbolTable, sourceFile: sourceFile)
    
    // Reset input to find schema
    input = originalInput
    
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
      typeAliases: typeAliases,
      imports: imports,
      sourceFile: sourceFile
    )
    
    // Resolve unresolved type references
    let resolvedSchema = try resolveTypeReferences(schema, symbolTable: symbolTable, sourceFile: sourceFile)
    
    // Validate the schema
    try resolvedSchema.validate()
    
    return resolvedSchema
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
  
  // MARK: - Import and Type Alias Collection
  
  /// Collect imports and type aliases from the file
  private func collectImportsAndTypeAliases(
    _ input: inout Substring,
    imports: inout [ImportDeclaration],
    typeAliases: inout [TypeAliasIR],
    symbolTable: SymbolTable,
    sourceFile: String?
  ) throws {
    try SkipWhitespaceAndComments().parse(&input)
    
    while !input.isEmpty {
      // Check for import statement
      if input.hasPrefix("import") {
        do {
          let importDecl = try ImportParser().parse(&input)
          if !importDecl.isInstantDBImport {
            imports.append(importDecl)
            symbolTable.registerImport(importDecl)
          }
          try SkipWhitespaceAndComments().parse(&input)
          continue
        } catch {
          // Not a valid import, skip to next line
          skipToNextLine(&input)
          continue
        }
      }
      
      // Check for type alias (with optional export)
      if input.hasPrefix("export type") || input.hasPrefix("type ") {
        do {
          var typeAlias = try TypeAliasParser().parse(&input)
          typeAlias.sourceFile = sourceFile
          typeAliases.append(typeAlias)
          symbolTable.register(typeAlias)
          try SkipWhitespaceAndComments().parse(&input)
          continue
        } catch let error as UnsupportedTypePatternError {
          // Rethrow unsupported pattern errors - these should surface to the user
          throw error
        } catch {
          // Not a valid type alias, skip to next line
          skipToNextLine(&input)
          continue
        }
      }
      
      // Check for export (might be followed by type)
      if input.hasPrefix("export ") {
        // Skip "export " and check what follows
        var tempInput = input
        tempInput.removeFirst(7)
        try SkipWhitespaceAndComments().parse(&tempInput)
        
        if tempInput.hasPrefix("type ") {
          do {
            var typeAlias = try TypeAliasParser().parse(&input)
            typeAlias.sourceFile = sourceFile
            typeAliases.append(typeAlias)
            symbolTable.register(typeAlias)
            try SkipWhitespaceAndComments().parse(&input)
            continue
          } catch let error as UnsupportedTypePatternError {
            // Rethrow unsupported pattern errors - these should surface to the user
            throw error
          } catch {
            skipToNextLine(&input)
            continue
          }
        }
      }
      
      // Stop when we hit the schema definition
      if input.hasPrefix("const") || input.hasPrefix("i.schema") {
        break
      }
      
      // Skip other content
      skipToNextLine(&input)
    }
  }
  
  /// Skip to the next line
  private func skipToNextLine(_ input: inout Substring) {
    while let char = input.first, char != "\n" {
      input.removeFirst()
    }
    if input.first == "\n" {
      input.removeFirst()
    }
  }
  
  /// Resolve imported types from external files
  private func resolveImportedTypes(
    imports: [ImportDeclaration],
    symbolTable: SymbolTable,
    sourceFile: String?
  ) throws {
    guard let basePath = symbolTable.basePath else { return }
    
    for importDecl in imports {
      // Skip InstantDB imports
      if importDecl.isInstantDBImport { continue }
      
      // Resolve the import path
      let importPath = resolveImportPath(importDecl.fromPath, basePath: basePath)
      
      // Try to read and parse the imported file
      guard let importContent = try? String(contentsOfFile: importPath, encoding: .utf8) else {
        // File not found - types will remain unresolved
        continue
      }
      
      // Parse type aliases from the imported file
      var importInput = importContent[...]
      var importedTypes: [TypeAliasIR] = []
      var dummyImports: [ImportDeclaration] = []
      let importSymbolTable = SymbolTable()
      
      try? collectImportsAndTypeAliases(
        &importInput,
        imports: &dummyImports,
        typeAliases: &importedTypes,
        symbolTable: importSymbolTable,
        sourceFile: importPath
      )
      
      // Register only the types that were imported
      for typeName in importDecl.namedImports {
        if let typeAlias = importedTypes.first(where: { $0.name == typeName }) {
          symbolTable.registerResolvedImport(typeAlias)
        }
      }
    }
  }
  
  /// Resolve an import path relative to the base path
  private func resolveImportPath(_ importPath: String, basePath: String) -> String {
    var path = importPath
    
    // Remove leading ./
    if path.hasPrefix("./") {
      path = String(path.dropFirst(2))
    }
    
    // Add .ts extension if not present
    if !path.hasSuffix(".ts") && !path.hasSuffix(".tsx") {
      path += ".ts"
    }
    
    // Combine with base path
    return (basePath as NSString).appendingPathComponent(path)
  }
  
  // MARK: - Type Resolution
  
  /// Resolve unresolved type references in the schema
  private func resolveTypeReferences(
    _ schema: SchemaIR,
    symbolTable: SymbolTable,
    sourceFile: String?
  ) throws -> SchemaIR {
    var resolvedSchema = schema
    
    // Resolve types in entities
    resolvedSchema.entities = try schema.entities.map { entity in
      var resolvedEntity = entity
      resolvedEntity.fields = try entity.fields.map { field in
        try resolveFieldType(field, symbolTable: symbolTable, entityName: entity.name, sourceFile: sourceFile)
      }
      return resolvedEntity
    }
    
    // Resolve types in rooms (presence and topics)
    resolvedSchema.rooms = try schema.rooms.map { room in
      var resolvedRoom = room
      if let presence = room.presence {
        var resolvedPresence = presence
        resolvedPresence.fields = try presence.fields.map { field in
          try resolveFieldType(field, symbolTable: symbolTable, entityName: room.name, sourceFile: sourceFile)
        }
        resolvedRoom.presence = resolvedPresence
      }
      resolvedRoom.topics = try room.topics.map { topic in
        var resolvedTopic = topic
        var resolvedPayload = topic.payload
        resolvedPayload.fields = try topic.payload.fields.map { field in
          try resolveFieldType(field, symbolTable: symbolTable, entityName: topic.name, sourceFile: sourceFile)
        }
        resolvedTopic.payload = resolvedPayload
        return resolvedTopic
      }
      return resolvedRoom
    }
    
    return resolvedSchema
  }
  
  /// Resolve unresolved type references in a field
  private func resolveFieldType(
    _ field: FieldIR,
    symbolTable: SymbolTable,
    entityName: String,
    sourceFile: String?
  ) throws -> FieldIR {
    guard let genericType = field.genericType else {
      return field
    }
    
    var resolvedField = field
    resolvedField.genericType = try resolveGenericType(
      genericType,
      symbolTable: symbolTable,
      fieldName: field.name,
      entityName: entityName,
      sourceFile: sourceFile
    )
    return resolvedField
  }
  
  /// Recursively resolve unresolved type references
  private func resolveGenericType(
    _ type: GenericTypeIR,
    symbolTable: SymbolTable,
    fieldName: String,
    entityName: String,
    sourceFile: String?
  ) throws -> GenericTypeIR {
    switch type {
    case .unresolved(let typeName):
      // Try to resolve from symbol table
      if let resolved = symbolTable.resolve(typeName) {
        return resolved
      }
      
      // Type not found - throw helpful error
      throw SchemaParseError.unresolvedType(
        typeName: typeName,
        fieldName: fieldName,
        entityName: entityName,
        sourceFile: sourceFile
      )
      
    case .array(let elementType):
      // Recursively resolve element type
      let resolvedElement = try resolveGenericType(
        elementType,
        symbolTable: symbolTable,
        fieldName: fieldName,
        entityName: entityName,
        sourceFile: sourceFile
      )
      return .array(resolvedElement)
      
    case .object(let fields):
      // Recursively resolve nested types in object fields
      let resolvedFields = try fields.map { field -> ObjectFieldIR in
        var resolvedField = field
        if let nestedType = field.genericType {
          resolvedField.genericType = try resolveGenericType(
            nestedType,
            symbolTable: symbolTable,
            fieldName: "\(fieldName).\(field.name)",
            entityName: entityName,
            sourceFile: sourceFile
          )
        }
        return resolvedField
      }
      return .object(resolvedFields)
      
    case .stringUnion:
      // String unions don't need resolution
      return type
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
  case unresolvedType(typeName: String, fieldName: String, entityName: String, sourceFile: String?)
  case unsupportedPattern(pattern: String, fieldName: String, entityName: String, sourceFile: String?)
  
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
      
    case .unresolvedType(let typeName, let fieldName, let entityName, let file):
      let fileInfo = file.map { " in '\($0)'" } ?? ""
      return """
      ════════════════════════════════════════════════════════════════
      UNRESOLVED TYPE REFERENCE\(fileInfo)
      ════════════════════════════════════════════════════════════════
      
      Cannot resolve type '\(typeName)' in field '\(fieldName)' on entity '\(entityName)'.
      
      The type '\(typeName)' is not defined in this file or imported from another file.
      
      To fix this:
      1. Define the type in the same file:
         type \(typeName) = "value1" | "value2";
         
      2. Or import it from another file:
         import { \(typeName) } from "./types";
         
      3. Or use an inline type definition:
         i.string<"value1" | "value2">()
         
      Supported patterns:
        • String unions: i.string<"a" | "b" | "c">()
        • Object types: i.json<{ field: type, ... }>()
        • Arrays: i.json<Item[]>() or i.json<Array<Item>>()
        • Type aliases: type MyType = "a" | "b"; then i.string<MyType>()
      """
      
    case .unsupportedPattern(let pattern, let fieldName, let entityName, let file):
      let fileInfo = file.map { " in '\($0)'" } ?? ""
      return """
      ════════════════════════════════════════════════════════════════
      UNSUPPORTED TYPE PATTERN\(fileInfo)
      ════════════════════════════════════════════════════════════════
      
      Found unsupported pattern in field '\(fieldName)' on entity '\(entityName)':
      
        \(pattern)
      
      TypeScript's type system is incredibly powerful, and we're doing our best
      to support common patterns, but some advanced features aren't implemented yet.
      
      Supported patterns:
        • String unions: i.string<"a" | "b" | "c">()
        • Object types: i.json<{ field: type, ... }>()
        • Arrays: i.json<Item[]>() or i.json<Array<Item>>()
        • Type aliases: type MyType = "a" | "b"; then i.string<MyType>()
        • Imports: import { MyType } from "./types"; then i.string<MyType>()
      
      Unsupported patterns:
        • Intersection types: TypeA & TypeB
        • Conditional types: T extends U ? X : Y
        • Mapped types: { [K in keyof T]: ... }
        • Template literal types: `${A}-${B}`
        • Generic constraints: <T extends Base>
      
      Workaround: Use i.json() without generics (generates AnyCodable)
      
      Want to add support for this pattern?
      See: Sources/InstantSchemaCodegen/Parsing/GenericTypeParser.swift
      """
    }
  }
}
