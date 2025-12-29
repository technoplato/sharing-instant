// SchemaIR.swift
// InstantSchemaCodegen
//
// Intermediate Representation (IR) for InstantDB schemas.
// This is the canonical representation that both TypeScript and Swift parsers produce,
// and that both TypeScript and Swift generators consume.
//
// ## Generic Type Support
//
// This IR supports TypeScript generics on field types:
// - String unions: i.string<"a" | "b" | "c">() → GenericTypeIR.stringUnion
// - Object types: i.json<{ field: type }>() → GenericTypeIR.object
// - Arrays: i.json<Type[]>() → GenericTypeIR.array
// - Type references: i.string<MyType>() → resolved via SymbolTable

import Foundation

// MARK: - Schema IR

/// The complete schema intermediate representation.
///
/// This is the canonical format that enables bidirectional codegen:
/// - TypeScript parser → SchemaIR → Swift generator
/// - Swift parser → SchemaIR → TypeScript generator
///
/// ## Example
///
/// ```swift
/// let schema = SchemaIR(
///   entities: [
///     EntityIR(name: "todos", fields: [...]),
///     EntityIR(name: "users", fields: [...])
///   ],
///   links: [
///     LinkIR(name: "userTodos", ...)
///   ]
/// )
/// ```
public struct SchemaIR: Codable, Sendable, Equatable {
  /// All entities defined in the schema
  public var entities: [EntityIR]
  
  /// All links (relationships) between entities
  public var links: [LinkIR]
  
  /// All rooms for presence and topics
  public var rooms: [RoomIR]
  
  /// Type aliases defined in the schema file
  public var typeAliases: [TypeAliasIR]
  
  /// Import declarations from the schema file
  public var imports: [ImportDeclaration]
  
  /// Schema-level documentation comment
  public var documentation: String?
  
  /// Source file this schema was parsed from (for error messages)
  public var sourceFile: String?
  
  public init(
    entities: [EntityIR] = [],
    links: [LinkIR] = [],
    rooms: [RoomIR] = [],
    typeAliases: [TypeAliasIR] = [],
    imports: [ImportDeclaration] = [],
    documentation: String? = nil,
    sourceFile: String? = nil
  ) {
    self.entities = entities
    self.links = links
    self.rooms = rooms
    self.typeAliases = typeAliases
    self.imports = imports
    self.documentation = documentation
    self.sourceFile = sourceFile
  }
  
  /// Find an entity by name
  public func entity(named name: String) -> EntityIR? {
    entities.first { $0.name == name }
  }
  
  /// Find all links where this entity is the "from" side
  public func linksFrom(entity name: String) -> [LinkIR] {
    links.filter { $0.forward.entityName == name }
  }
  
  /// Find all links where this entity is the "to" side
  public func linksTo(entity name: String) -> [LinkIR] {
    links.filter { $0.reverse.entityName == name }
  }
  
  /// Find a room by name
  public func room(named name: String) -> RoomIR? {
    rooms.first { $0.name == name }
  }
}

// MARK: - Entity IR

/// An entity (table/collection) in the schema.
///
/// ## Example
///
/// For this TypeScript:
/// ```typescript
/// todos: i.entity({
///   title: i.string(),
///   done: i.boolean(),
/// })
/// ```
///
/// The IR is:
/// ```swift
/// EntityIR(
///   name: "todos",
///   fields: [
///     FieldIR(name: "title", type: .string, isOptional: false),
///     FieldIR(name: "done", type: .boolean, isOptional: false)
///   ]
/// )
/// ```
public struct EntityIR: Codable, Sendable, Equatable, Identifiable {
  public var id: String { name }
  
  /// The entity name (namespace), e.g., "todos", "users"
  /// This is the key in the `entities` object in TypeScript
  public var name: String
  
  /// The fields (attributes) of this entity
  /// Does NOT include `id` - that's implicit for all entities
  public var fields: [FieldIR]
  
  /// Documentation comment for this entity
  public var documentation: String?
  
  public init(
    name: String,
    fields: [FieldIR] = [],
    documentation: String? = nil
  ) {
    self.name = name
    self.fields = fields
    self.documentation = documentation
  }
  
