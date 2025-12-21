// ParserErrors.swift
// InstantSchemaCodegen
//
// ═══════════════════════════════════════════════════════════════════════════════
// DETAILED PARSER ERROR TYPES
// ═══════════════════════════════════════════════════════════════════════════════
//
// This file contains error types that provide rich, actionable error messages
// for schema parsing failures. Each error includes:
//
// - Line and column numbers
// - Context showing the problematic code
// - Suggestions for fixing common mistakes
//
// ## Design Philosophy
//
// Error messages should answer three questions:
// 1. WHAT went wrong?
// 2. WHERE did it happen? (line, column, context)
// 3. HOW can it be fixed? (suggestions)
//
// ## Example Error Output
//
// ```
// ════════════════════════════════════════════════════════════════
// PARSE ERROR at line 15, column 23
// ════════════════════════════════════════════════════════════════
//
// Unknown field type 'i.text()'
//
// Context:
//   13 |   todos: i.entity({
//   14 |     title: i.string(),
//   15 |     description: i.text(),  // <-- ERROR HERE
//   16 |     done: i.boolean(),
//   17 |   }),
//
// Suggestion: Did you mean 'i.string()'? InstantDB supports:
//   - i.string()
//   - i.number()
//   - i.boolean()
//   - i.date()
//   - i.json()
// ════════════════════════════════════════════════════════════════
// ```

import Foundation

// MARK: - Source Location

/// Represents a position in source code.
///
/// Used to provide precise error locations.
public struct SourceLocation: Sendable, Equatable {
  /// 1-based line number
  public let line: Int
  
  /// 1-based column number
  public let column: Int
  
  /// Byte offset from start of file
  public let offset: Int
  
  public init(line: Int, column: Int, offset: Int) {
    self.line = line
    self.column = column
    self.offset = offset
  }
  
  /// Create a SourceLocation from a string index and content.
  public static func from(index: String.Index, in content: String) -> SourceLocation {
    let prefix = content[..<index]
    let lines = prefix.components(separatedBy: .newlines)
    let line = lines.count
    let column = (lines.last?.count ?? 0) + 1
    let offset = content.distance(from: content.startIndex, to: index)
    return SourceLocation(line: line, column: column, offset: offset)
  }
}

// MARK: - Detailed Parse Error

/// A detailed parse error with location, context, and suggestions.
///
/// ## Usage
///
/// ```swift
/// throw DetailedParseError(
///   message: "Unknown field type 'i.text()'",
///   location: SourceLocation(line: 15, column: 23, offset: 456),
///   context: extractContext(around: 456, in: content),
///   suggestion: "Did you mean 'i.string()'?"
/// )
/// ```
public struct DetailedParseError: Error, LocalizedError, Sendable {
  /// Short description of what went wrong
  public let message: String
  
  /// Where the error occurred
  public let location: SourceLocation?
  
  /// Lines of source code around the error
  public let context: String?
  
  /// Suggestion for how to fix the error
  public let suggestion: String?
  
  /// Source file path (if known)
  public let sourceFile: String?
  
  public init(
    message: String,
    location: SourceLocation? = nil,
    context: String? = nil,
    suggestion: String? = nil,
    sourceFile: String? = nil
  ) {
    self.message = message
    self.location = location
    self.context = context
    self.suggestion = suggestion
    self.sourceFile = sourceFile
  }
  
  public var errorDescription: String? {
    var output = """
    ════════════════════════════════════════════════════════════════
    """
    
    // Header with location
    if let loc = location {
      output += "\nPARSE ERROR at line \(loc.line), column \(loc.column)"
    } else {
      output += "\nPARSE ERROR"
    }
    
    if let file = sourceFile {
      output += " in '\(file)'"
    }
    
    output += """
    
    ════════════════════════════════════════════════════════════════
    
    \(message)
    """
    
    // Context
    if let ctx = context {
      output += """
      
      
      Context:
      \(ctx)
      """
    }
    
    // Suggestion
    if let sug = suggestion {
      output += """
      
      
      Suggestion: \(sug)
      """
    }
    
    output += """
    
    ════════════════════════════════════════════════════════════════
    """
    
    return output
  }
}

// MARK: - Context Extraction

