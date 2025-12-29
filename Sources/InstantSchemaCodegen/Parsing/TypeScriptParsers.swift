// TypeScriptParsers.swift
// InstantSchemaCodegen
//
// ═══════════════════════════════════════════════════════════════════════════════
// PRIMITIVE PARSERS FOR TYPESCRIPT SCHEMA FILES
// ═══════════════════════════════════════════════════════════════════════════════
//
// This file contains the foundational "primitive" parsers that form the building
// blocks for parsing InstantDB TypeScript schema files. These parsers handle the
// lowest-level constructs: whitespace, comments, string literals, and identifiers.
//
// ## Architecture
//
// The parser is built in layers, from primitives up to the full schema:
//
// ```
// Layer 4: Full Schema Parser (SchemaParser.swift)
//     ↓ uses
// Layer 3: InstantDB Constructs (InstantDBParsers.swift)
//     ↓ uses
// Layer 2: TypeScript Literals (this file - string literals, objects, arrays)
//     ↓ uses
// Layer 1: Primitives (this file - whitespace, comments, identifiers)
// ```
//
// ## Why swift-parsing?
//
// The swift-parsing library from Point-Free provides:
// - **Composability**: Small parsers combine into larger ones
// - **Type Safety**: Compile-time guarantees about parser input/output
// - **Bidirectionality**: ParsePrint enables both parsing AND printing
// - **Performance**: Zero-allocation parsing with Substring
//
// ## Documentation Philosophy
//
// Each parser includes:
// 1. What it parses (with examples)
// 2. What it outputs (the Swift type)
// 3. Why it exists (use cases)
// 4. How it composes with other parsers
//
// ## Swift 6 Concurrency
//
// We use `@preconcurrency` and `nonisolated(unsafe)` to handle the fact that
// swift-parsing's parser types are not yet Sendable. This is safe because:
// 1. Parsers are immutable value types
// 2. We only use them for parsing (no shared mutable state)
// 3. Point-Free will likely add Sendable conformance in a future release
//
// ## Reference
//
// - swift-parsing docs: https://swiftpackageindex.com/pointfreeco/swift-parsing
// - TypeScript spec: https://www.typescriptlang.org/docs/handbook/2/everyday-types.html

import Foundation
@preconcurrency import Parsing

// MARK: - Unsupported Pattern Errors

/// Errors for unsupported TypeScript type patterns.
///
/// These errors are thrown when the parser encounters valid TypeScript
/// that we don't support in code generation.
public enum UnsupportedTypePatternError: Error, LocalizedError {
  /// Intersection types (TypeA & TypeB) are not supported
  case intersectionType
  
  /// Conditional types (T extends U ? X : Y) are not supported
  case conditionalType
  
  /// Mapped types ({ [K in keyof T]: ... }) are not supported
  case mappedType
  
  public var errorDescription: String? {
    switch self {
    case .intersectionType:
      return "Intersection types (TypeA & TypeB) are not supported. Use a single object type instead."
    case .conditionalType:
      return "Conditional types (T extends U ? X : Y) are not supported."
    case .mappedType:
      return "Mapped types ({ [K in keyof T]: ... }) are not supported."
    }
  }
}

// MARK: - Whitespace Parsers

/// Parses optional horizontal whitespace (spaces and tabs only, NOT newlines).
///
/// ## What It Parses
///
/// ```typescript
/// // Input: "   \t  "
/// // Output: () (Void - whitespace is discarded)
/// ```
///
/// ## Why This Exists
///
/// TypeScript allows arbitrary horizontal whitespace between tokens.
/// We need to skip it without consuming newlines (which may be significant
/// for single-line comment parsing).
///
/// ## Example Usage
///
/// ```swift
/// let parser = Parse {
///   "hello"
///   HorizontalWhitespace()
///   "world"
/// }
/// try parser.parse("hello   world") // succeeds
/// ```
public struct HorizontalWhitespace: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws {
    let prefix = input.prefix { $0 == " " || $0 == "\t" }
    input.removeFirst(prefix.count)
  }
}