  /// The Swift struct name (PascalCase singular)
  /// "todos" → "Todo", "users" → "User", "people" → "Person"
  ///
  /// ## System Entities
  ///
  /// InstantDB has system entities prefixed with `$` (e.g., `$files`, `$users`).
  /// These are converted to Swift-safe names:
  /// - `$files` → `InstantFile`
  /// - `$users` → `InstantUser`
  ///
  /// The `$` prefix is reserved in Swift for compiler-synthesized declarations
  /// (like property wrapper projections), so we use the `Instant` prefix instead.
  public var swiftTypeName: String {
    // Handle InstantDB system entities (prefixed with $)
    // The $ prefix is reserved in Swift for compiler-synthesized declarations
    // like $foo for @State property wrappers, so we convert to Instant prefix
    if name.hasPrefix("$") {
      let baseName = String(name.dropFirst()) // Remove $
      // Convert "$files" → "InstantFile", "$users" → "InstantUser"
      let singular = singularize(baseName)
      return "Instant" + singular.prefix(1).uppercased() + singular.dropFirst()
    }
    
    // Handle irregular plurals
    let irregularPlurals: [String: String] = [
      "people": "Person",
      "children": "Child",
      "men": "Man",
      "women": "Woman",
      "mice": "Mouse",
      "geese": "Goose",
      "teeth": "Tooth",
      "feet": "Foot",
      "data": "Data",
      "media": "Media",
      "criteria": "Criterion",
      "phenomena": "Phenomenon",
    ]
    
    if let irregular = irregularPlurals[name.lowercased()] {
      return irregular
    }
    
    // Handle regular plurals
    let singular = singularize(name)
    
    return singular.prefix(1).uppercased() + singular.dropFirst()
  }
  
  /// Whether this entity is a system entity (prefixed with $)
  ///
  /// System entities like `$files` and `$users` are managed by InstantDB
  /// and have special behavior. They are rarely used directly in app code.
  public var isSystemEntity: Bool {
    name.hasPrefix("$")
  }
  
  /// The Swift property name for Schema.xxx
  ///
  /// For regular entities, this is the same as `name` (e.g., "todos").
  /// For system entities, the `$` is replaced with `instant` prefix:
  /// - `$files` → `instantFiles`
  /// - `$users` → `instantUsers`
  ///
  /// This ensures valid Swift property names while maintaining clarity
  /// that these are InstantDB system entities.
  public var swiftPropertyName: String {
    if name.hasPrefix("$") {
      // Convert "$files" → "instantFiles"
      return "instant" + String(name.dropFirst()).prefix(1).uppercased() + String(name.dropFirst()).dropFirst()
    }
    return name
  }
  
  /// Convert a plural name to singular
  private func singularize(_ name: String) -> String {
    if name.hasSuffix("ies") {
      // "categories" → "category"
      return String(name.dropLast(3)) + "y"
    } else if name.hasSuffix("es") && (name.hasSuffix("sses") || name.hasSuffix("xes") || name.hasSuffix("ches") || name.hasSuffix("shes")) {
      // "classes" → "class", "boxes" → "box"
      return String(name.dropLast(2))
    } else if name.hasSuffix("s") && !name.hasSuffix("ss") {
      return String(name.dropLast())
    } else {
      return name
    }
  }
}

// MARK: - Field IR

/// A field (attribute) on an entity.
///
/// ## Example
///
/// For `title: i.string()`, the IR is:
/// ```swift
/// FieldIR(name: "title", type: .string, isOptional: false)
/// ```
///
/// For `bio: i.string().optional()`, the IR is:
/// ```swift
/// FieldIR(name: "bio", type: .string, isOptional: true)
/// ```
///
/// ## Generic Types
///
/// For `status: i.string<"pending" | "active">()`, the IR is:
/// ```swift
/// FieldIR(
///   name: "status",
///   type: .string,
///   genericType: .stringUnion(["pending", "active"])
/// )
/// ```
public struct FieldIR: Codable, Sendable, Equatable, Identifiable {
  public var id: String { name }
  
  /// The field name, e.g., "title", "createdAt"
  public var name: String
  
  /// The field's data type
  public var type: FieldType
  
  /// Whether this field is optional (.optional() in TypeScript)
  public var isOptional: Bool
  
  /// Documentation comment for this field
  public var documentation: String?
  
  /// Default value (if specified)
  public var defaultValue: String?
  
  /// Generic type information (for i.string<T>() or i.json<T>())
  /// When present, this provides more specific type information than `type`
  public var genericType: GenericTypeIR?
  