/// Extract context lines around an error location.
///
/// ## Parameters
///
/// - offset: Byte offset of the error in the content
/// - content: The full source content
/// - radius: Number of lines to show before and after (default: 2)
///
/// ## Returns
///
/// A formatted string showing line numbers and content, with an arrow
/// pointing to the error line.
///
/// ## Example Output
///
/// ```
///   13 |   todos: i.entity({
///   14 |     title: i.string(),
///   15 |     description: i.text(),  // <-- ERROR HERE
///   16 |     done: i.boolean(),
///   17 |   }),
/// ```
public func extractContext(around offset: Int, in content: String, radius: Int = 2) -> String {
  let lines = content.components(separatedBy: .newlines)
  
  // Find the line containing the offset
  var currentOffset = 0
  var errorLine = 0
  for (index, line) in lines.enumerated() {
    let lineLength = line.count + 1 // +1 for newline
    if currentOffset + lineLength > offset {
      errorLine = index
      break
    }
    currentOffset += lineLength
  }
  
  // Calculate range of lines to show
  let startLine = max(0, errorLine - radius)
  let endLine = min(lines.count - 1, errorLine + radius)
  
  // Format output
  var output: [String] = []
  let maxLineNum = endLine + 1
  let lineNumWidth = String(maxLineNum).count
  
  for lineIndex in startLine...endLine {
    let lineNum = String(lineIndex + 1).padding(toLength: lineNumWidth, withPad: " ", startingAt: 0)
    let marker = lineIndex == errorLine ? " // <-- ERROR HERE" : ""
    output.append("  \(lineNum) | \(lines[lineIndex])\(marker)")
  }
  
  return output.joined(separator: "\n")
}

// MARK: - Common Error Factories

/// Factory functions for creating common parse errors with good defaults.
public enum ParseErrors {
  
  /// Error for unknown field type
  public static func unknownFieldType(
    _ typeName: String,
    at location: SourceLocation? = nil,
    in content: String? = nil,
    sourceFile: String? = nil
  ) -> DetailedParseError {
    let context = location.flatMap { loc in
      content.map { extractContext(around: loc.offset, in: $0) }
    }
    
    return DetailedParseError(
      message: "Unknown field type 'i.\(typeName)()'",
      location: location,
      context: context,
      suggestion: """
      InstantDB supports these field types:
        - i.string()  → String
        - i.number()  → Double
        - i.boolean() → Bool
        - i.date()    → Date
        - i.json()    → AnyCodable
      """,
      sourceFile: sourceFile
    )
  }
  
  /// Error for missing required property in a link
  public static func missingLinkProperty(
    _ property: String,
    linkName: String,
    at location: SourceLocation? = nil,
    in content: String? = nil,
    sourceFile: String? = nil
  ) -> DetailedParseError {
    let context = location.flatMap { loc in
      content.map { extractContext(around: loc.offset, in: $0) }
    }
    
    return DetailedParseError(
      message: "Missing '\(property)' in link '\(linkName)'",
      location: location,
      context: context,
      suggestion: """
      Links require both 'forward' and 'reverse' definitions:
      
        \(linkName): {
          forward: { on: "entityA", has: "many", label: "related" },
          reverse: { on: "entityB", has: "one", label: "parent" },
        }
      """,
      sourceFile: sourceFile
    )
  }
  
  /// Error for invalid cardinality value
  public static func invalidCardinality(
    _ value: String,
    at location: SourceLocation? = nil,
    in content: String? = nil,
    sourceFile: String? = nil
  ) -> DetailedParseError {
    let context = location.flatMap { loc in
      content.map { extractContext(around: loc.offset, in: $0) }
    }
    
    return DetailedParseError(
      message: "Invalid cardinality '\(value)'",
      location: location,
      context: context,
      suggestion: """
      Cardinality must be either:
        - "one"  → At most one related entity
        - "many" → Zero or more related entities
      """,
      sourceFile: sourceFile
    )
  }
  
  /// Error for unmatched brace
  public static func unmatchedBrace(
    opening: Bool,
    at location: SourceLocation? = nil,
    in content: String? = nil,
    sourceFile: String? = nil
  ) -> DetailedParseError {
    let context = location.flatMap { loc in
      content.map { extractContext(around: loc.offset, in: $0) }
    }
    
    let braceType = opening ? "opening '{'" : "closing '}'"
    
    return DetailedParseError(
      message: "Unmatched \(braceType)",
      location: location,
      context: context,
      suggestion: "Check that all braces are properly paired.",
      sourceFile: sourceFile
    )
  }
  
  /// Error for unexpected end of input
  public static func unexpectedEnd(
    expected: String,
    at location: SourceLocation? = nil,
    sourceFile: String? = nil
  ) -> DetailedParseError {
    DetailedParseError(
      message: "Unexpected end of input",
      location: location,
      context: nil,
      suggestion: "Expected \(expected) but reached end of file.",
      sourceFile: sourceFile
    )
  }
}