/// Parses optional whitespace including newlines.
///
/// ## What It Parses
///
/// ```typescript
/// // Input: "   \n\t  \n"
/// // Output: () (Void - whitespace is discarded)
/// ```
///
/// ## Why This Exists
///
/// Between major schema elements (entities, links, fields), we allow
/// arbitrary whitespace including newlines. This parser consumes all of it.
///
/// ## Example Usage
///
/// ```swift
/// let parser = Parse {
///   "{"
///   OptionalWhitespace()
///   "field: value"
///   OptionalWhitespace()
///   "}"
/// }
/// try parser.parse("{\n  field: value\n}") // succeeds
/// ```
public struct OptionalWhitespace: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws {
    let prefix = input.prefix { $0.isWhitespace }
    input.removeFirst(prefix.count)
  }
}

/// Parses at least one whitespace character (including newlines).
///
/// ## What It Parses
///
/// ```typescript
/// // Input: " \n\t"
/// // Output: () (Void - whitespace is discarded)
/// // Fails on empty string or non-whitespace
/// ```
///
/// ## Why This Exists
///
/// Some positions REQUIRE whitespace separation. For example, between
/// keywords: `const _schema` requires space between `const` and `_schema`.
public struct RequiredWhitespace: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws {
    let prefix = input.prefix { $0.isWhitespace }
    guard !prefix.isEmpty else {
      struct ExpectedWhitespace: Error {}
      throw ExpectedWhitespace()
    }
    input.removeFirst(prefix.count)
  }
}

// MARK: - Comment Parsers

/// Parses a single-line JavaScript/TypeScript comment.
///
/// ## What It Parses
///
/// ```typescript
/// // This is a comment
/// // Another comment with special chars: @#$%
/// ```
///
/// ## Output
///
/// Returns the comment text WITHOUT the leading `//` and trailing newline.
///
/// ```swift
/// try SingleLineComment().parse("// Hello world\n")
/// // Returns: " Hello world"
/// ```
///
/// ## Why This Exists
///
/// TypeScript schemas often include documentation comments. We preserve
/// these so they can be included in generated Swift code.
///
/// ## Edge Cases
///
/// - Comment at end of file (no trailing newline): handled
/// - Empty comment (`//\n`): returns empty string
public struct SingleLineComment: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> String {
    guard input.hasPrefix("//") else {
      struct ExpectedComment: Error {}
      throw ExpectedComment()
    }
    input.removeFirst(2)
    
    let content = input.prefix { $0 != "\n" }
    input.removeFirst(content.count)
    
    // Consume optional newline
    if input.first == "\n" {
      input.removeFirst()
    }
    
    return String(content)
  }
}

/// Parses a multi-line JavaScript/TypeScript comment.
///
/// ## What It Parses
///
/// ```typescript
/// /* Single line */
/// /*
///  * Multi-line
///  * comment
///  */
/// ```
///
/// ## Output
///
/// Returns the comment text WITHOUT the `/*` and `*/` delimiters.
///
/// ```swift
/// try MultiLineComment().parse("/* Hello */")
/// // Returns: " Hello "
/// ```
///
/// ## Why This Exists
///
/// Multi-line comments are used for block documentation and temporarily
/// disabling code. We need to skip them when parsing but may want to
/// preserve them for documentation extraction.
public struct MultiLineComment: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> String {
    guard input.hasPrefix("/*") else {
      struct ExpectedMultiLineComment: Error {}
      throw ExpectedMultiLineComment()
    }
    input.removeFirst(2)
    
    guard let endRange = input.range(of: "*/") else {
      struct UnterminatedComment: Error {}
      throw UnterminatedComment()
    }
    
    let content = input[..<endRange.lowerBound]
    input = input[endRange.upperBound...]
    
    return String(content)
  }
}

/// Parses a JSDoc comment (/** ... */).
///
/// ## What It Parses
///
/// ```typescript
/// /** A todo item with title and completion status */
/// /**
///  * A user who can own todos.
///  * @see https://example.com/docs
///  */
/// ```
///
/// ## Output
///
/// Returns the cleaned comment text with leading `*` stripped from each line.
///
/// ```swift
/// try JSDocComment().parse("/** Hello world */")
/// // Returns: "Hello world"
/// ```
///
/// ## Why This Exists
///
/// JSDoc comments are the primary documentation mechanism in TypeScript.
/// InstantDB schemas use them to document entities and fields. We extract
/// these to include in generated Swift documentation comments.
///
/// ## Cleaning Rules
///
/// 1. Remove `/**` and `*/` delimiters
/// 2. Remove leading `*` from each line
/// 3. Trim leading/trailing whitespace from each line
/// 4. Join lines with newlines
public struct JSDocComment: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> String {
    guard input.hasPrefix("/**") else {
      struct ExpectedJSDoc: Error {}
      throw ExpectedJSDoc()
    }
    input.removeFirst(3)
    