  public init(
    name: String,
    type: FieldType,
    isOptional: Bool = false,
    documentation: String? = nil,
    defaultValue: String? = nil,
    genericType: GenericTypeIR? = nil
  ) {
    self.name = name
    self.type = type
    self.isOptional = isOptional
    self.documentation = documentation
    self.defaultValue = defaultValue
    self.genericType = genericType
  }
}

// MARK: - Field Type

/// The data type of a field.
///
/// Maps between InstantDB types, TypeScript types, and Swift types:
///
/// | InstantDB     | TypeScript | Swift    |
/// |---------------|------------|----------|
/// | i.string()    | string     | String   |
/// | i.number()    | number     | Double   |
/// | i.boolean()   | boolean    | Bool     |
/// | i.date()      | Date       | Date     |
/// | i.json()      | any        | AnyCodable |
/// | i.any()       | any        | AnyCodable |
public enum FieldType: String, Codable, Sendable, Equatable {
  /// String type - `i.string()` → `String`
  case string
  
  /// Number type - `i.number()` → `Double`
  /// Note: InstantDB uses JavaScript numbers (always floating point)
  case number
  
  /// Integer type (for when we know it's an int)
  case integer
  
  /// Boolean type - `i.boolean()` → `Bool`
  case boolean
  
  /// Date type - `i.date()` → `Date`
  case date
  
  /// JSON/any type - `i.json()` or `i.any()` → `AnyCodable`
  case json
  
  /// The Swift type name
  public var swiftType: String {
    switch self {
    case .string: return "String"
    case .number: return "Double"
    case .integer: return "Int"
    case .boolean: return "Bool"
    case .date: return "Date"
    case .json: return "AnyCodable"
    }
  }
  
  /// The TypeScript type name
  public var typeScriptType: String {
    switch self {
    case .string: return "string"
    case .number, .integer: return "number"
    case .boolean: return "boolean"
    case .date: return "Date"
    case .json: return "any"
    }
  }
  
  /// The InstantDB schema builder call
  public var instantDBBuilder: String {
    switch self {
    case .string: return "i.string()"
    case .number, .integer: return "i.number()"
    case .boolean: return "i.boolean()"
    case .date: return "i.date()"
    case .json: return "i.json()"
    }
  }
}

// MARK: - Generic Type IR

/// Represents a generic type parameter on a field.
///
/// TypeScript schemas can specify generic types on field methods:
/// - `i.string<"a" | "b" | "c">()` → String union
/// - `i.json<{ field: type }>()` → Object type
/// - `i.json<Type[]>()` → Array type
///
/// ## Example
///
/// For `status: i.string<"pending" | "active" | "completed">()`:
/// ```swift
/// GenericTypeIR.stringUnion(["pending", "active", "completed"])
/// ```
///
/// For `metadata: i.json<{ createdBy: string, version: number }>()`:
/// ```swift
/// GenericTypeIR.object([
///   ObjectFieldIR(name: "createdBy", type: .string),
///   ObjectFieldIR(name: "version", type: .number)
/// ])
/// ```
public indirect enum GenericTypeIR: Codable, Sendable, Equatable {
  /// A union of string literal types: "a" | "b" | "c"
  /// Used with i.string<T>() to generate Swift enums
  case stringUnion([String])
  
  /// An object type: { field: type, ... }
  /// Used with i.json<T>() to generate Swift structs
  case object([ObjectFieldIR])
  
  /// An array type: Type[] or Array<Type>
  /// The associated value is the element type
  case array(GenericTypeIR)
  
  /// A reference to a type alias that couldn't be resolved
  /// This is an error state - should be resolved before code generation
  case unresolved(String)
  
  /// A resolved type alias - preserves the original name for code generation
  /// The name is used for generating the Swift type name, and the definition
  /// contains the actual type structure for generating the type body.
  case typeAlias(name: String, definition: GenericTypeIR)
  
  /// The Swift type name for this generic type
  /// - For stringUnion: generates an enum name based on context
  /// - For object: generates a struct name based on context
  /// - For array: wraps the element type in brackets
  /// - For typeAlias: uses the preserved type alias name
  public func swiftTypeName(context: String) -> String {
    switch self {
    case .stringUnion:
      return context.prefix(1).uppercased() + context.dropFirst()
    case .object:
      return context.prefix(1).uppercased() + context.dropFirst()
    case .array(let elementType):
      return "[\(elementType.swiftTypeName(context: context))]"
    case .unresolved(let name):
      return name
    case .typeAlias(let name, _):
      return name
    }
  }
}

