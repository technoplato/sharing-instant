// TypeScriptSchemaParser.swift
// InstantSchemaCodegen
//
// Parses InstantDB TypeScript schema files into SchemaIR.
// Uses regex-based parsing for robustness with real-world TypeScript files.

import Foundation

// MARK: - TypeScript Schema Parser

/// Parses InstantDB TypeScript schema files into SchemaIR.
///
/// This parser handles real-world TypeScript files with:
/// - JSDoc comments (/** ... */)
/// - Single-line comments (// ...)
/// - All InstantDB field types
/// - Optional modifiers
/// - Link definitions
///
/// ## Usage
///
/// ```swift
/// let parser = TypeScriptSchemaParser()
/// let schema = try parser.parse(fileAt: "instant.schema.ts")
/// ```
public struct TypeScriptSchemaParser {
  
  public init() {}
  
  /// Parse a TypeScript schema file
  public func parse(fileAt path: String) throws -> SchemaIR {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    return try parse(content: content, sourceFile: path)
  }
  
  /// Parse TypeScript schema content
  public func parse(content: String, sourceFile: String? = nil) throws -> SchemaIR {
    var schema = SchemaIR(sourceFile: sourceFile)
    
    // Extract the schema block
    guard let schemaBlock = extractSchemaBlock(from: content) else {
      throw TypeScriptParseError.noSchemaFound
    }
    
    // Parse entities
    if let entitiesBlock = extractBlock(named: "entities", from: schemaBlock) {
      schema.entities = try parseEntities(from: entitiesBlock, fullContent: content)
    }
    
    // Parse links
    if let linksBlock = extractBlock(named: "links", from: schemaBlock) {
      schema.links = try parseLinks(from: linksBlock, fullContent: content)
    }
    
    // Validate the parsed schema
    try schema.validate()
    
    return schema
  }
  
  // MARK: - Schema Block Extraction
  
  private func extractSchemaBlock(from content: String) -> String? {
    // Look for i.schema({ ... })
    let patterns = [
      #"i\.schema\s*\(\s*\{"#,
      #"schema\s*\(\s*\{"#
    ]
    
    for pattern in patterns {
      if let range = content.range(of: pattern, options: .regularExpression) {
        guard let braceStart = content.range(of: "{", range: range.lowerBound..<content.endIndex) else {
          continue
        }
        
        if let endIndex = findMatchingBrace(in: content, from: braceStart.lowerBound) {
          return String(content[braceStart.lowerBound...endIndex])
        }
      }
    }
    
    return nil
  }
  
  private func extractBlock(named name: String, from content: String) -> String? {
    let pattern = #"\b"# + name + #"\s*:\s*\{"#
    
    guard let range = content.range(of: pattern, options: .regularExpression) else {
      return nil
    }
    
    guard let braceStart = content.range(of: "{", range: range.lowerBound..<content.endIndex) else {
      return nil
    }
    
    guard let endIndex = findMatchingBrace(in: content, from: braceStart.lowerBound) else {
      return nil
    }
    
    return String(content[braceStart.lowerBound...endIndex])
  }
  
  private func findMatchingBrace(in content: String, from startIndex: String.Index) -> String.Index? {
    var depth = 0
    var index = startIndex
    
    while index < content.endIndex {
      let char = content[index]
      if char == "{" {
        depth += 1
      } else if char == "}" {
        depth -= 1
        if depth == 0 {
          return index
        }
      }
      index = content.index(after: index)
    }
    
    return nil
  }
  
  // MARK: - Entity Parsing
  