    guard let endRange = input.range(of: "*/") else {
      struct UnterminatedJSDoc: Error {}
      throw UnterminatedJSDoc()
    }
    
    let content = input[..<endRange.lowerBound]
    input = input[endRange.upperBound...]
    
    return cleanJSDocComment(String(content))
  }
}

/// Cleans a JSDoc comment by removing leading asterisks and normalizing whitespace.
///
/// ## Input
///
/// ```
///  * A todo item with title and completion status
///  * @param id The unique identifier
/// ```
///
/// ## Output
///
/// ```
/// A todo item with title and completion status
/// @param id The unique identifier
/// ```
private func cleanJSDocComment(_ raw: String) -> String {
  raw
    .components(separatedBy: .newlines)
    .map { line in
      var trimmed = line.trimmingCharacters(in: .whitespaces)
      // Remove leading * (common in multi-line JSDoc)
      if trimmed.hasPrefix("*") {
        trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
      }
      return trimmed
    }
    .filter { !$0.isEmpty }
    .joined(separator: "\n")
}

/// Parses any comment (single-line, multi-line, or JSDoc).
///
/// ## What It Parses
///
/// ```typescript
/// // Single line
/// /* Multi-line */
/// /** JSDoc */
/// ```
///
/// ## Output
///
/// Returns the comment content as a string.
///
/// ## Why This Exists
///
/// When skipping over comments in the schema, we don't care which type
/// it is - we just need to consume it. This parser handles all three types.
public struct AnyComment: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> String {
    // Try JSDoc first (more specific than multi-line)
    if input.hasPrefix("/**") {
      return try JSDocComment().parse(&input)
    }
    // Then multi-line
    if input.hasPrefix("/*") {
      return try MultiLineComment().parse(&input)
    }
    // Then single-line
    if input.hasPrefix("//") {
      return try SingleLineComment().parse(&input)
    }
    
    struct ExpectedComment: Error {}
    throw ExpectedComment()
  }
}

/// Skips optional whitespace and comments.
///
/// ## What It Parses
///
/// ```typescript
///    // comment
///    /* another */
///    
/// ```
///
/// ## Output
///
/// Returns `()` (Void) - all content is discarded.
///
/// ## Why This Exists
///
/// This is the most common "skip" parser used between tokens. It handles
/// the common pattern of whitespace, optional comments, more whitespace.
///
/// ## Example Usage
///
/// ```swift
/// let parser = Parse {
///   "{"
///   SkipWhitespaceAndComments()
///   Identifier()
///   SkipWhitespaceAndComments()
///   "}"
/// }
/// ```
public struct SkipWhitespaceAndComments: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws {
    while true {
      // Skip whitespace
      let beforeWS = input
      try OptionalWhitespace().parse(&input)
      
      // Try to parse a comment
      if input.hasPrefix("//") || input.hasPrefix("/*") {
        _ = try AnyComment().parse(&input)
        continue
      }
      
      // If we consumed nothing, we're done
      if input.startIndex == beforeWS.startIndex {
        break
      }
    }
  }
}

// MARK: - String Literal Parsers

/// Parses a double-quoted string literal.
///
/// ## What It Parses
///
/// ```typescript
/// "hello world"
/// "with \"escaped\" quotes"
/// "multi\nline"
/// ```
///
/// ## Output
///
/// Returns the string content WITHOUT quotes.
///
/// ```swift
/// try DoubleQuotedString().parse("\"hello\"")
/// // Returns: "hello"
/// ```
///
/// ## Why This Exists
///
/// TypeScript schemas use double-quoted strings for:
/// - Entity names in links: `on: "users"`
/// - Cardinality values: `has: "many"`
/// - Labels: `label: "todos"`
///
/// ## Escape Handling
///
/// Handles basic escape sequences: `\"`, `\\`, `\n`, `\t`, `\r`
public struct DoubleQuotedString: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> String {
    guard input.first == "\"" else {
      struct ExpectedDoubleQuote: Error {}
      throw ExpectedDoubleQuote()
    }
    input.removeFirst()
    