/// A field within an object type in a generic parameter.
///
/// ## Example
///
/// For `{ createdBy: string, version: number }`:
/// ```swift
/// [
///   ObjectFieldIR(name: "createdBy", type: .string),
///   ObjectFieldIR(name: "version", type: .number)
/// ]
/// ```
public struct ObjectFieldIR: Codable, Sendable, Equatable, Identifiable {
  public var id: String { name }
  
  /// The field name
  public var name: String
  
  /// The field's base type (string, number, boolean, etc.)
  public var type: FieldType
  
  /// Whether this field is optional (field?: type in TypeScript)
  public var isOptional: Bool
  
  /// Nested generic type (for nested objects or arrays)
  public var genericType: GenericTypeIR?
  
  public init(
    name: String,
    type: FieldType,
    isOptional: Bool = false,
    genericType: GenericTypeIR? = nil
  ) {
    self.name = name
    self.type = type
    self.isOptional = isOptional
    self.genericType = genericType
  }
}

// MARK: - Type Alias IR

/// A TypeScript type alias declaration.
///
/// ## Example
///
/// For `type Status = "pending" | "active" | "completed"`:
/// ```swift
/// TypeAliasIR(
///   name: "Status",
///   definition: .stringUnion(["pending", "active", "completed"])
/// )
/// ```
///
/// For `type Word = { text: string, start: number }`:
/// ```swift
/// TypeAliasIR(
///   name: "Word",
///   definition: .object([...])
/// )
/// ```
public struct TypeAliasIR: Codable, Sendable, Equatable, Identifiable {
  public var id: String { name }
  
  /// The type alias name (e.g., "Status", "Word")
  public var name: String
  
  /// The type definition
  public var definition: GenericTypeIR
  
  /// Whether this type is exported
  public var isExported: Bool
  
  /// Source file this type was defined in (for error messages)
  public var sourceFile: String?
  
  public init(
    name: String,
    definition: GenericTypeIR,
    isExported: Bool = false,
    sourceFile: String? = nil
  ) {
    self.name = name
    self.definition = definition
    self.isExported = isExported
    self.sourceFile = sourceFile
  }
}

// MARK: - Import Declaration

/// A TypeScript import declaration.
///
/// ## Example
///
/// For `import { TaskPriority, Word } from "./types"`:
/// ```swift
/// ImportDeclaration(
///   namedImports: ["TaskPriority", "Word"],
///   fromPath: "./types"
/// )
/// ```
public struct ImportDeclaration: Codable, Sendable, Equatable {
  /// The named imports (e.g., ["TaskPriority", "Word"])
  public var namedImports: [String]
  
  /// The import path (e.g., "./types", "@instantdb/core")
  public var fromPath: String
  
  /// Whether this is a type-only import (import type { ... })
  public var isTypeOnly: Bool
  
  public init(
    namedImports: [String],
    fromPath: String,
    isTypeOnly: Bool = false
  ) {
    self.namedImports = namedImports
    self.fromPath = fromPath
    self.isTypeOnly = isTypeOnly
  }
  
  /// Whether this is an InstantDB import (should be ignored for type resolution)
  public var isInstantDBImport: Bool {
    fromPath.contains("@instantdb")
  }
}

// MARK: - Symbol Table

/// A symbol table for resolving type references.
///
/// The symbol table is built during the first pass of parsing:
/// 1. Parse import statements → record which types are imported from where
/// 2. Parse type alias declarations → store type definitions
/// 3. During schema parsing, resolve type references using this table
///
/// ## Example Usage
///
/// ```swift
/// let symbolTable = SymbolTable()
///
/// // Register a type alias
/// symbolTable.register(TypeAliasIR(
///   name: "Status",
///   definition: .stringUnion(["pending", "active"])
/// ))
///
/// // Later, resolve the type
/// if let resolved = symbolTable.resolve("Status") {
///   // Use the resolved type
/// }
/// ```
public final class SymbolTable: @unchecked Sendable {
  /// Type aliases defined in the current file
  private var localTypes: [String: TypeAliasIR] = [:]
  
  /// Imported type names and their source files
  private var importedTypes: [String: String] = [:]
  
  /// Resolved types from imported files
  private var resolvedImports: [String: TypeAliasIR] = [:]
  