  private func parseEntities(from block: String, fullContent: String) throws -> [EntityIR] {
    var entities: [EntityIR] = []
    
    // Pattern that handles entity names with $ prefix (like $users, $files)
    let entityPattern = "([\\$a-zA-Z_][\\$a-zA-Z0-9_]*)\\s*:\\s*i\\.entity\\s*\\(\\s*\\{"
    let regex = try NSRegularExpression(pattern: entityPattern)
    let nsBlock = block as NSString
    let matches = regex.matches(in: block, range: NSRange(location: 0, length: nsBlock.length))
    
    for match in matches {
      guard match.numberOfRanges >= 2 else { continue }
      
      let nameRange = match.range(at: 1)
      let entityName = nsBlock.substring(with: nameRange)
      
      let entityStart = match.range.location + match.range.length - 1
      let blockStartIndex = block.index(block.startIndex, offsetBy: entityStart)
      
      guard let blockEndIndex = findMatchingBrace(in: block, from: blockStartIndex) else {
        throw TypeScriptParseError.unmatchedBrace(entityName)
      }
      
      let entityBlock = String(block[blockStartIndex...blockEndIndex])
      let documentation = extractDocumentation(before: entityName, in: fullContent)
      let fields = try parseFields(from: entityBlock, entityName: entityName, fullContent: fullContent)
      
      entities.append(EntityIR(
        name: entityName,
        fields: fields,
        documentation: documentation
      ))
    }
    
    return entities
  }
  
  // MARK: - Field Parsing
  
  private func parseFields(from block: String, entityName: String, fullContent: String) throws -> [FieldIR] {
    var fields: [FieldIR] = []
    
    let fieldPattern = #"(\w+)\s*:\s*i\.(\w+)\s*\(\s*\)(\s*\.optional\s*\(\s*\))?"#
    let regex = try NSRegularExpression(pattern: fieldPattern)
    let nsBlock = block as NSString
    let matches = regex.matches(in: block, range: NSRange(location: 0, length: nsBlock.length))
    
    for match in matches {
      guard match.numberOfRanges >= 3 else { continue }
      
      let nameRange = match.range(at: 1)
      let typeRange = match.range(at: 2)
      let fieldName = nsBlock.substring(with: nameRange)
      let typeName = nsBlock.substring(with: typeRange)
      
      let isOptional = match.numberOfRanges > 3 && match.range(at: 3).location != NSNotFound
      
      guard let fieldType = mapTypeScriptType(typeName) else {
        throw TypeScriptParseError.unknownFieldType(typeName, field: fieldName, entity: entityName)
      }
      
      let documentation = extractFieldDocumentation(fieldName: fieldName, in: block)
      
      fields.append(FieldIR(
        name: fieldName,
        type: fieldType,
        isOptional: isOptional,
        documentation: documentation
      ))
    }
    
    return fields
  }
  
  private func mapTypeScriptType(_ typeName: String) -> FieldType? {
    switch typeName.lowercased() {
    case "string": return .string
    case "number": return .number
    case "boolean", "bool": return .boolean
    case "date": return .date
    case "json", "any": return .json
    default: return nil
    }
  }
  
  // MARK: - Link Parsing
  
  private func parseLinks(from block: String, fullContent: String) throws -> [LinkIR] {
    var links: [LinkIR] = []
    
    // Pattern that handles link names with $ prefix (like $usersLinkedPrimaryUser)
    // Using [\\$\\w]+ to match $ and word characters
    let linkPattern = "([\\$a-zA-Z_][\\$a-zA-Z0-9_]*)\\s*:\\s*\\{"
    let regex = try NSRegularExpression(pattern: linkPattern)
    let nsBlock = block as NSString
    let matches = regex.matches(in: block, range: NSRange(location: 0, length: nsBlock.length))
    
    for match in matches {
      guard match.numberOfRanges >= 2 else { continue }
      
      let nameRange = match.range(at: 1)
      let linkName = nsBlock.substring(with: nameRange)
      
      // Skip known non-link keys
      let skipKeys = ["forward", "reverse", "on", "has", "label", "onDelete"]
      if skipKeys.contains(linkName) { continue }
      
      let linkStart = match.range.location + match.range.length - 1
      let blockStartIndex = block.index(block.startIndex, offsetBy: linkStart)
      
      guard let blockEndIndex = findMatchingBrace(in: block, from: blockStartIndex) else {
        throw TypeScriptParseError.unmatchedBrace(linkName)
      }
      
      let linkBlock = String(block[blockStartIndex...blockEndIndex])
      
      guard let forward = try parseLinkSide(named: "forward", from: linkBlock) else {
        throw TypeScriptParseError.missingLinkSide("forward", link: linkName)
      }
      
      guard let reverse = try parseLinkSide(named: "reverse", from: linkBlock) else {
        throw TypeScriptParseError.missingLinkSide("reverse", link: linkName)
      }
      
      let documentation = extractDocumentation(before: linkName, in: fullContent)
      
      links.append(LinkIR(
        name: linkName,
        forward: forward,
        reverse: reverse,
        documentation: documentation
      ))
    }
    
    return links
  }
  