    var result = ""
    while let char = input.first {
      if char == "\"" {
        input.removeFirst()
        return result
      } else if char == "\\" {
        input.removeFirst()
        guard let escaped = input.first else {
          struct UnterminatedString: Error {}
          throw UnterminatedString()
        }
        input.removeFirst()
        switch escaped {
        case "\"": result.append("\"")
        case "\\": result.append("\\")
        case "n": result.append("\n")
        case "t": result.append("\t")
        case "r": result.append("\r")
        default: result.append(escaped)
        }
      } else {
        result.append(char)
        input.removeFirst()
      }
    }
    
    struct UnterminatedString: Error {}
    throw UnterminatedString()
  }
}

/// Parses a single-quoted string literal.
///
/// ## What It Parses
///
/// ```typescript
/// 'hello world'
/// 'with \'escaped\' quotes'
/// ```
///
/// ## Output
///
/// Returns the string content WITHOUT quotes.
///
/// ## Why This Exists
///
/// TypeScript allows both single and double quotes for strings.
/// While InstantDB schemas typically use double quotes, we support
/// both for robustness.
public struct SingleQuotedString: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> String {
    guard input.first == "'" else {
      struct ExpectedSingleQuote: Error {}
      throw ExpectedSingleQuote()
    }
    input.removeFirst()
    
    var result = ""
    while let char = input.first {
      if char == "'" {
        input.removeFirst()
        return result
      } else if char == "\\" {
        input.removeFirst()
        guard let escaped = input.first else {
          struct UnterminatedString: Error {}
          throw UnterminatedString()
        }
        input.removeFirst()
        switch escaped {
        case "'": result.append("'")
        case "\\": result.append("\\")
        case "n": result.append("\n")
        case "t": result.append("\t")
        case "r": result.append("\r")
        default: result.append(escaped)
        }
      } else {
        result.append(char)
        input.removeFirst()
      }
    }
    
    struct UnterminatedString: Error {}
    throw UnterminatedString()
  }
}

/// Parses any string literal (single or double quoted).
///
/// ## What It Parses
///
/// ```typescript
/// "double quoted"
/// 'single quoted'
/// ```
///
/// ## Output
///
/// Returns the string content WITHOUT quotes.
///
/// ## Why This Exists
///
/// Convenience parser that accepts either quote style.
public struct StringLiteral: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> String {
    if input.first == "\"" {
      return try DoubleQuotedString().parse(&input)
    } else if input.first == "'" {
      return try SingleQuotedString().parse(&input)
    } else {
      struct ExpectedStringLiteral: Error {}
      throw ExpectedStringLiteral()
    }
  }
}

// MARK: - Identifier Parsers

/// Parses a JavaScript/TypeScript identifier.
///
/// ## What It Parses
///
/// Valid identifiers:
/// ```typescript
/// myVar
/// _private
/// $special
/// camelCase123
/// SCREAMING_CASE
/// ```
///
/// Invalid identifiers (will fail):
/// ```typescript
/// 123start    // Cannot start with digit
/// -dash       // Cannot start with hyphen
/// my-var      // Hyphens not allowed
/// ```
///
/// ## Output
///
/// Returns the identifier as a String.
///
/// ```swift
/// try Identifier().parse("myVariable")
/// // Returns: "myVariable"
/// ```
///
/// ## Why This Exists
///
/// Identifiers are used throughout TypeScript schemas:
/// - Entity names: `todos`, `users`
/// - Field names: `title`, `createdAt`
/// - Link names: `userTodos`
/// - Type names: `i.string`, `i.entity`
///
/// ## Grammar
///
/// ```
/// identifier = identifierStart identifierContinue*
/// identifierStart = [a-zA-Z_$]
/// identifierContinue = [a-zA-Z0-9_$]
/// ```
///
/// ## Note on $ Prefix
///
/// InstantDB uses `$` prefix for system entities (`$users`, `$files`).
/// This parser correctly handles the `$` as a valid identifier start.
public struct Identifier: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> String {
    guard let first = input.first,
          first.isLetter || first == "_" || first == "$" else {
      struct ExpectedIdentifier: Error {}
      throw ExpectedIdentifier()
    }
    