  /// Import declarations for tracking where types come from
  private var imports: [ImportDeclaration] = []
  
  /// The base path for resolving relative imports
  public var basePath: String?
  
  public init() {}
  
  /// Register a type alias defined in the current file
  public func register(_ typeAlias: TypeAliasIR) {
    localTypes[typeAlias.name] = typeAlias
  }
  
  /// Register an import declaration
  public func registerImport(_ importDecl: ImportDeclaration) {
    imports.append(importDecl)
    for name in importDecl.namedImports {
      importedTypes[name] = importDecl.fromPath
    }
  }
  
  /// Register a resolved type from an imported file
  public func registerResolvedImport(_ typeAlias: TypeAliasIR) {
    resolvedImports[typeAlias.name] = typeAlias
  }
  
  /// Resolve a type name to its definition
  ///
  /// Resolution order:
  /// 1. Local types (defined in current file)
  /// 2. Resolved imports (types from imported files)
  ///
  /// Returns nil if the type cannot be resolved.
  public func resolve(_ name: String) -> GenericTypeIR? {
    // First check local types
    if let local = localTypes[name] {
      return local.definition
    }
    
    // Then check resolved imports
    if let imported = resolvedImports[name] {
      return imported.definition
    }
    
    return nil
  }
  
  /// Check if a type name is known (either local or imported)
  public func isKnown(_ name: String) -> Bool {
    localTypes[name] != nil || resolvedImports[name] != nil || importedTypes[name] != nil
  }
  
  /// Get the import path for a type name, if it's imported
  public func importPath(for name: String) -> String? {
    importedTypes[name]
  }
  
  /// Get all local type aliases
  public var allLocalTypes: [TypeAliasIR] {
    Array(localTypes.values)
  }
  
  /// Get all import declarations
  public var allImports: [ImportDeclaration] {
    imports
  }
  
  /// Get all unresolved imported type names
  public var unresolvedImports: [String] {
    importedTypes.keys.filter { resolvedImports[$0] == nil }.sorted()
  }
}

// MARK: - Link IR

/// A link (relationship) between two entities.
///
/// InstantDB links are always bidirectional - they have a "forward" side
/// and a "reverse" side. Each side specifies:
/// - Which entity it attaches to
/// - The cardinality (one or many)
/// - The label (property name to access the link)
///
/// ## Example
///
/// For this TypeScript:
/// ```typescript
/// authorBooks: {
///   forward: { on: "authors", has: "many", label: "books" },
///   reverse: { on: "books", has: "one", label: "author" }
/// }
/// ```
///
/// The IR is:
/// ```swift
/// LinkIR(
///   name: "authorBooks",
///   forward: LinkSide(entityName: "authors", cardinality: .many, label: "books"),
///   reverse: LinkSide(entityName: "books", cardinality: .one, label: "author")
/// )
/// ```
///
/// This means:
/// - `author.books` → `[Book]` (one author has many books)
/// - `book.author` → `Author?` (one book has one author)
public struct LinkIR: Codable, Sendable, Equatable, Identifiable {
  public var id: String { name }
  
  /// The link name (key in the `links` object)
  public var name: String
  
  /// The "forward" side of the link
  public var forward: LinkSide
  
  /// The "reverse" side of the link
  public var reverse: LinkSide
  
  /// Documentation comment for this link
  public var documentation: String?
  
  public init(
    name: String,
    forward: LinkSide,
    reverse: LinkSide,
    documentation: String? = nil
  ) {
    self.name = name
    self.forward = forward
    self.reverse = reverse
    self.documentation = documentation
  }
  
  /// Whether this link involves a system entity (prefixed with $)
  public var involvesSystemEntity: Bool {
    forward.entityName.hasPrefix("$") || reverse.entityName.hasPrefix("$")
  }
  
  /// The Swift property name for SchemaLinks.xxx
  ///
  /// For regular links, this is the same as `name`.
  /// For links involving system entities, the `$` is replaced:
  /// - `$usersLinkedPrimaryUser` → `instantUsersLinkedPrimaryUser`
  public var swiftPropertyName: String {
    if name.hasPrefix("$") {
      return "instant" + String(name.dropFirst()).prefix(1).uppercased() + String(name.dropFirst()).dropFirst()
    }
    return name
  }
}

// MARK: - Link Side