  private func parseLinkSide(named name: String, from block: String) throws -> LinkSide? {
    // Pattern that handles entity names with $ prefix and additional fields like onDelete
    // Matches: forward: { on: "$users", has: "one", label: "linkedPrimaryUser", onDelete: "cascade" }
    let pattern = name + "\\s*:\\s*\\{\\s*on\\s*:\\s*\"([\\$a-zA-Z_][\\$a-zA-Z0-9_]*)\"\\s*,\\s*has\\s*:\\s*\"(\\w+)\"\\s*,\\s*label\\s*:\\s*\"(\\w+)\""
    
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: block, range: NSRange(location: 0, length: block.utf16.count)),
          match.numberOfRanges >= 4 else {
      return nil
    }
    
    let nsBlock = block as NSString
    let entityName = nsBlock.substring(with: match.range(at: 1))
    let cardinalityStr = nsBlock.substring(with: match.range(at: 2))
    let label = nsBlock.substring(with: match.range(at: 3))
    
    guard let cardinality = Cardinality(rawValue: cardinalityStr) else {
      throw TypeScriptParseError.invalidCardinality(cardinalityStr)
    }
    
    return LinkSide(
      entityName: entityName,
      cardinality: cardinality,
      label: label
    )
  }
  
  // MARK: - Documentation Extraction
  
  private func extractDocumentation(before identifier: String, in content: String) -> String? {
    let patterns = [
      #"/\*\*([^*]|\*(?!/))*\*/\s*"# + identifier,
      #"(///[^\n]*\n)+\s*"# + identifier
    ]
    
    for pattern in patterns {
      if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
         let match = regex.firstMatch(in: content, range: NSRange(location: 0, length: content.utf16.count)) {
        let nsContent = content as NSString
        let commentText = nsContent.substring(with: match.range)
        return cleanDocumentation(commentText, identifier: identifier)
      }
    }
    
    return nil
  }
  
  private func extractFieldDocumentation(fieldName: String, in block: String) -> String? {
    let pattern = #"(?://[^\n]*|/\*[^*]*\*/)\s*\n?\s*"# + fieldName + #"\s*:"#
    
    if let regex = try? NSRegularExpression(pattern: pattern),
       let match = regex.firstMatch(in: block, range: NSRange(location: 0, length: block.utf16.count)) {
      let nsBlock = block as NSString
      let commentText = nsBlock.substring(with: match.range)
      return cleanDocumentation(commentText, identifier: fieldName)
    }
    
    return nil
  }
  
  private func cleanDocumentation(_ raw: String, identifier: String) -> String {
    var result = raw
    
    if let range = result.range(of: identifier) {
      result = String(result[..<range.lowerBound])
    }
    
    result = result
      .replacingOccurrences(of: "/**", with: "")
      .replacingOccurrences(of: "*/", with: "")
      .replacingOccurrences(of: "///", with: "")
      .replacingOccurrences(of: "//", with: "")
      .replacingOccurrences(of: "*", with: "")
    
    result = result
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    
    return result.isEmpty ? "" : result
  }
}