    var result = String(first)
    input.removeFirst()
    
    while let char = input.first,
          char.isLetter || char.isNumber || char == "_" || char == "$" {
      result.append(char)
      input.removeFirst()
    }
    
    return result
  }
}

// MARK: - Number Parsers

/// Parses a numeric literal (integer or floating point).
///
/// ## What It Parses
///
/// ```typescript
/// 42
/// 3.14
/// -17
/// 0.5
/// ```
///
/// ## Output
///
/// Returns the number as a Double.
///
/// ```swift
/// try NumberLiteral().parse("3.14")
/// // Returns: 3.14
/// ```
///
/// ## Why This Exists
///
/// Numbers appear in TypeScript schemas for default values and
/// configuration options. While InstantDB schemas don't typically
/// have numeric literals in the schema definition itself, we include
/// this for completeness and potential future use.
public struct NumberLiteral: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> Double {
    var numberStr = ""
    
    // Optional negative sign
    if input.first == "-" {
      numberStr.append("-")
      input.removeFirst()
    }
    
    // Integer part (required)
    guard let first = input.first, first.isNumber else {
      struct ExpectedNumber: Error {}
      throw ExpectedNumber()
    }
    
    while let char = input.first, char.isNumber {
      numberStr.append(char)
      input.removeFirst()
    }
    
    // Optional decimal part
    if input.first == "." {
      numberStr.append(".")
      input.removeFirst()
      
      while let char = input.first, char.isNumber {
        numberStr.append(char)
        input.removeFirst()
      }
    }
    
    guard let value = Double(numberStr) else {
      struct InvalidNumber: Error {}
      throw InvalidNumber()
    }
    
    return value
  }
}

// MARK: - Boolean Parsers

/// Parses a boolean literal.
///
/// ## What It Parses
///
/// ```typescript
/// true
/// false
/// ```
///
/// ## Output
///
/// Returns a Bool.
///
/// ```swift
/// try BooleanLiteral().parse("true")
/// // Returns: true
/// ```
///
/// ## Why This Exists
///
/// Boolean literals may appear in default values or configuration.
public struct BooleanLiteral: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> Bool {
    if input.hasPrefix("true") {
      input.removeFirst(4)
      return true
    } else if input.hasPrefix("false") {
      input.removeFirst(5)
      return false
    } else {
      struct ExpectedBoolean: Error {}
      throw ExpectedBoolean()
    }
  }
}

// MARK: - Punctuation Parsers

/// Parses a comma, optionally surrounded by whitespace.
///
/// ## What It Parses
///
/// ```typescript
/// ,
///  ,
/// , 
///  , 
/// ```
///
/// ## Output
///
/// Returns `()` (Void) - the comma is consumed but not returned.
///
/// ## Why This Exists
///
/// Commas separate elements in arrays and object properties.
/// This parser handles the common pattern of optional whitespace around commas.
public struct Comma: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws {
    try OptionalWhitespace().parse(&input)
    guard input.first == "," else {
      struct ExpectedComma: Error {}
      throw ExpectedComma()
    }
    input.removeFirst()
    try OptionalWhitespace().parse(&input)
  }
}

/// Parses a colon, optionally surrounded by whitespace.
///
/// ## What It Parses
///
/// ```typescript
/// :
///  :
/// : 
///  : 
/// ```
///
/// ## Output
///
/// Returns `()` (Void) - the colon is consumed but not returned.
///
/// ## Why This Exists
///
/// Colons separate property names from values in TypeScript objects.
public struct Colon: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws {
    try OptionalWhitespace().parse(&input)
    guard input.first == ":" else {
      struct ExpectedColon: Error {}
      throw ExpectedColon()
    }
    input.removeFirst()
    try OptionalWhitespace().parse(&input)
  }
}

// MARK: - Import Parser