/// One side of a bidirectional link.
///
/// ## Properties
///
/// - `entityName`: Which entity this side attaches to (e.g., "authors")
/// - `cardinality`: Whether this side has "one" or "many" of the other entity
/// - `label`: The property name to access the linked entities (e.g., "books")
public struct LinkSide: Codable, Sendable, Equatable {
  /// The entity this side attaches to
  public var entityName: String
  
  /// The cardinality (one or many)
  public var cardinality: Cardinality
  
  /// The property name to access linked entities
  public var label: String
  
  public init(
    entityName: String,
    cardinality: Cardinality,
    label: String
  ) {
    self.entityName = entityName
    self.cardinality = cardinality
    self.label = label
  }
  
  /// The Swift type for this link side
  /// - `.one` → `OtherEntity?`
  /// - `.many` → `[OtherEntity]?`
  public func swiftType(for otherEntity: EntityIR) -> String {
    switch cardinality {
    case .one:
      return "\(otherEntity.swiftTypeName)?"
    case .many:
      return "[\(otherEntity.swiftTypeName)]?"
    }
  }
}

// MARK: - Cardinality

/// The cardinality of one side of a link.
public enum Cardinality: String, Codable, Sendable, Equatable {
  /// This side has at most one of the other entity
  case one
  
  /// This side has zero or more of the other entity
  case many
}

// MARK: - Room IR

/// A room for real-time presence and ephemeral topics.
///
/// Rooms allow users to share ephemeral state (presence) and broadcast
/// fire-and-forget messages (topics) without persisting to the database.
///
/// ## Example
///
/// For this TypeScript:
/// ```typescript
/// rooms: {
///   chat: {
///     presence: i.entity({
///       name: i.string(),
///       isTyping: i.boolean(),
///     }),
///     topics: {
///       emoji: i.entity({
///         name: i.string(),
///         angle: i.number(),
///       }),
///     },
///   },
/// }
/// ```
///
/// The IR is:
/// ```swift
/// RoomIR(
///   name: "chat",
///   presence: EntityIR(name: "chatPresence", fields: [...]),
///   topics: [TopicIR(name: "emoji", payload: EntityIR(...))]
/// )
/// ```
public struct RoomIR: Codable, Sendable, Equatable, Identifiable {
  public var id: String { name }
  
  /// The room name (key in the `rooms` object)
  public var name: String
  
  /// The presence data shape for this room (optional - room may have only topics)
  public var presence: EntityIR?
  
  /// Topics defined for this room (fire-and-forget events)
  public var topics: [TopicIR]
  
  /// Documentation comment for this room
  public var documentation: String?
  
  public init(
    name: String,
    presence: EntityIR? = nil,
    topics: [TopicIR] = [],
    documentation: String? = nil
  ) {
    self.name = name
    self.presence = presence
    self.topics = topics
    self.documentation = documentation
  }
  
  /// The Swift type name for the presence struct
  /// "chat" → "ChatPresence"
  public var presenceTypeName: String {
    name.prefix(1).uppercased() + name.dropFirst() + "Presence"
  }
}

// MARK: - Topic IR

/// A topic for fire-and-forget ephemeral messages within a room.
///
/// Topics are used for broadcasting events that don't need persistence,
/// like emoji reactions, cursor movements, or typing indicators.
///
/// ## Example
///
/// For this TypeScript:
/// ```typescript
/// topics: {
///   emoji: i.entity({
///     name: i.string(),
///     directionAngle: i.number(),
///     rotationAngle: i.number(),
///   }),
/// }
/// ```
///
/// The IR is:
/// ```swift
/// TopicIR(
///   name: "emoji",
///   payload: EntityIR(name: "emoji", fields: [...])
/// )
/// ```
public struct TopicIR: Codable, Sendable, Equatable, Identifiable {
  public var id: String { name }
  
  /// The topic name (key in the `topics` object)
  public var name: String
  
  /// The payload data shape for this topic
  public var payload: EntityIR
  
  /// The room this topic belongs to
  public var roomName: String
  
  /// Documentation comment for this topic
  public var documentation: String?
  
  public init(
    name: String,
    payload: EntityIR,
    roomName: String,
    documentation: String? = nil
  ) {
    self.name = name
    self.payload = payload
    self.roomName = roomName
    self.documentation = documentation
  }
  
  /// The Swift type name for the topic payload struct
  /// "emoji" → "EmojiTopic"
  public var payloadTypeName: String {
    name.prefix(1).uppercased() + name.dropFirst() + "Topic"
  }
}