// MARK: - TypeScript Schema Printer

/// Prints SchemaIR to TypeScript format with comment preservation.
public struct TypeScriptSchemaPrinter {
  
  public init() {}
  
  /// Print SchemaIR to TypeScript format
  public func print(_ schema: SchemaIR) -> String {
    var output = """
    import { i } from "@instantdb/core";
    
    const _schema = i.schema({
      entities: {
    
    """
    
    for (index, entity) in schema.entities.enumerated() {
      if let doc = entity.documentation {
        output += formatJSDocComment(doc, indent: "    ")
      }
      
      output += "    \(entity.name): i.entity({\n"
      
      for (fieldIndex, field) in entity.fields.enumerated() {
        if let doc = field.documentation, !doc.isEmpty {
          output += formatJSDocComment(doc, indent: "      ")
        }
        
        let optional = field.isOptional ? ".optional()" : ""
        let comma = fieldIndex < entity.fields.count - 1 ? "," : ""
        output += "      \(field.name): \(field.type.instantDBBuilder)\(optional)\(comma)\n"
      }
      
      let entityComma = index < schema.entities.count - 1 ? "," : ""
      output += "    })\(entityComma)\n"
    }
    
    output += "  },\n"
    
    if !schema.links.isEmpty {
      output += "  links: {\n"
      
      for (index, link) in schema.links.enumerated() {
        if let doc = link.documentation, !doc.isEmpty {
          output += formatJSDocComment(doc, indent: "    ")
        }
        
        output += """
            \(link.name): {
              forward: { on: "\(link.forward.entityName)", has: "\(link.forward.cardinality.rawValue)", label: "\(link.forward.label)" },
              reverse: { on: "\(link.reverse.entityName)", has: "\(link.reverse.cardinality.rawValue)", label: "\(link.reverse.label)" }
            }
        """
        
        if index < schema.links.count - 1 {
          output += ","
        }
        output += "\n"
      }
      
      output += "  }\n"
    }
    
    output += """
    });
    
    export type Schema = typeof _schema;
    
    """
    
    return output
  }
  
  private func formatJSDocComment(_ text: String, indent: String) -> String {
    let lines = text.components(separatedBy: .newlines)
    if lines.count == 1 {
      return "\(indent)/** \(lines[0]) */\n"
    } else {
      var output = "\(indent)/**\n"
      for line in lines {
        output += "\(indent) * \(line)\n"
      }
      output += "\(indent) */\n"
      return output
    }
  }
}

// MARK: - Convenience

/// Combined parser and printer for bidirectional schema conversion
public struct CommentPreservingSchemaParser {
  private let parser = TypeScriptSchemaParser()
  private let printer = TypeScriptSchemaPrinter()
  
  public init() {}
  
  public func parse(_ content: String, sourceFile: String? = nil) throws -> SchemaIR {
    try parser.parse(content: content, sourceFile: sourceFile)
  }
  
  public func print(_ schema: SchemaIR) throws -> String {
    printer.print(schema)
  }
}

// MARK: - Parse Errors

public enum TypeScriptParseError: Error, LocalizedError {
  case noSchemaFound
  case unmatchedBrace(String)
  case unknownFieldType(String, field: String, entity: String)
  case missingLinkSide(String, link: String)
  case invalidCardinality(String)
  
  public var errorDescription: String? {
    switch self {
    case .noSchemaFound:
      return "No i.schema({ ... }) block found in file"
    case .unmatchedBrace(let context):
      return "Unmatched brace in '\(context)'"
    case .unknownFieldType(let type, let field, let entity):
      return "Unknown field type 'i.\(type)()' for field '\(field)' in entity '\(entity)'"
    case .missingLinkSide(let side, let link):
      return "Missing '\(side)' definition in link '\(link)'"
    case .invalidCardinality(let value):
      return "Invalid cardinality '\(value)'. Expected 'one' or 'many'"
    }
  }
}