/// Parses a TypeScript import declaration.
///
/// ## What It Parses
///
/// ```typescript
/// import { i } from "@instantdb/core";
/// import { TaskPriority, Word } from "./types";
/// import type { MyType } from "./my-types";
/// ```
///
/// ## Output
///
/// Returns an `ImportDeclaration` with the named imports and source path.
///
/// ```swift
/// try ImportParser().parse("import { A, B } from \"./types\";")
/// // Returns: ImportDeclaration(namedImports: ["A", "B"], fromPath: "./types")
/// ```
///
/// ## Why This Exists
///
/// Import declarations are needed to resolve type references.
/// When we see `i.string<MyType>()`, we need to know where MyType comes from.
public struct ImportParser: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> ImportDeclaration {
    try SkipWhitespaceAndComments().parse(&input)
    
    // Check for "import"
    guard input.hasPrefix("import") else {
      struct ExpectedImport: Error {}
      throw ExpectedImport()
    }
    input.removeFirst(6) // "import"
    
    try RequiredWhitespace().parse(&input)
    
    // Check for "type" (import type { ... })
    var isTypeOnly = false
    if input.hasPrefix("type") {
      isTypeOnly = true
      input.removeFirst(4)
      try RequiredWhitespace().parse(&input)
    }
    
    // Parse { A, B, C }
    guard input.first == "{" else {
      struct ExpectedOpenBrace: Error {}
      throw ExpectedOpenBrace()
    }
    input.removeFirst()
    
    var namedImports: [String] = []
    try SkipWhitespaceAndComments().parse(&input)
    
    while !input.hasPrefix("}") && !input.isEmpty {
      let name = try Identifier().parse(&input)
      namedImports.append(name)
      
      try SkipWhitespaceAndComments().parse(&input)
      
      // Optional comma
      if input.first == "," {
        input.removeFirst()
        try SkipWhitespaceAndComments().parse(&input)
      }
    }
    
    guard input.first == "}" else {
      struct ExpectedCloseBrace: Error {}
      throw ExpectedCloseBrace()
    }
    input.removeFirst()
    
    try RequiredWhitespace().parse(&input)
    
    // Parse "from"
    guard input.hasPrefix("from") else {
      struct ExpectedFrom: Error {}
      throw ExpectedFrom()
    }
    input.removeFirst(4)
    
    try RequiredWhitespace().parse(&input)
    
    // Parse the path string
    let fromPath = try StringLiteral().parse(&input)
    
    try SkipWhitespaceAndComments().parse(&input)
    
    // Optional semicolon
    if input.first == ";" {
      input.removeFirst()
    }
    
    return ImportDeclaration(
      namedImports: namedImports,
      fromPath: fromPath,
      isTypeOnly: isTypeOnly
    )
  }
}

// MARK: - Type Alias Parser

/// Parses a TypeScript type alias declaration.
///
/// ## What It Parses
///
/// ```typescript
/// type Status = "pending" | "active" | "completed";
/// export type MediaType = "audio" | "video" | "text";
/// type Word = { text: string, start: number, end: number };
/// ```
///
/// ## Output
///
/// Returns a `TypeAliasIR` with the type name and definition.
///
/// ```swift
/// try TypeAliasParser().parse("type Status = \"pending\" | \"active\";")
/// // Returns: TypeAliasIR(name: "Status", definition: .stringUnion(["pending", "active"]))
/// ```
///
/// ## Why This Exists
///
/// Type aliases define reusable types that can be referenced in the schema.
/// When we see `i.string<Status>()`, we need to resolve Status to its definition.
public struct TypeAliasParser: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> TypeAliasIR {
    try SkipWhitespaceAndComments().parse(&input)
    
    // Check for "export"
    var isExported = false
    if input.hasPrefix("export") {
      isExported = true
      input.removeFirst(6)
      try RequiredWhitespace().parse(&input)
    }
    
    // Check for "type"
    guard input.hasPrefix("type") else {
      struct ExpectedType: Error {}
      throw ExpectedType()
    }
    input.removeFirst(4)
    
    try RequiredWhitespace().parse(&input)
    
    // Parse the type name
    let name = try Identifier().parse(&input)
    
    try SkipWhitespaceAndComments().parse(&input)
    
    // Parse "="
    guard input.first == "=" else {
      struct ExpectedEquals: Error {}
      throw ExpectedEquals()
    }
    input.removeFirst()
    