// MARK: - Validation

extension SchemaIR {
  /// Validate the schema for consistency
  public func validate() throws {
    // Check for duplicate entity names
    let entityNames = entities.map(\.name)
    let duplicateEntities = Dictionary(grouping: entityNames, by: { $0 })
      .filter { $0.value.count > 1 }
      .keys
    if !duplicateEntities.isEmpty {
      throw SchemaValidationError.duplicateEntityNames(Array(duplicateEntities))
    }
    
    // Check for duplicate link names
    let linkNames = links.map(\.name)
    let duplicateLinks = Dictionary(grouping: linkNames, by: { $0 })
      .filter { $0.value.count > 1 }
      .keys
    if !duplicateLinks.isEmpty {
      throw SchemaValidationError.duplicateLinkNames(Array(duplicateLinks))
    }
    
    // Check for duplicate room names
    let roomNames = rooms.map(\.name)
    let duplicateRooms = Dictionary(grouping: roomNames, by: { $0 })
      .filter { $0.value.count > 1 }
      .keys
    if !duplicateRooms.isEmpty {
      throw SchemaValidationError.duplicateRoomNames(Array(duplicateRooms))
    }
    
    // Validate links reference existing entities
    for link in links {
      if entity(named: link.forward.entityName) == nil {
        throw SchemaValidationError.unknownEntity(link.forward.entityName, inLink: link.name)
      }
      if entity(named: link.reverse.entityName) == nil {
        throw SchemaValidationError.unknownEntity(link.reverse.entityName, inLink: link.name)
      }
    }
    
    // Validate field names within entities
    for entity in entities {
      let fieldNames = entity.fields.map(\.name)
      let duplicateFields = Dictionary(grouping: fieldNames, by: { $0 })
        .filter { $0.value.count > 1 }
        .keys
      if !duplicateFields.isEmpty {
        throw SchemaValidationError.duplicateFieldNames(
          Array(duplicateFields),
          inEntity: entity.name
        )
      }
      
      // Check for reserved field names
      if fieldNames.contains("id") {
        throw SchemaValidationError.reservedFieldName("id", inEntity: entity.name)
      }
    }
    
    // Validate rooms
    for room in rooms {
      // Check for duplicate topic names within room
      let topicNames = room.topics.map(\.name)
      let duplicateTopics = Dictionary(grouping: topicNames, by: { $0 })
        .filter { $0.value.count > 1 }
        .keys
      if !duplicateTopics.isEmpty {
        throw SchemaValidationError.duplicateTopicNames(Array(duplicateTopics), inRoom: room.name)
      }
      
      // Validate presence fields if present
      if let presence = room.presence {
        let fieldNames = presence.fields.map(\.name)
        let duplicateFields = Dictionary(grouping: fieldNames, by: { $0 })
          .filter { $0.value.count > 1 }
          .keys
        if !duplicateFields.isEmpty {
          throw SchemaValidationError.duplicateFieldNames(
            Array(duplicateFields),
            inEntity: "\(room.name).presence"
          )
        }
      }
    }
  }
}

/// Errors that can occur during schema validation
public enum SchemaValidationError: Error, LocalizedError {
  case duplicateEntityNames([String])
  case duplicateLinkNames([String])
  case duplicateRoomNames([String])
  case duplicateTopicNames([String], inRoom: String)
  case duplicateFieldNames([String], inEntity: String)
  case unknownEntity(String, inLink: String)
  case reservedFieldName(String, inEntity: String)
  
  public var errorDescription: String? {
    switch self {
    case .duplicateEntityNames(let names):
      return "Duplicate entity names: \(names.joined(separator: ", "))"
    case .duplicateLinkNames(let names):
      return "Duplicate link names: \(names.joined(separator: ", "))"
    case .duplicateRoomNames(let names):
      return "Duplicate room names: \(names.joined(separator: ", "))"
    case .duplicateTopicNames(let names, let room):
      return "Duplicate topic names in room '\(room)': \(names.joined(separator: ", "))"
    case .duplicateFieldNames(let names, let entity):
      return "Duplicate field names in '\(entity)': \(names.joined(separator: ", "))"
    case .unknownEntity(let name, let link):
      return "Link '\(link)' references unknown entity '\(name)'"
    case .reservedFieldName(let name, let entity):
      return "Field name '\(name)' is reserved in entity '\(entity)'. The 'id' field is implicit."
    }
  }
}

