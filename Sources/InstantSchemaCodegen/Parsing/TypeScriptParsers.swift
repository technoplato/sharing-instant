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