    try SkipWhitespaceAndComments().parse(&input)
    
    // Parse the type definition
    let definition = try GenericTypeParser().parse(&input)
    
    try SkipWhitespaceAndComments().parse(&input)
    
    // Optional semicolon
    if input.first == ";" {
      input.removeFirst()
    }
    
    return TypeAliasIR(
      name: name,
      definition: definition,
      isExported: isExported
    )
  }
}

// MARK: - Generic Type Parser

/// Parses a generic type expression.
///
/// ## What It Parses
///
/// ```typescript
/// "pending" | "active" | "completed"  // String union
/// { text: string, start: number }     // Object type
/// Word[]                              // Array (bracket syntax)
/// Array<Word>                         // Array (generic syntax)
/// MyTypeAlias                         // Type reference
/// ```
///
/// ## Output
///
/// Returns a `GenericTypeIR` representing the parsed type.
///
/// ## Why This Exists
///
/// Generic types appear in two places:
/// 1. Type alias definitions: `type Status = "pending" | "active"`
/// 2. Field type parameters: `i.string<"pending" | "active">()`
public struct GenericTypeParser: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> GenericTypeIR {
    try SkipWhitespaceAndComments().parse(&input)
    
    // Check what kind of type this is
    let result: GenericTypeIR
    if input.first == "\"" || input.first == "'" {
      // String literal - start of a string union
      result = try parseStringUnion(&input)
    } else if input.first == "{" {
      // Object type
      result = try parseObjectType(&input)
    } else if input.hasPrefix("Array<") {
      // Array<T> syntax
      result = try parseArrayGenericSyntax(&input)
    } else {
      // Type reference (identifier) - could be followed by []
      let typeName = try Identifier().parse(&input)
      try SkipWhitespaceAndComments().parse(&input)
      
      // Check for array suffix []
      if input.hasPrefix("[]") {
        input.removeFirst(2)
        // This is an array of the referenced type
        result = .array(.unresolved(typeName))
      } else {
        // Plain type reference
        result = .unresolved(typeName)
      }
    }
    
    // Check for intersection type operator (&) - not supported
    try SkipWhitespaceAndComments().parse(&input)
    if input.first == "&" {
      throw UnsupportedTypePatternError.intersectionType
    }
    
    return result
  }
  
  /// Parse a string union: "a" | "b" | "c"
  private func parseStringUnion(_ input: inout Substring) throws -> GenericTypeIR {
    var cases: [String] = []
    
    // Parse first string literal
    let firstCase = try StringLiteral().parse(&input)
    cases.append(firstCase)
    
    try SkipWhitespaceAndComments().parse(&input)
    
    // Parse remaining cases separated by |
    while input.first == "|" {
      input.removeFirst()
      try SkipWhitespaceAndComments().parse(&input)
      
      let nextCase = try StringLiteral().parse(&input)
      cases.append(nextCase)
      
      try SkipWhitespaceAndComments().parse(&input)
    }
    
    return .stringUnion(cases)
  }
  
  /// Parse an object type: { field: type, ... }
  private func parseObjectType(_ input: inout Substring) throws -> GenericTypeIR {
    guard input.first == "{" else {
      struct ExpectedOpenBrace: Error {}
      throw ExpectedOpenBrace()
    }
    input.removeFirst()
    
    var fields: [ObjectFieldIR] = []
    try SkipWhitespaceAndComments().parse(&input)
    
    while !input.hasPrefix("}") && !input.isEmpty {
      let field = try parseObjectField(&input)
      fields.append(field)
      
      try SkipWhitespaceAndComments().parse(&input)
      
      // Optional comma or semicolon
      if input.first == "," || input.first == ";" {
        input.removeFirst()
        try SkipWhitespaceAndComments().parse(&input)
      }
    }
    
    guard input.first == "}" else {
      struct ExpectedCloseBrace: Error {}
      throw ExpectedCloseBrace()
    }
    input.removeFirst()
    
    // Check for array suffix []
    try SkipWhitespaceAndComments().parse(&input)
    if input.hasPrefix("[]") {
      input.removeFirst(2)
      return .array(.object(fields))
    }
    
    return .object(fields)
  }
  
  /// Parse a single field in an object type: fieldName: type or fieldName?: type
  private func parseObjectField(_ input: inout Substring) throws -> ObjectFieldIR {
    let name = try Identifier().parse(&input)
    
    try SkipWhitespaceAndComments().parse(&input)
    
    // Check for optional marker (?)
    var isOptional = false
    if input.first == "?" {
      isOptional = true
      input.removeFirst()
    }
    
    try Colon().parse(&input)
    
    // Parse the field type
    let (fieldType, genericType) = try parseFieldType(&input)
    
    return ObjectFieldIR(
      name: name,
      type: fieldType,
      isOptional: isOptional,
      genericType: genericType
    )
  }
  
  /// Parse a field type within an object: string, number, boolean, or nested type
  private func parseFieldType(_ input: inout Substring) throws -> (FieldType, GenericTypeIR?) {
    try SkipWhitespaceAndComments().parse(&input)
    
    // Check for nested object type
    if input.first == "{" {
      let objectType = try parseObjectType(&input)
      return (.json, objectType)
    }
    
    // Parse type name
    let typeName = try Identifier().parse(&input)
    
    try SkipWhitespaceAndComments().parse(&input)
    
    // Check for array suffix []
    if input.hasPrefix("[]") {
      input.removeFirst(2)
      let elementType = mapTypeScriptToFieldType(typeName)
      if elementType == .json {
        // Unknown type - treat as reference
        return (.json, .array(.unresolved(typeName)))
      } else {
        // Primitive array
        return (.json, .array(.object([ObjectFieldIR(name: "_element", type: elementType)])))
      }
    }
    
    // Map TypeScript type to FieldType
    let fieldType = mapTypeScriptToFieldType(typeName)
    
    // If it's an unknown type, it might be a reference
    if fieldType == .json && !["any", "object", "unknown"].contains(typeName.lowercased()) {
      return (.json, .unresolved(typeName))
    }
    
    return (fieldType, nil)
  }
  
  /// Map TypeScript type name to FieldType
  private func mapTypeScriptToFieldType(_ typeName: String) -> FieldType {
    switch typeName.lowercased() {
    case "string": return .string
    case "number": return .number
    case "boolean", "bool": return .boolean
    case "date": return .date
    default: return .json
    }
  }
  
  /// Parse Array<T> syntax
  private func parseArrayGenericSyntax(_ input: inout Substring) throws -> GenericTypeIR {
    guard input.hasPrefix("Array<") else {
      struct ExpectedArray: Error {}
      throw ExpectedArray()
    }
    input.removeFirst(6) // "Array<"
    
    try SkipWhitespaceAndComments().parse(&input)
    
    // Parse the element type
    let elementType = try parse(&input)
    
    try SkipWhitespaceAndComments().parse(&input)
    
    guard input.first == ">" else {
      struct ExpectedClosingAngleBracket: Error {}
      throw ExpectedClosingAngleBracket()
    }
    input.removeFirst()
    
    return .array(elementType)
  }
}

// MARK: - Generic Parameter Parser

/// Parses the generic type parameter from a field type: <T> in i.string<T>()
///
/// ## What It Parses
///
/// ```typescript
/// <"pending" | "active">
/// <{ text: string, start: number }>
/// <Word[]>
/// <Array<Word>>
/// ```
///
/// ## Output
///
/// Returns a `GenericTypeIR` or nil if no generic parameter.
///
/// ## Why This Exists
///
/// Field types can have optional generic parameters that provide more
/// specific type information than the base type.
public struct GenericParameterParser: Parser {
  public init() {}
  
  public func parse(_ input: inout Substring) throws -> GenericTypeIR? {
    try SkipWhitespaceAndComments().parse(&input)
    
    // Check for opening <
    guard input.first == "<" else {
      return nil
    }
    input.removeFirst()
    
    try SkipWhitespaceAndComments().parse(&input)
    
    // Parse the type inside
    let genericType = try GenericTypeParser().parse(&input)
    
    try SkipWhitespaceAndComments().parse(&input)
    
    // Expect closing >
    guard input.first == ">" else {
      struct ExpectedClosingAngleBracket: Error {}
      throw ExpectedClosingAngleBracket()
    }
    input.removeFirst()
    
    return genericType
  }
}

